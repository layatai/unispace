# Lazy file clipboard across macOS, Windows, and Linux

Status: implementation plan, 2026-10-05. No new runtime behavior is shipped by
this document. The preliminary announcement-only draft is not enabled: the
native receiver adapters must be proven before replacing working clipboard code.

## Product contract

Copying files publishes a replaceable clipboard selection. It does not hash or
stream their contents, prepare incoming staging, or create a transfer-history row.
The receiving application requests content when the user pastes; UniSpace then
creates a transfer and serves verified data with bounded memory.

Keyboard paste, application-menu paste, and context-menu paste must work through
the native OS integration. Keyboard interception is not the implementation.
Scope includes macOS, Windows/Macifier, and Linux (GNOME/KDE; Wayland/X11).
Regular files and multiple selections are in scope. Directory recursion, cut/move
semantics, symlinks and special files remain separate work; start with copy only.

The existing **Send Files** action remains an explicit user-requested send. Its
behavior must be separately tested from automatic clipboard continuity.

Important API boundary: operating systems expose **content demand**, not a
universal proof that a human clicked Paste. Clipboard format inspection, file
metadata queries, opening menus, and passive background polling must transfer
zero content bytes. Previewers and clipboard managers that actively read file
contents are a separate acceptance case. Do not claim strict paste-only behavior
until each native adapter passes that test; report a platform limitation instead
of silently enabling eager downloads.

## Mechanism and platform adapters

