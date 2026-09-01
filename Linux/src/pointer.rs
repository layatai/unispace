use crate::{model::uuid_wire, protocol};
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use chacha20poly1305::{
    ChaCha20Poly1305, Nonce,
    aead::{Aead, KeyInit},
};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::{collections::HashMap, net::SocketAddr, sync::Arc};
use subtle::ConstantTimeEq;
use tokio::{net::UdpSocket, sync::mpsc};
use tracing::{debug, warn};
use uuid::Uuid;

type HmacSha256 = Hmac<Sha256>;
const HELLO: u8 = 10;
const SEALED: u8 = 11;
const HELLO_PREFIX: &[u8] = b"UniSpace pointer hello v2";
const INFO_PREFIX: &str = "UniSpace pointer lane v2";
const MAX_DATAGRAM: usize = protocol::MAX_WIRE_PAYLOAD + 64;

#[derive(Debug, Serialize, Deserialize)]
struct PointerHello {
    version: u16,
    #[serde(rename = "workspaceID")]
    workspace_id: Uuid,
    #[serde(rename = "deviceID")]
    device_id: Uuid,
    #[serde(with = "base64_bytes")]
    nonce: Vec<u8>,
    #[serde(with = "base64_bytes")]
    proof: Vec<u8>,
    #[serde(default, rename = "supportedWireVersions")]
    supported_wire_versions: Vec<u16>,
}

struct PeerLane {
    device_id: Uuid,
    nonce: Vec<u8>,
    key: Option<[u8; 32]>,
    inbound_sequence: Option<u64>,
}

/// Authenticated UDP pointer lane. The controller Mac dials this listener and
/// speaks the same pointer-v2 profile used for Mac-to-Mac lanes; sealed
/// realtime pointer frames are forwarded on `events`. Datagrams that fail
/// validation are dropped individually — a bad packet never tears down the
/// reliable control channel.
pub async fn serve_pointer_lane(
    socket: UdpSocket,
    local_device: Uuid,
    workspace: Uuid,
    workspace_key: Vec<u8>,
    events: mpsc::Sender<protocol::RealtimePointerFrame>,
) -> Result<()> {
    let socket = Arc::new(socket);
    let mut peers: HashMap<SocketAddr, PeerLane> = HashMap::new();
    let mut buffer = vec![0u8; MAX_DATAGRAM];
    loop {
        let (size, address) = match socket.recv_from(&mut buffer).await {
            Ok(received) => received,
            Err(error) => {
                warn!(%error, "pointer lane receive failed");
                continue;
            }
        };
        let datagram = &buffer[..size];
        if let Err(error) = handle_datagram(
            &mut LaneContext {
                socket: &socket,
                peers: &mut peers,
                workspace_key: &workspace_key,
                local_device,
                workspace,
            },
            address,
            datagram,
            &events,
        )
        .await
        {
            debug!(%error, %address, "dropping pointer lane datagram");
        }
    }
}

struct LaneContext<'a> {
    socket: &'a UdpSocket,
    peers: &'a mut HashMap<SocketAddr, PeerLane>,
    workspace_key: &'a [u8],
    local_device: Uuid,
    workspace: Uuid,
}

