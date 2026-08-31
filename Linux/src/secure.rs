use crate::model::uuid_wire;
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
use subtle::ConstantTimeEq;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use uuid::Uuid;

type HmacSha256 = Hmac<Sha256>;
const HELLO: u8 = 10;
const SEALED: u8 = 11;

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecureHello {
    version: u16,
    workspace_id: Uuid,
    device_id: Uuid,
    #[serde(with = "base64_bytes")]
    nonce: Vec<u8>,
    #[serde(with = "base64_bytes")]
    proof: Vec<u8>,
    supported_wire_versions: Vec<u16>,
}

pub struct SecureStream {
    stream: TcpStream,
    key: [u8; 32],
    outbound_sequence: u64,
    inbound_sequence: Option<u64>,
}

pub struct ChannelProfile {
    pub port: u16,
    pub hello_prefix: &'static str,
    pub info_prefix: &'static str,
}

impl SecureStream {
    pub async fn connect_control(
        address: &str,
        local_device: Uuid,
        remote_device: Uuid,
        workspace: Uuid,
        workspace_key: &[u8],
    ) -> Result<Self> {
        let stream = TcpStream::connect((address, crate::CONTROL_PORT))
            .await
            .with_context(|| format!("connect to {address}:{}", crate::CONTROL_PORT))?;
        Self::authenticate(
            stream,
            local_device,
            Some(remote_device),
            workspace,
            workspace_key,
            ChannelProfile {
                port: crate::CONTROL_PORT,
                hello_prefix: "UniSpace secure hello v1",
                info_prefix: "UniSpace channel v1",
            },
        )
        .await
    }

    pub async fn connect_named(
        address: &str,
        local_device: Uuid,
        remote_device: Uuid,
        workspace: Uuid,
        workspace_key: &[u8],
        profile: ChannelProfile,
    ) -> Result<Self> {
        let stream = TcpStream::connect((address, profile.port)).await?;
        Self::authenticate(
            stream,
            local_device,
            Some(remote_device),
            workspace,
            workspace_key,
            profile,
        )
        .await
    }

    async fn authenticate(
        mut stream: TcpStream,
        local_device: Uuid,
        expected_device: Option<Uuid>,
        workspace: Uuid,
        workspace_key: &[u8],
        profile: ChannelProfile,
    ) -> Result<Self> {
        ensure!(workspace_key.len() >= 32, "workspace key is too short");
        let mut local_nonce = vec![0u8; 32];
        OsRng.fill_bytes(&mut local_nonce);
        let proof = hello_proof(
            workspace_key,
            profile.hello_prefix,
            workspace,
            local_device,
            &local_nonce,
        )?;
        let hello = SecureHello {
            version: 1,
            workspace_id: workspace,
            device_id: local_device,
            nonce: local_nonce.clone(),
            proof,
            supported_wire_versions: vec![1, 2],
        };
        write_outer(&mut stream, HELLO, &serde_json::to_vec(&hello)?).await?;
        let (kind, payload) = read_outer(&mut stream).await?;
        ensure!(kind == HELLO, "expected secure hello");
        let peer: SecureHello = serde_json::from_slice(&payload)?;
        ensure!(
            peer.version == 1
                && peer.workspace_id == workspace
                && peer.nonce.len() == 32
                && peer.proof.len() == 32,
            "invalid secure hello"
        );
        if let Some(expected) = expected_device {
            ensure!(peer.device_id == expected, "unexpected secure peer");
        }
        let expected = hello_proof(
            workspace_key,
            profile.hello_prefix,
            workspace,
            peer.device_id,
            &peer.nonce,
        )?;
        ensure!(
            bool::from(expected.ct_eq(&peer.proof)),
            "secure hello authentication failed"
        );
        let local_first = uuid_wire(local_device) < uuid_wire(peer.device_id);
        let mut salt = Vec::with_capacity(64);
        if local_first {
            salt.extend_from_slice(&local_nonce);
            salt.extend_from_slice(&peer.nonce)
        } else {
            salt.extend_from_slice(&peer.nonce);
            salt.extend_from_slice(&local_nonce)
        }
        let info = format!("{}|{}", profile.info_prefix, uuid_wire(workspace));
        let hk = Hkdf::<Sha256>::new(Some(&salt), workspace_key);
        let mut key = [0u8; 32];
        hk.expand(info.as_bytes(), &mut key)
            .map_err(|_| anyhow::anyhow!("HKDF failed"))?;
        Ok(Self {
            stream,
            key,
            outbound_sequence: 0,
            inbound_sequence: None,
        })
    }

