# UniSpace file transfer

UniSpace can transfer regular files between trusted Macs without sending file contents through the latency-critical keyboard and pointer connection.

## Finder copy and paste

1. Pair the Macs in the same UniSpace workspace.
2. Make one Mac the active controller, or choose a destination in **File Transfers**.
3. Copy one or more regular files in Finder.
4. UniSpace offers the selection to the active compatible Mac over the encrypted content channel.
5. The receiver streams the files into its application sandbox, verifies every SHA-256 digest, and only then places receiver-local file URLs on the pasteboard.
6. Paste in Finder on the receiving Mac to copy the verified staged files to the chosen destination.

The original source paths are never sent to the other Mac. Directories, packages, symbolic links, sockets, devices, and other special file types are intentionally rejected in this release.

## Transfer Center

Open **File Transfers** from the app menu, menu-bar item, or with **Command-Shift-T**. The Transfer Center shows active, paused, verifying, completed, cancelled, and failed work. It supports cancellation, retry after an interruption, reveal, explicit export, and clearing completed entries.

## Security model

- File content uses a separate TCP connection advertised as `_unispace-content._tcp` on port `61340`.
- The content connection authenticates the workspace and peer with an HMAC proof derived from the workspace key.
- Each connection derives an independent ChaCha20-Poly1305 session key with HKDF and enforces a monotonically increasing replay sequence.
- Incoming manifests, filenames, file counts, sizes, chunk lengths, and offsets are treated as untrusted.
- Absolute paths, traversal components, duplicate destination names, invalid digests, unsafe file types, out-of-range chunks, and oversized transfers are rejected before materialization.
- Files remain in the app sandbox until explicitly pasted, revealed, or exported.
- Partial files are never exposed as complete files, and completed files are published only after SHA-256 verification.
- Clipboard contents and file contents are not logged.

## Streaming, cancellation, and recovery

The default chunk size is 256 KiB and the maximum accepted chunk is 1 MiB. The sender reads one bounded chunk at a time and the receiver persists cumulative durable offsets. A transient content-channel disconnect pauses the transfer without ending keyboard or pointer control. After reconnection, the receiver reports verified offsets and the sender resumes from those offsets.

Incoming partial-transfer metadata is stored atomically in Application Support and recovered after relaunch. Stale partial transfers and completed staged files are removed according to bounded retention periods. Cancelling a transfer removes its partial staging data.

## Compatibility and limits

Older UniSpace releases continue to support keyboard and pointer control but do not advertise the content service. The Transfer Center reports an unavailable destination instead of attempting plaintext or control-channel fallback.

Default limits are centralized in `FileTransferLimits`, including:

- 1,000 files per manifest;
- 255 UTF-8 bytes per filename;
- 1 MiB maximum chunk size;
- 1 TiB maximum transfer size;
- seven-day retention for incomplete transfers;
- one-day retention for completed staged files.

These limits are defensive protocol bounds, not recommendations for routine transfer size.
