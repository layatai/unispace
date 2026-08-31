# Performance regression remediation

## Goals

- Keep idle CPU below 2% on the Fox validation Mac.
- Stop repeated Keychain reads and unchanged SwiftUI publications.
- Ensure only the connection owner probes an unavailable peer.
- Keep clipboard and file-transfer recovery independent from remote-control input.
- Preserve the existing macOS and Macifier wire protocols.

## Fox production evidence

The notarized 1.1.4 build authenticated the Fox control connection, but its
QUIC realtime lane failed before sending a packet. Network.framework reported
TLS minimum 1.3 with maximum 1.2 and rejected every attempt with
`NO_SUPPORTED_VERSIONS_ENABLED`. The loopback QUIC integration tests pass in
both Debug and optimized Release, so they do not cover this routed-endpoint
failure.

Pointer motion consequently used the reliable TCP control socket. On Fox that
socket averaged 73–124 ms RTT while a direct Tailscale probe took 17 ms; the
socket accumulated 4.3 MiB retransmitted and 21.7 MiB out-of-order. Samples on
both Macs showed 9–16% CPU in pointer encryption, TCP receive/decode, event-tap
suppression, and injection. TCP head-of-line blocking is the direct cause of
the visible pointer lag.

Build 19 removed that QUIC dependency by moving modern Mac pointer traffic to
authenticated UDP. A follow-up live session exposed a separate failover defect:
UDP delivery stopped while TCP heartbeat remained healthy, leaving the remote
session active and the controller cursor suppressed. See
[`remote-pointer-stall-handover.md`](remote-pointer-stall-handover.md) for the
evidence, code review, and required regression coverage.

## Connection ownership

| Connection | Proactive dial owner |
| --- | --- |
| macOS controller to macOS receiver | Controller Mac |
| macOS receiver to macOS receiver | Neither |
| Macifier Windows to macOS controller | Macifier, targeting the accepted controller only |
| Authenticated UDP pointer | Active controller, for the active target only |
| Legacy QUIC pointer | Active controller only when the peer lacks UDP pointer v2 |
| Clipboard and file transfer | Current continuity target or explicit transfer destination only |

The last accepted controller is persisted per workspace. A workspace without a
persisted controller uses one deterministic bootstrap Mac until a controller
claim is observed. Windows peers are never selected as a macOS outbound target
because Macifier is the outbound client.

Each peer has at most one connection attempt in flight. Retry delays are 1, 2,
4, 8, and 15 seconds, followed by one attempt per minute, with 15% jitter.
Backoff resets only after ten seconds of stable connectivity. Network recovery,
a changed route, a controller change, and an explicit refresh may wake a retry.

Connection status follows actual ownership. An offline peer is `Reconnecting`
only while this Mac owns and schedules its outbound retry. Passive Macs and
inbound-only Windows peers remain `Offline`, and the UI does not offer a retry
action that policy would reject.

## Controller isolation

`ControlSessionCoordinator` publishes a typed, read-only session snapshot.
Continuity consumes that snapshot but cannot restart the trusted control
transport, stop a control session, or alter input suppression.

Activation input uses a bounded stream. The activation envelope is written
before buffered input is drained, so confirmation does not create per-event
main-actor tasks or allow input to overtake activation.

## Event-driven continuity

Clipboard and file-transfer view models subscribe to immutable application
context instead of polling `AppModel`. The workspace key is cached until the
workspace or key revision changes. Published properties are assigned only when
their values differ.

Secondary transports keep passive listeners but dial only their desired peer.
Realtime connects only for an activating or active control session. Modern
macOS peers use the existing authenticated, replay-protected UDP pointer-v2
wire format already supported by Macifier. The receiver listens passively; the
controller is the sole Mac dialer. QUIC remains a compatibility fallback for a
peer that does not advertise UDP pointer v2. Clipboard connects only while
sharing has a target. File transfer connects only to the selected or automatic
destination.

The continuity target is resolved from the authenticated control plane before
the clipboard channel exists: remote controller, active control-session peer,
then a sole connected compatible peer. That target is passed to the clipboard
transport, which establishes TCP 61342 and reports its independent connection
state. Clipboard connectivity controls the `Waiting`/`Encrypted` badge; it does
not gate target selection.

## Regression gates

- Four-node topology with one unavailable node: only the dial owner retries.
- No overlapping QUIC and TCP attempt for the same peer.
- At most one attempt per unavailable peer per minute after the circuit opens.
- Controller transfer cancels retries owned by the former controller.
- Macifier reconnects only to its persisted controller.
- Passive and inbound-only peers show `Offline` and expose no manual retry.
- Clipboard selects one control-connected target before TCP 61342 is connected;
  an idle multi-peer workspace selects none and never dials every peer.
- Identical context produces no Keychain read, QoS update, or UI publication.
- Delayed activation preserves activation-before-input ordering with bounded
  buffering, no heartbeat loss, and no pointer stall above 50 ms.
- Existing unit, coverage, UI, native-input, and Windows CI gates remain intact.
- A routed Fox session sends pointer state over UDP 61341, does not retry QUIC
  61339, and keeps pointer delivery independent from the TCP control RTT.

## Delivery

1. Validate connection ownership and retry diagnostics on Fox for 15 minutes.
2. Validate idle Keychain, scene-update, and CPU counters.
3. Validate remote input during clipboard activity and a large file transfer.
4. Run the signed native-input smoke and Macifier Windows CI.
5. Notarize and install only after all gates pass.
