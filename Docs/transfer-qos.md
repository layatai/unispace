# File-transfer responsiveness

UniSpace keeps file data on its independent authenticated content connection, but the file and input connections still share CPU, storage, Wi-Fi, and kernel queues. The transfer QoS layer therefore treats bulk files as elastic background work and protects remote-control latency at the application layer.

## Runtime modes

| Mode | Trigger | Chunk size | Maximum unacknowledged data | Rate |
| --- | --- | ---: | ---: | ---: |
| Throughput | No live remote-control session | 256 KiB | 8 MiB | Uncapped by UniSpace |
| Interactive | Remote control is active | 64 KiB | 512 KiB | 8 MiB/s |
| Degraded | Active peer latency is at least 30 ms | 64 KiB | 256 KiB | 2 MiB/s |

The secure file protocol remains version 1. Existing acknowledgements provide receiver-driven credit, so no wire-format change is required and macOS/Windows compatibility is preserved.

## Storage behavior

Incoming files use a persistent write handle. Writes advance an in-memory contiguous offset, while crash-safe resume uses a separate durable offset. UniSpace synchronizes and atomically persists the durable offset after 8 MiB and at least 250 ms, after one second at the latest, and whenever an entry is finalized or the app suspends its transfer resources.

If the process stops unexpectedly, recovery truncates bytes after the last durable offset. The sender then retransmits that bounded tail. Partial files are never exposed to Finder.

Outgoing files use a persistent sequential read handle. File size and modification time are revalidated every 16 MiB, every second, and at end of file. Handles and security-scoped access are released on suspension, cancellation, completion, removal, or workspace shutdown.

## UI backpressure

State transitions, failures, cancellation, and completion are delivered immediately. Replaceable byte-progress snapshots are coalesced to at most 10 updates per second before reaching the main actor.

## Diagnostics and tuning

`QoSFileTransferTransport`, `CheckpointingTransferStore`, and `StreamingPersistentFileSourceProvider` expose non-sensitive diagnostics for tests and benchmarks. Diagnostics include policy mode, outstanding bytes, handle counts, checkpoint counts, and validation counts; they never include filenames, paths, hashes, clipboard content, or file content.

Tune the defaults only with the transfer-plus-pointer benchmark matrix. A throughput increase must not regress pointer p95 latency, create stalls above 50 ms, or cause heartbeat loss.
