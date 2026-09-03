# Handover: Linux receiver — pointer movement alignment (2026-09-02)

Status: **root cause fixed and deployed** on Mac `taimb2` ↔ Linux `dellom`.
The realtime lane now decodes both axes with the controller's scale and signs,
and edge return works. One final gate remains: observe a deliberate physical
right-then-down motion in Hyprland to confirm the visible cursor follows it.

## Environment

- Repo: this checkout, branch `feat/linux-receiver`
- Linux host: `ssh tai@dellom.tailda4c05.ts.net`
  - build: `~/unispace-build`
  - binary: `~/.local/bin/unispace-linux`
  - log: `~/receiver.log`
  - config: `~/.config/unispace/receiver.json`
- Mac diagnostics:
  `~/Library/Containers/com.layatai.unispace/Data/Library/Application Support/UniSpace/Logs/diagnostics.log`
- Deploy loop and protocol gotchas: `.pi/skills/linux-host/SKILL.md`

## Root cause

Swift `PortableBinaryCodec.encode` writes `timestampNanos` immediately after
`sequence`, before the six pointer doubles. Rust read and wrote the timestamp
after those doubles. The frame still had the expected byte count, so decoding
succeeded with every pointer field shifted:

| Rust field before the fix | Actual Swift field in those bytes |
|---|---|
| `dx` | `timestampNanos` interpreted as `f64` (displayed as `0`) |
| `dy` | `deltaX` |
| `cumulativeX` | `deltaY` |
| `cumulativeY` | `cumulativeDeltaX` |
| `absoluteX` | `cumulativeDeltaY` |
| `absoluteY` | `absoluteX` |
| `timestampNanos` | `absoluteY` bits interpreted as `u64` |

That is why horizontal controller motion appeared on Linux as vertical motion.
It was not capture corruption or a uinput axis bug.

## Evidence

The diagnostic binary was verified before trusting logs:

```text
strings ~/.local/bin/unispace-linux | grep -F 'frame g='
frame g=

pgrep -a -x unispace-linux
504652 /home/tai/.local/bin/unispace-linux run

RUST_LOG=unispace_linux=debug
```

Before the codec fix, controller absolute X changed by hundreds while the
decoded X delta remained zero and horizontal motion accumulated as Y:

```text
frame g=122 s=900  wire=(0.000,-13.000) applied=(1.000,-13.000) cum=(-7.000,433.000) abs=(183.000,156.020)
frame g=122 s=1340 wire=(0.000,26.000)  applied=(1.000,26.000)  cum=(0.000,1376.000) abs=(-780.000,156.020)
```

After correcting the field order, both axes decode with the original signs and
the cumulative-loss recovery produces the same movement when no frame is lost:

```text
frame g=132 s=20 wire=(-19.000,12.000) applied=(-19.000,12.000) cum=(-203.000,100.000) abs=(5.000,372.000)
frame g=132 s=60 wire=(29.000,-3.000)   applied=(29.000,-3.000)   cum=(-101.000,153.000) abs=(5.000,372.000)
```

Mac diagnostics also confirmed final-binary edge return:

```text
[2026-09-01T19:42:57Z] Boundary crossed ... edge=right
[2026-09-01T19:42:57Z] Ending session; reason=peer crossed boundary right
```

## Fixes

### Portable realtime codec order — `fb4dd32`

- `Linux/src/protocol.rs` now matches Swift's portable layout exactly:
  version/identity/epoch/generation/sequence, `timestampNanos`, then
  delta/cumulative/absolute X/Y doubles.
- Regression test
  `protocol::tests::realtime_pointer_matches_swift_field_order_and_round_trips`
  asserts the timestamp and first delta byte offsets, so a symmetric Rust-only
  round trip cannot hide another cross-language order mismatch.

### Pointer-lane reconnect lifecycle — `8d75728`

During validation, restarting the Mac exposed a second bug: the detached
`serve_pointer_lane` task survived `run_connection`, kept UDP 61339 bound, and
made every reconnect fail with `bind UDP pointer lane`.

The task is now owned by a Tokio `JoinSet`; dropping the connection scope aborts
the lane and releases its socket. Verified on the same receiver PID `513264`:

```text
2026-09-02T03:18:37Z control channel closed
2026-09-02T03:18:37Z controller disconnected
2026-09-02T03:18:39Z connected controller=taimb2
```

No bind failure occurred after the reconnect.

## Hypotheses resolved

- `CGEventInputCapture`/`PendingCursorWarp` was not the axis corruption source;
  the portable decoder shifted the already-correct captured fields.
- Do not add manual `SYN_REPORT` events or split X/Y batches.
  `evdev::uinput::VirtualDevice::emit` already appends `SYN_REPORT`, and related
  REL_X/REL_Y events belong in one batch.
- Do not use controller `absoluteX/Y` as Linux target coordinates. They describe
  the suppressed Mac cursor, not the target display.
- EV_ABS is not justified by current evidence. Reconsider it only if the final
  physical test proves Hyprland's relative-pointer acceleration produces an
  unacceptable visible scale.

## Validation completed

- `cargo test`: 12 passed, 0 failed
- `cargo clippy --all-targets -- -D warnings`: passed
- Installed diagnostic binary contains `frame g=` and runs as one process
- Mac UI returned to 2 of 4 devices online after the controlled reconnect
- Realtime progress acknowledgements and right-edge return work
- Emergency stop, 5-second watchdog, keepalive, per-generation dedupe, and
  BTN_* click codes were not changed

## Remaining live gate

1. With dellom online, physically cross the Mac's linked edge.
2. Move slowly right about 200 px, then down about 100 px; stop before an edge.
3. While moving, sample Hyprland with
   `HYPRLAND_INSTANCE_SIGNATURE=<current instance> hyprctl cursorpos -j` and
   compare it with `frame g=` lines in `~/receiver.log`.
4. Confirm visible direction and scale, then deploy the clean committed source
   (the current host binary intentionally retains sampled `info!` diagnostics).

Coordinate automation is not a substitute for this gate: it cannot reproduce
the physical relative deltas while macOS has disassociated and edge-anchored
the cursor.

## Housekeeping

- Local commits: `fb4dd32`, `8d75728`; do not push unless explicitly requested.
- The branch diverges from origin; verify both sides before any rebase or push.
- The installed host binary includes temporary sampled `frame g=` logging; the
  committed source does not.
- Expected SSH-session clipboard warnings are unrelated to pointer movement.
