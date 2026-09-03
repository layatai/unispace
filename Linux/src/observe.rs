use crate::config::Configuration;
use anyhow::{Context, Result};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{mpsc, watch},
    time::{Instant, sleep_until},
};
use tracing::warn;

const MAX_TRANSFERS: usize = 20;
const PROGRESS_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ControlState {
    #[default]
    Disconnected,
    Connected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransferDirection {
    Incoming,
    Outgoing,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransferState {
    Transferring,
    Completed,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferSnapshot {
    pub id: String,
    pub direction: TransferDirection,
    pub display_name: String,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub state: TransferState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReceiverSnapshot {
    pub paired: bool,
    pub workspace_name: String,
    pub controller_name: String,
    pub host_address: String,
    pub control: ControlState,
    pub receiving: bool,
    pub clipboard: bool,
    pub files: bool,
    pub uinput_ready: bool,
    pub service_running: bool,
    pub transfers: Vec<TransferSnapshot>,
}

impl ReceiverSnapshot {
    pub fn unpaired() -> Self {
        Self {
            paired: false,
            workspace_name: String::new(),
            controller_name: String::new(),
            host_address: String::new(),
            control: ControlState::Disconnected,
            receiving: false,
            clipboard: false,
            files: false,
            uinput_ready: uinput_accessible(),
            service_running: false,
            transfers: Vec::new(),
        }
    }

    pub fn from_configuration(configuration: &Configuration) -> Self {
        Self {
            paired: true,
            workspace_name: configuration.workspace.name.clone(),
            controller_name: configuration
                .workspace
                .mac()
                .map(|device| device.name.clone())
                .unwrap_or_default(),
            host_address: configuration.host_address.clone(),
            control: ControlState::Disconnected,
            receiving: false,
            clipboard: false,
            files: false,
            uinput_ready: uinput_accessible(),
            service_running: true,
            transfers: Vec::new(),
        }
    }

    pub fn tray_title(&self) -> String {
        if self.receiving {
            format!("Receiving from {}", self.controller_name)
        } else if self.control == ControlState::Connected {
            format!("Connected to {}", self.controller_name)
        } else if self.paired && !self.controller_name.is_empty() {
            format!("Waiting for {}", self.controller_name)
        } else {
            "UniSpace Receiver".into()
        }
    }
}

#[derive(Clone)]
pub struct StatusHub {
    snapshots: watch::Sender<ReceiverSnapshot>,
    send_files: mpsc::Sender<Vec<PathBuf>>,
}

impl StatusHub {
    pub fn new(initial: ReceiverSnapshot) -> (Self, mpsc::Receiver<Vec<PathBuf>>) {
        let (snapshots, _) = watch::channel(initial);
        let (send_files, send_rx) = mpsc::channel(4);
        (
            Self {
                snapshots,
                send_files,
            },
            send_rx,
        )
    }

    pub fn subscribe(&self) -> watch::Receiver<ReceiverSnapshot> {
        self.snapshots.subscribe()
    }

    pub fn snapshot(&self) -> ReceiverSnapshot {
        self.snapshots.borrow().clone()
    }

    pub fn set_control(&self, connected: bool) {
        self.modify(|snapshot| {
            snapshot.control = if connected {
                ControlState::Connected
            } else {
                ControlState::Disconnected
            };
            if !connected {
                snapshot.receiving = false;
            }
        });
    }

    pub fn set_receiving(&self, receiving: bool) {
        self.modify(|snapshot| snapshot.receiving = receiving);
    }

    pub fn set_clipboard(&self, connected: bool) {
        self.modify(|snapshot| snapshot.clipboard = connected);
    }

    pub fn set_files(&self, connected: bool) {
        self.modify(|snapshot| snapshot.files = connected);
    }

    pub fn set_uinput_ready(&self, ready: bool) {
        self.modify(|snapshot| snapshot.uinput_ready = ready);
    }

    pub fn upsert_transfer(&self, transfer: TransferSnapshot) {
        self.modify(|snapshot| upsert_transfer(&mut snapshot.transfers, transfer));
    }

    pub fn fail_active_transfers(&self) {
        self.modify(|snapshot| {
            for transfer in &mut snapshot.transfers {
                if transfer.state == TransferState::Transferring {
                    transfer.state = TransferState::Failed;
                }
            }
        });
    }

    pub fn request_send_files(&self, paths: Vec<PathBuf>) {
        if !self.snapshot().files {
            return;
        }
        let _ = self.send_files.try_send(paths);
    }

    fn modify(&self, edit: impl FnOnce(&mut ReceiverSnapshot)) {
        self.snapshots.send_if_modified(|snapshot| {
            let before = snapshot.clone();
            edit(snapshot);
            *snapshot != before
        });
    }
}

#[derive(Deserialize)]
struct ClientCommand {
    op: String,
    #[serde(default)]
    paths: Vec<PathBuf>,
}

pub fn socket_path() -> PathBuf {
    let uid = unsafe { libc::getuid() };
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{uid}"));
    PathBuf::from(runtime).join("unispace").join("status.sock")
}

pub fn transfers_root() -> Result<PathBuf> {
    Ok(ProjectDirs::from("com", "layatai", "UniSpace")
        .context("home directory unavailable")?
        .data_local_dir()
        .join("Transfers"))
}

pub fn uinput_accessible() -> bool {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/uinput")
        .is_ok()
}

pub fn fallback_snapshot() -> ReceiverSnapshot {
    match Configuration::load() {
        Ok(configuration) => {
            let mut snapshot = ReceiverSnapshot::from_configuration(&configuration);
            snapshot.service_running = crate::service::is_active();
            snapshot.uinput_ready = uinput_accessible();
            snapshot
        }
        Err(_) => ReceiverSnapshot::unpaired(),
    }
}

pub async fn serve(hub: StatusHub) {
    if let Err(error) = serve_at(hub, &socket_path()).await {
        warn!(%error, "status socket unavailable");
    }
}

pub async fn serve_at(hub: StatusHub, path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        let mut permissions = std::fs::metadata(parent)?.permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(parent, permissions)?;
    }
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path).context("bind status socket")?;
    let mut permissions = std::fs::metadata(path)?.permissions();
    permissions.set_mode(0o600);
    std::fs::set_permissions(path, permissions)?;
    loop {
        let (stream, _) = listener.accept().await?;
        let hub = hub.clone();
        tokio::spawn(async move {
            if let Err(error) = handle_client(hub, stream).await {
                tracing::debug!(%error, "status client ended");
            }
        });
    }
}

pub async fn send_files(paths: Vec<PathBuf>) -> Result<()> {
    let mut stream = UnixStream::connect(socket_path())
        .await
        .context("receiver is not running")?;
    let mut payload = serde_json::to_vec(&serde_json::json!({
        "op": "sendFiles",
        "paths": paths,
    }))?;
    payload.push(b'\n');
    stream.write_all(&payload).await?;
    stream.flush().await?;
    Ok(())
}

async fn handle_client(hub: StatusHub, stream: UnixStream) -> Result<()> {
    let (reader, writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    let writes = write_snapshots(hub.subscribe(), writer);
    tokio::pin!(writes);
    loop {
        tokio::select! {
            result = &mut writes => {
                result?;
                return Ok(());
            }
            line = lines.next_line() => {
                match line? {
                    Some(line) => apply_command(&hub, &line),
                    None => return Ok(()),
                }
            }
        }
    }
}

fn apply_command(hub: &StatusHub, line: &str) {
    let Ok(command) = serde_json::from_str::<ClientCommand>(line) else {
        return;
    };
    if command.op == "sendFiles" {
        hub.request_send_files(command.paths);
    }
}

async fn write_snapshots(
    mut rx: watch::Receiver<ReceiverSnapshot>,
    mut writer: tokio::net::unix::OwnedWriteHalf,
) -> Result<()> {
    let mut last = rx.borrow().clone();
    write_line(&mut writer, &last).await?;
    let mut pending: Option<ReceiverSnapshot> = None;
    let mut deadline = Instant::now() + Duration::from_secs(60 * 60 * 24 * 365);
    loop {
        tokio::select! {
            changed = rx.changed() => {
                changed?;
                let snapshot = rx.borrow_and_update().clone();
                if progress_only(&last, &snapshot) {
                    pending = Some(snapshot);
                    deadline = Instant::now() + PROGRESS_INTERVAL;
                } else {
                    pending = None;
                    last = snapshot;
                    deadline = Instant::now() + Duration::from_secs(60 * 60 * 24 * 365);
                    write_line(&mut writer, &last).await?;
                }
            }
            _ = sleep_until(deadline), if pending.is_some() => {
                last = pending.take().expect("pending snapshot");
                write_line(&mut writer, &last).await?;
                deadline = Instant::now() + Duration::from_secs(60 * 60 * 24 * 365);
            }
        }
    }
}

async fn write_line(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    snapshot: &ReceiverSnapshot,
) -> Result<()> {
    let mut line = serde_json::to_vec(snapshot)?;
    line.push(b'\n');
    writer.write_all(&line).await?;
    writer.flush().await?;
    Ok(())
}

fn progress_only(left: &ReceiverSnapshot, right: &ReceiverSnapshot) -> bool {
    if left.transfers.len() != right.transfers.len() {
        return false;
    }
    let transfers_ok = left.transfers.iter().zip(&right.transfers).all(|(a, b)| {
        a.id == b.id
            && a.direction == b.direction
            && a.display_name == b.display_name
            && a.bytes_total == b.bytes_total
            && a.state == b.state
            && a.state == TransferState::Transferring
            && a.directory == b.directory
    });
    if !transfers_ok {
        return false;
    }
    let mut stripped_left = left.clone();
    let mut stripped_right = right.clone();
    for transfer in stripped_left
        .transfers
        .iter_mut()
        .chain(stripped_right.transfers.iter_mut())
    {
        transfer.bytes_done = 0;
    }
    stripped_left == stripped_right
}

fn upsert_transfer(transfers: &mut Vec<TransferSnapshot>, transfer: TransferSnapshot) {
    if let Some(existing) = transfers.iter_mut().find(|item| item.id == transfer.id) {
        *existing = transfer;
        return;
    }
    transfers.insert(0, transfer);
    transfers.truncate(MAX_TRANSFERS);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::time::{sleep, timeout};

    fn sample() -> ReceiverSnapshot {
        ReceiverSnapshot {
            paired: true,
            workspace_name: "Desk".into(),
            controller_name: "Tai's Mac".into(),
            host_address: "mac.local".into(),
            control: ControlState::Connected,
            receiving: true,
            clipboard: true,
            files: true,
            uinput_ready: true,
            service_running: true,
            transfers: vec![TransferSnapshot {
                id: "t1".into(),
                direction: TransferDirection::Incoming,
                display_name: "notes.txt".into(),
                bytes_done: 10,
                bytes_total: 20,
                state: TransferState::Transferring,
                directory: Some("/tmp/t1".into()),
            }],
        }
    }

    #[test]
    fn snapshot_uses_swift_style_camel_case() {
        let value = serde_json::to_value(sample()).unwrap();
        assert_eq!(value["workspaceName"], "Desk");
        assert_eq!(value["controllerName"], "Tai's Mac");
        assert_eq!(value["hostAddress"], "mac.local");
        assert_eq!(value["control"], "connected");
        assert_eq!(value["uinputReady"], true);
        assert_eq!(value["serviceRunning"], true);
        assert_eq!(value["transfers"][0]["displayName"], "notes.txt");
        assert_eq!(value["transfers"][0]["bytesDone"], 10);
        assert_eq!(value["transfers"][0]["bytesTotal"], 20);
        assert_eq!(value["transfers"][0]["state"], "transferring");
        assert_eq!(value["transfers"][0]["direction"], "incoming");
    }

    #[tokio::test]
    async fn hub_update_is_visible_to_subscribers() {
        let (hub, _send_rx) = StatusHub::new(ReceiverSnapshot::unpaired());
        let mut rx = hub.subscribe();
        hub.set_control(true);
        timeout(Duration::from_secs(1), rx.changed())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(rx.borrow().control, ControlState::Connected);
        hub.set_receiving(true);
        timeout(Duration::from_secs(1), rx.changed())
            .await
            .unwrap()
            .unwrap();
        assert!(rx.borrow().receiving);
    }

    #[tokio::test]
    async fn socket_client_reads_snapshot_and_enqueues_send_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("status.sock");
        let (hub, mut send_rx) = StatusHub::new(sample());
        let served = hub.clone();
        let socket = path.clone();
        let server = tokio::spawn(async move { serve_at(served, &socket).await });
        let mut stream = wait_for_socket(&path).await;
        let (reader, mut writer) = stream.split();
        let mut lines = BufReader::new(reader).lines();
        let line = timeout(Duration::from_secs(1), lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let snapshot: ReceiverSnapshot = serde_json::from_str(&line).unwrap();
        assert_eq!(snapshot.workspace_name, "Desk");
        assert!(snapshot.receiving);

        let mut payload = serde_json::to_vec(&serde_json::json!({
            "op": "sendFiles",
            "paths": ["/tmp/a.txt"],
        }))
        .unwrap();
        payload.push(b'\n');
        writer.write_all(&payload).await.unwrap();
        writer.flush().await.unwrap();
        let paths = timeout(Duration::from_secs(1), send_rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(paths, vec![PathBuf::from("/tmp/a.txt")]);
        server.abort();
    }

    async fn wait_for_socket(path: &Path) -> UnixStream {
        for _ in 0..50 {
            if let Ok(stream) = UnixStream::connect(path).await {
                return stream;
            }
            sleep(Duration::from_millis(20)).await;
        }
        panic!("status socket did not appear");
    }
}