async fn handle_datagram(
    context: &mut LaneContext<'_>,
    address: SocketAddr,
    datagram: &[u8],
    events: &mpsc::Sender<protocol::RealtimePointerFrame>,
) -> Result<()> {
    let (kind, payload) = decode_outer(datagram)?;
    match kind {
        HELLO => {
            let hello: PointerHello =
                serde_json::from_slice(payload).context("invalid pointer hello")?;
            ensure!(
                hello.version == 2
                    && hello.workspace_id == context.workspace
                    && hello.nonce.len() == 32
                    && hello.proof.len() == 32,
                "invalid pointer hello"
            );
            let expected = hello_proof(context.workspace_key, context.workspace, hello.device_id, &hello.nonce)?;
            ensure!(
                bool::from(expected.ct_eq(&hello.proof)),
                "pointer hello authentication failed"
            );
            let peer_nonce = hello.nonce.clone();
            let peer_device = hello.device_id;
            let lane = context.peers
                .entry(address)
                .or_insert_with(|| PeerLane {
                    device_id: peer_device,
                    nonce: peer_nonce.clone(),
                    key: None,
                    inbound_sequence: None,
                });
            if lane.device_id == peer_device && lane.nonce == peer_nonce && lane.key.is_some() {
                return Ok(()); // repeated handshake from an authenticated peer
            }
            lane.device_id = peer_device;
            lane.nonce = peer_nonce.clone();
            lane.key = None;
            lane.inbound_sequence = None;

            let mut local_nonce = vec![0u8; 32];
            OsRng.fill_bytes(&mut local_nonce);
            let proof = hello_proof(context.workspace_key, context.workspace, context.local_device, &local_nonce)?;
            let reply = PointerHello {
                version: 2,
                workspace_id: context.workspace,
                device_id: context.local_device,
                nonce: local_nonce.clone(),
                proof,
                supported_wire_versions: vec![1, 2],
            };
            let datagram = encode_outer(HELLO, &serde_json::to_vec(&reply)?);
            context.socket.send_to(&datagram, address).await?;
            let key = derive_pointer_key(
                context.workspace_key,
                context.local_device,
                &local_nonce,
                peer_device,
                &peer_nonce,
                context.workspace,
            )?;
            lane.key = Some(key);
            debug!(%address, "pointer lane authenticated");
            Ok(())
        }
        SEALED => {
            let Some(lane) = context.peers.get_mut(&address) else {
                bail!("sealed packet before hello");
            };
            let Some(key) = lane.key else {
                bail!("sealed packet before hello");
            };
            ensure!(payload.len() >= 28, "truncated secure packet");
            let cipher = ChaCha20Poly1305::new_from_slice(&key)?;
            let plaintext = cipher
                .decrypt(Nonce::from_slice(&payload[..12]), &payload[12..])
                .map_err(|_| anyhow::anyhow!("authentication failed"))?;
            ensure!(plaintext.len() >= 8, "truncated secure packet");
            let sequence = u64::from_be_bytes(plaintext[..8].try_into()?);
            ensure!(
                lane.inbound_sequence.is_none_or(|last| sequence > last),
                "replayed pointer packet"
            );
            lane.inbound_sequence = Some(sequence);
            let (frame_kind, frame) = protocol::decode_realtime_pointer(&plaintext[8..])?;
            ensure!(
                frame_kind == protocol::WireKind::RealtimePointerBinaryV2,
                "unexpected pointer lane frame"
            );
            ensure!(
                frame.workspace_id == context.workspace
                    && frame.controller_id == lane.device_id,
                "pointer lane workspace mismatch"
            );
            let _ = events.try_send(frame); // pointer state is replaceable; drop on backlog
            Ok(())
        }
        other => bail!("unexpected pointer packet kind {other}"),
    }
}

fn decode_outer(datagram: &[u8]) -> Result<(u8, &[u8])> {
    ensure!(datagram.len() >= 5, "truncated outer packet");
    let length = u32::from_be_bytes(datagram[0..4].try_into()?) as usize;
    ensure!(
        length <= MAX_DATAGRAM && datagram.len() == length + 5,
        "invalid outer length"
    );
    let kind = datagram[4];
    ensure!(kind == HELLO || kind == SEALED, "invalid packet kind");
    Ok((kind, &datagram[5..]))
}

fn encode_outer(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 5);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.push(kind);
    out.extend_from_slice(payload);
    out
}

fn hello_proof(key: &[u8], workspace: Uuid, device: Uuid, nonce: &[u8]) -> Result<Vec<u8>> {
    let mut payload = Vec::with_capacity(HELLO_PREFIX.len() + 72 + nonce.len());
    payload.extend_from_slice(HELLO_PREFIX);
    payload.extend_from_slice(uuid_wire(workspace).as_bytes());
    payload.extend_from_slice(uuid_wire(device).as_bytes());
    payload.extend_from_slice(nonce);
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key)?;
    mac.update(&payload);
    Ok(mac.finalize().into_bytes().to_vec())
}

