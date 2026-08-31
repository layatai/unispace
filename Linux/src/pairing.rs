use crate::{
    PAIRING_PORT,
    config::Configuration,
    model::{DeviceDescriptor, WorkspaceSnapshot},
};
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use chacha20poly1305::{
    ChaCha20Poly1305, Nonce,
    aead::{Aead, KeyInit},
};
use hkdf::Hkdf;
use p256::{EncodedPoint, PublicKey, ecdh::EphemeralSecret};
use rand::{RngCore, rngs::OsRng};
use serde_json::{Value, json};
use sha2::Sha256;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

pub struct PendingPairing {
    stream: TcpStream,
    key: [u8; 32],
    pub code: String,
    pub peer_name: String,
}

impl PendingPairing {
    pub async fn begin(address: &str, device: &DeviceDescriptor) -> Result<Self> {
        let mut stream = TcpStream::connect((address, PAIRING_PORT))
            .await
            .with_context(|| format!("connect to {address}:{PAIRING_PORT}"))?;
        let offer_message = read_message(&mut stream).await?;
        let offer = &offer_message["offer"];
        let peer_name = offer["device"]["name"].as_str().unwrap_or("Mac").to_owned();
        let peer_public = BASE64.decode(
            offer["offer"]["publicKey"]
                .as_str()
                .context("missing public key")?,
        )?;
        let peer_nonce =
            BASE64.decode(offer["offer"]["nonce"].as_str().context("missing nonce")?)?;
        let secret = EphemeralSecret::random(&mut OsRng);
        let public = EncodedPoint::from(secret.public_key()).as_bytes().to_vec();
        let mut nonce = vec![0u8; 32];
        OsRng.fill_bytes(&mut nonce);
        let peer_key = PublicKey::from_sec1_bytes(&peer_public)?;
        let shared = secret.diffie_hellman(&peer_key);
        let local_first = public < peer_public;
        let mut transcript = Vec::new();
        if local_first {
            transcript.extend_from_slice(&public);
            transcript.extend_from_slice(&peer_public);
            transcript.extend_from_slice(&nonce);
            transcript.extend_from_slice(&peer_nonce)
        } else {
            transcript.extend_from_slice(&peer_public);
            transcript.extend_from_slice(&public);
            transcript.extend_from_slice(&peer_nonce);
            transcript.extend_from_slice(&nonce)
        }
        let hk = Hkdf::<Sha256>::new(Some(&transcript), shared.raw_secret_bytes().as_slice());
        let mut key = [0u8; 32];
        hk.expand(b"UniSpace pairing v1", &mut key)
            .map_err(|_| anyhow::anyhow!("pairing HKDF failed"))?;
        let code = format!(
            "{:06}",
            u32::from_be_bytes(key[..4].try_into()?) % 1_000_000
        );
        let join = json!({"join":{"device":device,"offer":{"publicKey":BASE64.encode(public),"nonce":BASE64.encode(nonce)}}});
        write_message(&mut stream, &join).await?;
        Ok(Self {
            stream,
            key,
            code,
            peer_name,
        })
    }
    pub async fn confirm(mut self, address: String) -> Result<Configuration> {
        write_message(&mut self.stream, &json!({"confirmation":{}})).await?;
        loop {
            let message = read_message(&mut self.stream).await?;
            if message.get("confirmation").is_some() {
                continue;
            }
            if let Some(value) = message.get("credential") {
                let mut workspace: WorkspaceSnapshot =
                    serde_json::from_value(value["workspace"].clone())?;
                let combined = BASE64.decode(
                    value["sealed"]["combined"]
                        .as_str()
                        .context("missing sealed key")?,
                )?;
                ensure!(combined.len() >= 28, "invalid sealed credential");
                let cipher = ChaCha20Poly1305::new_from_slice(&self.key)?;
                let key = cipher
                    .decrypt(Nonce::from_slice(&combined[..12]), &combined[12..])
                    .map_err(|_| anyhow::anyhow!("credential authentication failed"))?;
                let local = workspace
                    .devices
                    .iter()
                    .find(|d| d.platform.raw_value == "linux")
                    .context("Linux device missing from workspace")?;
                workspace.local_device_id = local.id;
                let configuration = Configuration {
                    device_id: local.id.raw_value,
                    host_address: address,
                    workspace,
                };
                configuration.save(&key)?;
                return Ok(configuration);
            }
        }
    }
}

async fn read_message(stream: &mut TcpStream) -> Result<Value> {
    let size = stream.read_u32().await? as usize;
    ensure!(size <= 65_536, "pairing message too large");
    let mut data = vec![0; size];
    stream.read_exact(&mut data).await?;
    Ok(serde_json::from_slice(&data)?)
}
async fn write_message(stream: &mut TcpStream, value: &Value) -> Result<()> {
    let data = serde_json::to_vec(value)?;
    ensure!(data.len() <= 65_536, "pairing message too large");
    stream.write_u32(data.len() as u32).await?;
    stream.write_all(&data).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::{SecretKey, ecdh::diffie_hellman, elliptic_curve::sec1::ToEncodedPoint};

    #[test]
    fn matches_shared_swift_pairing_vector() {
        let private = SecretKey::from_slice(
            &hex::decode("0000000000000000000000000000000000000000000000000000000000000001")
                .unwrap(),
        )
        .unwrap();
        let public_a = private
            .public_key()
            .to_encoded_point(false)
            .as_bytes()
            .to_vec();
        let public_b = hex::decode("047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1").unwrap();
        let peer = PublicKey::from_sec1_bytes(&public_b).unwrap();
        let shared = diffie_hellman(private.to_nonzero_scalar(), peer.as_affine());
        let nonce_a =
            hex::decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
                .unwrap();
        let nonce_b =
            hex::decode("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
                .unwrap();
        let mut transcript = Vec::new();
        transcript.extend_from_slice(&public_a);
        transcript.extend_from_slice(&public_b);
        transcript.extend_from_slice(&nonce_a);
        transcript.extend_from_slice(&nonce_b);
        let hk = Hkdf::<Sha256>::new(Some(&transcript), shared.raw_secret_bytes().as_slice());
        let mut key = [0u8; 32];
        hk.expand(b"UniSpace pairing v1", &mut key).unwrap();
        assert_eq!(
            hex::encode(key),
            "0b368f28c7b208f081c207f5cce6f5493d1f3524109cdfe6e0ff6463ee94ceea"
        );
        assert_eq!(
            u32::from_be_bytes(key[..4].try_into().unwrap()) % 1_000_000,
            124_968
        );
    }
}
