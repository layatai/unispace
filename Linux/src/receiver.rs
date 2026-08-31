use crate::{
    config::Configuration,
    input::InputSink,
    model::DeviceDescriptor,
    protocol::{self, ControlMessage, Epoch, WireKind},
    secure::SecureStream,
};
use anyhow::{Context, Result, ensure};
use std::{collections::BTreeSet, time::Duration};
use tokio::time::sleep;
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Default)]
struct SessionState {
    active: Option<(Uuid, Epoch)>,
    last_sequence: Option<u64>,
    cursor: Option<CursorState>,
}

struct CursorState {
    display_id: Uuid,
    width: f64,
    height: f64,
    x: f64,
    y: f64,
    linked_edges: BTreeSet<protocol::DisplayEdge>,
}

impl CursorState {
    fn advance(&mut self, dx: f64, dy: f64) -> Option<(protocol::DisplayEdge, f64)> {
        let next_x = self.x + dx;
        let next_y = self.y + dy;
        let crossed = if next_x < 0.0 && self.linked_edges.contains(&protocol::DisplayEdge::Left) {
            Some((
                protocol::DisplayEdge::Left,
                (next_y / self.height).clamp(0.0, 1.0),
            ))
        } else if next_x >= self.width && self.linked_edges.contains(&protocol::DisplayEdge::Right)
        {
            Some((
                protocol::DisplayEdge::Right,
                (next_y / self.height).clamp(0.0, 1.0),
            ))
        } else if next_y < 0.0 && self.linked_edges.contains(&protocol::DisplayEdge::Top) {
            Some((
                protocol::DisplayEdge::Top,
                (next_x / self.width).clamp(0.0, 1.0),
            ))
        } else if next_y >= self.height
            && self.linked_edges.contains(&protocol::DisplayEdge::Bottom)
        {
            Some((
                protocol::DisplayEdge::Bottom,
                (next_x / self.width).clamp(0.0, 1.0),
            ))
        } else {
            None
        };
        self.x = next_x.clamp(0.0, self.width - 1.0);
        self.y = next_y.clamp(0.0, self.height - 1.0);
        crossed
    }
}

pub async fn run(configuration: Configuration, mut input: impl InputSink) -> Result<()> {
    let local = configuration
        .workspace
        .devices
        .iter()
        .find(|d| d.id.raw_value == configuration.device_id)
        .context("local device missing")?
        .clone();
    let remote = configuration
        .workspace
        .mac()
        .context("controller Mac missing")?
        .clone();
    loop {
        let key = configuration.workspace_key()?;
        match run_connection(&configuration, &key, &local, &remote, &mut input).await {
            Ok(()) => warn!("controller disconnected"),
            Err(error) => warn!(%error,"controller connection failed"),
        }
        input.release_all()?;
        sleep(Duration::from_secs(2)).await;
    }
}

