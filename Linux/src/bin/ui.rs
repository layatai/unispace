use anyhow::Result;
use unispace_linux::{config::Configuration, host, pairing::PendingPairing, service};

#[derive(serde::Serialize)]
struct UiState {
    paired: bool,
    workspace_name: String,
    host_address: String,
}

impl UiState {
    fn unpaired() -> Self {
        Self {
            paired: false,
            workspace_name: String::new(),
            host_address: String::new(),
        }
    }
}

fn summarize(configuration: &Configuration) -> UiState {
    UiState {
        paired: true,
        workspace_name: configuration.workspace.name.clone(),
        host_address: configuration.host_address.clone(),
    }
}

#[derive(serde::Serialize)]
struct Offer {
    peer_name: String,
    code: String,
}

#[derive(serde::Serialize)]
struct PairingResult {
    state: UiState,
    warning: Option<String>,
}

type PendingSlot = tokio::sync::Mutex<Option<PendingPairing>>;

#[tauri::command]
async fn state() -> UiState {
    match Configuration::load() {
        Ok(configuration) => summarize(&configuration),
        Err(_) => UiState::unpaired(),
    }
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
        state: summarize(&configuration),
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

fn main() -> Result<()> {
    let address = Configuration::load()
        .map(|configuration| configuration.host_address)
        .unwrap_or_default();
    tauri::Builder::default()
        .manage(tokio::sync::Mutex::new(Option::<PendingPairing>::None))
        .manage(tokio::sync::Mutex::new(address))
        .invoke_handler(tauri::generate_handler![
            state,
            begin_pairing,
            confirm_pairing,
            cancel_pairing,
            unpair
        ])
        .run(tauri::generate_context!())
        .map_err(|error| anyhow::anyhow!("tauri: {error}"))?;
    Ok(())
}
