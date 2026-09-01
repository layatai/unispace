import Foundation

public final class ControlLatencyActivity {
    private let processInfo: ProcessInfo
    private var token: NSObjectProtocol?

    public private(set) var isActive = false

    public init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    deinit { stop() }

    public func start() {
        guard token == nil else { return }
        token = processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Active UniSpace remote control session"
        )
        isActive = true
    }

    public func stop() {
        guard let token else { return }
        processInfo.endActivity(token)
        self.token = nil
        isActive = false
    }
}
