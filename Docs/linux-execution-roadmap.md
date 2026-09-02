# UniSpace Linux — execution roadmap (2026-09-02)

Supersedes the ordering in `linux-production-app-plan.md` where they overlap;
that document remains the reference for rationale and protocol background.
Current branch: `feat/linux-receiver` @ `477054c` (9 local commits, unpushed).

## Where we are

| Component | State |
|---|---|
| Pairing (6-digit, P-256) | ✅ live-verified |
| Control channel + activation + acks | ✅ live-verified |
| Realtime UDP pointer lane (transport) | ✅ live-verified (healthy, 12–14 ms) |
| Click injection | ✅ live-verified |
| Heartbeat watchdog / keepalive / emergency stop | ✅ implemented, live |
| **Pointer movement alignment** | ❌ blocker — agent in flight (see `linux-pointer-handover.md`) |
| Gestures | ⚠️ arrive; shortcut mapping ≠ Omarchy/Hyprland defaults |
| Clipboard / file transfer | ⚠️ protocol fixed (kind 1/2); untested in a desktop session |
| Tauri UI | ✅ built, untested on Linux |
| Display enumeration | ❌ xrandr-or-1920×1080 fallback |
| Packaging / CI / hardening | ⚠️ skeleton exists (nfpm, one CI workflow) |

## Track A — Make the receiver shippable (target: this week)

**A1. Pointer alignment** — in flight (Codex agent, terminal `term-5`).
- Exit criteria: user crosses Mac left edge → cursor tracks 1:1 on both axes at
  native scale → click → 3-finger swipe fires a bound action → crosses Linux
  right edge → control returns to the Mac. All observed in `receiver.log` +
  Mac diagnostics `t=` trace.
- Endgame options ranked in the handover (delta source vs SYN batching vs EV_ABS).
- If EV_ABS wins: calibrate ABS_X/ABS_Y to the real display rect (Phase B1
  prerequisite) and drop REL entirely for pointer motion.

**A2. Gestures on Hyprland** (2 h, after A1)
- Shortcuts (Alt+←/→, Win+Ctrl+←/→, Win+Tab, Win+D) are GNOME/KDE conventions.
- Add a `gesture-bindings` section to `receiver.json` (config.rs) with Omarchy/
  Hyprland defaults, documented in `Linux/README.md`. No daemon changes beyond
  config plumbing.

**A3. Desktop-session validation** (1 h, needs the user at the box)
- Run the receiver from the Hyprland session (`systemctl --user` unit already
  packaged): clipboard round-trip (arboard needs WAYLAND_DISPLAY), tray icon
  (ksni), notifications, files transfer both directions.
- Known-broken-from-SSH clipboard is expected; verify it works in-session.
- Fix anything found; the Wayland data-control path in arboard is
  `wayland-data-control` feature — verify it actually engages under Hyprland
  (needs `wl-clipboard`-compatible data control protocol).

**A4. File-transfer live test** (1 h)
- Both directions Mac ↔ Linux with the two-process simulator fixtures replaced
  by the real hosts. `Linux/src/files.rs` is 447 lines untested live.

**A5. Branch & release hygiene** (1 h, after A1)
- Merge `bca47b3` (pairing clearChannel fix) into `docs/pointer-stall-handover`
  (Mac side) and PR it — it fixes live pairing for every new device.
- Push `feat/linux-receiver` with `--force-with-lease`, open PR.
- Bump to 1.2.0, prepare build 25 (`chore: prepare` commit pattern).

**Exit criteria Track A:** a stranger installs the deb/rpm on Ubuntu GNOME and
Fedora KDE, pairs, controls, swaps clipboard and files, uninstalls — without
reading source.

## Track B — Real display geometry (Phase 2, 2–3 days)

**B1. X11 RandR enumeration** (`x11rb` crate): outputs/CRTCs →
`DisplayDescriptor` list with real rects + scale; replaces `xrandr` shell-out
in `host.rs`.
**B2. Wayland enumeration**: `wl_output` + `zxdg_output_manager_v3` via
`wayland-client`; GNOME/KDE portal fallback
(`org.gnome.Mutation.DisplayConfig` / `kde.KWin`).
**B3. Hotplug**: udev (`udev` crate) + Wayland output events → re-enumerate →
re-announce workspace to the Mac (`hello` + workspace refresh). Session
continuity: if the active display disappears → `release_all` + end session.
**B4. Multi-display + scale**: frame rects in the global layout; absolute
pointer mapping (if EV_ABS) per-display; normalized edges across the union.
- Acceptance: hotplug mid-session re-routes edges without restart; 100%/200%
  scale verified; two-display Linux box routes both edges.

## Track C — Hardening (Phase 3, 3–4 days, parallelizable with B)

**C1. Fuzzing**: `cargo-fuzz` targets for `protocol::decode_*`, secure hello
parse, pointer/input frame decoders. Seed corpus from the simulator's captured
frames. CI gate: no crashes, no OOMs, 10 min/night.
**C2. systemd hardening**: add to `unispace.service` —
`ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`,
`RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`,
`CapabilityBoundingSet=`, `MemoryDenyWriteExecute=yes`,
`ReadWritePaths=%h/.config/unispace`.
**C3. Diagnostics parity**: ring-buffer log + `unispace-linux diagnostics dump`
with monotonic `t=` seam stamps (decoded → session → injected), matching the
Mac's trace so cross-machine correlation stays possible.
**C4. CI**: build+test+clippy on x86_64 and aarch64 (cross or QEMU), nfpm
artifacts, the loopback simulator smoke, fuzz smoke.
**C5. Watchdog parity test**: kill the Mac app mid-session → receiver releases
input within 5 s (regression test in `receiver.rs` tests).

## Track D — Release ops (Phase 4, 2 days, after A+B)

**D1. Protocol handshake refusal**: on connect, if the Mac's hello version is
newer than supported → actionable desktop notification ("Update the Linux
receiver"), not silent failure.
**D2. Update check**: tray menu item + `latest.json` fetch against GitHub
releases; notification only, no auto-update daemon.
**D3. QA matrix sign-off**: Ubuntu 24.04 / Fedora 41 × GNOME / KDE (Hyprland
best-effort) × Wayland / X11 × x86_64 / arm64(Pi 5) × 100% / 200% scale.
Runbook in `Linux/QA.md`, one row per cell.
**D4. Tag 1.2.0**, sign, publish deb/rpm + GitHub release.

## Track E — Linux as controller (deferred)

Input capture (evdev), cursor suppression, and controller-side sessions.
Separate plan; wire protocol already supports it. Start only after Track D.

## Dependency graph

```
A1 (agent, in flight) ──► A2, A3, A4 ──► A5 ──► Track D ──► 1.2.0
                              │
B1/B2 ──► B3 ──► B4 ──────────┤            (B can start after A1; feeds
C1..C5 (parallel) ────────────┘             EV_ABS calibration if chosen)
```

## Immediately actionable queue

1. Wait on the Codex agent (A1) — verify its root-cause claim against logs
   before accepting; live-test yourself.
2. A2 gesture config (agent or 2 h manual).
3. A3/A4 desktop-session validation (needs the user at the Linux box).
4. A5 branch hygiene (merge pairing fix → Mac branch PR first — it unblocks
   everyone pairing new devices).
5. Kick off C1+C2 while B waits on A1's EV_ABS decision.
