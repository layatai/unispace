import Foundation

enum ConnectionRetrySchedule {
    private static let initialDelays: [TimeInterval] = [1, 2, 4, 8, 15]

    static func baseDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return initialDelays[0] }
        return attempt < initialDelays.count ? initialDelays[attempt] : 60
    }

    static func delay(forAttempt attempt: Int, jitter: Double = .random(in: 0.85...1.15)) -> TimeInterval {
        baseDelay(forAttempt: attempt) * min(max(jitter, 0.85), 1.15)
    }
}
