import AppKit
import CryptoKit
import Foundation
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

@MainActor
final class SimulationPasteboardBox: Sendable {
    private let pasteboard: NSPasteboard

    init(name: String) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
    }

    func makeClipboardService() -> SystemClipboardService {
        SystemClipboardService(pasteboard: pasteboard, pollingInterval: .milliseconds(10))
    }

    func makeFilePasteboard() -> SystemFilePasteboard {
        SystemFilePasteboard(pasteboard: pasteboard, pollingInterval: .milliseconds(10))
    }

    func writeClipboard(_ value: String) {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func readClipboard() -> String? {
        pasteboard.string(forType: .string)
    }

    func writeFiles(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    func readFiles() -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
    }

    func release() {
        pasteboard.releaseGlobally()
    }
}

final class SimulationLineEmitter: @unchecked Sendable {
    private let lock = NSLock()

    func send(_ message: SimulationMessage) {
        guard let data = try? SimulationJSON.encoder.encode(message) else { return }
        lock.withLock {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }
}

final class SimulationInputCapture: InputCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = false

    var isSuppressionEnabled: Bool { lock.withLock { suppressed } }
    func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {}
    func stop() {}
    func setSuppressionEnabled(_ enabled: Bool) { lock.withLock { suppressed = enabled } }
}

final class SimulationMetricsRecorder: @unchecked Sendable {
    private struct Bucket {
        var wire: [UInt64] = []
        var wireSources: [UInt64] = []
        var wireArrivals: [UInt64] = []
        var visible: [UInt64] = []
        var visibleSources: [UInt64] = []
        var visibleArrivals: [UInt64] = []
        var keyboardWire: [UInt64] = []
        var realtimePointerFrames = 0
        var reliablePointerFrames = 0
    }

    private let lock = NSLock()
    private var condition = "idle"
    private var buckets: [String: Bucket] = [:]

    func begin(_ condition: String) {
        lock.withLock {
            self.condition = condition
            buckets[condition] = Bucket()
        }
    }

    func recordWire(timestampNanos: UInt64, isPointer: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= timestampNanos else { return }
        lock.withLock {
            var bucket = buckets[condition, default: Bucket()]
            if isPointer {
                bucket.wire.append(now - timestampNanos)
                bucket.wireSources.append(timestampNanos)
                bucket.wireArrivals.append(now)
            } else {
                bucket.keyboardWire.append(now - timestampNanos)
            }
            buckets[condition] = bucket
        }
    }

    /// Counts which lane delivered a pointer frame (realtime vs reliable).
    func recordPointerLane(realtime: Bool) {
        lock.withLock {
            var bucket = buckets[condition, default: Bucket()]
            if realtime { bucket.realtimePointerFrames += 1 } else { bucket.reliablePointerFrames += 1 }
            buckets[condition] = bucket
        }
    }

    func laneCounts(_ condition: String) -> (realtime: Int, reliable: Int) {
        lock.withLock {
            let bucket = buckets[condition, default: Bucket()]
            return (bucket.realtimePointerFrames, bucket.reliablePointerFrames)
        }
    }

    func recordVisible(_ event: InputEvent) {
        guard case let .pointerMove(_, _, _, absoluteY) = event,
              absoluteY.isFinite,
              absoluteY > 0 else { return }
        let capturedAt = UInt64(absoluteY.rounded())
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= capturedAt else { return }
        lock.withLock {
            var bucket = buckets[condition, default: Bucket()]
            bucket.visible.append(now - capturedAt)
            bucket.visibleSources.append(capturedAt)
            bucket.visibleArrivals.append(now)
            buckets[condition] = bucket
        }
    }

    func report(_ condition: String) -> (wire: LatencySummary, visible: LatencySummary) {
        lock.withLock {
            let bucket = buckets[condition, default: Bucket()]
            return (
                latencySummary(
                    samplesNanoseconds: bucket.wire,
                    sourceNanoseconds: bucket.wireSources,
                    arrivalsNanoseconds: bucket.wireArrivals
                ),
                latencySummary(
                    samplesNanoseconds: bucket.visible,
                    sourceNanoseconds: bucket.visibleSources,
                    arrivalsNanoseconds: bucket.visibleArrivals
                )
            )
        }
    }

    func keyboardReport(_ condition: String) -> LatencySummary {
        lock.withLock {
            let samples = buckets[condition, default: Bucket()].keyboardWire
            return latencySummary(samplesNanoseconds: samples, arrivalsNanoseconds: [])
        }
    }
}

final class SimulationInputInjector: InputInjector, @unchecked Sendable {
    private let recorder: SimulationMetricsRecorder

    init(recorder: SimulationMetricsRecorder) {
        self.recorder = recorder
    }

    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {}

    func inject(_ event: InputEvent) {
        recorder.recordVisible(event)
    }

    func releaseAll() {}
}

enum SimulationFiles {
    static func digest(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func writeDeterministicFile(at url: URL, byteCount: Int) throws {
        let handleData = Data((0..<64 * 1_024).map { UInt8(truncatingIfNeeded: $0) })
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var remaining = byteCount
        while remaining > 0 {
            let count = min(remaining, handleData.count)
            try handle.write(contentsOf: handleData.prefix(count))
            remaining -= count
        }
    }
}

/// Timestamps clipboard stages so a slow round trip can be attributed to the
/// source poll, the network hop, or the destination pasteboard write.
final class TimedClipboardService: ClipboardService, @unchecked Sendable {
    private let base: ClipboardService
    private let lock = NSLock()
    // Lock-guarded so the node can read timings off the main actor.
    nonisolated(unsafe) private var lastObservedNanos: UInt64?
    nonisolated(unsafe) private var lastApplyStartNanos: UInt64?
    nonisolated(unsafe) private var lastApplyEndNanos: UInt64?

    nonisolated init(base: ClipboardService) { self.base = base }

    func events() -> AsyncStream<ClipboardObservation> {
        let upstream = base.events()
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                for await observation in upstream {
                    self?.lock.withLock { self?.lastObservedNanos = DispatchTime.now().uptimeNanoseconds }
                    continuation.yield(observation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() { base.stop() }

    func apply(_ payload: ClipboardPayload) {
        let start = DispatchTime.now().uptimeNanoseconds
        base.apply(payload)
        let end = DispatchTime.now().uptimeNanoseconds
        lock.withLock { lastApplyStartNanos = start; lastApplyEndNanos = end }
    }

    nonisolated func timing() -> [String: String] {
        lock.withLock {
            [
                "observedNanos": lastObservedNanos.map(String.init) ?? "",
                "applyStartNanos": lastApplyStartNanos.map(String.init) ?? "",
                "applyEndNanos": lastApplyEndNanos.map(String.init) ?? "",
            ]
        }
    }
}
