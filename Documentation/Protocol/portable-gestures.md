# Portable gesture interoperability

UniSpace preserves native macOS gesture replay while providing deterministic Linux and Windows
equivalents. Gesture transport is capability-gated so older peers continue receiving
keyboard, pointer, button, drag, and scroll events without decoding unknown frames.

## Capabilities and routes

| Capability | Receiver | Payload |
| --- | --- | --- |
| `public-trackpad-gestures-v1` | macOS | Original serialized `CGEvent` for native replay |
| `portable-trackpad-gestures-v1` | Linux/Windows | Normalized `PortableGesture` in portable input v2 |

The controller captures each gesture in the suppressible Core Graphics event tap.
That prevents the gesture from also executing on the controller while remote control
is active. The serialized event remains unchanged for Mac peers; the same raw event is
normalized for portable Linux and Windows peers.

## Supported input

| macOS input | Raw source | Portable kind | Windows equivalent |
| --- | --- | --- | --- |
| Two-finger scroll | `scrollWheel` | `scroll` | Vertical/horizontal wheel |
| Secondary click | Right mouse event | `mouseButton` | Right click |
| Three-finger drag | Mouse drag event | Pointer + held button | Native drag |
| Two-finger pinch | HID zoom `8` | `magnify` | Ctrl+wheel zoom |
| Two-finger rotate | HID rotation `5` | `rotate` | Transported; safe no-op |
| Smart zoom | AppKit smart magnify | `smartMagnify` | Application zoom-in |
| Navigation left/right | HID navigation swipe `16` | `swipe` | Browser forward/back |
| Three/four-finger left/right | Dock swipe `23`, axis `1` | `workspaceSwipe` | Win+Ctrl+Left/Right |
| Three/four-finger up | Dock swipe `23`, axis `2`, positive | `workspaceSwipe` | Windows Task View |
| Three/four-finger down | Dock swipe `23`, axis `2`, negative | `workspaceSwipe` | Show Desktop |
| Spread fingers | Dock swipe `23`, axis `3`, positive | `desktopPinch` | Show Desktop |
| Pinch fingers | Dock swipe `23`, axis `3`, negative | `desktopPinch` | Windows app launcher |

Rotation is captured and transported so compatible receivers may add an application-
specific action later. Macifier intentionally does not invent a global Windows
shortcut because Windows has no safe system-wide rotation equivalent.

## Portable wire model

`PortableGesture` contains:

- `kind`: gesture semantic;
- `phase`: `none`, `mayBegin`, `began`, `changed`, `ended`, or `cancelled`;
- `deltaX` and `deltaY`: normalized directional movement;
- `value`: magnification, rotation, or pinch direction/value.

Gesture kinds are append-only wire values:

| Value | Kind |
| ---: | --- |
| `0` | `other` |
| `1` | `magnify` |
| `2` | `swipe` |
| `3` | `rotate` |
| `4` | `smartMagnify` |
| `5` | `begin` |
| `6` | `end` |
| `7` | `workspaceSwipe` |
| `8` | `desktopPinch` |

Portable input v2 uses event discriminator `6`, followed by kind, phase, three
big-endian doubles (`deltaX`, `deltaY`, `value`), and no platform-native bytes.

## Raw macOS fields

Mission Control and workspace gestures are Dock/WindowServer gestures rather than
ordinary AppKit swipes. UniSpace reads the raw fields used by Apple's open-source
WebKit event serializer and established Dock-swipe implementations:

| Field | Meaning |
| ---: | --- |
| `110` | HID gesture subtype |
| `113` | Zoom value |
| `114` | Rotation value |
| `123` | Dock-swipe axis: horizontal `1`, vertical `2`, pinch `3` |
| `124` | Accumulated swipe/pinch progress |
| `129`, `130` | Exit velocity X/Y fallback |
| `132` | Phase: began `1`, changed `2`, ended `4`, cancelled `8`, may-begin `128` |
| `134` | Navigation swipe direction mask |

These fields are private macOS implementation details. They are covered by synthetic
raw-event tests and currently target macOS 14 through macOS 26. A future macOS release
that changes the Dock gesture representation requires a version-specific adapter; it
must not fall back to an unsuppressible global AppKit monitor.

References:

- [Apple: Handling Trackpad Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)
- [Apple WebKit raw event serializer fields](https://www.mail-archive.com/webkit-changes@lists.webkit.org/msg113473.html)
- [Dock-swipe gesture field and direction reference](https://github.com/oomol-lab/dockswipe/blob/main/dockswipe.m)

## Acceptance checks

Before release:

1. Run `./Scripts/test.sh --full` and keep all coverage floors enabled.
2. Run `./Scripts/test.sh --input-smoke` with Input Monitoring and Post Events granted.
3. Run Macifier's Free and Paid `Macifier.UniSpace.Tests` suites on Windows.
4. Physically verify host suppression plus replay on a Mac peer.
5. Physically verify three/four-finger up, down, left, and right plus pinch/spread on Windows.
6. Verify disconnect, emergency return, and `releaseAll` leave no held modifier or key.
