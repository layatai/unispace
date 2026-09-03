use crate::{
    FILE_TRANSFER_PORT,
    config::Configuration,
    model::Identifier,
    observe::{StatusHub, TransferDirection, TransferSnapshot, TransferState, transfers_root},
    secure::{ChannelProfile, SecureStream},
};
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
use tokio::{
    sync::mpsc,
    time::{MissedTickBehavior, interval, timeout},
};
use tracing::warn;
use uuid::Uuid;

const HEADER: usize = 39;
const MAX_CHUNK: usize = 1024 * 1024;
const MAX_TRANSFER: u64 = 1_099_511_627_776;
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    #[serde(rename = "transferID")]
    transfer_id: Identifier,
    #[serde(rename = "workspaceID")]
    workspace_id: Identifier,
    #[serde(rename = "sourceDeviceID")]
    source_device_id: Identifier,
    #[serde(rename = "destinationDeviceID")]
    destination_device_id: Identifier,
    entries: Vec<Entry>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: Identifier,
    filename: String,
    #[serde(rename = "byteCount")]
    byte_count: u64,
    sha256: String,
}
struct Incoming {
    manifest: Manifest,
    dir: PathBuf,
    offsets: BTreeMap<Uuid, u64>,
    completed: BTreeMap<Uuid, PathBuf>,
}
struct Outgoing {
    transfer_id: Uuid,
    manifest: Value,
    paths: BTreeMap<Uuid, PathBuf>,
}

