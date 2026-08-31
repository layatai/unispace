use crate::{
    CLIPBOARD_PORT,
    config::Configuration,
    model::Identifier,
    secure::{ChannelProfile, SecureStream},
};
use anyhow::{Context, Result, ensure};
use arboard::Clipboard;
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::time::{MissedTickBehavior, interval};
use tracing::warn;
use uuid::Uuid;

const HEADER: usize = 39;

pub async fn run(configuration: Configuration) -> Result<()> {
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
            port: CLIPBOARD_PORT,
            hello_prefix: "UniSpace secure clipboard hello v1",
            info_prefix: "UniSpace clipboard channel v1",
        },
    )
    .await?;
    let mut clipboard = Clipboard::new()?;
    let mut ticker = interval(Duration::from_millis(350));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut last = clipboard.get_text().unwrap_or_default();
    let mut revision = 0u64;
    loop {
        tokio::select! {
            packet=channel.receive()=>{
                let packet=packet?;
                if let Some(text)=decode(&packet,configuration.workspace.id.raw_value,remote.id.raw_value)?
                    && text!=last
                {
                    clipboard.set_text(text.clone())?;
                    last=text;
                }
            }
            _=ticker.tick()=>if let Ok(text)=clipboard.get_text()
                && !text.is_empty() && text!=last
            {
                last=text.clone();
                revision=revision.saturating_add(1);
                channel.send(&encode(configuration.workspace.id.raw_value,configuration.device_id,revision,&text)?).await?;
            }
        }
    }
}

pub async fn supervise(configuration: Configuration) {
    loop {
        if let Err(error) = run(configuration.clone()).await {
            warn!(%error,"clipboard channel disconnected");
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

fn encode(workspace: Uuid, sender: Uuid, revision: u64, text: &str) -> Result<Vec<u8>> {
    ensure!(
        text.len() <= 256 * 1024,
        "clipboard representation too large"
    );
    let mut representations = vec![("plainText", text)];
    if is_portable_url(text) {
        representations.push(("url", text));
    }
    let mut canonical = Vec::new();
    for (kind, value) in &representations {
        canonical.extend_from_slice(&(kind.len() as u32).to_be_bytes());
        canonical.extend_from_slice(kind.as_bytes());
        canonical.extend_from_slice(&(value.len() as u32).to_be_bytes());
        canonical.extend_from_slice(value.as_bytes());
    }
    let hash = Sha256::digest(&canonical);
    let representations = representations
        .into_iter()
        .map(|(kind, value)| json!({"kind":kind,"value":value}))
        .collect::<Vec<_>>();
    let payload = serde_json::to_vec(
        &json!({"payloadID":Identifier::new(),"originDeviceID":Identifier{raw_value:sender},"revision":revision,"timestamp":now_iso8601(),"contentHash":BASE64.encode(hash),"representations":representations}),
    )?;
    ensure!(
        payload.len() + HEADER <= 600 * 1024,
        "clipboard payload too large"
    );
    let mut out = Vec::with_capacity(HEADER + payload.len());
    out.extend_from_slice(&1u16.to_be_bytes());
    out.push(1);
    out.extend_from_slice(workspace.as_bytes());
    out.extend_from_slice(sender.as_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&payload);
    Ok(out)
}

fn is_portable_url(value: &str) -> bool {
    let Some((scheme, _)) = value.trim().split_once(':') else {
        return false;
    };
    !scheme.eq_ignore_ascii_case("file")
        && scheme.starts_with(|character: char| character.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "+-.".contains(character))
}

fn decode(data: &[u8], workspace: Uuid, sender: Uuid) -> Result<Option<String>> {
    ensure!(
        data.len() >= HEADER && u16::from_be_bytes(data[0..2].try_into()?) == 1 && data[2] == 1,
        "invalid clipboard envelope"
    );
    ensure!(
        &data[3..19] == workspace.as_bytes() && &data[19..35] == sender.as_bytes(),
        "clipboard peer mismatch"
    );
    let length = u32::from_be_bytes(data[35..39].try_into()?) as usize;
    ensure!(length == data.len() - HEADER, "invalid clipboard length");
    let payload: Value = serde_json::from_slice(&data[HEADER..])?;
    let representations = payload["representations"]
        .as_array()
        .context("missing representations")?;
    Ok(representations
        .iter()
        .find(|v| v["kind"] == "plainText")
        .and_then(|v| v["value"].as_str())
        .map(str::to_owned))
}

pub fn now_iso8601() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    iso8601(seconds)
}
fn iso8601(seconds: f64) -> String {
    let whole = seconds as i64;
    let millis = ((seconds - whole as f64) * 1000.0) as u32;
    // GNU date is not needed at runtime; this compact UTC conversion handles the supported date range.
    let days = whole.div_euclid(86400);
    let secs = whole.rem_euclid(86400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    y += if m <= 2 { 1 } else { 0 };
    (y, m as u32, d as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_trip() {
        let w = Uuid::new_v4();
        let d = Uuid::new_v4();
        let value = encode(w, d, 1, "hello").unwrap();
        assert_eq!(decode(&value, w, d).unwrap(), Some("hello".into()));
    }

    #[test]
    fn recognizes_portable_urls_but_not_file_urls() {
        assert!(is_portable_url("https://example.com/path"));
        assert!(is_portable_url("mailto:hello@example.com"));
        assert!(!is_portable_url("file:///home/user/document.txt"));
        assert!(!is_portable_url("ordinary clipboard text"));
    }
}