/// Mirrors the Mac's derivation: the side whose device UUID sorts first
/// contributes its nonce first to the HKDF salt.
fn derive_pointer_key(
    workspace_key: &[u8],
    local_device: Uuid,
    local_nonce: &[u8],
    peer_device: Uuid,
    peer_nonce: &[u8],
    workspace: Uuid,
) -> Result<[u8; 32]> {
    let local_first = uuid_wire(local_device) < uuid_wire(peer_device);
    let mut salt = Vec::with_capacity(64);
    if local_first {
        salt.extend_from_slice(local_nonce);
        salt.extend_from_slice(peer_nonce);
    } else {
        salt.extend_from_slice(peer_nonce);
        salt.extend_from_slice(local_nonce);
    }
    let info = format!("{INFO_PREFIX}|{}", uuid_wire(workspace));
    let hk = Hkdf::<Sha256>::new(Some(&salt), workspace_key);
    let mut key = [0u8; 32];
    hk.expand(info.as_bytes(), &mut key)
        .map_err(|_| anyhow::anyhow!("HKDF failed"))?;
    Ok(key)
}

mod base64_bytes {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        value: &Vec<u8>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&BASE64.encode(value))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Vec<u8>, D::Error> {
        let value = String::deserialize(deserializer)?;
        BASE64.decode(value).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn authenticates_and_receives_realtime_frames() -> Result<()> {
        let _guard = PORT_GUARD.lock().await;
        let workspace = Uuid::new_v4();
        let local_device = Uuid::new_v4();
        let controller = Uuid::new_v4();
        let workspace_key: Vec<u8> = (0u8..32).collect();
        let (_events_tx, _events_rx) = mpsc::channel::<protocol::RealtimePointerFrame>(8);
        let (client, mut events_rx) = start_lane(local_device, workspace, workspace_key.clone()).await;

        // Send the controller hello.
        let mut nonce = vec![0u8; 32];
        OsRng.fill_bytes(&mut nonce);
        let proof = hello_proof(&workspace_key, workspace, controller, &nonce)?;
        let hello = PointerHello {
            version: 2,
            workspace_id: workspace,
            device_id: controller,
            nonce: nonce.clone(),
            proof,
            supported_wire_versions: vec![1, 2],
        };
        client
            .send(&encode_outer(HELLO, &serde_json::to_vec(&hello)?))
            .await?;

        // Receive the receiver's hello reply.
        let mut buffer = vec![0u8; MAX_DATAGRAM];
        let size = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.recv(&mut buffer),
        )
        .await
        .context("no hello reply")??;
        let (kind, payload) = decode_outer(&buffer[..size])?;
        assert_eq!(kind, HELLO);
        let reply_result: std::result::Result<PointerHello, _> = serde_json::from_slice(payload);
        let reply = match reply_result {
            Ok(reply) => reply,
            Err(error) => panic!("reply parse failed: {error}; payload={}", String::from_utf8_lossy(payload)),
        };
        assert_eq!(reply.version, 2);
        assert_eq!(reply.workspace_id, workspace);
        let expected = hello_proof(&workspace_key, workspace, reply.device_id, &reply.nonce)?;
        assert_eq!(expected, reply.proof);

