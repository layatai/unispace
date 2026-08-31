# Remote mouse lag handover

## Status

The 1.1.4 build 18 investigation found a realtime-lane readiness regression
relative to v1.1.3. The source fix is implemented and unit-tested, but the
installed app used for profiling has not been replaced. End-to-end validation
still needs the updated build on both Macs.

## Live profile

The profile was captured while moving the pointer through a remote macOS peer
over Tailscale.

- UniSpace used roughly 4–13% CPU while input was active, after a brief 21%
  spike. Resident memory stabilized near 188 MiB.
- The main thread was asleep for about 98.5% of samples. This was not a
  main-thread or CPU saturation problem.
- The active network queue spent most sampled work decoding property lists,
  consistent with pointer frames using the reliable control connection.
- The reliable TCP connection reported roughly 50–71 ms RTT and accumulated
  out-of-order and duplicate receive traffic during pointer movement.
- The macOS realtime UDP port transferred zero bytes throughout the active
  sample. Synthetic mouse event posting was present, so input reached the
  receiver after traversing the reliable path.

The observed lag therefore came from replaceable pointer movement falling back
to ordered TCP, where round-trip delay and head-of-line blocking directly
affected cursor motion.

## Regression comparison

v1.1.3 prepared realtime connections for all eligible peers. The 1.1.4
connection-ownership work correctly stopped retrying every offline peer, but it
also delayed the realtime QUIC connection until session activation. In the
profiled session the lane never became ready, so pointer frames remained on the
reliable fallback.

The fix preserves bounded connection ownership: every authenticated macOS
control peer is now a warm realtime candidate, while offline workspace peers
remain excluded. The active session peer is retained independently, so a
control-connection transition cannot tear down its realtime lane.

## Implementation

- `NetworkPeerTransport` refreshes warm realtime peers whenever an
  authenticated control connection is registered or removed.
- `QUICRealtimeTransport` retains the union of warm peers and the active desired
  peer. Direct dialing, Bonjour acceptance, authentication, and retry decisions
  all use that retained set.
- The first reliable pointer fallback emits a degraded health event. Successful
  realtime delivery clears the fallback state and emits recovery once, avoiding
  per-frame diagnostic noise.
- The authenticated QUIC datagram test now exercises warm-peer establishment,
  and a separate test covers warm/desired retention and removal.

No wire format, pairing material, or fallback delivery semantics changed.

## Verification

- Debug build with code signing disabled: passed.
- Authenticated QUIC datagram transfer using warm peers: passed.
- Warm and desired peer retention: passed.
- Non-UI unit suite: 206 passed, 1 skipped, 0 failed.
- `git diff --check`: passed.

`Scripts/test.sh --unit` could not start because `xcodegen` is not installed on
the profiling Mac. Running its checked-in-project `xcodebuild` equivalent passed
the unit suite.

## Rollout validation

1. Install the updated build on both Macs and establish the reliable control
   connection without moving control across the edge yet.
2. Confirm the realtime UDP lane exchanges bytes before or immediately when
   activation begins.
3. Exercise continuous pointer motion over the same Tailscale route and verify
   that the reliable-fallback health message does not remain active.
4. Capture pointer latency and stalls alongside TCP/UDP counters. Compare the
   same route and movement pattern with v1.1.3 and 1.1.4 build 18.
5. If UDP remains idle, inspect QUIC listener reachability and authentication on
   both endpoints before changing pointer batching.

The existing 16 ms pointer coalescing and per-event main-actor dispatch were
also present in v1.1.3 and were not changed here. They remain secondary tuning
targets if lag persists after the realtime lane is verified.
