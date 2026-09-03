use anyhow::Result;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;
use tauri::Emitter;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixStream;
use unispace_linux::{
    config::Configuration, host, observe, pairing::PendingPairing, service,
};

#[derive(serde::Serialize)]
struct Offer {
    peer_name: String,
    code: String,
}

#[derive(serde::Serialize)]
struct PairingResult {
    state: observe::ReceiverSnapshot,
    warning: Option<String>,
}

type PendingSlot = tokio::sync::Mutex<Option<PendingPairing>>;

#[tauri::command]
async fn state() -> observe::ReceiverSnapshot {
    match tokio::time::timeout(Duration::from_millis(150), read_live_snapshot()).await {
        Ok(Ok(snapshot)) => snapshot,
        _ => observe::fallback_snapshot(),
    }
}

async fn read_live_snapshot() -> Result<observe::ReceiverSnapshot, String> {
    let stream = UnixStream::connect(observe::socket_path())
        .await
        .map_err(|error| error.to_string())?;
    let mut lines = BufReader::new(stream).lines();
    let line = lines
        .next_line()
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "empty status socket".to_string())?;
    serde_json::from_str(&line).map_err(|error| error.to_string())
}

#[tauri::command]
async fn begin_pairing(
    address: String,
    pending: tauri::State<'_, PendingSlot>,
    target: tauri::State<'_, tokio::sync::Mutex<String>>,
) -> Result<Offer, String> {
    let descriptor = host::local_descriptor();
    let started = PendingPairing::begin(&address, &descriptor)
        .await
        .map_err(|error| error.to_string())?;
    let offer = Offer {
        peer_name: started.peer_name.clone(),
        code: started.code.clone(),
    };
    *target.lock().await = address;
    *pending.lock().await = Some(started);
    Ok(offer)
}

#[tauri::command]
async fn confirm_pairing(
    pending: tauri::State<'_, PendingSlot>,
    target: tauri::State<'_, tokio::sync::Mutex<String>>,
) -> Result<PairingResult, String> {
    let Some(started) = pending.lock().await.take() else {
        return Err("No pairing in progress".into());
    };
    let address = target.lock().await.clone();
    let configuration = started
        .confirm(address)
        .await
        .map_err(|error| error.to_string())?;
    let warning = service::start()
        .err()
        .map(|error| format!("Paired, but the receiver service did not start: {error}"));
    Ok(PairingResult {
        state: observe::ReceiverSnapshot::from_configuration(&configuration),
        warning,
    })
}

#[tauri::command]
async fn cancel_pairing(pending: tauri::State<'_, PendingSlot>) -> Result<(), String> {
    *pending.lock().await = None;
    Ok(())
}

#[tauri::command]
fn unpair() -> Result<(), String> {
    service::stop().map_err(|error| error.to_string())?;
    if let Ok(configuration) = Configuration::load() {
        configuration.remove().map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn start_service() -> Result<(), String> {
    service::start().map_err(|error| error.to_string())
}

#[tauri::command]
fn choose_files() -> Result<Vec<String>, String> {
    let paths = rfd::FileDialog::new()
        .set_title("Send Files")
        .pick_files()
        .unwrap_or_default();
    Ok(paths
        .into_iter()
        .map(|path| path.to_string_lossy().into_owned())
        .collect())
}

#[tauri::command]
async fn send_files(paths: Vec<String>) -> Result<(), String> {
    observe::send_files(paths.into_iter().map(PathBuf::from).collect())
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn open_folder(path: String) -> Result<(), String> {
    let folder = if path.is_empty() {
        let root = observe::transfers_root().map_err(|error| error.to_string())?;
        std::fs::create_dir_all(&root).map_err(|error| error.to_string())?;
        root
    } else {
        PathBuf::from(path)
    };
    Command::new("xdg-open")
        .arg(folder)
        .spawn()
        .map_err(|error| error.to_string())?;
    Ok(())
}

async fn pump_status(app: tauri::AppHandle) {
    loop {
        match UnixStream::connect(observe::socket_path()).await {
            Ok(stream) => {
                let mut lines = BufReader::new(stream).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if let Ok(snapshot) = serde_json::from_str::<observe::ReceiverSnapshot>(&line) {
                        let _ = app.emit("receiver-status", snapshot);
                    }
                }
            }
            Err(_) => {
                let _ = app.emit("receiver-status", observe::fallback_snapshot());
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }
    }
}

fn main() -> Result<()> {
    let address = Configuration::load()
        .map(|configuration| configuration.host_address)
        .unwrap_or_default();
    tauri::Builder::default()
        .manage(tokio::sync::Mutex::new(Option::<PendingPairing>::None))
        .manage(tokio::sync::Mutex::new(address))
        .setup(|app| {
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                pump_status(handle).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            state,
            begin_pairing,
            confirm_pairing,
            cancel_pairing,
            unpair,
            start_service,
            choose_files,
            send_files,
            open_folder
        ])
        .run(tauri::generate_context!())
        .map_err(|error| anyhow::anyhow!("tauri: {error}"))?;
    Ok(())
}
