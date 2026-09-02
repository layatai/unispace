# UniSpace Receiver for Linux

The Linux receiver lets a paired Mac control a GNOME or KDE desktop on X11 or
Wayland. It uses the same portable, authenticated UniSpace protocols as the
Windows receiver, including the authenticated UDP realtime pointer lane. Linux
remains receiver-only in this release.

## Supported systems

- Ubuntu 24.04 LTS and newer, and the current two Fedora releases
- x86_64 and arm64
- GNOME and KDE Plasma on Wayland or X11
- A 5-second controller-heartbeat watchdog releases injected input if the
  controller stalls

Pointer motion rides the authenticated UDP lane (`udp-pointer-v2`) with
generation/sequence progress acknowledgements (`realtime-pointer-progress-v1`),
falling back to the reliable TCP channel automatically. Other freedesktop
desktops can use basic keyboard and pointer injection, but clipboard
integration, status presentation, and gesture shortcuts are best effort.
Display geometry currently comes from `xrandr` on X11 (fallback 1920x1080);
Wayland enumeration and hotplug are planned (see
`Docs/linux-production-app-plan.md`).

## Install and pair

Install the `.deb` or `.rpm`, then grant your account access to the dedicated
virtual-input group and sign out once:

```sh
sudo usermod -aG unispace "$USER"
```

On the controller Mac choose **Pair New Device**. On Linux run:

```sh
unispace-linux pair MAC_ADDRESS
```

Pairing starts the packaged user service automatically. If the desktop session
was not available during pairing, start it after signing in:

```sh
systemctl --user enable --now unispace.service
```

The package globally enables the service; it remains dormant until a workspace
configuration exists. The workspace key is stored in Secret Service (GNOME
Keyring or KWallet), never in the JSON configuration file.

The application launcher opens receiver status. KDE and desktops implementing
StatusNotifierItem can also show a tray item; GNOME uses the launcher and desktop
notifications unless an AppIndicator extension is installed.

## Gesture bindings

`~/.config/unispace/receiver.json` accepts a `gestureBindings` section. The
default `auto` profile uses `XDG_CURRENT_DESKTOP` to select Hyprland, GNOME, or
KDE shortcuts. Omitted bindings inherit the profile; an empty array disables a
binding.

```json
{
  "gestureBindings": {
    "profile": "auto",
    "workspaceUp": ["leftMeta", "space"],
    "workspaceDown": []
  }
}
```

Profiles are `auto`, `hyprland`, `gnome`, `kde`, and `disabled`. Override names
are `navigationBack`, `navigationForward`, `workspacePrevious`,
`workspaceNext`, `workspaceUp`, `workspaceDown`, `smartMagnify`, `pinchIn`, and
`spread`. Supported keys are `leftCtrl`, `leftShift`, `leftAlt`, `leftMeta`,
`left`, `right`, `tab`, `space`, `a`, `d`, `s`, and `equal`.

The Hyprland profile follows Omarchy defaults: horizontal workspace swipes use
Super+Tab/Super+Shift+Tab, swipe up opens the Omarchy menu, swipe down toggles
the scratchpad, pinch opens Apps, and spread toggles the scratchpad. GNOME and
KDE retain the portable Meta+Ctrl+Arrow, Meta+Tab, Meta+D, and Meta+A mappings.

## File transfer and uninstall

File continuity supports regular files, including empty and multiple files.
Directories and symbolic links are intentionally ignored.

Uninstalling stops the receiver and removes package-owned binaries, service,
launcher, and uinput rules. It preserves the user's workspace configuration,
Secret Service credential, and `unispace` group for safe reinstall. Remove the
local membership first when that data should also be deleted:

```sh
unispace-linux unpair
sudo apt remove unispace-linux   # Ubuntu
sudo dnf remove unispace-linux   # Fedora
```

## Build and test

```sh
cargo test --manifest-path Linux/Cargo.toml
./Scripts/build-linux.sh
```

`build-linux.sh` creates the release binary and, when `nfpm` is installed, both
Debian and RPM packages under `dist/`.

## Security

Access to `/dev/uinput` permits system-wide synthetic input. The package grants
it only to the dedicated `unispace` group; it does not run a root daemon. Pairing
uses a six-digit verified P-256 exchange, and every network channel authenticates
the workspace and encrypts application frames with ChaCha20-Poly1305.
