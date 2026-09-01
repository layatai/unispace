# Handover: Linux receiver — pointer movement alignment (2026-09-02)

Status: control channel, pairing, heartbeat watchdog, click injection, and the
realtime UDP pointer lane all WORK live (Mac taimb2 ↔ Linux dellom). Remaining
blocker: **injected pointer movement does not track the controller's motion**.
Everything below is verified evidence, not speculation.

## Environment

- Repo: this checkout, branch `feat/linux-receiver` (rebased on origin/docs/pointer-stall-handover)
- Linux test host: `ssh tai@dellom.tailda4c05.ts.net` (Omarchy/Arch, Hyprland/Wayland, x86_64)
  - build dir `~/unispace-build`, binary `~/.local/bin/unispace-linux`,
    log `~/receiver.log` (start with `RUST_LOG=unispace_linux=debug`)
  - uinput rule installed; user in `unispace` group
  - paired: `~/.config/unispace/receiver.json` exists; workspace "My UniSpace"
- Mac controller diagnostics:
  `~/Library/Containers/com.layatai.unispace/Data/Library/Application Support/UniSpace/Logs/diagnostics.log`
- Deploy loop and all protocol gotchas: see `.pi/skills/linux-host/SKILL.md` — READ IT FIRST
- Reference implementations: Windows receiver
  `/Users/tai/projects/macifier-unispace-windows/Features/UniSpace/` (works live),
  Mac receiver `Sources/Application/RealtimeInputReceiver.swift`

## What works live (verified 2026-09-01 19:28Z session 779EBD31)

- Pairing (6-digit code confirm), control channel, activation ack
- Realtime UDP lane: healthy; Mac accepted progress acks gen=119 seq=1019→1047,
  heartbeat echo latency 12–14 ms
- Click injection (BTN_* codes advertised on the uinput device)
- 3-finger swipe arrives and fires shortcuts (mapping ≠ Omarchy defaults — UX, not transport)
- Edge return: not yet confirmed with the final binary (worked with earlier code)

## The blocker — pointer movement

User reports (chronological, each after a deploy):
1. "mouse moving works, then cannot move horizontally" (cumulative + global sequence dedupe —
   root cause found: the controller restarts sequence at 0 on generation bump, the old
   global watermark dropped every frame after a bump)
2. "not aligned with my action" (absolute-delta attempt — absoluteX/Y is the MAC's
   clamped cursor position while suppressed, NOT a target-space coordinate; do not use it)
3. "stuck in vertical" (stale deploy, invalid data)
4. "worse" with the Mac `RealtimeInputReceiver` semantics ported exactly
   (baseline zeroed on generation change) — current state

Evidence for step 4 session 779EBD31: Mac accepted progress acks seq 1019→1047
(realtime frames WERE received and processed by the Linux receiver) yet movement
"got worse". Contradiction to resolve: per-frame `debug!(dx…, dy…, "pointer")`
lines never appear in `~/receiver.log` even at RUST_LOG=debug — first verify the
deployed binary actually contains the instrumentation
(`strings ~/.local/bin/unispace-linux | grep "reliable pointer"`) and that
RUST_LOG is set on the running process (`tracing` env filter
`unispace_linux=debug`). Do not trust logs from a stale binary.

## Leading hypotheses (in order)

1. **Axis corruption in the delta source**: the controller's captured
   `mouseEventDeltaX/Y` while the cursor is suppressed-anchored at the screen
   edge may not equal the user's raw motion (cursor warp after every event —
   `CursorSuppressionState` + `PendingCursorWarp` in CGEventInputCapture.swift).
   Fox (Mac receiver) works with the same deltas, so something may differ in how
   Fox's injector applies them vs uinput REL_X/REL_Y. Compare against how the
   Mac's own `CGEventInputInjector.inject(pointerMove)` applies deltas.
2. **uinput REL event batching**: `UinputSink.emit` sends one `device.emit` per
   event with REL_X and REL_Y in a single burst without SYN separators between
   motion groups; Hyprland/libinput may coalesce or misinterpret. Try emitting
   `SYN_REPORT` (evdev `InputEvent` sync) after each motion pair and moving the
   axis events into separate emit batches.
3. **Double-scaling or duplicate application**: reliable-path moves (fallback)
   and realtime moves may BOTH be applied during probing→healthy transitions
   (the Mac sends probe + reliable simultaneously in probing mode). Check for
   duplicated motion when the mode flips.
4. **Entry-position mismatch compounding**: activation places the Linux cursor
   at the entry edge, but the first realtime frame's cumulative baseline starts
   at 0 while the controller's own cursor has moved during the handshake —
   produces an initial jump, not a sustained axis lock.

## Next steps (suggested order)

1. Verify instrumentation reaches the log: add `info!` (not debug) one-line logs,
   redeploy, move the mouse 5 seconds, read `receiver.log`. Log every 20th frame
   with (generation, sequence, dx, dy, absolute) plus any drop reason.
2. Once per-frame deltas are visible, classify: wrong values from the wire
   (delta source — investigate controller-side capture under suppression) vs
   correct deltas but wrong cursor result (uinput/libinput — try SYN batching,
   try `uinput` absolute axes EV_ABS with ABS_X/ABS_Y calibrated to the Linux
   display, which sidesteps delta semantics entirely).
3. EV_ABS is the likely endgame for Hyprland: inject absolute positions from
   `absoluteX/absoluteY` mapped onto the Linux display rect — but only after
   confirming what `absoluteX/Y` contains while the controller cursor is
   suppressed (it may be constant; check with the Mac-side debug log).
4. Confirm edge return + clicks + gestures with the final binary.
5. Then continue `Docs/linux-production-app-plan.md` Phase 2 (display
   enumeration) and Phase 3 (hardening).

## Housekeeping

- Commits on `feat/linux-receiver` are clean and pushed? — NOT pushed; diverged
  from origin (needs `--force-with-lease`).
- Mac app at /Applications/UniSpace.app is a dev build (Developer ID, team
  Y69F3DRK44) with trace instrumentation; backup of the previous install:
  `/Applications/UniSpace.app.bak-20260901`.
- Another agent session may be active in this checkout — check `git status`
  before mutating, and coordinate commits.
- Do not weaken: emergency stop, heartbeat watchdog (5 s), click BTN codes,
  keepalive, per-generation dedupe.
