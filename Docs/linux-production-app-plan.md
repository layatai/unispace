# Plan: native, production-grade UniSpace app for Linux

Status: proposed, 2026-09-01
Baseline: `Linux/` Rust receiver (v1.1.4, ~2.6k lines) — receiver-only, portable v2
wire format, uinput injection, arboard clipboard, file transfer, P-256 pairing,
Secret Service keyring, ksni tray, systemd user service, deb/rpm via nfpm, CI
workflow. Rebased onto `docs/pointer-stall-handover` (see
`unify-windows-peer-connection-plan.md` for the wire-format context).

## Definition of "production grade"

1. **Latency parity** with the Windows receiver: p95 pointer ≤ 10 ms visible
   (the two-node simulator's current gate), no input stalls on lane failure.
2. **Live-session survivability**: lane restarts, app restarts, sleep/resume, and
   workspace re-pairing must not strand a session (Mac↔Windows spent weeks here —
   do not repeat it; the failure modes are documented in
   `remote-pointer-stall-handover.md`).
3. **Trust-boundary rigor**: every inbound frame is attacker-reachable. Fuzz the
   decoders; harden the systemd unit; never widen uinput access beyond the
   dedicated group.
4. **Operability**: diagnostics log with monotonic seam timestamps (parity with the
   Mac's `trace t=` instrumentation), versioned protocol negotiation, update path,
   headless CI coverage on both deb and rpm targets.

## Phase 0 — Ground truth (1 day)

- Enumerate what `input.rs` does per desktop today (X11 vs Wayland, GNOME vs KDE:
  pointer absolute vs relative, gesture mapping, wheel) in `Linux/README.md`.
- Wire a Linux node into `Tools/UniSpaceSimulation` as a third process speaking
  portable v2 over loopback. This is the regression gate for every later phase.
- Acceptance: `Scripts/simulate.sh` runs Mac-controller → Linux-receiver activation,
  input, clipboard, file transfer, and restart recovery headlessly.

## Phase 1 — Realtime pointer lane (3–4 days)

The single biggest user-visible gap. Mac probes with `realtimePointerProgressV1`;
Linux currently answers nothing.

- Implement `udp-pointer-v2` + `realtime-pointer-progress-v1`: receiver-initiated
  UDP hello to the Mac (mirror `AuthenticatedPointerTransport`'s receiver flow and
  its replace-restart rules — including the Windows "newest inbound wins" case),
  progress acknowledgements, generation/sequence validation.
- Absolute pointing: `EV_ABS` with calibrated `ABS_X/ABS_Y` ranges per display,
  matching the Mac's normalized coordinates; keep `EV_REL` fallback when
  calibration is unavailable.
- Thread model: dedicated RT-priority writer thread (`SCHED_FIFO` via rtkit or
  systemd `RLIMIT_RTPRIO`), lock-free queue from network to uinput, drop-oldest on
  overflow — never block the socket task on a slow uinput write.
- Enable `realtimePointerProgressV1` in `DeviceDescriptor::linux()` capabilities.
- Acceptance: simulator p95 wire gap ≤ 5 ms with the UDP lane; forced lane kill
  recovers via reliable path with no session loss.

## Phase 2 — Real display geometry (2–3 days)

Displays are currently configuration-pinned; wrong geometry breaks edge routing
and absolute injection.

- X11: RandR (`xrandr`-equivalent via XCB) for CRTCs/outputs/scale.
- Wayland: `zxdg_output_manager_v3` for logical geometry + `wl_output` scale;
  fall back to the freedesktop DisplayConfig portals (GNOME `org.gnome.Mutter.DisplayConfig`,
  KDE `org.kde.KWin.TabletModeManager`/displayconfig) — both desktops in the
  support matrix ship one.
- Publish displays in the hello/workspace announcement; refresh on hotplug
  (udev + Wayland output events) and re-announce to the Mac.
- Acceptance: display hotplug mid-session re-routes edges without restarting the
  receiver; scale factors verified at 100%/200%.

## Phase 3 — Production hardening (3–4 days)

- **Fuzzing**: `cargo-fuzz` targets for frame/control/secure decoders (they parse
  untrusted network bytes). Gate CI on no regressions.
- **systemd hardening**: `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`,
  `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`, `CapabilityBoundingSet=`,
  `MemoryDenyWriteExecute`. uinput access stays group-gated; document the udev rule.
- **Observability**: diagnostics ring buffer + `unispace-linux diagnostics dump`
  with monotonic timestamps at decode → session-delivery → inject seams (parity
  with the Mac trace); `--json` status for scripting.
- **Reliability**: connection retry schedule matching the Mac's
  `ConnectionRetrySchedule`; session watchdog (heartbeat expiry → release all);
  graceful degradation when keyring/portal is absent.
- **CI**: build + test + clippy `-D warnings` + `cargo-deny` on x86_64 *and* aarch64
  (cross or QEMU); nfpm packages as artifacts; a smoke run of the loopback
  simulator against a Linux node.

## Phase 4 — Release operations (2 days)

- Version-protocol handshake check at connect (receiver refuses incompatible Mac
  builds with an actionable notification — no silent weirdness).
- Update path: GitHub releases + `latest.json` check from the tray; deb/rpm repos
  or upgrade instruction in-app. No auto-update daemon (scope creep).
- QA matrix runbook: Ubuntu 24.04 + Fedora 41, GNOME + KDE, Wayland + X11,
  x86_64 + arm64 (Pi 5), 100%/200% scale, with a signed-off checklist per cell.

## Phase 5 — Linux as controller (deferred, separate plan)

Bidirectional control needs input *capture* (evdev /dev/input reads, requiring
`input` group + compositor quirks on Wayland) and cursor suppression — a feature
project, not a hardening project. The wire protocol already supports it.

## Explicitly skipped

- GPU/UI shell (the app is a tray + notifications by design; a GUI is not needed
  for production operation).
- Mir/Deepin/Sway-first-class support (basic injection works; not in the QA matrix).
- Containerized/Flatpak distribution (uinput + keyring + portal sandboxing is a
  project of its own; deb/rpm first).