Windows provides the reference architecture: an OLE data object advertises
`FileGroupDescriptorW` metadata and serves indexed `FileContents` through
`TYMED_ISTREAM`. `IStream` avoids loading an entire file into memory. The RDP
clipboard protocol carries separate size and byte-range requests, identified by
file index and stream ID, with 64-bit offsets and explicit huge-file capability.
Its clipboard-data lock pins a selection during an active read.
[Shell formats](https://learn.microsoft.com/en-us/windows/win32/shell/clipboard),
[RDP range requests](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/cbc851d3-4e68-45f4-9292-26872a9209f2),
[RDP clipboard lock](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/150bac72-bc7f-42e5-9e8e-cb5a0ddc7dbc).

| Receiver | Proposed integration | Metadata-only operations | Content trigger |
| --- | --- | --- | --- |
| Windows / Macifier | Native COM `IDataObject` with virtual file descriptors and per-file `IStream` | Format enumeration, `QueryGetData`, descriptors, stream `Stat` | `Read` / `CopyTo`; `Seek` sets position without downloading |
| macOS | File Provider extension exposing system-managed dataless files; clipboard contains their local URLs | Item lookup, enumeration, size/name/type and placeholder URL lookup | `fetchContents`; evaluate partial-content fetching for ranged materialization |
| Linux | Per-user read-only FUSE filesystem; clipboard references virtual paths using desktop-native file-list MIME formats | `lookup`, `getattr`, `readdir`, metadata-only opens | Filesystem `read` callbacks mapped to bounded range requests |

The macOS and Linux designs are proposed adapters, not already-proven paste
integrations. Apple documents dataless items and content fetching, but also
allows system-initiated materialization. The first milestone must validate this
behavior with the actual supported Finder versions and clipboard managers.
[Apple File Provider](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension),
[lazy content policy](https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy/downloadlazily),
[partial fetching](https://developer.apple.com/documentation/fileprovider/nsfileproviderpartialcontentfetching).

A local disposable probe confirmed that plain `NSFilePromiseProvider` objects on
the general clipboard leave Finder's Paste disabled. No write callback ran.
Apple's file-promise documentation describes the drag-and-drop pasteboard as
separate from ordinary copy/paste. File promises alone are therefore not the
Finder implementation. [Apple file promises](https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises).

Linux FUSE provides normal filesystem access through a userspace daemon, including
separate metadata/read callbacks. Validate `/dev/fuse`, user-mount support,
permissions and sandboxed-app access on real GNOME and KDE installations. If the
adapter cannot mount, expose that capability failure; never revert to transfer on
copy. [Kernel FUSE overview](https://docs.kernel.org/filesystems/fuse/fuse.html),
[libfuse operations](https://libfuse.github.io/doxygen/structfuse__operations.html).

## Shared architecture

```text
Source native clipboard watcher
  -> selection registry (metadata + private local references)
  -> encrypted selection announcement
  -> receiver native virtual-file adapter

Receiver application consumes content
  -> pin selection / open read lease
  -> read(file ID, offset, length)
  -> source reader -> encrypted chunks -> bounded cache
  -> native stream/provider/filesystem -> destination application
  -> verify / finish / release lease
```

Keep OS APIs in Infrastructure. Domain owns validated descriptors, identifiers,
versions and protocol values. Application owns selection lifecycle, read leases,
range scheduling, cancellation, retries and transfer snapshots. Native adapters
call a small content-reader interface; they do not implement transport policy.

The Swift, .NET and Rust implementations share one wire specification and golden
vectors, not three independently evolving formats. Reuse the authenticated
content connection and existing control-aware QoS. File reads never run on the
keyboard/pointer queues or block the application UI actor/thread.

### Proposed negotiated messages

Message names below are a design, not assigned wire IDs. Negotiate a new
`file-clipboard-stream-v2` capability before sending any new frame.

| Operation | Essential fields / purpose |
| --- | --- |
| `ClipboardAnnounce` | Session epoch, selection ID, opaque file IDs, names, 64-bit sizes, types and version fingerprints; no source paths or full-file hashes |
| `ClipboardWithdraw` | Selection ID; removes an unconsumed announcement without invalidating active pinned reads |
| `OpenRead` / `ReadOpened` | Selection/file IDs and expected versions; returns a peer-bound lease with limits and expiry |
| `ReadRange` / `RangeData` | Lease ID, request ID, file ID, 64-bit offset and bounded length; response echoes identity and range |
| `FinishRead` | Integrity result and completion accounting |
| `CancelRead` / `CloseRead` | Cancels pending requests and releases handles/cache/lease |
| `ReadError` | Typed unavailable, changed, expired, unsupported, invalid-range, cancelled and I/O errors |

Metadata requests must never call the current full-file `prepare()` path. Split
description/stat from open/read/hash. Open file handles only after content demand.
Reuse the current 256 KiB default chunk and adaptive transfer-credit policy as
initial settings; keep the current defensive maximums and benchmark gates.
Enforce per-request, per-peer and global outstanding-byte/cache limits.

Preserve integrity guarantees: validate source version before/after reads, fail
on mutation instead of mixing versions, authenticate every response and correlate
it to the requested range. Compute/check whole-file SHA-256 after demand begins,
without a full-file hash during copy. Sequential reads can hash incrementally;
seek-heavy reads require an explicit final verification strategy. A transfer is
never marked completed before the required verification succeeds.

### Lifecycle and recovery

- One latest unpinned selection per clipboard origin. A new copy replaces it.
- Active pastes pin their original selection. Copying something else must not
  corrupt a transfer already in progress; future pastes use the new selection.
- Repeated native reads share a bounded cache and source lease. Separate streams
  keep independent cursors; duplicate requests cannot start duplicate transfers.
- EOF, cancellation, peer loss, owner exit and lease expiry have finite outcomes.
  Native callbacks must complete with success or a meaningful error, never hang.
- Reconnection may resume an already requested transfer only while its consumer
  and source version remain valid. It must not turn announcements into transfers.
- Persist actual paste/send intent separately from clipboard announcements.
  Existing records without known intent are held for explicit Retry or Cancel;
  migration must not delete user files or automatically replay the old queue.
- Restrict reads to the announced selection and authenticated destination peer.
  Validate filenames, ranges and arithmetic; source paths remain local.
- Clear only clipboard content still owned by the matching selection generation.
  Do not overwrite a newer local copy when a transfer finishes.

## Implementation sequence and gates

### 1. Prove the native adapters before changing the shipping path

Build disposable local prototypes backed by a generated file, without networking.
Verify keyboard, menu and context-menu Paste on Explorer, Finder, Nautilus and
Dolphin. Instrument metadata calls, content opens and bytes read. Inspect clipboard
formats, open menus and leave a copied selection idle for 60 seconds: all must
show zero file-content reads. Exercise clipboard managers and thumbnailers.

Windows: prove indexed descriptors, `IStream.Read/Seek/Stat/Clone`, owner lifetime,
COM apartment/marshalling and asynchronous extraction. Use
[`IDataObjectAsyncCapability`](https://learn.microsoft.com/en-us/windows/win32/api/shldisp/nn-shldisp-idataobjectasynccapability)
where supported; preserve correct synchronous consumer behavior too.

macOS: prove File Provider registration, signing/entitlements, domain lifecycle,
sandbox access, app-extension communication, dataless URLs and lazy materialization.
The provider domain is a real installation/UX change and must be included in the
review, installer, rollback and uninstall design. Do not substitute ordinary empty
files for placeholders.

Linux: prove FUSE metadata/read behavior and URI-list interoperability on Wayland
and X11, including sandbox/document-portal access. No system-wide mount or access
to other users is required by the design.

Gate: native copy-to-paste semantics and zero-content-before-demand are observed
on each OS. A failing adapter stays unadvertised until the issue is resolved.

### 2. Freeze the protocol and implement the demand-driven core

Create shared fixtures for valid/invalid announcements, version negotiation,
leases, range reads, EOF, cancellation, expired selections and large offsets.
Implement metadata enumeration and leased readers in Swift, C# and Rust. Preserve
existing framing, authentication, replay protection and control isolation.
Add tests proving that copy/metadata inspection/reconnect do not call content
preparation, hashing, reads, staging or transfer-history creation.

### 3. Wire all native adapters to the shared core

Windows first as the reference adapter, followed by macOS File Provider and Linux
FUSE, each behind its verified capability. These are ordered milestones, not a
Windows-only release. Keep native callbacks thin; use cancellable worker I/O and
bounded caches. Revalidate the local prototype cases over the real encrypted
transport. No Ctrl+V/Command+V event-hook fallback.

### 4. Update UX and migrate the queue

Show an available remote clipboard selection separately from Transfers. Display
its source and file count without creating paused work. Create a transfer row
when content is first requested. Show progress, cancellation and actionable
offline/source-changed errors. Keep explicit Send Files, Retry and Cancel distinct.
Persist origin/intent so only real, user-requested transfers are recoverable.

### 5. Run the full interoperability and resilience baseline

Test all nine source/destination combinations: Mac, Windows and Linux as both
source and receiver. Linux receiver coverage includes GNOME/KDE and Wayland/X11.

Required cases:

1. Copy, wait, inspect clipboard formats/metadata, open menus and reconnect: zero
   content bytes, zero full-file hashing, zero transfer rows or staged payloads.
2. Keyboard, menu and context-menu Paste: exact destination bytes and filenames.
3. Empty files, Unicode names, multiple files, duplicate basenames, size limits,
   sparse files over 4 GiB, and range requests beyond the 32-bit boundary.
4. Random reads/seeks, concurrent streams, repeated paste and duplicate requests;
   memory/cache usage remains bounded independently of total file size.
5. New copy before paste invalidates the old unpinned selection; new copy during
   paste preserves that paste's pinned selection and changes the next paste.
6. Cancellation, deleted/modified source, destination collision, full disk,
   permission denial, sleep/wake, peer restart and network interruption.
7. Preview/background readers and third-party clipboard managers: record whether
   they request content and verify the agreed demand policy explicitly.
8. Bulk paste while real cursor/keyboard control is active: existing latency and
   recovery thresholds pass without relaxing tests or coverage.
9. Old/new peer combinations: no new unsupported frames and no eager clipboard
   fallback. Existing explicit v1 sends and unrelated features retain coverage.

Run debug tests, optimized production-artifact tests and native live acceptance.
Cross-compilation, mock streams and healthy sockets cannot pass the native rows.
Update the live verifier to check the quiet pre-paste period, then drive a real
paste and verify the final destination—not merely a staged receiver clipboard.

### 6. Package and ship only verified platform combinations

Update UniSpace, Macifier and Linux packaging together. Include the provider
extension/FUSE prerequisite checks, signed/notarized Mac artifacts and native
Windows/Linux tests. Record source/build IDs, permissions, consumer application,
pre-paste byte counters, requested ranges and final hashes in the acceptance
report. Do not log clipboard contents or private source paths. Retain rollback
artifacts and capability-disable behavior without downgrading to eager copying.

## Repository touchpoints

| Area | Current implementation to refactor / extend |
| --- | --- |
| Swift protocol/core | `Sources/Domain/FileTransferProtocol.swift`, `Sources/Application/FileTransferFrameCodec.swift`, `FileTransferContracts.swift`, `FileTransferCoordinator.swift` |
| macOS clipboard/source/UI | `Sources/Infrastructure/SystemFilePasteboard.swift`, `StreamingPersistentFileSourceProvider.swift`, `Sources/App/FileTransferViewModel.swift`, `TransferCenterView.swift` |
| macOS native adapter | New File Provider extension target, shared broker/service interfaces, entitlements and `project.yml` / release-script integration |
| Windows / Macifier | `Features/UniSpace/Infrastructure/WindowsFilePasteboard.cs`, `StreamingWindowsFileSourceProvider.cs`, `FileTransferWireCodec.cs`, `Application/WindowsFileTransferCoordinator.cs`; new COM virtual-file adapters |
| Linux | Split clipboard polling, eager offers and content serving in `Linux/src/files.rs`; add a native virtual-file adapter and packaging/readiness checks |
| Tests/docs | Finder/clipboard/transfer tests in both repositories, Rust tests and shared wire fixtures; `Scripts/test-feature-baseline.sh`, optimized release probes, live verifiers, `Docs/FileTransfer.md`, `Docs/feature-baseline.md` |

## Completion criteria

The feature is complete when all supported native paste surfaces work across the
OS matrix, passive clipboard activity causes no payload transfer, large-file
memory stays bounded, cancellation/recovery preserve intent, and the installed
artifacts pass the existing feature baseline plus the new demand-based checks.
This plan does not treat a keyboard-only implementation as broad OS support.
