# UniSpace Linux — execution roadmap (2026-09-02)

Supersedes the ordering in `linux-production-app-plan.md` where they overlap;
that document remains the reference for rationale and protocol background.
Current branch: `feat/linux-receiver`, rebased onto
`docs/pointer-stall-handover` @ `ad85cfe`. PR #39 is the review branch; Track A
remains open until the live gates below are complete.

## Where we are

| Component | State |
|---|---|
| Pairing (6-digit, P-256) | ✅ live-verified |
| Control channel + activation + acks | ✅ live-verified |
| Realtime UDP pointer lane (transport) | ✅ live-verified (healthy, 12–14 ms) |
| Click injection | ✅ live-verified |
| Heartbeat watchdog / keepalive / emergency stop | ✅ implemented, live |
| **Pointer movement alignment** | ⚠️ codec fixed and both axes decoded live; physical 1:1 sign-off pending |
| Gestures | ✅ auto Hyprland/GNOME/KDE profiles implemented; physical action pending |
| Clipboard / file transfer | ⚠️ channels and desktop environment verified; active-session round trips pending |
| Tauri UI / tray | ✅ both binaries built on Linux; UI launches; StatusNotifierItem registered live |
| Display enumeration | ❌ xrandr-or-1920×1080 fallback |
| Packaging / CI / hardening | ⚠️ skeleton exists (nfpm, one CI workflow) |

## Track A — Make the receiver shippable (target: this week)

**A1. Pointer alignment** — code fixed; physical exit gate pending.
- Exit criteria: user crosses Mac left edge → cursor tracks 1:1 on both axes at
  native scale → click → 3-finger swipe fires a bound action → crosses Linux
  right edge → control returns to the Mac. All observed in `receiver.log` +
  Mac diagnostics `t=` trace.
- `54ed185` fixes Swift/Rust realtime field order; `74fdc13` releases UDP 61339
  with the connection. Live logs prove both decoded axes and right-edge return.
- Remaining: correlate physical right/down/left/up motion with `hyprctl
  cursorpos`; require ≤3 px orthogonal drift and ≤5% displacement error. If REL
  fails, keep Track A open and promote B1/EV_ABS; do not add a scale hack.

**A2. Gestures on Hyprland** — implemented in `1d8d36c`; physical exit gate
pending.
- `gestureBindings` supports auto/Hyprland/GNOME/KDE/disabled profiles,
  symbolic chord overrides, inheritance, and explicit empty-array disabling.
- Omarchy defaults use Super+Tab/Super+Shift+Tab, menu, scratchpad, and Apps.
  Config resolution and compatibility are covered by Rust tests.
- Remaining: a physical three-finger gesture must fire the configured action.

**A3. Desktop-session validation** — partially verified; relogin and active
session required.
- Clean 1.2.0 binaries build on dellom; UI launches and the receiver owns
  `org.kde.StatusNotifierItem-<pid>-1` with real Wayland/D-Bus environment.
- The graphical systemd manager predates `unispace` group membership and
  correctly fails `/dev/uinput`; the user must sign out/in before the packaged
  service can be validated without weakening permissions.
- Clipboard is intentionally accepted only for the active/desired peer.
  Round-trip validation must run while control is on dellom, not while idle.

**A4. File-transfer live test** — automated edge case fixed; live test pending.
- `7800bcb` creates/truncates partial files so empty and resumed transfers can
  finalize; URI and zero-byte regression tests pass.
- Remaining: both directions with zero-byte, binary, multiple, duplicate-name,
  and repeated files; compare SHA-256 on real hosts.

**A5. Branch & release hygiene** — implementation ready; remote Linux PR and
package matrix pending.
- PR #41 now contains pairing recovery `ad85cfe`; 78 macOS unit tests, coverage
  floors, and the two-process simulator passed before push.
- `c24f8c7` prepares product-wide 1.2.0/build 25. Linux format, 17 tests, and
  Clippy pass; signed full macOS tests/UI/coverage/simulator and native input
  smoke also pass.
- PR #39 is retargeted to `docs/pointer-stall-handover` and updated by exact-SHA
  force-with-lease. `897b5f6` adds the official Tauri 2 Ubuntu build
  prerequisites after the first CI run exposed missing GLib/GTK/WebKit headers.
  Both Linux architectures and Finder continuity now pass. The macOS QoS job
  passed tests and coverage twice but failed hosted-runner visible-latency
  thresholds while wire p95 stayed below 2 ms; local signed full simulation
  passes. Do not weaken the QoS gate—keep the PR open on this CI blocker.

**Exit criteria Track A:** a stranger installs the deb/rpm on Ubuntu GNOME and
Fedora KDE, pairs, controls, swaps clipboard and files, uninstalls — without
reading source. **OPEN:** the user selected strict sign-off but has not yet
provided the two interactive desktop hosts, so Track A must not be marked done.

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
A1 physical + A2 gesture ──► A3/A4 active-session QA ──► distro packages ──► A5
                              │
B1/B2 ──► B3 ──► B4 ──────────┤            (B can start after A1; feeds
C1..C5 (parallel) ────────────┘             EV_ABS calibration if chosen)
```

## Immediately actionable queue

1. User signs out/in on dellom, then performs the A1/A2 physical control gate.
2. While dellom is active, run clipboard and file tests in both directions.
3. User supplies Ubuntu 24.04 GNOME and Fedora KDE hosts with SSH, sudo, and
   interactive desktop access; build/install/pair/control/uninstall packages.
4. Update PR #39 and wait for all checks; record artifact hashes and host
   results here, then mark Track A complete.
5. Kick off C1+C2 while B waits on the final REL/EV_ABS evidence.