async fn run_connection(
    configuration: &Configuration,
    key: &[u8],
    local: &DeviceDescriptor,
    remote: &DeviceDescriptor,
    input: &mut impl InputSink,
) -> Result<()> {
    let mut channel = SecureStream::connect_control(
        &configuration.host_address,
        local.id.raw_value,
        remote.id.raw_value,
        configuration.workspace.id.raw_value,
        key,
    )
    .await?;
    channel.send(&protocol::hello_frame(local)?).await?;
    info!(controller=%remote.name,"connected");
    crate::status::notify(
        "UniSpace connected",
        &format!("{} can now control this PC", remote.name),
    );
    let mut state = SessionState::default();
    loop {
        let packet = channel.receive().await?;
        let (kind, payload) = protocol::decode_frame(&packet)?;
        match kind {
            WireKind::ControlJsonV2 => match protocol::decode_control(payload)? {
                ControlMessage::Activate {
                    session_id,
                    generation,
                    controller_id,
                    display_id,
                    edge,
                    position,
                } => {
                    let display = local
                        .displays
                        .iter()
                        .find(|display| display.id.raw_value == display_id);
                    let accepted = controller_id == remote.id.raw_value && display.is_some();
                    if let Some(display) = display.filter(|_| accepted) {
                        input.release_all()?;
                        input.activate(
                            display.frame.width,
                            display.frame.height,
                            edge,
                            position,
                        )?;
                        let (x, y) = match edge {
                            protocol::DisplayEdge::Left => (1.0, display.frame.height * position),
                            protocol::DisplayEdge::Right => {
                                (display.frame.width - 2.0, display.frame.height * position)
                            }
                            protocol::DisplayEdge::Top => (display.frame.width * position, 1.0),
                            protocol::DisplayEdge::Bottom => {
                                (display.frame.width * position, display.frame.height - 2.0)
                            }
                        };
                        state.active = Some((
                            session_id,
                            Epoch {
                                generation,
                                controller_id,
                            },
                        ));
                        state.last_sequence = None;
                        state.cursor = Some(CursorState {
                            display_id,
                            width: display.frame.width,
                            height: display.frame.height,
                            x,
                            y,
                            linked_edges: linked_edges(
                                &configuration.workspace.topology,
                                display_id,
                            ),
                        });
                    }
                    channel
                        .send(&protocol::activation_result_frame(session_id, accepted)?)
                        .await?;
                }
                ControlMessage::Deactivate { session_id }
                | ControlMessage::ReleaseAll { session_id } => {
                    if state.active.is_some_and(|active| active.0 == session_id) {
                        input.release_all()?;
                        state = SessionState::default();
                    }
                }
                ControlMessage::RotateWorkspaceKey(key) => {
                    ensure!(key.len() >= 32, "rotated workspace key is too short");
                    configuration.replace_workspace_key(&key)?;
                    return Ok(());
                }
                _ => {}
            },
            WireKind::InputBinaryV2 | WireKind::RealtimePointerBinaryV2 => {
                let frame =
                    protocol::decode_input(payload, kind == WireKind::RealtimePointerBinaryV2)?;
                ensure!(
                    frame.workspace_id == configuration.workspace.id.raw_value,
                    "input workspace mismatch"
                );
                let Some((session, epoch)) = state.active else {
                    continue;
                };
                ensure!(
                    frame.session_id == session
                        && frame.controller_id == remote.id.raw_value
                        && frame.epoch == epoch,
                    "input session mismatch"
                );
                if kind == WireKind::InputBinaryV2 {
                    if state
                        .last_sequence
                        .is_some_and(|last| frame.sequence <= last)
                    {
                        continue;
                    }
                    state.last_sequence = Some(frame.sequence);
                }
                if let protocol::InputEvent::PointerMove { dx, dy, .. } = &frame.event
                    && let Some((edge, position)) = state
                        .cursor
                        .as_mut()
                        .and_then(|cursor| cursor.advance(*dx, *dy))
                {
                    let display_id = state.cursor.as_ref().unwrap().display_id;
                    channel
                        .send(&protocol::boundary_crossed_frame(
                            session, display_id, edge, position,
                        )?)
                        .await?;
                    input.release_all()?;
                    state = SessionState::default();
                    continue;
                }
                input.inject(&frame.event)?;
            }
        }
    }
}

fn linked_edges(topology: &serde_json::Value, display_id: Uuid) -> BTreeSet<protocol::DisplayEdge> {
    topology
        .get("links")
        .and_then(|value| value.as_array())
        .into_iter()
        .flatten()
        .filter_map(|link| {
            let source = &link["source"];
            let source_id = source["displayID"]["rawValue"]
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok());
            if source_id != Some(display_id) {
                return None;
            }
            match source["edge"].as_str()? {
                "left" => Some(protocol::DisplayEdge::Left),
                "right" => Some(protocol::DisplayEdge::Right),
                "top" => Some(protocol::DisplayEdge::Top),
                "bottom" => Some(protocol::DisplayEdge::Bottom),
                _ => None,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_only_returns_through_linked_edges() {
        let mut cursor = CursorState {
            display_id: Uuid::nil(),
            width: 100.0,
            height: 50.0,
            x: 1.0,
            y: 25.0,
            linked_edges: [protocol::DisplayEdge::Left].into_iter().collect(),
        };
        assert_eq!(
            cursor.advance(-2.0, 0.0),
            Some((protocol::DisplayEdge::Left, 0.5))
        );
        cursor.x = 99.0;
        assert_eq!(cursor.advance(2.0, 0.0), None);
    }
}
