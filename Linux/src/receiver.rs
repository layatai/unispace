use crate::{
    config::Configuration,
    input::InputSink,
    model::DeviceDescriptor,
    pointer,
    protocol::{self, ControlMessage, Epoch, WireKind},
    secure::SecureStream,
};
use anyhow::{Context, Result, ensure};
use std::{collections::BTreeSet, time::Duration};
use tokio::{
    sync::mpsc,
    time::{Instant, interval, sleep},
};
use tracing::{debug, info, warn};
use uuid::Uuid;

const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Default)]
struct SessionState {
    active: Option<(Uuid, Epoch)>,
    last_sequence: Option<u64>,
    cursor: Option<CursorState>,
    pointer: PointerTracking,
    last_heartbeat: Option<Instant>,
}

#[derive(Default)]
struct PointerTracking {
    last_sequence: Option<u64>,
    generation: Option<u64>,
    last_cumulative: (f64, f64),
    progress: Option<(u64, u64)>,
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

pub async fn run(configuration: Configuration, mut input: impl InputSink + 'static) -> Result<()> {
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
        let _ = input.release_all();
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
    let channel = SecureStream::connect_control(
        &configuration.host_address,
        local.id.raw_value,
        remote.id.raw_value,
        configuration.workspace.id.raw_value,
        key,
    )
    .await?;
    let (reader, mut writer) = channel.split();
    let (control_tx, mut control_rx) = mpsc::channel(256);
    tokio::spawn(async move {
        let mut reader = reader;
        loop {
            match reader.receive().await {
                Ok(packet) => {
                    if control_tx.send(packet).await.is_err() {
                        break;
                    }
                }
                Err(error) => {
                    warn!(%error, "control channel closed");
                    break;
                }
            }
        }
    });
    // The controller Mac dials this lane; realtime pointer frames arrive here.
    let (pointer_tx, mut pointer_rx) = mpsc::channel(256);
    let lane_socket = tokio::net::UdpSocket::bind(("0.0.0.0", crate::POINTER_PORT))
        .await
        .context("bind UDP pointer lane")?;
    tokio::spawn(pointer::serve_pointer_lane(
        lane_socket,
        local.id.raw_value,
        configuration.workspace.id.raw_value,
        key.to_vec(),
        pointer_tx,
    ));
    writer.send(&protocol::hello_frame(local)?).await?;
    info!(controller=%remote.name,"connected");
    crate::status::notify(
        "UniSpace connected",
        &format!("{} can now control this PC", remote.name),
    );
    let mut state = SessionState::default();
    // The Mac pushes topology updates (edge links) as workspace snapshots;
    // live edits must reach boundary detection, not stay frozen at pairing.
    let mut topology = configuration.workspace.topology.clone();
    let mut watchdog = interval(Duration::from_secs(1));
    watchdog.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            packet = control_rx.recv() => {
                let Some(packet) = packet else {
                    return Ok(()); // control channel ended; reconnect
                };
                let (kind, payload) = protocol::decode_frame(&packet)?;
                match kind {
                    WireKind::ControlJsonV2 => {
                        let message = protocol::decode_control(payload)?;
                        if let ControlMessage::Workspace(snapshot) = &message {
                            topology = snapshot.topology.clone();
                        }
                        handle_control(
                            &mut state,
                            &topology,
                            configuration,
                            local,
                            remote,
                            &mut writer,
                            input,
                            message,
                        )
                        .await?;
                    }
                    WireKind::InputBinaryV2 => {
                        handle_reliable_input(
                            &mut state,
                            configuration,
                            remote,
                            &mut writer,
                            input,
                            payload,
                        )
                        .await?;
                    }
                    WireKind::RealtimePointerBinaryV2 => {}
                }
            }
            frame = pointer_rx.recv() => {
                let Some(frame) = frame else {
                    // Pointer lane unavailable; reliable input still works.
                    continue;
                };
                handle_realtime_pointer(&mut state, remote, &mut writer, input, frame).await?;
            }
            _ = watchdog.tick() => {
                if let Some((session, _)) = state.active
                    && state
                        .last_heartbeat
                        .is_some_and(|seen| seen.elapsed() > HEARTBEAT_TIMEOUT)
                {
                    warn!(%session,"controller heartbeat timed out; releasing input");
                    input.release_all()?;
                    state = SessionState::default();
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_control(
    state: &mut SessionState,
    topology: &serde_json::Value,
    configuration: &Configuration,
    local: &DeviceDescriptor,
    remote: &DeviceDescriptor,
    writer: &mut crate::secure::SecureWriter,
    input: &mut impl InputSink,
    message: ControlMessage,
) -> Result<()> {
    match message {
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
                input.activate(display.frame.width, display.frame.height, edge, position)?;
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
                state.pointer = PointerTracking::default();
                state.last_heartbeat = Some(Instant::now());
                state.cursor = Some(CursorState {
                    display_id,
                    width: display.frame.width,
                    height: display.frame.height,
                    x,
                    y,
                    linked_edges: linked_edges(topology, display_id),
                });
            }
            writer
                .send(&protocol::activation_result_frame(session_id, accepted)?)
                .await?;
        }
        ControlMessage::Deactivate { session_id }
        | ControlMessage::ReleaseAll { session_id } => {
            if state.active.is_some_and(|active| active.0 == session_id) {
                input.release_all()?;
                *state = SessionState::default();
            }
        }
        ControlMessage::RotateWorkspaceKey(key) => {
            ensure!(key.len() >= 32, "rotated workspace key is too short");
            configuration.replace_workspace_key(&key)?;
            return Ok(());
        }
        ControlMessage::Workspace(_) => {}
        ControlMessage::Heartbeat {
            session_id,
            timestamp_nanos,
        }
            if state.active.is_some_and(|active| active.0 == session_id) => {
                state.last_heartbeat = Some(Instant::now());
                writer
                    .send(&protocol::heartbeat_frame(session_id, timestamp_nanos)?)
                    .await?;
                if let Some((generation, sequence)) = state.pointer.progress {
                    writer
                        .send(&protocol::realtime_pointer_progress_frame(
                            session_id, generation, sequence,
                        )?)
                        .await?;
                }
            }
        _ => {}
    }
    Ok(())
}

async fn handle_reliable_input(
    state: &mut SessionState,
    configuration: &Configuration,
    remote: &DeviceDescriptor,
    writer: &mut crate::secure::SecureWriter,
    input: &mut impl InputSink,
    payload: &[u8],
) -> Result<()> {
    let frame = protocol::decode_input(payload, false)?;
    ensure!(
        frame.workspace_id == configuration.workspace.id.raw_value,
        "input workspace mismatch"
    );
    let Some((session, epoch)) = state.active else {
        return Ok(());
    };
    ensure!(
        frame.session_id == session
            && frame.controller_id == remote.id.raw_value
            && frame.epoch == epoch,
        "input session mismatch"
    );
    if state
        .last_sequence
        .is_some_and(|last| frame.sequence <= last)
    {
        return Ok(());
    }
    state.last_sequence = Some(frame.sequence);
    state.last_heartbeat = Some(Instant::now());
    inject_with_boundary(state, writer, input, frame.event).await
}

async fn handle_realtime_pointer(
    state: &mut SessionState,
    remote: &DeviceDescriptor,
    writer: &mut crate::secure::SecureWriter,
    input: &mut impl InputSink,
    frame: protocol::RealtimePointerFrame,
) -> Result<()> {
    let Some((session, epoch)) = state.active else {
        return Ok(());
    };
    if frame.session_id != session
        || frame.controller_id != remote.id.raw_value
        || frame.epoch != epoch
    {
        return Ok(());
    }
    // Dedupe per generation: the controller restarts its sequence counter
    // whenever the realtime generation increments.
    if state.pointer.generation == Some(frame.generation)
        && state
            .pointer
            .last_sequence
            .is_some_and(|last| frame.sequence <= last)
    {
        return Ok(());
    }
    if state.pointer.generation != Some(frame.generation) {
        debug!(generation = frame.generation, "pointer generation changed");
        state.pointer.generation = Some(frame.generation);
        // Mirrors the Windows receiver: a new generation restarts from the
        // frame's own delta (the controller also resets its cumulative base).
        state.pointer.last_cumulative = (frame.cumulative_x - frame.dx, frame.cumulative_y - frame.dy);
    }
    state.pointer.last_sequence = Some(frame.sequence);
    state.pointer.progress = Some((frame.generation, frame.sequence));
    state.last_heartbeat = Some(Instant::now());
    let movement = (
        frame.cumulative_x - state.pointer.last_cumulative.0,
        frame.cumulative_y - state.pointer.last_cumulative.1,
    );
    state.pointer.last_cumulative = (frame.cumulative_x, frame.cumulative_y);
    let event = protocol::InputEvent::PointerMove {
        dx: movement.0,
        dy: movement.1,
        absolute_x: frame.absolute_x,
        absolute_y: frame.absolute_y,
    };
    tracing::debug!(dx = movement.0, dy = movement.1, "pointer");
    inject_with_boundary(state, writer, input, event).await
}

async fn inject_with_boundary(
    state: &mut SessionState,
    writer: &mut crate::secure::SecureWriter,
    input: &mut impl InputSink,
    event: protocol::InputEvent,
) -> Result<()> {
    if let protocol::InputEvent::PointerMove { dx, dy, .. } = &event
        && let Some((edge, position)) = state
            .cursor
            .as_mut()
            .and_then(|cursor| cursor.advance(*dx, *dy))
    {
        let display_id = state.cursor.as_ref().expect("cursor exists").display_id;
        let session = state.active.map(|(session, _)| session);
        input.release_all()?;
        *state = SessionState::default();
        if let Some(session) = session {
            writer
                .send(&protocol::boundary_crossed_frame(
                    session, display_id, edge, position,
                )?)
                .await?;
        }
        return Ok(());
    }
    input.inject(&event)
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
