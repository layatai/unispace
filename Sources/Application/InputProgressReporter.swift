import Foundation
import UniSpaceDomain

/// Coalesces application acknowledgments independently of UI and input injection.
final class InputProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let transport: PeerTransport
    private let clock: MonotonicClock
    private let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var pointer: (DeviceID, RealtimePointerProgress)?
    private var input: (DeviceID, InputDeliveryProgress)?
    private var heartbeat: (DeviceID, ControlEnvelope)?
    private var worker: Task<Void, Never>?

    init(transport: PeerTransport, clock: MonotonicClock) {
        self.transport = transport
        self.clock = clock
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = pair.stream
        continuation = pair.continuation
    }

    func start() {
        lock.withLock {
            guard worker == nil else { return }
            let signals = signals
            worker = Task { [weak self] in
                for await _ in signals {
                    guard !Task.isCancelled, let self else { return }
                    await self.flush()
                    do { try await self.clock.sleep(for: .milliseconds(16)) }
                    catch { return }
                }
            }
        }
    }

    func record(_ progress: RealtimePointerProgress, from source: DeviceID) {
        lock.withLock { pointer = (source, progress) }
        continuation.yield(())
    }

    func record(_ progress: InputDeliveryProgress, from source: DeviceID) {
        lock.withLock { input = (source, progress) }
        continuation.yield(())
    }

    func recordHeartbeat(_ envelope: ControlEnvelope, from source: DeviceID) {
        lock.withLock { heartbeat = (source, envelope) }
        continuation.yield(())
    }

    func reset() {
        lock.withLock { pointer = nil; input = nil; heartbeat = nil }
    }

    func stop() {
        lock.withLock { worker?.cancel(); worker = nil; pointer = nil; input = nil; heartbeat = nil }
        continuation.finish()
    }

    private func flush() async {
        let values = lock.withLock {
            let values = (pointer, input, heartbeat)
            pointer = nil
            input = nil
            heartbeat = nil
            return values
        }
        if let (peer, progress) = values.0 {
            try? await transport.send(ControlEnvelope(message: .realtimePointerProgress(progress)), to: peer)
        }
        if let (peer, progress) = values.1 {
            try? await transport.send(ControlEnvelope(message: .inputProgress(progress)), to: peer)
        }
        if let (peer, envelope) = values.2 {
            try? await transport.send(envelope, to: peer)
        }
    }
}