        // Derive the shared key the same way the lane does and send a frame.
        let session_key =
            derive_pointer_key(&workspace_key, controller, &nonce, reply.device_id, &reply.nonce, workspace)?;
        let frame = protocol::RealtimePointerFrame {
            workspace_id: workspace,
            session_id: Uuid::new_v4(),
            controller_id: controller,
            epoch: protocol::Epoch {
                generation: 1,
                controller_id: controller,
            },
            generation: 1,
            sequence: 0,
            dx: 2.0,
            dy: -1.0,
            cumulative_x: 2.0,
            cumulative_y: -1.0,
            absolute_x: 10.0,
            absolute_y: 20.0,
            timestamp_nanos: 1,
        };
        let sealed = seal(&session_key, 0, &protocol::encode_realtime_pointer(&frame)?)?;
        client.send(&sealed).await?;
        let received = tokio::time::timeout(std::time::Duration::from_secs(2), events_rx.recv())
            .await
            .context("no pointer event")?
            .expect("channel open");
        assert_eq!(received, frame);
        Ok(())
    }

    #[tokio::test]
    async fn drops_replayed_and_unauthenticated_datagrams() -> Result<()> {
        let _guard = PORT_GUARD.lock().await;
        let workspace = Uuid::new_v4();
        let controller = Uuid::new_v4();
        let workspace_key: Vec<u8> = (32u8..64).collect();
        let (_events_tx, _events_rx) = mpsc::channel::<protocol::RealtimePointerFrame>(8);
        let (client, mut events_rx) =
            start_lane(Uuid::new_v4(), workspace, workspace_key.clone()).await;
        // Sealed packet before any hello is dropped, not fatal.
        client.send(&[0, 0, 0, 9, SEALED, 0, 1, 2, 3]).await?;
        let mut nonce = vec![0u8; 32];
        OsRng.fill_bytes(&mut nonce);
        let hello = PointerHello {
            version: 2,
            workspace_id: workspace,
            device_id: controller,
            nonce: nonce.clone(),
            proof: hello_proof(&workspace_key, workspace, controller, &nonce)?,
            supported_wire_versions: vec![1, 2],
        };
        client
            .send(&encode_outer(HELLO, &serde_json::to_vec(&hello)?))
            .await?;
        let mut buffer = vec![0u8; MAX_DATAGRAM];
        let size = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.recv(&mut buffer),
        )
        .await
        .context("no hello reply")??;
        let (kind, payload) = decode_outer(&buffer[..size])?;
        assert_eq!(kind, HELLO);
        let reply: PointerHello = serde_json::from_slice(payload)?;
        let session_key =
            derive_pointer_key(&workspace_key, controller, &nonce, reply.device_id, &reply.nonce, workspace)?;
        let frame = protocol::RealtimePointerFrame {
            workspace_id: workspace,
            session_id: Uuid::new_v4(),
            controller_id: controller,
            epoch: protocol::Epoch {
                generation: 1,
                controller_id: controller,
            },
            generation: 1,
            sequence: 7,
            dx: 0.0,
            dy: 0.0,
            cumulative_x: 0.0,
            cumulative_y: 0.0,
            absolute_x: 0.0,
            absolute_y: 0.0,
            timestamp_nanos: 1,
        };
        let sealed = seal(&session_key, 7, &protocol::encode_realtime_pointer(&frame)?)?;
        client.send(&sealed).await?;
        client.send(&sealed).await?; // replayed sequence is dropped
        let received = tokio::time::timeout(std::time::Duration::from_secs(2), events_rx.recv())
            .await
            .context("no pointer event")?
            .expect("channel open");
        assert_eq!(received.sequence, 7);
        // A second frame must arrive for the replay to have been dropped.
        let next = protocol::RealtimePointerFrame { sequence: 8, ..frame };
        client
            .send(&seal(&session_key, 8, &protocol::encode_realtime_pointer(&next)?)?)
            .await?;
        let received = tokio::time::timeout(std::time::Duration::from_secs(2), events_rx.recv())
            .await
            .context("no second pointer event")?
            .expect("channel open");
        assert_eq!(received.sequence, 8);
        Ok(())
    }

    async fn start_lane(
        local_device: Uuid,
        workspace: Uuid,
        workspace_key: Vec<u8>,
    ) -> (tokio::net::UdpSocket, mpsc::Receiver<protocol::RealtimePointerFrame>) {
        let socket = tokio::net::UdpSocket::bind("127.0.0.1:0")
            .await
            .expect("bind lane socket");
        let address = socket.local_addr().expect("lane local address");
        let (events_tx, events_rx) = mpsc::channel(8);
        tokio::spawn(serve_pointer_lane(
            socket,
            local_device,
            workspace,
            workspace_key,
            events_tx,
        ));
        let client = tokio::net::UdpSocket::bind("127.0.0.1:0")
            .await
            .expect("bind client socket");
        client.connect(address).await.expect("connect to lane");
        (client, events_rx)
    }

    static PORT_GUARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    fn seal(key: &[u8; 32], sequence: u64, plaintext_frame: &[u8]) -> Result<Vec<u8>> {
        let mut plaintext = Vec::with_capacity(plaintext_frame.len() + 8);
        plaintext.extend_from_slice(&sequence.to_be_bytes());
        plaintext.extend_from_slice(plaintext_frame);
        let mut nonce_bytes = [0u8; 12];
        OsRng.fill_bytes(&mut nonce_bytes);
        let cipher = ChaCha20Poly1305::new_from_slice(key)?;
        let ciphertext = cipher
            .encrypt(Nonce::from_slice(&nonce_bytes), plaintext.as_ref())
            .map_err(|_| anyhow::anyhow!("encryption failed"))?;
        let mut combined = Vec::with_capacity(12 + ciphertext.len());
        combined.extend_from_slice(&nonce_bytes);
        combined.extend_from_slice(&ciphertext);
        Ok(encode_outer(SEALED, &combined))
    }
}
