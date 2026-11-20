import Foundation

struct SimulationPorts: Codable, Sendable {
    let control: UInt16
    let realtime: UInt16
    /// Authenticated UDP pointer lane; it must not share the realtime port.
    let pointer: UInt16
    let files: UInt16
    let clipboard: UInt16
}

struct SimulationNodeConfiguration: Codable, Sendable {
    let name: String
    let deviceID: UUID
    let displayID: UUID
    let peerName: String
    let peerDeviceID: UUID
    let peerDisplayID: UUID
    let workspaceID: UUID
    let workspaceKeyBase64: String
    let stateDirectory: String
    let pasteboardName: String
    let ports: SimulationPorts
    let peerPorts: SimulationPorts
    let ownsControlConnection: Bool
}

struct SimulationCommand: Codable, Sendable {
    let id: UUID
    let name: String
    var values: [String: String] = [:]
}

struct SimulationMessage: Codable, Sendable {
    let kind: String
    let id: UUID?
    let name: String
    let ok: Bool?
    let timestampNanos: UInt64
    let values: [String: String]

    static func response(
        to command: SimulationCommand,
        ok: Bool,
        values: [String: String] = [:]
    ) -> Self {
        Self(
            kind: "response",
            id: command.id,
            name: command.name,
            ok: ok,
            timestampNanos: DispatchTime.now().uptimeNanoseconds,
            values: values
        )
    }

    static func event(_ name: String, values: [String: String] = [:]) -> Self {
        Self(
            kind: "event",
            id: nil,
            name: name,
            ok: nil,
            timestampNanos: DispatchTime.now().uptimeNanoseconds,
            values: values
        )
    }
}

struct LatencySummary: Codable, Sendable, Equatable {
    let count: Int
    let meanMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
    let maximumGapMilliseconds: Double

    static let empty = Self(
        count: 0,
        meanMilliseconds: 0,
        p50Milliseconds: 0,
        p95Milliseconds: 0,
        p99Milliseconds: 0,
        maximumMilliseconds: 0,
        maximumGapMilliseconds: 0
    )
}

struct ConditionReport: Codable, Sendable {
    let name: String
    let wire: LatencySummary
    let visible: LatencySummary
    let passed: Bool
    let failures: [String]
    var realtimeShare: Double? = nil
}

struct SimulationStepReport: Codable, Sendable {
    let name: String
    let durationMilliseconds: Double
}

struct SimulationReport: Codable, Sendable {
    let passed: Bool
    let samplesPerCondition: Int
    let conditions: [ConditionReport]
    let steps: [SimulationStepReport]
    let failures: [String]
    let nodePIDs: [Int32]
    let artifactDirectory: String?
    var inputQueue: [String: UInt64]? = nil
    var thresholdProfile: String? = nil
}

struct SimulationThresholds: Sendable {
    let idleP95Milliseconds: Double
    let keyboardP95Milliseconds: Double
    let maximumLatencyMilliseconds: Double
    let loadedP95Factor: Double
    let loadedP95DeltaMilliseconds: Double
    let activationMilliseconds: Double
    let clipboardMilliseconds: Double
    let reconnectMilliseconds: Double
    /// Share of pointer frames that must arrive on the realtime lane. Timing
    /// independent, so it catches a missing fast lane on any runner.
    let minimumRealtimeShare: Double
    let name: String

    /// Local and pre-release runs on developer Macs.
    static let strict = Self(
        idleP95Milliseconds: 35,
        keyboardP95Milliseconds: 25,
        maximumLatencyMilliseconds: 50,
        loadedP95Factor: 1.5,
        loadedP95DeltaMilliseconds: 5,
        activationMilliseconds: 250,
        clipboardMilliseconds: 100,
        reconnectMilliseconds: 5_000,
        minimumRealtimeShare: 0.9,
        name: "strict"
    )

    /// Shared GitHub-hosted macOS runners, whose scheduler stalls starve the
    /// simulator's main threads for 60-80 ms regardless of the code under test.
    /// Wider timing budgets; the realtime-lane share stays as strict.
    static let hosted = Self(
        idleP95Milliseconds: 60,
        keyboardP95Milliseconds: 50,
        maximumLatencyMilliseconds: 150,
        loadedP95Factor: 1.5,
        loadedP95DeltaMilliseconds: 15,
        activationMilliseconds: 500,
        clipboardMilliseconds: 300,
        reconnectMilliseconds: 10_000,
        minimumRealtimeShare: 0.9,
        name: "hosted"
    )

    /// `UNISPACE_SIM_PROFILE=hosted` selects the hosted-runner budgets.
    static var current: Self {
        ProcessInfo.processInfo.environment["UNISPACE_SIM_PROFILE"] == "hosted" ? .hosted : .strict
    }
}

struct SimulationFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum SimulationJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()
}

func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = max(0, min(Double(sorted.count - 1), percentile * Double(sorted.count - 1)))
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    guard lower != upper else { return sorted[lower] }
    let fraction = rank - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
}

func latencySummary(
    samplesNanoseconds: [UInt64],
    sourceNanoseconds: [UInt64] = [],
    arrivalsNanoseconds: [UInt64]
) -> LatencySummary {
    guard !samplesNanoseconds.isEmpty else { return .empty }
    let milliseconds = samplesNanoseconds.map { Double($0) / 1_000_000 }
    let arrivalGaps = zip(arrivalsNanoseconds, arrivalsNanoseconds.dropFirst()).compactMap { first, second in
        second >= first ? second - first : nil
    }
    let sourceGaps = zip(sourceNanoseconds, sourceNanoseconds.dropFirst()).compactMap { first, second in
        second >= first ? second - first : nil
    }
    let gaps = zip(arrivalGaps, sourceGaps).map { arrival, source in
        Double(arrival > source ? arrival - source : 0) / 1_000_000
    }
    return LatencySummary(
        count: milliseconds.count,
        meanMilliseconds: milliseconds.reduce(0, +) / Double(milliseconds.count),
        p50Milliseconds: percentile(milliseconds, 0.50),
        p95Milliseconds: percentile(milliseconds, 0.95),
        p99Milliseconds: percentile(milliseconds, 0.99),
        maximumMilliseconds: milliseconds.max() ?? 0,
        maximumGapMilliseconds: gaps.max() ?? 0
    )
}
