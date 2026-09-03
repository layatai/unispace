<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="112" alt="UniSpace app icon">
</p>

<h1 align="center">UniSpace</h1>

<p align="center">
  <strong>One keyboard. Every device.</strong><br>
  Move your pointer and files between up to four Macs, Linux PCs, and Windows PCs as if they shared one desk—over your LAN or private Tailscale network.
</p>

<p align="center">
  <a href="https://github.com/layatai/unispace/releases/latest"><img src="https://img.shields.io/github/v/release/layatai/unispace?display_name=tag&style=flat-square" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple" alt="macOS 14 or newer">
  <img src="https://img.shields.io/badge/native-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white" alt="Native SwiftUI app">
</p>

<p align="center">
  <a href="https://github.com/layatai/unispace/releases/latest"><strong>Download the latest release</strong></a>
  ·
  <a href="#quick-start">Quick start</a>
  ·
  <a href="#networking">Networking</a>
  ·
  <a href="Documentation/Protocol/portable-gestures.md">Gesture support</a>
</p>

<p align="center">
  <img src="Documentation/Images/welcome.png" width="900" alt="UniSpace welcome screen with Create Workspace and Join Workspace options">
</p>

UniSpace is a native macOS Dock and menu-bar controller for sharing one Mac's keyboard, pointer, clipboard, and regular files with your other Macs, Linux PCs, and Windows PCs. Arrange their displays the way they sit on your desk, then cross a touching edge to move control to the next device. Linux uses the receiver in this repository; Windows support is provided by the receiver built into Macifier.

## Built for a shared desk

- **Natural handoff:** move through a configured display edge to control another device, then cross back to return.
- **Finder and File Explorer continuity:** copy regular files on one trusted device and paste them on another after encrypted streaming and SHA-256 verification.
- **LAN or Tailscale:** discover nearby devices with Bonjour or connect directly with a MagicDNS name or Tailscale IP.
- **Responsive under imperfect networks:** trusted sessions keep bulk file content separate from reliable keyboard, button, drag, and scroll events and replaceable pointer motion.
- **A safe way home:** press `Control-Option-Command-Escape` at any time to stop remote control and return locally.

<p align="center">
  <img src="Documentation/Images/control-center.png" width="820" alt="UniSpace control center showing two Macs online and required permissions allowed">
</p>

<p align="center"><sub>Controller ready with two Macs online, required permissions granted, and the emergency return shortcut always visible.</sub></p>

## Quick start

