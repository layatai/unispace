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

These changes keep existing wire formats. Confirmed control disconnection still
releases input immediately; authenticated session resume is not implemented by
this patch.

## Prioritized next steps

### 1. Independent input progress and measurable latency

Progress currently comes back through `AppModel.handleControl` and the reliable
heartbeat path. Add a negotiated acknowledgment path handled outside UI work,
with rate-limited feedback and reliable heartbeat backup. Track captured,
queued, sent, accepted, and injected stages independently. Report queue age,
acknowledgment age, lane switches, RTT, and reconnect duration. Sender and
receiver monotonic timestamps must not be subtracted across machines without
clock synchronization or an explicit offset model.

Keep separate deadlines for peer liveness and outstanding movement. Adapt a
movement deadline to measured RTT/jitter and acknowledgment cadence, with
bounds verified under loss. A live heartbeat alone must not indefinitely hide
an input path that never advances. Reliable-send completion is also not proof
of receiver injection; negotiated input progress should cover both lanes.

### 2. Explicit session resume after a short interruption

Introduce a capability-gated `recovering` state and resume request/result. Bind
requests to the authenticated peer, controller epoch, session, and a fresh
transport generation. The receiver must acknowledge ownership before input
resumes. Preserve the remote target and last position while recovering; clear
uncertain pressed keys/buttons and reconcile state before accepting new input.
Never replay an outage's queued clicks or key presses.

Use a bounded recovery interval determined by fault-injection testing. Emergency
stop must release the local cursor immediately. Receiver restart, rejected
resume, changed controller, or expired grace must safely terminate ownership.
Late disconnect callbacks from an old connection must not terminate its
replacement. Older peers retain current fail-open behavior.

### 3. Explicit ordering across motion and reliable events

Datagrams can arrive after a reliable button transition. Add an input-state
revision or motion fence to negotiated messages so the receiver can reject
pre-transition motion. Include a cumulative motion checkpoint when switching
lanes; resetting a generation alone does not establish what displacement was
already applied. Test loss of the final datagram before an idle pause, delayed
old-generation packets, and fallback during drag without double application.

### 4. Benchmark batching and transport options

Compare 1, 4, 8, and the current 16 ms fallback batching budgets on the actual
Mac-to-Mac and portable-peer routes, including Tailscale. The healthy synchronous
UDP fast path already bypasses the 16 ms coordinator batching interval.
Measure p50/p95/p99 latency, packet rate, CPU, and queue growth during file and
clipboard traffic. Add a total ordered-queue bound with explicit recovery on
overflow; do not silently discard key/button transitions.

Evaluate QUIC streams plus DATAGRAM only after the routed QUIC failures recorded
in [the previous investigation](performance-regression-remediation.md) have been
reproduced or ruled out with current endpoint builds. Keep a compatible fallback.

## Validation

- Three new regression tests first failed against the original implementation:
  idle resumption, capture blocked by reliable send, and reliable-only heartbeat
  protection. They pass with the fix.
- Six new regression tests in total cover these failures, stalled-lane expiry,
  displacement-preserving coalescing, button ordering, late cancelled-send
  failure, and successful sends after failure. Existing tests were not relaxed.
- `Scripts/test.sh --unit`: 271 tests executed, zero failures; one signed native
  input smoke test intentionally skipped by unit mode. All coverage gates pass.
- The included Release two-process simulation passes all 500-sample conditions
  (idle, clipboard load, file load), including recovery and post-recovery control.
  Simulated visible p95 is 9.65 / 9.74 / 9.28 ms respectively.
- These are local automated results, not physical cursor measurements or proof
  of a deployed fix. The updated app still needs installation and verification
  on the affected controller/receiver pair, including idle/resume, packet loss,
  blocked UDP, short network interruption, restart, and emergency stop.