    pub async fn send(&mut self, data: &[u8]) -> Result<()> {
        let mut plaintext = Vec::with_capacity(data.len() + 8);
        plaintext.extend_from_slice(&self.outbound_sequence.to_be_bytes());
        plaintext.extend_from_slice(data);
        self.outbound_sequence = self
            .outbound_sequence
            .checked_add(1)
            .context("sequence exhausted")?;
        let mut nonce_bytes = [0u8; 12];
        OsRng.fill_bytes(&mut nonce_bytes);
        let cipher = ChaCha20Poly1305::new_from_slice(&self.key)?;
        let ciphertext = cipher
            .encrypt(Nonce::from_slice(&nonce_bytes), plaintext.as_ref())
            .map_err(|_| anyhow::anyhow!("encryption failed"))?;
        let mut combined = Vec::with_capacity(12 + ciphertext.len());
        combined.extend_from_slice(&nonce_bytes);
        combined.extend_from_slice(&ciphertext);
        write_outer(&mut self.stream, SEALED, &combined).await
    }

    pub async fn receive(&mut self) -> Result<Vec<u8>> {
        loop {
            let (kind, payload) = read_outer(&mut self.stream).await?;
            if kind == HELLO {
                continue;
            }
            ensure!(
                kind == SEALED && payload.len() >= 28,
                "invalid secure packet"
            );
            let cipher = ChaCha20Poly1305::new_from_slice(&self.key)?;
            let plaintext = cipher
                .decrypt(Nonce::from_slice(&payload[..12]), &payload[12..])
                .map_err(|_| anyhow::anyhow!("authentication failed"))?;
            ensure!(plaintext.len() >= 8, "truncated secure packet");
            let sequence = u64::from_be_bytes(plaintext[..8].try_into()?);
            ensure!(
                self.inbound_sequence.is_none_or(|last| sequence > last),
                "replayed secure packet"
            );
            self.inbound_sequence = Some(sequence);
            return Ok(plaintext[8..].to_vec());
        }
    }
}

fn hello_proof(
    key: &[u8],
    prefix: &str,
    workspace: Uuid,
    device: Uuid,
    nonce: &[u8],
) -> Result<Vec<u8>> {
    let mut payload = Vec::new();
    payload.extend_from_slice(prefix.as_bytes());
    payload.extend_from_slice(uuid_wire(workspace).as_bytes());
    payload.extend_from_slice(uuid_wire(device).as_bytes());
    payload.extend_from_slice(nonce);
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key)?;
    mac.update(&payload);
    Ok(mac.finalize().into_bytes().to_vec())
}

async fn write_outer(stream: &mut TcpStream, kind: u8, payload: &[u8]) -> Result<()> {
    ensure!(
        payload.len() <= crate::protocol::MAX_WIRE_PAYLOAD + 64,
        "outer packet too large"
    );
    stream
        .write_all(&(payload.len() as u32).to_be_bytes())
        .await?;
    stream.write_u8(kind).await?;
    stream.write_all(payload).await?;
    Ok(())
}
async fn read_outer(stream: &mut TcpStream) -> Result<(u8, Vec<u8>)> {
    let length = stream.read_u32().await? as usize;
    ensure!(
        length <= crate::protocol::MAX_WIRE_PAYLOAD + 64,
        "outer packet too large"
    );
    let kind = stream.read_u8().await?;
    if kind != HELLO && kind != SEALED {
        bail!("invalid secure packet kind")
    };
    let mut payload = vec![0; length];
    stream.read_exact(&mut payload).await?;
    Ok((kind, payload))
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