1. [Download the latest release](https://github.com/layatai/unispace/releases/latest), open the DMG, and move UniSpace to Applications.
2. Launch UniSpace on each Mac, install the [Linux receiver](Linux/README.md) on each Linux PC, and enable UniSpace in Macifier on each Windows receiver. Grant **Input Monitoring** and **Post Events** on Macs when prompted.
3. Choose **Create Workspace** on the Mac whose keyboard and pointer you want to use.
4. Choose **Pair New Device** on the controller, then **Join Workspace** on the other Mac, run `unispace-linux pair MAC_ADDRESS` on Linux, or join through Macifier on Windows.
5. Select the controller over the LAN, or enter its MagicDNS name or Tailscale IP. Confirm the same six-digit code on both devices.
6. Open **Displays**, drag the display cards so their edges touch, and move the pointer through that edge.
7. Copy regular files in Finder or your desktop file manager and paste them on the active compatible device. On macOS, **File Transfers** shows progress, cancellation, retry, and received files.

To join a different workspace later, open **General → Workspace**, choose **Leave Workspace…**, then return to setup and select **Join Workspace**. This removes only the local workspace membership and stored workspace key; operating-system permissions remain unchanged.

## Control and reconnection

Keyboard input, pointer buttons, dragging, scrolling, modifiers, and shortcuts
follow the active device. If the focused remote device disconnects, UniSpace
immediately ends the active session, releases pointer suppression, and returns
keyboard and pointer focus to the controller. A later reconnect restores device
availability but never silently reclaims focus; move through the configured edge
again to start a new session.

UniSpace automatically retries trusted peers over Bonjour and stored Tailscale
addresses. On **Devices**, use **Refresh Connections** to retry only offline
devices, or **Retry Now** on one device. **Restart Networking…** is the
disruptive fallback: it briefly disconnects every peer and ends active control.

File transfers use a separate encrypted TCP content session. A content-session
interruption pauses and resumes from receiver-verified offsets without terminating
keyboard or pointer control.

## Networking

Bonjour handles automatic discovery on a trusted local network. Across Tailscale, enter the controller Mac's MagicDNS name or Tailscale IP when joining or editing a device's connection address.

| Port | Protocol | Purpose |
| --- | --- | --- |
| `61337` | TCP | Pairing and workspace-key exchange |
| `61338` | UDP, then TCP fallback | Existing Mac-to-Mac v1 control; Linux/Windows reliable TCP fallback |
| `61339` | UDP | Existing Mac-to-Mac replaceable pointer motion |
| `61340` | QUIC/UDP | Cross-platform reliable stream, ALPN `unispace/3` |
| `61340` | TCP | Encrypted resumable file-transfer content channel |
| `61341` | UDP | Authenticated replay-protected latest pointer state for capable receivers |

Allow these ports through any host or tailnet firewall between participating devices. Linux and Windows initiate trusted control and file-transfer sessions, so portable receivers do not need inbound firewall exceptions. Reliable input and control messages remain available when the pointer or file-transfer lane is unavailable.

## Security and privacy

- Pairing requires a matching code and approval on both devices.
- The workspace key is transferred only after an ephemeral key exchange.
- Peer sessions derive per-connection keys, authenticate handshakes, encrypt traffic with ChaCha20-Poly1305, and reject replayed messages.
- File transfers validate manifests and offsets, stream through bounded buffers, and publish received files only after SHA-256 verification.
- Incoming files remain in application-owned staging until pasted, revealed, or explicitly exported.
- Workspace secrets are protected by Keychain on macOS, Secret Service on Linux, and DPAPI on Windows.
- Raw keyboard, pointer, clipboard contents, and file contents are never logged.

## Current scope

UniSpace forwards standard pointer movement and buttons, scrolling, keyboard keys,
modifiers, shortcuts, and supported multi-finger trackpad gestures. Mac peers replay
the original native gesture. Linux and Windows peers receive normalized portable gestures for
pinch zoom, navigation, Mission Control/App Exposé, workspace switching, smart zoom,
Launchpad, and Show Desktop. See the [gesture interoperability contract](Documentation/Protocol/portable-gestures.md)
for the exact mappings and compatibility rules. Mixed versions keep normal input
working without sending incompatible frames.

Compatible versions also share text and links and transfer regular files between
macOS, Linux, and Windows. See [Docs/FileTransfer.md](Docs/FileTransfer.md) for file-transfer
protocol, staging, recovery, and compatibility details.

Connection ownership, continuity isolation, and performance release gates are
documented in [Docs/performance-regression-remediation.md](Docs/performance-regression-remediation.md).

Directories, macOS packages, symbolic links, reparse points, special files, screen
sharing, receiver-to-Mac control, an internet relay, Touch ID or power-button forwarding,
login/UAC secure-desktop control, Secure Input bypasses, and live cross-device drag
continuation remain intentionally unsupported.

<details>
<summary><strong>Build and test from source</strong></summary>

### Requirements

- macOS 14 or newer
- Xcode 26.6 or a compatible Swift 6 toolchain
- XcodeGen 2.46 or newer
- Input Monitoring and Post Events permissions on every participating Mac

```sh
./Scripts/test.sh          # full suite, including the signed UI launch test
./Scripts/test.sh --unit   # deterministic unit, protocol, transport, and simulated E2E tests
./Scripts/test.sh --input-smoke # signed TCC/event-tap check; requires both input permissions
./Scripts/build.sh --universal
./Scripts/simulate.sh           # two headless nodes with protocol-latency gates
./Scripts/simulate.sh shell     # interactive two-node fault-injection shell
```

The full and unit modes write an `.xcresult` bundle under `.build/test-results` and enforce the coverage floors in `Config/Coverage.json`. The native input smoke test is opt-in because macOS grants Input Monitoring and Accessibility to the signed test process separately.

The generated Xcode project is derived from `project.yml`; edit the YAML and regenerate instead of hand-editing `project.pbxproj`.

The Windows receiver and its tests are maintained in the companion Macifier repository. Cross-platform file-transfer codec fixtures must pass in both Swift and .NET before release.

The simulator launches two isolated CLI node processes over loopback and uses
named pasteboards, so it does not open windows or modify the general pasteboard.
It generates an ephemeral workspace key in mode-`0600` temporary configuration
files and never reads or writes Keychain.
Its scripted run checks control activation, input latency, clipboard delivery,
Finder-style file transfer, and restart recovery. Pointer p95 is compared with
the idle baseline and any latency or delivery stall above 50 ms fails the run.

The Rust Linux receiver is built and tested from this repository:

```sh
cargo test --manifest-path Linux/Cargo.toml
./Scripts/build-linux.sh
```

</details>

<details>
<summary><strong>Create a signed and notarized release</strong></summary>

Store notarization credentials in a `notarytool` Keychain profile, then run:

```sh
UNISPACE_NOTARY_PROFILE=your-profile ./Scripts/release.sh
```

The script also accepts `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID`, or the corresponding App Store Connect API-key variables. It produces a versioned universal DMG, then validates signing, stapling, and Gatekeeper acceptance.

</details>
