# Seamless windows: macOS preview

This branch implements a one-window Mac-to-Mac streaming preview. It is **not yet the complete seamless-window product** described in the roadmap in PR #42. Do not release it as fully working until the validation and remaining implementation below are complete.

## Using the preview

1. Build this branch on two paired Macs running macOS 14 or later.
2. Open the **Seamless Windows** section in the main UniSpace window's sidebar on both Macs (also reachable from the UniSpace menu or the menu bar icon). Enable sharing for the current session on both — this is intentionally not persisted across relaunches, so it resets each time UniSpace restarts; enabling triggers an automatic window scan.
3. On the source Mac, grant Accessibility and Screen Recording permission when prompted. Reopen UniSpace if macOS requires it.
4. Keep the source window visible. Either double-click it in the picker's list (auto-moves to the already-selected destination Mac), or use the menu bar icon's **Move Window to Mac** submenu to pick an application window and destination without opening the picker at all.
5. The destination auto-accepts the incoming window — no confirmation click. Its contents appear in a frameless-looking resizable window with native traffic-light buttons; no desktop is captured. Drag the transparent top area to reposition this window without moving the source. Interactions below that area are forwarded to the source app.
6. Click inside the proxy before typing. Close it, use **Bring All Windows Home**, or press Control Option Command Escape to end sharing.

The source app keeps running on its original Mac. Closing the proxy never closes the source application. The current preview also leaves the source window visible. Destination resizing scales the presentation; it does not resize the source application — an earlier attempt to do this by simulating a corner-drag on the source's real desktop was pulled after it closed the shared window on the receiver, since a synthetic drag at computed screen coordinates has no way to confirm it grabbed the right control. Resizing the source ends the session so input cannot use stale geometry. Clipboard and file transfer continue through their existing features.

## Architecture and bounds

- Domain: opaque window identity, validated input/geometry, presentation epoch, control messages, bounded H.264 access units. Native handles never cross the network.
- Application: source-authoritative presentation state, monotonic 25-second lease deadline (generous enough for a cold Tailscale/WAN handshake, not just LAN), acceptance, renewal, expiry, stale-frame and replay rejection. Every new presentation has a new epoch.
- Infrastructure: ScreenCaptureKit single-window capture, VideoToolbox H.264 encoder, AVSampleBufferDisplayLayer hardware decoding, native NSWindow, CGWindowList-based selection and PID-targeted `CGEvent` input (no AX — this app's sandbox denies mach-lookup to `com.apple.axserver`), and encrypted connections.
- App: session opt-in embedded in the main window's sidebar, local window picker, destination picker, menu bar quick-move, automatic receiver acceptance, status, emergency return-home actions. Views contain no network or capture logic.

Control uses TCP 61343 (`_unispace-win._tcp`); video uses TCP 61344 (`_unispace-vid._tcp`). These do not share the existing input, clipboard, or file-transfer queues. Discovery uses Bonjour; a stored direct address is used when no Bonjour route exists. Both endpoints must use this preview protocol; Windows and Linux are not offered as destinations.

Each connection authenticates the workspace, peer ID, lane and a random nonce with the existing workspace key. Directional HKDF-SHA256 keys bind both nonces, IDs, workspace and lane. ChaCha20-Poly1305 protects framed messages and monotonic replay counters. This inherits the existing workspace trust model: all devices holding the workspace key share that trust boundary.

Queues are bounded: up to 64 small control messages, one video send, one encode callback, three capture buffers, and four connections per service. Frame bytes are limited to 2 MiB, control messages to 16 KiB, parameter sets to 4 KiB each, dimensions to 4096 and total pixels to 4096 × 2160. Capture is initially capped at 1920 × 1080 and 30 FPS. A dropped encoded unit forces a keyframe; the receiver rejects dependent frames after a sequence gap. A stalled send closes after two seconds. TCP head-of-line blocking remains a limitation; these bounds do not establish the 80 ms latency goal.

Only a locally selected, unambiguously matched CG window (by title and size) accepts input. The service checks the presentation epoch, intended peer and local lease deadline before applying input. Keyboard/mouse state is released on focus loss, return home and disconnect. Local source keyboard/mouse interaction, source minimization/closure, system sleep, capture failure, or lease expiry ends sharing. Reconnect requires a fresh explicit offer and acceptance. No frames, window titles or clipboard contents are written to logs.

## Remaining implementation

- True single-owner presentation: keep capture alive while the source window is no longer locally presented, using a validated public API strategy. No hidden/minimized-window behavior is assumed.
- Title-bar edge dragging and device-layout drop targets; multi-window ownership and moving an existing proxy between destinations.
- Source resize acknowledgements, dynamic capture geometry, mixed-DPI changes, and reliable child-window/menu/dialog groups.
- Datagram/QUIC media with explicit pacing, congestion response, frame-age metrics, and bounded decoder acknowledgement; measure whether the preview TCP route meets any LAN target.
- Windows capture/proxy/input implementation and portable media/control interoperability. The current property-list payload is macOS-only.
- Full IME/text composition, accessibility representation of remote content, custom title bars, protected/elevated content, and global shortcut policy.

## Validation gates

The new macOS workflow regenerates the project, compiles the app, runs the lease/protocol tests and builds a universal release. Existing full-suite workflows remain required. CI cannot establish that ScreenCaptureKit, macOS permissions, remote input, or the two-device UX work correctly.

Before accepting the feature, record results on two physical Macs for: first frame and p95 glass-to-glass latency; sustained 1080p/30; CPU, memory and bandwidth; typing/click/drag/scroll; local interruption and emergency stop; held-input disconnect; sleep; source close/minimize; simultaneous offers; rejected offers; malformed/authentication failures; app relaunch; LAN and direct/Tailscale routing; resize and display-scale changes; large file transfers while controlling the window; and permission revocation.

Target p95 LAN latency is below 80 ms with no regression in existing pointer/control handling. These are targets, not measured results. Full seamless-window milestone acceptance remains open.
