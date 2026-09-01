# Remote pointer stall handover

## Status

UniSpace 1.1.5 build 19 can enter a state where remote control remains active,
the controller cursor remains suppressed, and the receiver stops moving the
pointer. The reliable control connection and heartbeat continue, so neither
endpoint exits the session automatically.

This document records the live evidence and review of commit `a30752b` (`fix:
restore low-latency Mac pointer transport`) on
`origin/perf/continuity-transfer-qos`. PR #41 now includes the source fix and
regression coverage described below.

## Live evidence

The receiver was `fox’s MacBook Pro`, controlled by `taimb2` over Tailscale.
The installed application was UniSpace 1.1.5 build 19, signed at approximately
the same time as commits `a30752b` and `d8a272b`.

- The application UI reported `Receiving, 2 of 4 devices online`.
- The TCP control connection remained established at roughly 33–42 ms RTT.
- Each one-second sample carried approximately 181 bytes inbound and 325 bytes
  outbound, consistent with heartbeat/echo traffic rather than pointer motion.
- UDP 61341, used by the new authenticated pointer transport, transferred zero
  bytes during the observation. Legacy realtime QUIC UDP 61339 also transferred
  zero bytes.
- The receiver process was healthy. Its main thread was asleep in 6,561 of
  6,565 samples, ruling out receiver CPU or main-thread saturation.
- The macOS application firewall was disabled, and UniSpace was explicitly
  permitted to receive incoming connections.
- The receiver continued to synthesize no pointer events because no pointer
  frames arrived.

SSH on `taimb2` was unavailable because port 22 refused the connection. The
sender process therefore could not be sampled to distinguish a silently
black-holed UDP flow from a send completion that never returned.

## Review findings

### UDP enqueue is treated as peer delivery

`AuthenticatedPointerTransport.send` returns `true` after
`SecurePeerConnection.send` receives Network.framework's `contentProcessed`
completion. For UDP, that completion confirms local processing; it does not
confirm that the peer received or accepted the datagram.

`NetworkPeerTransport.sendRealtime` interprets `true` as a usable realtime lane
and skips reliable fallback. Once an authenticated UDP flow becomes stale or
its route black-holes, pointer packets can therefore be discarded indefinitely
while the sender continues to report success.

### Pointer sends have no deadline

The async `SecurePeerConnection.send` continuation has no timeout. If
Network.framework does not call its completion promptly, the pointer send stays
suspended and cannot reach reliable fallback. The coordinator actor is
reentrant, so its separate heartbeat task can continue to make the session look
healthy during this stall.

### Heartbeat health does not cover pointer health

Session liveness is based on reliable TCP heartbeat/echo traffic. It has no
knowledge of UDP receive progress. A healthy heartbeat therefore prevents the
receiver watchdog and controller cleanup paths from ending a session whose
pointer lane has stopped delivering.

Input suppression is released on explicit stop, activation failure, or control
disconnect. None occurs in this failure mode, which leaves the controller
cursor anchored even though the receiver gets no motion.

### Tests cover only the healthy path

The new authenticated-pointer tests verify localhost authentication and frame
delivery for Windows-initiated and Mac-controller flows. Both tests pass. They
do not cover:

- receiver restart after UDP authentication;
- a route or address change;
- silently dropped datagrams;
- a send completion that never fires;
- reliable fallback after a previously healthy lane becomes stale; or
- releasing input suppression when pointer progress stops.

## Recommended remediation

1. Add receiver acknowledgement or freshness information for the latest
   pointer generation and sequence. Piggybacking it on the reliable heartbeat
   keeps the acknowledgement off the lossy lane.
2. Treat a lane as healthy only while acknowledgements advance. When freshness
   expires, invalidate the UDP connection and use reliable pointer fallback
   until authentication and acknowledgement recover.
3. Put a short, bounded deadline around realtime sends. A missing completion
   must not indefinitely suspend pointer forwarding.
4. Add a fail-open controller guard: if captured pointer input is active but no
   delivery path makes progress, end the remote-control session and restore
   local mouse association.
5. Emit non-sensitive diagnostics for lane state, last sent sequence, last
   acknowledged sequence, fallback transitions, and send timeouts.

Reliable fallback should be selected by observed lane health, not only by the
presence of an authenticated connection object.

## Implemented remediation

- New Macs advertise `realtime-pointer-progress-v1`. The receiver reports the
  latest accepted UDP generation and sequence over the authenticated reliable
  control channel.
- Progress-capable sessions use a 250 ms heartbeat interval and require fresh
  pointer acknowledgements. Initial probing and stale lanes keep real pointer
  movement on reliable input while sending zero-delta UDP probes.
- Acknowledgements older than 750 ms invalidate and reconnect the UDP lane.
  Reliable pointer delivery remains active until a new probe is acknowledged.
- UDP sends no longer await Network.framework's local `contentProcessed`
  callback, so a missing datagram completion cannot suspend pointer forwarding.
- Reliable pointer delivery has a bounded drain. A send error or timeout ends
  the session and releases local input suppression.
- Older macOS peers without progress acknowledgements use reliable pointer
  delivery. Windows keeps the existing Macifier-compatible UDP behavior.
- Motion batching is deadline-aware: a late 16 ms flush task is bypassed by the
  next captured event, which immediately sends the latest coalesced position.
  This removes the sender-side 75 ms stalls observed under concurrent load
  without increasing the batching budget or weakening the latency gate.
- Realtime pointer input has its own transport stream and is routed on a
  dedicated user-interactive task directly to the control coordinator. It no
  longer passes through `AppModel` or waits on the Main Actor behind heartbeat,
  Continuity, and file-transfer UI updates.
- Active control sessions hold a scoped latency-critical `ProcessInfo`
  activity, released at idle, so macOS cannot coalesce interactive work into
  the 75 ms scheduling pauses reproduced by the CI runner.
- The unrelated Swift explicit-`self` CI failure in `AppModel` is fixed without
  changing pairing behavior.

## Required regression coverage

- Authenticate UDP, stop progress acknowledgements, and verify subsequent
  pointer movement falls back and reconnects without waiting indefinitely.
- Drop acknowledgements while TCP heartbeat remains healthy and verify reliable
  delivery stays active.
- Withhold reliable send completion and verify the bounded fail-open deadline.
- Restore progress after fallback and verify one clean transition to realtime.
- Verify controller suppression is released if reliable delivery cannot
  progress.
- Run the same transition tests across a routed Tailscale endpoint; localhost
  success alone is not an adequate gate.

## Immediate recovery

Use **Stop Remote Control** or press **Control–Option–Command–Escape**. If the
event tap itself is no longer processing input, terminate UniSpace on the
controller to restore the local cursor association.

## Relevant code

- `Sources/Infrastructure/AuthenticatedPointerTransport.swift`
- `Sources/Infrastructure/NetworkPeerTransport.swift`
- `Sources/Application/ControlSessionCoordinator.swift`
- `Sources/Infrastructure/CGEventInputCapture.swift`
- `Tests/InfrastructureTests/InfrastructureTests.swift`

The local diagnostic sample was saved as `/tmp/unispace-stuck.sample` and is not
checked into the repository.
