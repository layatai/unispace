use anyhow::{Context, Result};
use std::{
    io::Write,
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};
use tauri::{Emitter, Manager, webview::PageLoadEvent};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixStream as TokioUnixStream;
use unispace_linux::{config::Configuration, host, observe, pairing::PendingPairing, service};

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

enum Instance {
    Primary(UnixListener),
    AlreadyRunning,
}

#[tauri::command]
fn ping() -> String {
    format!("pong {}", std::process::id())
}

/// Config-only snapshot. Does not touch the status socket — used to paint Home
/// immediately when this machine is already paired, even if live IPC is slow.
#[tauri::command]
fn local_state() -> observe::ReceiverSnapshot {
    observe::fallback_snapshot(None)
}

#[tauri::command]
async fn state() -> observe::ReceiverSnapshot {
    // Generous enough that an ordinarily busy socket does not produce a
    // fallback snapshot: a fallback reports "disconnected" with no transfers,
    // so a spurious one repaints the whole window.
    match tokio::time::timeout(Duration::from_millis(750), read_live_snapshot()).await {
        Ok(Ok(snapshot)) => snapshot,
        Ok(Err(error)) => observe::fallback_snapshot(Some(format!(
            "The receiver service is not reporting status ({error}); showing its last known state."
        ))),
        Err(_) => observe::fallback_snapshot(Some(
            "The receiver service did not answer in time; showing its last known state.".into(),
        )),
    }
}

async fn read_live_snapshot() -> Result<observe::ReceiverSnapshot, String> {
    let stream = TokioUnixStream::connect(observe::socket_path())
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
fn stop_service() -> Result<(), String> {
    service::stop().map_err(|error| error.to_string())
}

/// Recovers a degraded receiver: stops the systemd unit and any manually
/// launched daemon (e.g. one started before a relogin, whose process groups
/// lack `unispace`), then starts the service fresh from the current session.
#[tauri::command]
fn restart_receiver() -> Result<(), String> {
    service::stop().map_err(|error| error.to_string())?;
    let _ = Command::new("pkill")
        .args(["-x", "unispace-linux"])
        .status();
    std::thread::sleep(Duration::from_millis(600));
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

fn ui_socket_path() -> PathBuf {
    observe::socket_path().with_file_name("ui.sock")
}

fn notify_existing(path: &Path) -> bool {
    let Ok(mut stream) = UnixStream::connect(path) else {
        return false;
    };
    stream.write_all(b"focus\n").is_ok()
}

fn claim_instance() -> Result<Instance> {
    let path = ui_socket_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        let mut permissions = std::fs::metadata(parent)?.permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(parent, permissions)?;
    }
    if notify_existing(&path) {
        return Ok(Instance::AlreadyRunning);
    }
    let _ = std::fs::remove_file(&path);
    match UnixListener::bind(&path) {
        Ok(listener) => {
            let mut permissions = std::fs::metadata(&path)?.permissions();
            permissions.set_mode(0o600);
            std::fs::set_permissions(&path, permissions)?;
            listener.set_nonblocking(true)?;
            Ok(Instance::Primary(listener))
        }
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::AddrInUse | std::io::ErrorKind::AlreadyExists
            ) =>
        {
            if notify_existing(&path) {
                Ok(Instance::AlreadyRunning)
            } else {
                Err(error).context("claim UI instance socket")
            }
        }
        Err(error) => Err(error).context("claim UI instance socket"),
    }
}

fn focus_main(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        // Do not heal on every focus — set_resizable toggles steal clicks.
    }
}

/// Tao 0.35's Wayland CSD leaves minimize/maximize/close unresponsive until the
/// surface gets a fresh configure (tauri#13440 / #11856). On Omarchy/Hyprland
/// tiled windows, `set_size` is ignored — toggling resizable still forces one.
/// Call sparingly: each heal reconfigures the surface and drops in-flight clicks.
fn heal_wayland_chrome(window: &tauri::WebviewWindow) {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return;
    }
    let _ = window.set_resizable(false);
    let _ = window.set_resizable(true);
    if let Ok(size) = window.outer_size() {
        let nudged = tauri::PhysicalSize {
            width: size.width.saturating_add(1).max(2),
            height: size.height.max(1),
        };
        let _ = window.set_size(nudged);
        let _ = window.set_size(size);
    }
    #[cfg(target_os = "linux")]
    strip_wayland_minmax_buttons(window);
}

/// Tao's Wayland header hardcodes min/max buttons; Omarchy has no use for them.
#[cfg(target_os = "linux")]
fn strip_wayland_minmax_buttons(window: &tauri::WebviewWindow) {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return;
    }
    let window = window.clone();
    let _ = window.clone().run_on_main_thread(move || {
        use gtk::prelude::*;
        use std::sync::atomic::{AtomicBool, Ordering};
        static WATCHING: AtomicBool = AtomicBool::new(false);

        let Ok(gtk_window) = window.gtk_window() else {
            return;
        };
        let Some(titlebar) = gtk_window.titlebar() else {
            return;
        };
        set_close_only_layout(&titlebar);
        // One watcher only — a previous 500ms Continue timer was registered on
        // every heal/focus and kept the GTK main loop busy, making the UI dead.
        if WATCHING.swap(true, Ordering::SeqCst) {
            return;
        }
        let titlebar = titlebar.clone();
        gtk::glib::timeout_add_local(std::time::Duration::from_millis(1500), move || {
            set_close_only_layout(&titlebar);
            gtk::glib::ControlFlow::Continue
        });
    });
}

