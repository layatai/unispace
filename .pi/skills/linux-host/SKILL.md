---
name: linux-host
description: Deploy, debug, and validate the UniSpace Linux receiver on the dellom test host (SSH, build, pairing, logs, protocol gotchas). Use when working on Linux/ receiver code, live cross-platform validation, or anything involving the dellom.tailda4c05.ts.net box.
---

# UniSpace Linux host (dellom)

Test host for live validation of the Rust Linux receiver (`Linux/` crate).

## Host facts

- SSH: `ssh tai@dellom.tailda4c05.ts.net` (Tailscale, key auth, no password)
- Tailnet IP: `100.77.185.39`; Omarchy (Arch + Hyprland, Wayland), x86_64
- Rust via mise: `cargo`/`rustc` on PATH (edition 2024 OK)
- Receiver binary: `~/.local/bin/unispace-linux`; build dir: `~/unispace-build`
- Config: `~/.config/unispace/receiver.json`; uinput rule: `/etc/udev/rules.d/70-unispace-uinput.rules` (group `unispace`, user is a member)
- `/dev/uinput` must be `crw-rw---- root unispace` — if perms regress after reboot before the udev rule loads, re-run `~/setup-uinput.sh`

## Build + deploy loop

```sh
# 1. sync sources (run from unispace/Linux/)
rsync -a src/ tai@dellom.tailda4c05.ts.net:~/unispace-build/src/

# 2. build + install + restart on the host
ssh tai@dellom.tailda4c05.ts.net 'pkill -x unispace-linux; cd ~/unispace-build && cargo build --release --bin unispace-linux && install -m 755 target/release/unispace-linux ~/.local/bin/unispace-linux && (RUST_LOG=unispace_linux=debug nohup ~/.local/bin/unispace-linux run > ~/receiver.log 2>&1 &) && sleep 8; tail -20 ~/receiver.log'
```

- Always run `cargo test` + `cargo clippy --all-targets -- -D warnings` locally BEFORE deploying.
- Sync `Cargo.toml`/`Cargo.lock` too when dependencies change.
- Never use `cd Linux && …` chains in one-off bash calls unless the previous call left cwd there; use absolute paths.

## Logs

- Receiver: `~/receiver.log` on the host (`grep -v clipboard` to skip the expected
  X11 clipboard warnings — the daemon runs from SSH without a display session,
  so `arboard` cannot reach X11/Wayland; clipboard only works when launched
  inside the desktop session).
- Mac controller trace: `~/Library/Containers/com.layatai.unispace/Data/Library/
  Application Support/UniSpace/Logs/diagnostics.log` — grep `t=` lines for the
  decoded → consumed → coordinator seam timestamps, and `Activating session …
  platform=linux`.
- Watch live: `ssh … 'tail -f -n 0 ~/receiver.log'`

## Pairing (requires a human on the Mac)

1. Mac app → "Pair New Device" (keeps a direct listener open on TCP 61337).
2. On the box: `printf "y\n" | ~/.local/bin/unispace-linux pair taimb2.tailda4c05.ts.net`
   — better: run it in background writing to `~/pair.log`, read the 6-digit code,
   and have the user click "Codes match" on the Mac only after comparing.
3. Do NOT probe port 61337 with nc first — see gotcha below.

## Protocol gotchas (all bit us live — don't reintroduce them)

- **Key casing**: Swift Codable uses exact property names. Wire JSON must use
  `workspaceID`, `deviceID`, `deviceID` inside displays, `localDeviceID` — NOT
  `#[serde(rename_all = "camelCase")]` output (`workspaceId`). `PeerAddress`
  serializes as a plain string, not `{"host"}`. Regression test:
  `model::wire_casing_tests`.
- **Packet kinds per lane**: control channel uses HELLO=10/SEALED=11; clipboard
  and file-transfer lanes use **1/2**. `ChannelProfile` carries them.
- **`supportedWireVersions` is optional** in the Mac's hello — `#[serde(default)]`.
- **Keepalive is mandatory** on every secure channel: the connection idles
  between sessions, and without TCP keepalive a Mac restart leaves the receiver
  parked on a half-open socket (edges silently stop routing).
- **Portable realtime field order is an ABI**: after version/identity/epoch,
  generation, and sequence, Swift writes `timestampNanos` and then delta,
  cumulative, and absolute X/Y doubles. Keep Rust aligned with
  `PortableBinaryCodec`; regression test:
  `protocol::tests::realtime_pointer_matches_swift_field_order_and_round_trips`.
- **Pointer movement uses cumulative displacement differences** for datagram
  loss recovery, with a zero baseline on generation change. `absoluteX/Y` is
  the suppressed Mac cursor position, not a target-space coordinate. Dedupe per
  (generation, sequence): sequence restarts at 0 on generation bump.
- **Pointer-lane tasks must end with their control connection**. A detached UDP
  task keeps port 61339 bound and makes every reconnect fail with
  `bind UDP pointer lane`; keep it owned by the connection's `JoinSet`.
- **uinput must advertise BTN_\* codes** (0x110–0x116) or every click is
  silently dropped by the kernel while movement still works.
- **Gestures follow Windows-injector semantics**: swipe shortcuts fire once per
  gesture on threshold, reset per phase (mayBegin/began → reset, cancelled →
  reset, ended → reset). Alt+Left/Right etc. are NOT bound in Omarchy/Hyprland
  by default — "gesture doesn't work" is often just an unbound shortcut.
- **Workspace updates arrive at runtime** (Mac pushes topology edits) — edge
  links must be read from the live snapshot, never frozen at pairing time.
- **notify-rust / ksni block_on**: run both on dedicated OS threads (see
  `status.rs`) or they panic with "Cannot start a runtime from within a runtime".

## Mac-side pairing service gotcha

`PairingNetworkService.startHosting` accepts ONE connection; a stray connection
(any port probe!) cancels it and used to wedge hosting until a Mac app restart.
Fixed by `clearChannel` in `PairingNetworkService.swift` (commit bca47b3) —
never port-probe 61337 while pairing is open.

## Validation checklist (live)

1. `ssh … 'pgrep -c unispace-linux'` → 1; `receiver.log` shows
   `connected controller=taimb2`
2. Mac diagnostics: workspace contains the linux device; topology links exist
3. Cross Mac left edge → activation → move (realtime lane), click (reliable),
   push through Linux right edge → returns control to the Mac
4. Watch for `pointer generation changed` / `pointer jump clamped` debug lines
   during movement anomalies
