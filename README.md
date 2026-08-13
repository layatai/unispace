# UniSpace

UniSpace is a native macOS Dock and menu-bar app for controlling up to four personal Macs with one keyboard and pointer over a trusted LAN or Tailscale network.

## Requirements

- macOS 14 or newer
- Xcode 26.6 or a compatible Swift 6 toolchain
- XcodeGen 2.46 or newer
- Input Monitoring and Post Events permissions on every participating Mac

## Build and test

```sh
./Scripts/test.sh          # full suite, including the signed UI launch test
./Scripts/test.sh --unit   # unsigned domain, application, and infrastructure tests
./Scripts/build.sh --universal
```

The generated Xcode project is derived from `project.yml`; edit the YAML and regenerate instead of hand-editing the project file.

## Pair Macs

1. Launch UniSpace on the first Mac and create a workspace.
2. Grant Input Monitoring and Post Events permissions when prompted.
3. Make the first Mac the controller and choose **Pair New Mac**.
4. On the second Mac choose **Join Workspace**.
5. Confirm that the six-digit code matches on both Macs, then approve both sides.
6. Arrange displays in Settings by dragging their cards next to each other.

UniSpace uses Bonjour for automatic LAN discovery. Across Tailscale, enter the host Mac’s MagicDNS name or Tailscale IP; UniSpace uses TCP `61337` for pairing and TCP `61338` for trusted control sessions. Pairing transfers a random workspace key only after an ephemeral key exchange and two-sided code confirmation. Peer sessions use per-connection keys derived from that workspace key, HMAC-authenticated handshakes, ChaCha20-Poly1305 encryption, and replay sequencing. Workspace secrets are stored in Keychain. Raw keyboard and pointer events are never logged.

Use `Control-Option-Command-Escape` to stop a remote-control session and return control locally.

To join a different workspace, open **General → Workspace**, choose **Leave Workspace…**, and confirm. This removes only this Mac’s local workspace membership and Keychain key, preserves macOS permissions, and returns to the setup screen where **Join Workspace** is available.

## Signed release

Store notarization credentials in a notarytool Keychain profile, then run:

```sh
UNISPACE_NOTARY_PROFILE=your-profile ./Scripts/release.sh
```

The script also accepts the same `APPLE_ID`, `APPLE_PASSWORD`, and
`APPLE_TEAM_ID` environment contract used by the gitui release workflow, or
the corresponding App Store Connect API-key variables.

The release script creates a universal Developer ID archive and a versioned notarized DMG such as `dist/UniSpace-1.0.6.dmg`, then validates code signing, stapling, and Gatekeeper acceptance. It never accepts credentials on the command line beyond the non-secret Keychain profile name.

## Current scope

UniSpace forwards standard mouse movement/buttons, scrolling, keyboard keys, modifiers, and shortcuts. It intentionally does not provide screen sharing, clipboard/file transfer, internet relay, Touch ID or power-button forwarding, login-window control, or Secure Input bypasses.
