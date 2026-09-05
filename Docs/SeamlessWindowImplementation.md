# Seamless windows: macOS preview

This branch implements a one-window Mac-to-Mac streaming preview. It is **not yet the complete seamless-window product** described in the roadmap in PR #42. Do not release it as fully working until the validation and remaining implementation below are complete.

## Using the preview

1. Build this branch on two paired Macs running macOS 14 or later.
2. Open **Seamless Windows…** from the UniSpace menu on both Macs. Enable sharing for the current session on both.
3. On the source Mac, click **Refresh Windows** and grant Accessibility and Screen Recording permission when prompted. Reopen UniSpace if macOS requires it.
4. Keep the selected source window visible. Choose that window and a paired destination Mac, then click **Move Window to Mac**.
5. Accept the incoming window on the destination. Its contents appear in a native resizable window alongside local apps; no desktop is captured.
6. Click inside the proxy before typing. Close it, use **Bring All Windows Home**, or press Control Option Command Escape to end sharing.

The source app keeps running on its original Mac. Closing the proxy never closes the source application. The current preview also leaves the source window visible. Destination resizing scales the presentation; it does not resize the source application. Clipboard and file transfer continue through their existing features.

## Architecture and bounds

- Domain: opaque window identity, validated input/geometry, presentation epoch, control messages, bounded H.264 access units. Native handles never cross the network.
- Application: source-authoritative presentation state, monotonic ten-second lease deadline, acceptance, renewal, expiry, stale-frame and replay rejection. Every new presentation has a new epoch.
- Infrastructure: ScreenCaptureKit single-window capture, VideoToolbox H.264 encoder, AVSampleBufferDisplayLayer hardware decoding, native NSWindow, AX selection and PID-targeted input, and encrypted connections.
- App: session opt-in, local window picker, destination picker, explicit receiver acceptance, status, emergency return-home actions. Views contain no network or capture logic.

Control uses TCP 61343 (`_unispace-win._tcp`); video uses TCP 61344 (`_unispace-vid._tcp`). These do not share the existing input, clipboard, or file-transfer queues. Discovery uses Bonjour; a stored direct address is used when no Bonjour route exists. Both endpoints must use this preview protocol; Windows and Linux are not offered as destinations.

Each connection authenticates the workspace, peer ID, lane and a random nonce with the existing workspace key. Directional HKDF-SHA256 keys bind both nonces, IDs, workspace and lane. ChaCha20-Poly1305 protects framed messages and monotonic replay counters. This inherits the existing workspace trust model: all devices holding the workspace key share that trust boundary.

Queues are bounded: up to 64 small control messages, one video send, one encode callback, three capture buffers, and four connections per service. Frame bytes are limited to 2 MiB, control messages to 16 KiB, parameter sets to 4 KiB each, dimensions to 4096 and total pixels to 4096 × 2160. Capture is initially capped at 1920 × 1080 and 30 FPS. A dropped encoded unit forces a keyframe; the receiver rejects dependent frames after a sequence gap. A stalled send closes after two seconds. TCP head-of-line blocking remains a limitation; these bounds do not establish the 80 ms latency goal.

Only a locally selected, unambiguously matched AX window accepts input. The service checks the presentation epoch, intended peer and local lease deadline before applying input. Keyboard/mouse state is released on focus loss, return home and disconnect. Local source keyboard/mouse interaction, source minimization/closure, system sleep, capture failure, or lease expiry ends sharing. Reconnect requires a fresh explicit offer and acceptance. No frames, window titles or clipboard contents are written to logs.

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
