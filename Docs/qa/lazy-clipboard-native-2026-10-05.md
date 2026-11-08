# Lazy clipboard native QA — 2026-10-05

The native mechanism is verified on real desktops. These are adapter feasibility
and acceptance checks using disposable local fixtures, not proof of cross-host
UniSpace streaming or a shipped release.

| Desktop | Native mechanism | Quiet metadata phase | Native paste result |
| --- | --- | --- | --- |
| taimb2, macOS 26 | Replicated File Provider, downloadLazily, security-scoped URLs | Provider diagnostics showed dataless 65,536-byte items and zero background downloads before paste | Finder Edit > Paste materialized one file; subsequent two-file clipboard paste produced both files with matching SHA-256 |
| MSI, Windows, khanh session 6 | OLE FileGroupDescriptorW / FileContents / IStream | Zero read calls and zero content bytes after publication and opening Explorer destination; 97 seconds elapsed before paste | Explorer's native folder Paste verb produced empty, Unicode, and 2 MiB binary fixtures; all sizes and SHA-256 hashes match |
| dellom, Hyprland 0.56.2 | Read-only fuser 0.17 mount plus x-special/gnome-copied-files | 92 metadata calls, zero opens, zero content reads before paste | Actual Nautilus Ctrl+V produced three matching files; nine read callbacks, 2,097,172 content bytes |

## Findings applied to implementation

- File Provider registration requires the document group and enumeration keys at
  the extension level. The provider must also be enabled by the user. Only the
  disposable UniSpace Lazy QA provider was enabled, with explicit approval.
- Activate the security scope of getUserVisibleURL results while publishing.
  Use AppKit's NSURL pasteboard writers to publish all URLs; raw clipboard item
  strings lost file URL types even though writeObjects returned success.
- Current Nautilus's GNOME copied-files format rejects empty lines, including a
  trailing newline. Emit `copy` followed by newline-separated URIs, without a
  final newline. Source: GNOME/nautilus `src/nautilus-clipboard.c`.
- Desktop access must be checked live. Windows initially denied clipboard access
  to our scheduled session, but direct retry later succeeded without the user
  launching the harness. Linux's locked desktop rejected clipboard reads and
  focus operations; the check succeeded after the desktop became unlocked.

## Artifact and evidence locations

- macOS installed QA provider: `/Applications/UniSpaceLazyQA.app`, signed and
  notarized; accepted submission `2aa599c8-99b7-495d-bd2a-88ae38318f4b`.
  Revised host publication logic was tested as a signed development build inside
  `.build/lazy-native-probe/DerivedData/Build/Products/Release`, using the enabled
  provider. That revised host has not been installed as a notarized release.
- Finder disposable destination: `.build/lazy-native-probe/paste-destination-two`.
  Each file is 65,536 `a` bytes; SHA-256:
  `bf718b6f653bebc184e1479f1935b8da974d701b893afcf49e701f3e2f9f9c5a`.
- Windows harness: `tools/lazy-clipboard-qa` in the isolated Macifier checkout;
  remote evidence under `artifacts/lazy-native-qa/session-1`.
  Windows counter snapshot is copied to `.build/lazy-windows-qa/native-state-evidence.json`.
- Linux harness: `Tools/LinuxLazyClipboardNativeProbe`;
  remote `/home/tai/projects/unispace-lazy-native-qa/run-1`;
  verified hashes copied to `.build/lazy-linux-qa/verified.json`.
- Swift core/local-file focused suite: `.build/lazy-native-probe/core-tests.log`.
- Macifier portable protocol suite: `.build/lazy-windows-qa/portable-tests.log`,
  30 passing on both this Mac and native MSI, zero failing, zero skipped. Two existing CS4014 warnings remain.

## Remaining acceptance gates

Native adapters passing does not close the feature. Complete Windows/Linux
runtime integration, cross-language golden vectors, real cross-host copy/paste,
large-file cancellation/replacement/disconnect checks, transfer history and
persisted intent migration, and strict existing regression/coverage gates before
shipping the application changes.

## Regression verification

Seven coordinator tests exercise the actual outer frame codec between two
coordinators: metadata-only announcement, demand download and SHA verification,
withdrawal, reconnect, unsupported peers, corrupted ranges, and stale selection
generations. Source tests also verify idempotent concurrent opens and idle lease
expiry. The existing unit/coverage/control-simulation gate passed without
changing any thresholds. Full cross-host release acceptance remains open.

Final gates: domain coverage 98.53% (minimum 95%), application 95.44%
(minimum 95%), infrastructure 77.01% (minimum 77%). Optimized release probes
passed mixed batches, delayed acknowledgements, cancellation, disconnect, and
reset. Feature evidence verifier tests: 11 passed; live-control verifier tests:
8 passed. The unsigned native-input smoke test retains its existing skip.

Cleanup: the Mac QA host closed through AppKit's termination path; the Windows
harness restored its original OLE clipboard and its temporary QA tasks were
removed. Production MSI Macifier remained PID 24032, session 6, at its original
installed path. Linux cleared only the exact still-owned QA URI payload and
stopped only the disposable QA FUSE unit. Generated fixture destinations and
verification evidence are retained for review. The explicitly enabled Mac QA
provider remains available for subsequent acceptance checks.
