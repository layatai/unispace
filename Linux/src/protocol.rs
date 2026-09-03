use crate::model::{DeviceDescriptor, Identifier, WorkspaceSnapshot};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::io::{Cursor, Read};
use uuid::Uuid;

pub const MAX_WIRE_PAYLOAD: usize = 1_048_576;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum WireKind {
    ControlJsonV2 = 4,
    InputBinaryV2 = 5,
    RealtimePointerBinaryV2 = 6,
}

impl TryFrom<u8> for WireKind {
    type Error = anyhow::Error;
    fn try_from(value: u8) -> Result<Self> {
        match value {
            4 => Ok(Self::ControlJsonV2),
            5 => Ok(Self::InputBinaryV2),
            6 => Ok(Self::RealtimePointerBinaryV2),
            _ => bail!("unsupported portable wire kind {value}"),
        }
    }
}

pub fn frame(kind: WireKind, payload: &[u8]) -> Result<Vec<u8>> {
    ensure!(
        payload.len() <= MAX_WIRE_PAYLOAD,
        "wire payload is too large"
    );
    let mut out = Vec::with_capacity(payload.len() + 5);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.push(kind as u8);
    out.extend_from_slice(payload);
    Ok(out)
}

pub fn decode_frame(data: &[u8]) -> Result<(WireKind, &[u8])> {
    ensure!(data.len() >= 5, "truncated wire frame");
    let length = u32::from_be_bytes(data[0..4].try_into()?) as usize;
    ensure!(
        length <= MAX_WIRE_PAYLOAD && data.len() == length + 5,
        "invalid wire length"
    );
    Ok((WireKind::try_from(data[4])?, &data[5..]))
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum DisplayEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl DisplayEdge {
    fn from_json(value: &str) -> Result<Self> {
        match value {
            "left" => Ok(Self::Left),
            "right" => Ok(Self::Right),
            "top" => Ok(Self::Top),
            "bottom" => Ok(Self::Bottom),
            _ => bail!("invalid edge"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Top => "top",
            Self::Bottom => "bottom",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ControlMessage {
    Hello(DeviceDescriptor),
    Workspace(WorkspaceSnapshot),
    ControllerClaim {
        generation: u64,
        controller_id: Uuid,
    },
    Activate {
        session_id: Uuid,
        generation: u64,
        controller_id: Uuid,
        display_id: Uuid,
        edge: DisplayEdge,
        position: f64,
    },
    Deactivate {
        session_id: Uuid,
    },
    Heartbeat {
        session_id: Uuid,
        timestamp_nanos: u64,
    },
    ReleaseAll {
        session_id: Uuid,
    },
    RotateWorkspaceKey(Vec<u8>),
    Other(String),
}

pub fn decode_control(payload: &[u8]) -> Result<ControlMessage> {
    let root: Value = serde_json::from_slice(payload).context("invalid portable control JSON")?;
    ensure!(
        root.get("version").and_then(Value::as_u64) == Some(2),
        "unsupported control version"
    );
    let kind = root
        .get("type")
        .and_then(Value::as_str)
        .context("missing control type")?;
    let p = root.get("payload").context("missing control payload")?;
    let id = |name: &str| -> Result<Uuid> {
        let raw = p
            .get(name)
            .and_then(|v| v.get("rawValue"))
            .and_then(Value::as_str)
            .context("missing identifier")?;
        Ok(Uuid::parse_str(raw)?)
    };
    Ok(match kind {
        "hello" => ControlMessage::Hello(serde_json::from_value(p["device"].clone())?),
        "workspace" => ControlMessage::Workspace(serde_json::from_value(p["workspace"].clone())?),
        "controllerClaim" => ControlMessage::ControllerClaim {
            generation: p["epoch"]["generation"]
                .as_u64()
                .context("missing generation")?,
            controller_id: Uuid::parse_str(
                p["epoch"]["controllerID"]["rawValue"]
                    .as_str()
                    .context("missing controller")?,
            )?,
        },
        "activate" => {
            let a = &p["activation"];
            ControlMessage::Activate {
                session_id: Uuid::parse_str(
                    a["sessionID"]["rawValue"]
                        .as_str()
                        .context("missing session")?,
                )?,
                generation: a["epoch"]["generation"]
                    .as_u64()
                    .context("missing generation")?,
                controller_id: Uuid::parse_str(
                    a["epoch"]["controllerID"]["rawValue"]
                        .as_str()
                        .context("missing controller")?,
                )?,
                display_id: Uuid::parse_str(
                    a["targetDisplayID"]["rawValue"]
                        .as_str()
                        .context("missing display")?,
                )?,
                edge: DisplayEdge::from_json(a["entryEdge"].as_str().context("missing edge")?)?,
                position: a["normalizedPosition"]
                    .as_f64()
                    .context("missing position")?,
            }
        }
        "deactivate" => ControlMessage::Deactivate {
            session_id: id("sessionID")?,
        },
        "heartbeat" => ControlMessage::Heartbeat {
            session_id: id("sessionID")?,
            timestamp_nanos: p["timestampNanos"].as_u64().context("missing timestamp")?,
        },
        "releaseAll" => ControlMessage::ReleaseAll {
            session_id: id("sessionID")?,
        },
        "rotateWorkspaceKey" => ControlMessage::RotateWorkspaceKey(base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            p["workspaceKey"].as_str().context("missing key")?,
        )?),
        other => ControlMessage::Other(other.to_owned()),
    })
}

pub fn hello_frame(device: &DeviceDescriptor) -> Result<Vec<u8>> {
    let payload =
        serde_json::to_vec(&json!({"version":2,"type":"hello","payload":{"device":device}}))?;
    frame(WireKind::ControlJsonV2, &payload)
}

pub fn activation_result_frame(session: Uuid, accepted: bool) -> Result<Vec<u8>> {
    let payload = serde_json::to_vec(&json!({
        "version":2,"type":"activationResult","payload":{
            "sessionID": Identifier { raw_value: session }, "accepted":accepted
        }
    }))?;
    frame(WireKind::ControlJsonV2, &payload)
}

pub fn boundary_crossed_frame(
    session: Uuid,
    display: Uuid,
    edge: DisplayEdge,
    normalized_position: f64,
) -> Result<Vec<u8>> {
    let payload = serde_json::to_vec(&json!({
        "version":2,"type":"boundaryCrossed","payload":{
            "sessionID":Identifier{raw_value:session},
            "displayID":Identifier{raw_value:display},
            "edge":edge.as_str(),
            "normalizedPosition":normalized_position.clamp(0.0,1.0)
        }
    }))?;
    frame(WireKind::ControlJsonV2, &payload)
}

pub fn heartbeat_frame(session: Uuid, timestamp_nanos: u64) -> Result<Vec<u8>> {
    let payload = serde_json::to_vec(&json!({
        "version":2,"type":"heartbeat","payload":{
            "sessionID":Identifier{raw_value:session},
            "timestampNanos":timestamp_nanos
        }
    }))?;
    frame(WireKind::ControlJsonV2, &payload)
}

pub fn realtime_pointer_progress_frame(
    session: Uuid,
    generation: u64,
    sequence: u64,
) -> Result<Vec<u8>> {
    let payload = serde_json::to_vec(&json!({
        "version":2,"type":"realtimePointerProgress","payload":{
            "sessionID":Identifier{raw_value:session},
            "generation":generation,
            "sequence":sequence
        }
    }))?;
    frame(WireKind::ControlJsonV2, &payload)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Epoch {
    pub generation: u64,
    pub controller_id: Uuid,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PortableInputFrame {
    pub workspace_id: Uuid,
    pub session_id: Uuid,
    pub controller_id: Uuid,
    pub epoch: Epoch,
    pub sequence: u64,
    pub timestamp_nanos: u64,
    pub event: InputEvent,
}

#[derive(Clone, Debug, PartialEq)]
pub enum InputEvent {
    PointerMove {
        dx: f64,
        dy: f64,
        absolute_x: f64,
        absolute_y: f64,
    },
    MouseButton {
        button: u8,
        down: bool,
        click_count: u16,
    },
    Scroll {
        dx: f64,
        dy: f64,
        continuous: bool,
    },
    Key {
        usage: u16,
        down: bool,
        repeat: bool,
    },
    Modifiers(u16),
    Gesture {
        kind: u8,
        phase: u8,
        dx: f64,
        dy: f64,
        value: f64,
    },
}

struct Reader(Cursor<Vec<u8>>);
impl Reader {
    fn take<const N: usize>(&mut self) -> Result<[u8; N]> {
        let mut v = [0; N];
        self.0.read_exact(&mut v)?;
        Ok(v)
    }
    fn u8(&mut self) -> Result<u8> {
        Ok(self.take::<1>()?[0])
    }
    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.take()?))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.take()?))
    }
    fn f64(&mut self) -> Result<f64> {
        Ok(f64::from_bits(self.u64()?))
    }
    fn uuid(&mut self) -> Result<Uuid> {
        Ok(Uuid::from_bytes(self.take()?))
    }
    fn bool(&mut self) -> Result<bool> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => bail!("invalid boolean"),
        }
    }
    fn end(&self) -> Result<()> {
        ensure!(
            self.0.position() as usize == self.0.get_ref().len(),
            "trailing input bytes"
        );
        Ok(())
    }
}