#[cfg(target_os = "linux")]
fn set_close_only_layout(widget: &gtk::Widget) {
    use gtk::prelude::*;
    if let Ok(header) = widget.clone().downcast::<gtk::HeaderBar>() {
        header.set_decoration_layout(Some(":close"));
        return;
    }
    if let Some(bin) = widget.downcast_ref::<gtk::Bin>() {
        if let Some(child) = bin.child() {
            set_close_only_layout(&child);
        }
        return;
    }
    if let Some(container) = widget.downcast_ref::<gtk::Container>() {
        for child in container.children() {
            set_close_only_layout(&child);
        }
    }
}

fn attach_wayland_chrome_heal(window: &tauri::WebviewWindow) {
    #[cfg(target_os = "linux")]
    strip_wayland_minmax_buttons(window);
    #[cfg(not(target_os = "linux"))]
    let _ = window;
    // Intentionally no Focused→heal hook: it made the window non-clickable.
}

/// Prefer Plasma's server-side decorations. Tiling compositors often have no
/// titlebar buttons of their own, so leave GTK CSD there and heal hit-testing.
fn prefer_server_decorations() {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() || std::env::var_os("GTK_CSD").is_some() {
        return;
    }
    let desktop = std::env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .to_ascii_lowercase();
    if desktop.contains("kde") || desktop.contains("plasma") {
        // SAFETY: called before GTK/Tauri initialization; no concurrent env readers.
        unsafe { std::env::set_var("GTK_CSD", "0") };
    }
}

async fn serve_focus(listener: tokio::net::UnixListener, app: tauri::AppHandle) {
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        let mut lines = BufReader::new(stream).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.trim() == "focus" {
                focus_main(&app);
            }
        }
    }
}

async fn pump_status(app: tauri::AppHandle) {
    loop {
        match TokioUnixStream::connect(observe::socket_path()).await {
            Ok(stream) => {
                let mut lines = BufReader::new(stream).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if let Ok(snapshot) = serde_json::from_str::<observe::ReceiverSnapshot>(&line) {
                        push_snapshot(&app, snapshot);
                    }
                }
            }
            Err(_) => {
                push_snapshot(
                    &app,
                    observe::fallback_snapshot(Some(
                        "The receiver service is not running; start it from Home.".into(),
                    )),
                );
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }
    }
}

fn push_snapshot(app: &tauri::AppHandle, snapshot: observe::ReceiverSnapshot) {
    // Emit and eval only when JSON changes. Duplicate status lines were
    // re-running apply, remounting the React tree, and eating clicks.
    let Ok(json) = serde_json::to_string(&snapshot) else {
        return;
    };
    {
        use std::sync::{Mutex, OnceLock};
        static LAST: OnceLock<Mutex<String>> = OnceLock::new();
        let last = LAST.get_or_init(|| Mutex::new(String::new()));
        let Ok(mut prev) = last.lock() else {
            return;
        };
        if *prev == json {
            return;
        }
        *prev = json.clone();
    }
    let _ = app.emit("receiver-status", &snapshot);
    if let Some(window) = app.get_webview_window("main") {
        let script = format!(
            "(function(){{try{{if(typeof window.__unispaceApply==='function')window.__unispaceApply({json});}}catch(e){{}}}})();"
        );
        let _ = window.eval(script);
    }
}

fn main() -> Result<()> {
    prefer_server_decorations();

    let listener = match claim_instance()? {
        Instance::AlreadyRunning => return Ok(()),
        Instance::Primary(listener) => listener,
    };

    let address = Configuration::load()
        .map(|configuration| configuration.host_address)
        .unwrap_or_default();
    tauri::Builder::default()
        .manage(tokio::sync::Mutex::new(Option::<PendingPairing>::None))
        .manage(tokio::sync::Mutex::new(address))
        .on_page_load(|webview, payload| {
            if payload.event() != PageLoadEvent::Finished {
                return;
            }
            // Push config state into the page without invoke() — webkit2gtk IPC
            // has been unreliable here, and setup emit races ahead of listen().
            let snapshot = observe::fallback_snapshot(None);
            let Ok(json) = serde_json::to_string(&snapshot) else {
                return;
            };
            let direct = format!(
                "(function(){{try{{\
                  var s={json};\
                  window.__unispaceBoot=s;\
                  if(typeof window.__unispaceApply==='function')window.__unispaceApply(s);\
                }}catch(e){{}}}})();"
            );
            let _ = webview.eval(direct);
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            let focus_handle = app.handle().clone();
            let heal_handle = app.handle().clone();
            if let Some(window) = app.get_webview_window("main") {
                attach_wayland_chrome_heal(&window);
            }
            tauri::async_runtime::spawn(async move {
                pump_status(handle).await;
            });
            tauri::async_runtime::spawn(async move {
                let listener = match tokio::net::UnixListener::from_std(listener) {
                    Ok(listener) => listener,
                    Err(error) => {
                        tracing::warn!(%error, "UI instance socket unavailable");
                        return;
                    }
                };
                serve_focus(listener, focus_handle).await;
            });
            // Single delayed heal after map — not a burst that fights input.
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_millis(250)).await;
                if let Some(window) = heal_handle.get_webview_window("main") {
                    heal_wayland_chrome(&window);
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            ping,
            local_state,
            state,
            begin_pairing,
            confirm_pairing,
            cancel_pairing,
            unpair,
            start_service,
            stop_service,
            restart_receiver,
            choose_files,
            send_files,
            open_folder
        ])
        .run(tauri::generate_context!())
        .map_err(|error| anyhow::anyhow!("tauri: {error}"))?;
    Ok(())
}
