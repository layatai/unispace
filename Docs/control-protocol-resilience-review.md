# Control protocol resilience review

Reviewed on 2026-10-01 after reports of pointer lag and unexpected return to the controller.

The immediate recommendation is to keep UniSpace's separate motion and reliable
control paths, repair their queueing and liveness rules, then add negotiated
session recovery. A transport replacement alone would leave those application
state problems intact.

## Comparison with other implementations

| Reference | Verified behavior | Application to UniSpace |
| --- | --- | --- |
| [Moonlight input sender](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c) | Uses a dedicated input sender, a 150-packet queue limit, and 1 ms mouse batching. Relative movements accumulate displacement; absolute movements retain the latest position. Its relative mouse packets currently use reliable ENet delivery. | Coalesce unsent motion while preserving button/key ordering. Benchmark shorter batching intervals rather than copying 1 ms without measuring CPU and packet rate. |
| [Deskflow protocol](https://deskflow.github.io/deskflow/protocol_reference.html) | Distinguishes connected and active states. Keep-alives run every 3 seconds, with a 9-second receive timeout; any incoming message refreshes the client timeout. Screen entry carries modifier state. | Separate connection health, pointer delivery progress, and control ownership. Synchronize pressed state at session boundaries. Its timeout values are reference behavior, not proposed UniSpace defaults. |
| [RDP UDP extension](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeudp/fe211d97-92dd-47e6-8fa3-b23f2c1a5af9) | Defines reliable and unreliable modes; the latter avoids retransmission delays. Also supports forward error correction. | Preserve ordered delivery for state transitions and allow superseded motion to be replaced. This specification does not imply every RDP mouse event uses an unreliable lane. |
| [RDP automatic reconnection](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/e729948a-3f4e-4568-9aef-d355e30b5389) | Reconnects to an existing session using session identity and an authenticated reconnect proof. | Make ownership resumable independently of a socket. Use UniSpace's authenticated channel and fresh session generation; do not copy historical RDP cryptographic algorithms. |
| [RustDesk input service](https://github.com/rustdesk/rustdesk/blob/master/src/server/input_service.rs) | Its `active_mouse_` implementation disables a blocking cursor-position check, documenting latency and dropped fast movement on macOS. | Keep OS position polling and network waits out of input consumption. This is a specific implementation lesson, not a claim that RustDesk uses the same transport as UniSpace. |
| [QUIC DATAGRAM, RFC 9221](https://www.rfc-editor.org/rfc/rfc9221.html) | Reliable streams and unreliable datagrams share authentication and congestion control. A transport acknowledgment does not prove application processing. Datagram expiration may be supported by implementations. | A possible future transport simplification, but keep application progress acknowledgments and input prioritization. Support and routed performance must be established on every target platform first. |

## Findings and changes implemented

Relevant source: [coordinator](../Sources/Application/ControlSessionCoordinator.swift),
[fast pointer sender](../Sources/Application/RealtimePointerCaptureSender.swift),
[realtime receiver](../Sources/Application/RealtimeInputReceiver.swift), and
[peer transport](../Sources/Infrastructure/NetworkPeerTransport.swift).

1. **Idle was mistaken for lost pointer progress.** The fast sender required a
   recent acknowledgment even when all sent movement was acknowledged. Resuming
   after a pause exceeding 750 ms unnecessarily triggered fallback and lane
   reconnection. The deadline now runs only while motion is outstanding. New
   sends and duplicate acknowledgments cannot keep an unresponsive lane alive.
2. **Reliable fallback blocked the capture consumer.** A movement handler could
   await the entire reliable queue for up to 750 ms. Delivery monitoring now
   runs independently, with the same bounded timeout and session checks.
3. **Slow sends accumulated obsolete pointer samples.** Adjacent unsent movements
   now combine their deltas and retain the latest coordinates. In-flight frames,
   session boundaries, keys, and button transitions are preserved.
4. **Old failures could corrupt recovery.** A cancelled send's late error could
   clear a replacement worker's queue. Error handling now checks its generation.
   A completed failed batch also cannot mark subsequent successful batches as
   failed.
5. **Heartbeat protection depended on pointer capability.** Fresh heartbeat
   evidence now protects reliable-only peers from transient pointer-send failure.
   Only peers that negotiated pointer progress enter that lane's recovery mode.
   Failed input with stale heartbeat still returns local control.

The initial bug fixes retain existing wire formats. The roadmap implementation
below adds messages only for peers advertising `control-resilience-v1`. Legacy
peers retain immediate input release on control disconnection.

## Implemented resilience protocol

### Independent progress and diagnostics

Modern peers send coalesced application progress independently of the heartbeat,
at most once per 16 ms reporting cycle. On macOS, session messages and realtime
injection bypass `AppModel` and its Main Actor work. Acknowledgment writes run
separately from input consumption; a blocked write cannot block that consumer.
Reliable heartbeat responses remain a backup for pointer progress.

`inputProgress` identifies the highest processed reliable sequence in the active
session. Realtime progress identifies generation and sequence. Both are emitted
after the receiver's input-processing call. This proves application processing,
not that the operating system displayed a physical cursor movement.

The sender tracks unacknowledged reliable input separately from peer heartbeats.
Five seconds without application progress releases control even when socket
writes and heartbeats keep succeeding. The pointer deadline adapts to smoothed
RTT and jitter, bounded between 750 ms and 3 seconds. Idle time without outstanding
motion does not consume this deadline. A heartbeat checkpoints an unacknowledged
final movement after the pointer becomes idle.

`inputQueueSnapshot()` exposes accepted, locally sent, and coalesced frame counts,
current and peak queue depth, and oldest queued age. Measurements use the local
monotonic clock. The simulation includes these counters beside wire and simulated
injection latency; timestamps are never subtracted across independent machines.

### Bounded authenticated session recovery

A negotiated session enters `recovering` for up to two seconds after control
transport loss. The controller retains suppression and the target while its
transport reconnects. The receiver releases uncertain pressed keys/buttons and
retains cursor position. Outage input and buffered activation input are discarded.
Emergency stop remains active, including modifiers held before the disconnect.

After authentication, the controller sends `resume` with the previous session ID,
a fresh session ID, and controller epoch. The receiver accepts only a matching
peer, epoch, and retained session within the recovery interval. An identical
accepted request is idempotent. On `resumeResult`, the controller resets sequences
and sends its current modifier snapshot before normal input. Neither endpoint
replays outage clicks or key presses, and neither warps the cursor back to the
entry edge. Old-session packets cannot mutate the resumed session.

Expired or rejected recovery releases local control. Receiver restart and changed
ownership cannot resume an unavailable session. Transport callbacks from replaced
connections are ignored. Macifier retries the connection promptly while its
recovery interval is active; ordinary reconnect backoff remains in effect afterward.

### Ordering between datagrams and reliable input

Before switching from realtime motion to a reliable input event, the sender emits
`pointerCheckpoint` in the same ordered send worker. It contains the closing
generation, cumulative displacement, and the following reliable sequence. The
receiver applies only the displacement not already received, closes that generation,
and blocks newer datagrams until the associated reliable input has been processed.

The sender waits for application acknowledgment of pending reliable input before
promoting a probed realtime lane. Duplicate checkpoints cannot apply displacement
twice; old generations remain rejected. This handles delayed packets around clicks,
drag boundaries, fallback, and loss of the final datagram before an idle pause.

The reliable queue permits at most 256 waiting frames. Adjacent unsent motion is
coalesced without crossing checkpoints or key/button boundaries. Overflow explicitly
terminates the session and releases input instead of silently dropping transitions.

### Macifier UDP recovery

Macifier keeps one outstanding receive while retrying a missing UDP hello every
500 ms of silence. Malformed or unauthenticated datagrams cannot stop the loop or
advance replay state. A new authenticated peer nonce resets the encrypted packet
sequence; duplicate hellos preserve replay protection, and retired nonces cannot
roll the channel back. The Mac listener answers an authenticated duplicate hello
when its initial reply was lost, without resetting sequence state or creating a
symmetric hello-response loop. Socket failures restart only the pointer lane. The reliable
connection and receiver ownership remain governed by their own recovery policy.

## Wire compatibility

The native envelope remains version 1 and the portable envelope remains version 2.
New messages require the capability on both participating applications. They are:

| Type | Payload |
| --- | --- |
| `inputProgress` | `sessionID`, `sequence` |
| `pointerCheckpoint` | `checkpoint`: `sessionID`, `generation`, `reliableSequence`, `cumulativeDeltaX`, `cumulativeDeltaY` |
| `resume` | `resume`: `previousSessionID`, `sessionID`, `epoch` |
| `resumeResult` | `previousSessionID`, `sessionID`, `accepted` |

UUIDs retain the existing `{ "rawValue": "UUID" }` encoding. Shared
[portable vectors](../Documentation/Protocol/control-resilience-v1-vectors.json)
are round-tripped by Swift and Macifier's C# tests. Binary input layouts and old
capability behavior are unchanged. Linux peers that do not advertise the new
capability continue using their existing protocol.

## Benchmarking and validation

Run the existing gates:

```sh
Scripts/test.sh --unit
```

Compare fallback batching without changing production defaults:

```sh
python3 Scripts/benchmark-control-batching.py --samples 500
```

The benchmark builds Release once, forces reliable pointer delivery, and compares
1, 4, 8, and 16 ms under idle, clipboard, and file load. It records p50/p95/p99,
maximum latency/stall, child CPU seconds, frame counts, and queue diagnostics in
`.build/control-batching.json`. It preserves every existing latency gate and exits
nonzero if any condition fails. This is a local simulation, not a Tailscale or
physical cursor benchmark. The normal synchronous UDP fast path bypasses the
fallback batching interval.

Regression coverage includes reconnect expiry, wrong peer/epoch/session, duplicate
resume, discarded outage input, emergency stop, stale deactivation, cumulative
checkpoint recovery, reliable/datagram ordering, bounded queues, application
progress despite a healthy socket, and identical portable wire fixtures. Macifier
also runs UDP tests against real loopback sockets and its receiver tests with a
monotonic fake clock and input injector. Its original UDP implementation fails
three of the new regression tests; the repaired implementation passes them.

The final unit gate ran 287 tests with zero failures; unit mode intentionally
skipped the separate signed native-input smoke test. Application coverage was
95.46% against the unchanged 95% minimum. The normal 500-sample, two-process
simulation passed idle, clipboard, and file-load conditions. Macifier passed 22
portable protocol/recovery tests and 70 input tests; its Windows integration
target cross-compiled, with existing warnings. Native Windows execution remains
pending a Windows host.

The benchmark harness also has a regression test for a child that exits before
readiness. Failure reporting must not reacquire the same condition lock; the
benchmark subprocess group now has a finite deadline and scoped cleanup.

The initial batching run recorded a 1 ms file-load spike above the unchanged 50 ms
maximum while 4/8/16 ms passed. That run overlapped other local validation, so it
is not evidence to select a production interval. Keep the 16 ms default and retain
all benchmark failures in the report.

The subsequent sequential run passed all four configurations with 500 samples per
condition. These local results do not replace routed-device measurements.

| Batching | Highest condition p95 | Highest latency | Child CPU |
| --- | --- | --- | --- |
| 1 ms | 0.81 ms | 12.58 ms | 5.77 s |
| 4 ms | 1.03 ms | 6.94 ms | 5.11 s |
| 8 ms | 1.26 ms | 11.95 ms | 6.67 s |
| 16 ms | 9.85 ms | 21.38 ms | 6.27 s |

## Remaining environment validation

Install both updated apps and verify on the affected Windows/Mac and Mac/Mac
routes: idle/resume, blocked UDP, short interruption, restart, drag, held modifiers,
and emergency stop. Native Windows injection and routed Tailscale measurements
require the actual Windows host; cross-compilation and local protocol tests do not
substitute for those checks.

QUIC DATAGRAM migration remains conditional on those routed measurements and
platform support. The earlier routed QUIC failures in
[the previous investigation](performance-regression-remediation.md) make a wholesale
transport replacement premature. The application-level recovery and ordering
changes above work with the current authenticated transports.