pub fn decode_input(payload: &[u8], realtime: bool) -> Result<PortableInputFrame> {
    let mut r = Reader(Cursor::new(payload.to_vec()));
    ensure!(r.u16()? == 2, "unsupported input version");
    let workspace_id = r.uuid()?;
    let session_id = r.uuid()?;
    let controller_id = r.uuid()?;
    let epoch = Epoch {
        generation: r.u64()?,
        controller_id: r.uuid()?,
    };
    if realtime {
        let _generation = r.u64()?;
        let sequence = r.u64()?;
        let dx = r.f64()?;
        let dy = r.f64()?;
        let _cumulative_x = r.f64()?;
        let _cumulative_y = r.f64()?;
        let event = InputEvent::PointerMove {
            dx,
            dy,
            absolute_x: r.f64()?,
            absolute_y: r.f64()?,
        };
        let timestamp_nanos = r.u64()?;
        r.end()?;
        return Ok(PortableInputFrame {
            workspace_id,
            session_id,
            controller_id,
            epoch,
            sequence,
            timestamp_nanos,
            event,
        });
    }
    let sequence = r.u64()?;
    let timestamp_nanos = r.u64()?;
    let event = match r.u8()? {
        1 => InputEvent::PointerMove {
            dx: r.f64()?,
            dy: r.f64()?,
            absolute_x: r.f64()?,
            absolute_y: r.f64()?,
        },
        2 => InputEvent::MouseButton {
            button: r.u8()?,
            down: r.bool()?,
            click_count: r.u16()?,
        },
        3 => InputEvent::Scroll {
            dx: r.f64()?,
            dy: r.f64()?,
            continuous: r.bool()?,
        },
        4 => InputEvent::Key {
            usage: r.u16()?,
            down: r.bool()?,
            repeat: r.bool()?,
        },
        5 => InputEvent::Modifiers(r.u16()?),
        6 => InputEvent::Gesture {
            kind: r.u8()?,
            phase: r.u8()?,
            dx: r.f64()?,
            dy: r.f64()?,
            value: r.f64()?,
        },
        value => bail!("unknown input event {value}"),
    };
    r.end()?;
    Ok(PortableInputFrame {
        workspace_id,
        session_id,
        controller_id,
        epoch,
        sequence,
        timestamp_nanos,
        event,
    })
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RealtimePointerFrame {
    pub workspace_id: Uuid,
    pub session_id: Uuid,
    pub controller_id: Uuid,
    pub epoch: Epoch,
    pub generation: u64,
    pub sequence: u64,
    pub dx: f64,
    pub dy: f64,
    pub cumulative_x: f64,
    pub cumulative_y: f64,
    pub absolute_x: f64,
    pub absolute_y: f64,
    pub timestamp_nanos: u64,
}

/// Decodes a sealed realtime pointer payload (the plaintext after the secure
/// sequence prefix), mirroring `WireFrameCodec`'s portable realtime layout.
pub fn decode_realtime_pointer(payload: &[u8]) -> Result<(WireKind, RealtimePointerFrame)> {
    let (kind, body) = decode_frame(payload)?;
    let mut r = Reader(Cursor::new(body.to_vec()));
    ensure!(r.u16()? == 2, "unsupported input version");
    let workspace_id = r.uuid()?;
    let session_id = r.uuid()?;
    let controller_id = r.uuid()?;
    let epoch = Epoch {
        generation: r.u64()?,
        controller_id: r.uuid()?,
    };
    let generation = r.u64()?;
    let sequence = r.u64()?;
    let timestamp_nanos = r.u64()?;
    let dx = r.f64()?;
    let dy = r.f64()?;
    let cumulative_x = r.f64()?;
    let cumulative_y = r.f64()?;
    let absolute_x = r.f64()?;
    let absolute_y = r.f64()?;
    r.end()?;
    Ok((
        kind,
        RealtimePointerFrame {
            workspace_id,
            session_id,
            controller_id,
            epoch,
            generation,
            sequence,
            dx,
            dy,
            cumulative_x,
            cumulative_y,
            absolute_x,
            absolute_y,
            timestamp_nanos,
        },
    ))
}

/// Encodes the realtime pointer wire frame used by the Mac controller.
pub fn encode_realtime_pointer(value: &RealtimePointerFrame) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(128);
    out.extend_from_slice(&2u16.to_be_bytes());
    out.extend_from_slice(value.workspace_id.as_bytes());
    out.extend_from_slice(value.session_id.as_bytes());
    out.extend_from_slice(value.controller_id.as_bytes());
    out.extend_from_slice(&value.epoch.generation.to_be_bytes());
    out.extend_from_slice(value.epoch.controller_id.as_bytes());
    out.extend_from_slice(&value.generation.to_be_bytes());
    out.extend_from_slice(&value.sequence.to_be_bytes());
    out.extend_from_slice(&value.timestamp_nanos.to_be_bytes());
    for field in [
        value.dx,
        value.dy,
        value.cumulative_x,
        value.cumulative_y,
        value.absolute_x,
        value.absolute_y,
    ] {
        out.extend_from_slice(&field.to_bits().to_be_bytes());
    }
    frame(WireKind::RealtimePointerBinaryV2, &out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_shared_key_vector() -> Result<()> {
        let bytes=hex::decode("0002000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f0000000000000004303132333435363738393a3b3c3d3e3f000000000000000500000000000000060400040100").unwrap();
        let value = decode_input(&bytes, false).unwrap();
        assert_eq!(value.sequence, 5);
        assert_eq!(
            value.event,
            InputEvent::Key {
                usage: 4,
                down: true,
                repeat: false
            }
        );
        Ok(())
    }

    #[test]
    fn realtime_pointer_matches_swift_field_order_and_round_trips() -> Result<()> {
        let value = RealtimePointerFrame {
            workspace_id: Uuid::new_v4(),
            session_id: Uuid::new_v4(),
            controller_id: Uuid::new_v4(),
            epoch: Epoch {
                generation: 9,
                controller_id: Uuid::new_v4(),
            },
            generation: 3,
            sequence: 41,
            dx: 1.5,
            dy: -2.5,
            cumulative_x: 100.25,
            cumulative_y: 50.125,
            absolute_x: 800.0,
            absolute_y: 300.0,
            timestamp_nanos: 123_456,
        };
        let encoded = encode_realtime_pointer(&value)?;
        let (_, payload) = decode_frame(&encoded)?;
        let timestamp_offset = 2 + 16 * 3 + 8 + 16 + 8 + 8;
        assert_eq!(
            &payload[timestamp_offset..timestamp_offset + 8],
            &value.timestamp_nanos.to_be_bytes()
        );
        assert_eq!(
            &payload[timestamp_offset + 8..timestamp_offset + 16],
            &value.dx.to_bits().to_be_bytes()
        );
        let (kind, decoded) = decode_realtime_pointer(&encoded).unwrap();
        assert_eq!(kind, WireKind::RealtimePointerBinaryV2);
        assert_eq!(decoded, value);
        Ok(())
    }

    #[test]
    fn control_frames_use_mac_field_names() -> Result<()> {
        let session = Uuid::new_v4();
        let progress_frame = realtime_pointer_progress_frame(session, 7, 3)?;
        let (_, progress_payload) = decode_frame(&progress_frame)?;
        let progress = decode_control(progress_payload)?;
        match progress {
            ControlMessage::Other(message) => {
                assert_eq!(message, "realtimePointerProgress")
            }
            other => panic!("unexpected {other:?}"),
        }
        let heartbeat_frame = heartbeat_frame(session, 99)?;
        let (_, heartbeat_payload) = decode_frame(&heartbeat_frame)?;
        let heartbeat = decode_control(heartbeat_payload)?;
        assert_eq!(
            heartbeat,
            ControlMessage::Heartbeat {
                session_id: session,
                timestamp_nanos: 99
            }
        );
        Ok(())
    }
}