pub async fn run(
    configuration: Configuration,
    hub: StatusHub,
    send_files: &mut mpsc::Receiver<Vec<PathBuf>>,
) -> Result<()> {
    let key = configuration.workspace_key()?;
    let remote = configuration
        .workspace
        .mac()
        .context("controller Mac missing")?;
    let mut channel = SecureStream::connect_named(
        &configuration.host_address,
        configuration.device_id,
        remote.id.raw_value,
        configuration.workspace.id.raw_value,
        &key,
        ChannelProfile {
            port: FILE_TRANSFER_PORT,
            hello_prefix: "UniSpace secure content hello v1",
            info_prefix: "UniSpace content channel v1",
            hello_kind: 1,
            sealed_kind: 2,
        },
    )
    .await?;
    hub.set_files(true);
    let mut incoming: Option<Incoming> = None;
    let mut outgoing: Option<Outgoing> = None;
    let mut last_selection = Vec::new();
    let mut ticker = interval(Duration::from_secs(1));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
          packet=channel.receive()=>{let packet=packet?;let (kind,payload)=decode_envelope(&packet,configuration.workspace.id.raw_value,remote.id.raw_value)?;
            match kind{
                1=>{
                    let offer:Value=serde_json::from_slice(payload)?;
                    let manifest:Manifest=serde_json::from_value(offer["manifest"].clone())?;
                    validate_manifest(&manifest,&configuration)?;
                    let transfer=prepare(manifest)?;
                    persist_incoming_manifest(&transfer, &offer["manifest"]);
                    let offsets=resume_offsets(&transfer);
                    let id=transfer.manifest.transfer_id;
                    hub.upsert_transfer(incoming_snapshot(&transfer, TransferState::Transferring));
                    incoming=Some(transfer);
                    channel.send(&encode_json(2,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":id,"offsets":offsets}))?).await?;
                }
                2=>{
                    let request:Value=serde_json::from_slice(payload)?;
                    let transfer=outgoing.as_ref().context("request without outgoing transfer")?;
                    ensure!(id(&request,"transferID")?==transfer.transfer_id,"transfer mismatch");
                    send_outgoing(&mut channel,&configuration,transfer,&request,&hub).await?;
                }
                3=>{
                    let transfer=incoming.as_mut().context("chunk without active transfer")?;
                    let (transfer_id,entry_id,offset,data)=decode_chunk(payload)?;
                    ensure!(transfer_id==transfer.manifest.transfer_id.raw_value,"transfer mismatch");
                    let entry=transfer.manifest.entries.iter().find(|e|e.id.raw_value==entry_id).context("unknown entry")?;
                    let expected=*transfer.offsets.get(&entry_id).unwrap_or(&0);
                    ensure!(offset==expected&&offset+data.len() as u64<=entry.byte_count,"invalid chunk offset");
                    let path=transfer.dir.join(format!("{}.partial",entry_id));
                    let mut file=OpenOptions::new().create(true).truncate(false).write(true).open(path)?;
                    file.seek(SeekFrom::Start(offset))?;
                    file.write_all(data)?;
                    file.sync_data()?;
                    let verified=offset+data.len() as u64;
                    transfer.offsets.insert(entry_id,verified);
                    hub.upsert_transfer(incoming_snapshot(transfer, TransferState::Transferring));
                    channel.send(&encode_json(4,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":Identifier{raw_value:transfer_id},"entryID":Identifier{raw_value:entry_id},"verifiedOffset":verified}))?).await?;
                }
                5=>{
                    let value:Value=serde_json::from_slice(payload)?;
                    let transfer_id=id(&value,"transferID")?;
                    let entry_id=id(&value,"entryID")?;
                    let transfer=incoming.as_mut().context("completion without transfer")?;
                    ensure!(transfer_id==transfer.manifest.transfer_id.raw_value,"transfer mismatch");
                    finalize_entry(transfer,entry_id)?;
                    hub.upsert_transfer(incoming_snapshot(transfer, TransferState::Transferring));
                    let size=transfer.manifest.entries.iter().find(|e|e.id.raw_value==entry_id).unwrap().byte_count;
                    channel.send(&encode_json(4,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":Identifier{raw_value:transfer_id},"entryID":Identifier{raw_value:entry_id},"verifiedOffset":size}))?).await?;
                }
                6=>{
                    let value:Value=serde_json::from_slice(payload)?;
                    let transfer_id=id(&value,"transferID")?;
                    let transfer=incoming.take().context("completion without transfer")?;
                    ensure!(transfer_id==transfer.manifest.transfer_id.raw_value&&transfer.completed.len()==transfer.manifest.entries.len(),"incomplete transfer");
                    let paths=transfer.manifest.entries.iter().map(|e|transfer.completed[&e.id.raw_value].clone()).collect::<Vec<_>>();
                    let accepted=publish_files(&paths).is_ok();
                    hub.upsert_transfer(incoming_snapshot(&transfer, if accepted { TransferState::Completed } else { TransferState::Failed }));
                    channel.send(&encode_json(7,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":Identifier{raw_value:transfer_id},"accepted":accepted,"failureCode":if accepted{Value::Null}else{json!("stagingFailure")}}))?).await?;
                }
                7=>{
                    let value:Value=serde_json::from_slice(payload)?;
                    if outgoing.as_ref().is_some_and(|transfer|id(&value,"transferID").ok()==Some(transfer.transfer_id)){
                        let transfer=outgoing.take().expect("outgoing transfer");
                        hub.upsert_transfer(outgoing_snapshot(&transfer, outgoing_total(&transfer.manifest), TransferState::Completed));
                    }
                }
                8|11=>{
                    hub.fail_active_transfers();
                    incoming=None;
                    outgoing=None;
                }
                9=>{
                    let value:Value=serde_json::from_slice(payload)?;
                    let transfer_id=id(&value,"transferID")?;
                    if incoming.as_ref().is_none_or(|transfer| transfer.manifest.transfer_id.raw_value != transfer_id) {
                        incoming = restore_incoming(transfer_id);
                    }
                    if let Some(transfer)=incoming.as_ref().filter(|transfer| transfer.manifest.transfer_id.raw_value == transfer_id) {
                        channel.send(&encode_json(10,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":transfer.manifest.transfer_id,"offsets":resume_offsets(transfer),"completed":false}))?).await?;
                    } else {
                        channel.send(&encode_json(11,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":Identifier{raw_value:transfer_id},"code":"resumeRejected"}))?).await?;
                    }
                }
                10=>{
                    let state:Value=serde_json::from_slice(payload)?;
                    let transfer_id=id(&state,"transferID")?;
                    if state["completed"].as_bool()==Some(true) {
                        if outgoing.as_ref().is_some_and(|transfer| transfer.transfer_id==transfer_id) {
                            let transfer=outgoing.take().expect("outgoing transfer");
                            hub.upsert_transfer(outgoing_snapshot(&transfer, outgoing_total(&transfer.manifest), TransferState::Completed));
                        }
                    } else if let Some(transfer)=outgoing.as_ref().filter(|transfer| transfer.transfer_id==transfer_id) {
                        send_outgoing(&mut channel,&configuration,transfer,&state,&hub).await?;
                    } else {
                        channel.send(&encode_json(11,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":Identifier{raw_value:transfer_id},"code":"resumeRejected"}))?).await?;
                    }
                }
                _=>{}
            }}
          Some(paths) = send_files.recv() => {
            offer_outgoing(&configuration, remote.id.raw_value, sendable_paths(paths), &mut outgoing, &mut channel, &hub).await?;
          }
          _=ticker.tick()=>if outgoing.is_none() {
            let polled = timeout(Duration::from_millis(400), tokio::task::spawn_blocking(clipboard_files)).await;
            if let Ok(Ok(Ok(paths))) = polled
                && !paths.is_empty() && paths!=last_selection
            {
                last_selection=paths.clone();
                offer_outgoing(&configuration, remote.id.raw_value, paths, &mut outgoing, &mut channel, &hub).await?;
            }
          }
        }
    }
}
pub async fn supervise(
    configuration: Configuration,
    hub: StatusHub,
    mut send_files: mpsc::Receiver<Vec<PathBuf>>,
) {
    loop {
        if let Err(error) = run(configuration.clone(), hub.clone(), &mut send_files).await {
            hub.set_files(false);
            hub.fail_active_transfers();
            warn!(%error,"file-transfer channel disconnected");
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

async fn offer_outgoing(
    configuration: &Configuration,
    destination: Uuid,
    paths: Vec<PathBuf>,
    outgoing: &mut Option<Outgoing>,
    channel: &mut SecureStream,
    hub: &StatusHub,
) -> Result<()> {
    if outgoing.is_some() || paths.is_empty() {
        return Ok(());
    }
    let transfer = prepare_outgoing(configuration, destination, paths)?;
    hub.upsert_transfer(outgoing_snapshot(&transfer, 0, TransferState::Transferring));
    channel
        .send(&encode_json(
            1,
            configuration.workspace.id.raw_value,
            configuration.device_id,
            &json!({"manifest":transfer.manifest}),
        )?)
        .await?;
    *outgoing = Some(transfer);
    Ok(())
}

fn resume_offsets(transfer: &Incoming) -> Vec<Value> {
    transfer
        .offsets
        .iter()
        .map(|(id, offset)| json!({"entryID":Identifier{raw_value:*id},"offset":offset}))
        .collect()
}

fn persist_incoming_manifest(transfer: &Incoming, manifest: &Value) {
    let _ = fs::write(
        transfer.dir.join("manifest.json"),
        serde_json::to_vec(manifest).unwrap_or_default(),
    );
}

fn restore_incoming(transfer_id: Uuid) -> Option<Incoming> {
    restore_incoming_from_dir(&transfers_root().ok()?.join(transfer_id.to_string()))
}

fn restore_incoming_from_dir(root: &Path) -> Option<Incoming> {
    let manifest = serde_json::from_slice(&fs::read(root.join("manifest.json")).ok()?).ok()?;
    prepare_in(manifest, root.to_path_buf()).ok()
}

fn decode_envelope(data: &[u8], workspace: Uuid, sender: Uuid) -> Result<(u8, &[u8])> {
    ensure!(
        data.len() >= HEADER && u16::from_be_bytes(data[0..2].try_into()?) == 1,
        "invalid transfer envelope"
    );
    ensure!(
        &data[3..19] == workspace.as_bytes() && &data[19..35] == sender.as_bytes(),
        "transfer peer mismatch"
    );
    let length = u32::from_be_bytes(data[35..39].try_into()?) as usize;
    ensure!(length == data.len() - HEADER, "invalid transfer length");
    Ok((data[2], &data[HEADER..]))
}
fn encode_json(kind: u8, workspace: Uuid, sender: Uuid, value: &Value) -> Result<Vec<u8>> {
    encode(kind, workspace, sender, &serde_json::to_vec(value)?)
}
fn encode(kind: u8, workspace: Uuid, sender: Uuid, payload: &[u8]) -> Result<Vec<u8>> {
    ensure!(
        payload.len() <= 2 * 1024 * 1024 - HEADER,
        "transfer frame too large"
    );
    let mut out = Vec::with_capacity(HEADER + payload.len());
    out.extend_from_slice(&1u16.to_be_bytes());
    out.push(kind);
    out.extend_from_slice(workspace.as_bytes());
    out.extend_from_slice(sender.as_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}
fn decode_chunk(data: &[u8]) -> Result<(Uuid, Uuid, u64, &[u8])> {
    ensure!(data.len() >= 44, "truncated chunk");
    let transfer = Uuid::from_bytes(data[0..16].try_into()?);
    let entry = Uuid::from_bytes(data[16..32].try_into()?);
    let offset = u64::from_be_bytes(data[32..40].try_into()?);
    let count = u32::from_be_bytes(data[40..44].try_into()?) as usize;
    ensure!(
        count > 0 && count <= MAX_CHUNK && data.len() == 44 + count,
        "invalid chunk size"
    );
    Ok((transfer, entry, offset, &data[44..]))
}
fn id(value: &Value, name: &str) -> Result<Uuid> {
    Ok(Uuid::parse_str(
        value[name]["rawValue"]
            .as_str()
            .context("missing identifier")?,
    )?)
}
fn validate_manifest(manifest: &Manifest, configuration: &Configuration) -> Result<()> {
    let controller = configuration
        .workspace
        .mac()
        .context("controller Mac missing")?;
    ensure!(
        manifest.workspace_id.raw_value == configuration.workspace.id.raw_value
            && manifest.source_device_id.raw_value == controller.id.raw_value
            && manifest.destination_device_id.raw_value == configuration.device_id,
        "manifest destination mismatch"
    );
    ensure!(
        !manifest.entries.is_empty() && manifest.entries.len() <= 1000,
        "invalid manifest count"
    );
    let mut total = 0u64;
    for entry in &manifest.entries {
        ensure!(
            !entry.filename.is_empty()
                && entry.filename.len() <= 255
                && !entry.filename.contains('/')
                && !entry.filename.contains('\\')
                && entry.filename != "."
                && entry.filename != "..",
            "unsafe filename"
        );
        ensure!(BASE64.decode(&entry.sha256)?.len() == 32, "invalid digest");
        total = total
            .checked_add(entry.byte_count)
            .context("transfer overflow")?;
    }
    ensure!(total <= MAX_TRANSFER, "transfer too large");
    Ok(())
}
fn prepare(manifest: Manifest) -> Result<Incoming> {
    let root = transfers_root()?.join(manifest.transfer_id.raw_value.to_string());
    prepare_in(manifest, root)
}

fn prepare_in(manifest: Manifest, root: PathBuf) -> Result<Incoming> {
    fs::create_dir_all(&root)?;
    let mut offsets = BTreeMap::new();
    for entry in &manifest.entries {
        let path = root.join(format!("{}.partial", entry.id.raw_value));
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        let size = file.metadata()?.len().min(entry.byte_count);
        file.set_len(size)?;
        offsets.insert(entry.id.raw_value, size);
    }
    Ok(Incoming {
        manifest,
        dir: root,
        offsets,
        completed: BTreeMap::new(),
    })
}
fn finalize_entry(transfer: &mut Incoming, entry_id: Uuid) -> Result<()> {
    let entry = transfer
        .manifest
        .entries
        .iter()
        .find(|e| e.id.raw_value == entry_id)
        .context("unknown entry")?;
    ensure!(
        transfer.offsets.get(&entry_id) == Some(&entry.byte_count),
        "entry incomplete"
    );
    let partial = transfer.dir.join(format!("{}.partial", entry_id));
    let mut file = fs::File::open(&partial)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 256 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    ensure!(
        hash.finalize().as_slice() == BASE64.decode(&entry.sha256)?.as_slice(),
        "file digest mismatch"
    );
    let final_path = unique_path(&transfer.dir, &entry.filename);
    fs::rename(partial, &final_path)?;
    transfer.completed.insert(entry_id, final_path);
    Ok(())
}
fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let original = dir.join(name);
    if !original.exists() {
        return original;
    }
    let path = Path::new(name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("File");
    let extension = path.extension().and_then(|s| s.to_str());
    for index in 2..10_000 {
        let candidate = dir.join(match extension {
            Some(ext) => format!("{stem} ({index}).{ext}"),
            None => format!("{stem} ({index})"),
        });
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(Uuid::new_v4().to_string())
}
fn publish_files(paths: &[PathBuf]) -> Result<()> {
    let body = paths
        .iter()
        .map(|path| format!("file://{}", percent_path(path)))
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n";
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let mut command = if wayland {
        let mut c = Command::new("wl-copy");
        c.args(["--type", "text/uri-list"]);
        c
    } else {
        let mut c = Command::new("xclip");
        c.args(["-selection", "clipboard", "-t", "text/uri-list", "-i"]);
        c
    };
    let mut child = command
        .stdin(Stdio::piped())
        .spawn()
        .context("install wl-clipboard or xclip to publish received files")?;
    child.stdin.take().unwrap().write_all(body.as_bytes())?;
    ensure!(child.wait()?.success(), "clipboard publication failed");
    Ok(())
}
fn percent_path(path: &Path) -> String {
    path.to_string_lossy()
        .bytes()
        .flat_map(|byte| {
            if byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte) {
                vec![byte as char]
            } else {
                format!("%{byte:02X}").chars().collect()
            }
        })
        .collect()
}

fn clipboard_files() -> Result<Vec<PathBuf>> {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let output = if wayland {
        Command::new("wl-paste")
            .args(["--no-newline", "--type", "text/uri-list"])
            .output()
    } else {
        Command::new("xclip")
            .args(["-selection", "clipboard", "-t", "text/uri-list", "-o"])
            .output()
    }?;
    if !output.status.success() {
        return Ok(Vec::new());
    }
    let text = String::from_utf8(output.stdout)?;
    // Files under the transfers root are files we just RECEIVED (incoming
    // completion publishes them to the clipboard); auto-offering them back
    // forks an endless Mac↔Linux re-transfer loop.
    let transfers_root = crate::observe::transfers_root().ok();
    Ok(sendable_paths(
        text.lines()
            .filter(|line| !line.starts_with('#'))
            .filter_map(file_uri)
            .filter(|path| {
                transfers_root.as_ref().is_none_or(|root| !path.starts_with(root))
            })
            .collect(),
    ))
}

pub fn sendable_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    paths
        .into_iter()
        .filter(|path| {
            fs::symlink_metadata(path).is_ok_and(|metadata| {
                metadata.file_type().is_file() && !metadata.file_type().is_symlink()
            })
        })
        .collect()
}
fn file_uri(value: &str) -> Option<PathBuf> {
    let value = value.trim().strip_prefix("file://")?;
    let mut bytes = Vec::new();
    let raw = value.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' && i + 2 < raw.len() {
            bytes.push(u8::from_str_radix(std::str::from_utf8(&raw[i + 1..i + 3]).ok()?, 16).ok()?);
            i += 3
        } else {
            bytes.push(raw[i]);
            i += 1
        }
    }
    Some(PathBuf::from(String::from_utf8(bytes).ok()?))
}
fn prepare_outgoing(
    configuration: &Configuration,
    destination: Uuid,
    paths: Vec<PathBuf>,
) -> Result<Outgoing> {
    ensure!(paths.len() <= 1000, "too many files");
    let transfer_id = Uuid::new_v4();
    let mut manifest_entries = Vec::new();
    let mut mapped = BTreeMap::new();
    let mut total = 0u64;
    for path in paths {
        let metadata = fs::metadata(&path)?;
        total = total
            .checked_add(metadata.len())
            .context("transfer overflow")?;
        ensure!(total <= MAX_TRANSFER, "transfer too large");
        let filename = path
            .file_name()
            .and_then(|s| s.to_str())
            .context("invalid filename")?
            .to_owned();
        ensure!(
            !filename.contains('/') && filename.len() <= 255,
            "invalid filename"
        );
        let entry_id = Uuid::new_v4();
        let mut file = fs::File::open(&path)?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 256 * 1024];
        loop {
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            hasher.update(&buffer[..count]);
        }
        manifest_entries.push(json!({"id":Identifier{raw_value:entry_id},"filename":filename,"contentTypeIdentifier":Value::Null,"byteCount":metadata.len(),"sha256":BASE64.encode(hasher.finalize()),"modificationDate":Value::Null}));
        mapped.insert(entry_id, path);
    }
    let manifest = json!({"transferID":Identifier{raw_value:transfer_id},"workspaceID":configuration.workspace.id,"sourceDeviceID":Identifier{raw_value:configuration.device_id},"destinationDeviceID":Identifier{raw_value:destination},"entries":manifest_entries,"createdAt":crate::clipboard::now_iso8601()});
    Ok(Outgoing {
        transfer_id,
        manifest,
        paths: mapped,
    })
}
async fn send_outgoing(
    channel: &mut SecureStream,
    configuration: &Configuration,
    transfer: &Outgoing,
    request: &Value,
    hub: &StatusHub,
) -> Result<()> {
    let offsets = request["offsets"].as_array().context("missing offsets")?;
    let mut sent = 0u64;
    for value in offsets {
        let entry_id = id(value, "entryID")?;
        let mut offset = value["offset"].as_u64().context("missing offset")?;
        sent = sent.saturating_add(offset);
        let path = transfer
            .paths
            .get(&entry_id)
            .context("unknown outgoing entry")?;
        let mut file = fs::File::open(path)?;
        ensure!(offset <= file.metadata()?.len(), "invalid requested offset");
        file.seek(SeekFrom::Start(offset))?;
        let mut buffer = vec![0u8; 256 * 1024];
        loop {
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            let mut payload = Vec::with_capacity(44 + count);
            payload.extend_from_slice(transfer.transfer_id.as_bytes());
            payload.extend_from_slice(entry_id.as_bytes());
            payload.extend_from_slice(&offset.to_be_bytes());
            payload.extend_from_slice(&(count as u32).to_be_bytes());
            payload.extend_from_slice(&buffer[..count]);
            channel
                .send(&encode(
                    3,
                    configuration.workspace.id.raw_value,
                    configuration.device_id,
                    &payload,
                )?)
                .await?;
            offset += count as u64;
            sent += count as u64;
            hub.upsert_transfer(outgoing_snapshot(
                transfer,
                sent,
                TransferState::Transferring,
            ));
        }
        channel.send(&encode_json(5,configuration.workspace.id.raw_value,configuration.device_id,&json!({"transferID":Identifier{raw_value:transfer.transfer_id},"entryID":Identifier{raw_value:entry_id}}))?).await?;
    }
    channel
        .send(&encode_json(
            6,
            configuration.workspace.id.raw_value,
            configuration.device_id,
            &json!({"transferID":Identifier{raw_value:transfer.transfer_id}}),
        )?)
        .await?;
    Ok(())
}

fn incoming_snapshot(transfer: &Incoming, state: TransferState) -> TransferSnapshot {
    TransferSnapshot {
        id: transfer.manifest.transfer_id.raw_value.to_string(),
        direction: TransferDirection::Incoming,
        display_name: file_display_name(
            &transfer
                .manifest
                .entries
                .iter()
                .map(|entry| entry.filename.clone())
                .collect::<Vec<_>>(),
        ),
        bytes_done: transfer.offsets.values().copied().sum(),
        bytes_total: transfer
            .manifest
            .entries
            .iter()
            .map(|entry| entry.byte_count)
            .sum(),
        state,
        directory: Some(transfer.dir.to_string_lossy().into()),
    }
}

fn outgoing_snapshot(
    transfer: &Outgoing,
    bytes_done: u64,
    state: TransferState,
) -> TransferSnapshot {
    let names = outgoing_names(&transfer.manifest);
    TransferSnapshot {
        id: transfer.transfer_id.to_string(),
        direction: TransferDirection::Outgoing,
        display_name: file_display_name(&names),
        bytes_done,
        bytes_total: outgoing_total(&transfer.manifest),
        state,
        directory: transfer
            .paths
            .values()
            .next()
            .and_then(|path| path.parent())
            .map(|path| path.to_string_lossy().into()),
    }
}

fn outgoing_names(manifest: &Value) -> Vec<String> {
    manifest["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|entry| entry["filename"].as_str().map(str::to_owned))
        .collect()
}

fn outgoing_total(manifest: &Value) -> u64 {
    manifest["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|entry| entry["byteCount"].as_u64())
        .sum()
}

fn file_display_name(names: &[String]) -> String {
    match names {
        [] => "Files".into(),
        [one] => one.clone(),
        [first, rest @ ..] => format!("{first} +{}", rest.len()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_byte_transfer_creates_and_finalizes_a_partial_file() {
        let directory = tempfile::tempdir().unwrap();
        let entry_id = Uuid::new_v4();
        let root = directory.path().join("transfer");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join(format!("{entry_id}.partial")), b"stale").unwrap();
        let manifest = Manifest {
            transfer_id: Identifier::new(),
            workspace_id: Identifier::new(),
            source_device_id: Identifier::new(),
            destination_device_id: Identifier::new(),
            entries: vec![Entry {
                id: Identifier {
                    raw_value: entry_id,
                },
                filename: "empty.txt".into(),
                byte_count: 0,
                sha256: BASE64.encode(Sha256::digest([])),
            }],
        };

        let mut transfer = prepare_in(manifest, root).unwrap();
        assert_eq!(transfer.offsets[&entry_id], 0);
        finalize_entry(&mut transfer, entry_id).unwrap();
        assert_eq!(
            fs::metadata(transfer.completed[&entry_id].clone())
                .unwrap()
                .len(),
            0
        );
    }

    #[test]
    fn file_uri_round_trips_spaces_and_unicode() {
        let path = PathBuf::from("/tmp/UniSpace file 🚀.txt");
        assert_eq!(
            file_uri(&format!("file://{}", percent_path(&path))),
            Some(path)
        );
    }

    #[test]
    fn sendable_paths_keeps_regular_files_only() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("ok.txt");
        fs::write(&file, b"hi").unwrap();
        let nested = directory.path().join("sub");
        fs::create_dir(&nested).unwrap();
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert_eq!(sendable_paths(vec![file.clone(), nested, link]), vec![file]);
    }

    #[test]
    fn restore_incoming_reloads_partial_offsets_from_disk() {
        let directory = tempfile::tempdir().unwrap();
        let entry_id = Uuid::new_v4();
        let transfer_id = Uuid::new_v4();
        let root = directory.path().join(transfer_id.to_string());
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join(format!("{entry_id}.partial")), b"hello").unwrap();
        let manifest = json!({
            "transferID": {"rawValue": transfer_id},
            "workspaceID": {"rawValue": Uuid::new_v4()},
            "sourceDeviceID": {"rawValue": Uuid::new_v4()},
            "destinationDeviceID": {"rawValue": Uuid::new_v4()},
            "entries": [{
                "id": {"rawValue": entry_id},
                "filename": "hello.txt",
                "byteCount": 5,
                "sha256": BASE64.encode(Sha256::digest(b"hello")),
            }],
        });
        fs::write(
            root.join("manifest.json"),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();

        let restored = restore_incoming_from_dir(&root).unwrap();
        assert_eq!(restored.offsets[&entry_id], 5);
        assert_eq!(restored.manifest.transfer_id.raw_value, transfer_id);
    }
}
