# UniSpace file transfer

UniSpace transfers regular files between trusted macOS, Linux, and Windows devices without sending file contents through the latency-critical keyboard and pointer connection. Linux support is provided by the receiver in this repository; Windows support is provided by the paired Macifier receiver.

## File Explorer and Finder copy/paste

1. Pair the Mac and Linux/Windows PC, or two Macs, in the same UniSpace workspace.
2. Make a device the active control target, or choose it in **File Transfers** on macOS.
3. Copy one or more regular files in Finder or File Explorer.
4. UniSpace offers the selection to the active compatible device over the encrypted content channel.
5. The receiver streams files into application-owned staging, verifies every SHA-256 digest, and only then publishes receiver-local file paths to the operating-system clipboard.
6. Paste in Finder or File Explorer to copy the verified files to the chosen destination.

Source-machine paths are never sent to the receiving device. Directories, packages, symbolic links, reparse points, sockets, devices, and other special file types are intentionally rejected in this release.

## Transfer Center

On macOS, open **File Transfers** from the app menu, menu-bar item, or with **Command-Shift-T**. It shows active, paused, verifying, completed, cancelled, and failed work, with cancellation, retry, reveal, explicit export, and cleanup actions.

On Windows, Macifier runs the same transfer state machine in the UniSpace receiver. File Explorer copy/paste works automatically while the trusted workspace is connected. Received files are staged under the current user's local application data and remain available for normal File Explorer paste operations.

On Linux, the Rust receiver monitors `text/uri-list` selections on GNOME and KDE, stages incoming files under the user's local data directory, verifies their SHA-256 digests, and publishes only finalized files to the Wayland or X11 clipboard.

## Portable protocol

The file-transfer protocol is explicitly portable between Swift, Rust, and .NET:

- fixed big-endian envelope header with protocol version, message kind, workspace UUID, sender UUID, and payload length;
- JSON metadata payloads using the existing Swift UUID wrapper representation;
- binary chunk payloads containing transfer UUID, entry UUID, offset, byte count, and raw bytes;
- 256 KiB default chunks and a 1 MiB maximum accepted chunk;
- cumulative durable acknowledgements and verified-offset resume.

The portable encoding replaces the former Swift binary-property-list boundary so Macifier can decode every message without platform-specific serialization behavior.

## Security model

- Content uses a separate TCP connection advertised as `_unispace-xfer._tcp` on TCP port `61340`. Portable receivers initiate this outbound connection; the same numeric port may also carry UniSpace QUIC over UDP without conflict.
- The content connection authenticates workspace and peer identity using an HMAC proof derived from the workspace key.
- Each connection derives an independent ChaCha20-Poly1305 session key with HKDF and enforces a monotonically increasing replay sequence.
- Incoming manifests, filenames, file counts, sizes, chunk lengths, and offsets are treated as untrusted.
- Absolute paths, traversal components, duplicate destination names, Windows-reserved names, invalid digests, unsafe file types, out-of-range chunks, and oversized transfers are rejected.
- Files remain in application-owned staging until explicitly pasted, revealed, or exported.
- Partial files are never exposed as complete files; completed files are published only after SHA-256 verification.
- Clipboard contents and file contents are not logged.

## Streaming, cancellation, and recovery

The sender reads one bounded chunk at a time and the receiver persists cumulative durable offsets. A transient content-channel disconnect pauses the transfer without ending keyboard or pointer control. After reconnection, the receiver reports verified offsets and the sender resumes from those offsets.

Incoming and outgoing resume metadata is stored atomically and recovered after relaunch. Stale partial transfers and completed staged files are removed according to bounded retention periods. Cancellation removes partial staging data.

## Compatibility and limits

Older UniSpace or Macifier releases keep keyboard and pointer control but do not expose file transfer. A compatible peer advertises `file-transfer-v1`; the content service still authenticates capabilities by successfully completing the dedicated encrypted handshake.

Default defensive limits are centralized in `FileTransferLimits`:

- 1,000 files per manifest;
- 255 UTF-8 bytes per filename;
- 1 MiB maximum chunk size;
- 1 TiB maximum transfer size;
- seven-day retention for incomplete transfers;
- one-day retention for completed staged files.

One bulk transfer per direction and peer is active at a time. Directories, packages, rich drag-and-drop continuation, and automatic external destination folders remain out of scope.
