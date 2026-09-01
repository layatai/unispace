import Darwin
import Foundation

@main
enum UniSpaceSimulationMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let mode = arguments.first else {
                throw SimulationFailure(usage)
            }
            switch mode {
            case "node":
                guard let path = value(after: "--config", in: arguments) else {
                    throw SimulationFailure("node requires --config\n\(usage)")
                }
                try await runSimulationNode(configurationURL: URL(fileURLWithPath: path))
            case "run-two":
                let samples = Int(value(after: "--samples", in: arguments) ?? "500") ?? 500
                let keepArtifacts = value(after: "--keep-artifacts", in: arguments)
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                let orchestrator = try SimulationOrchestrator(
                    executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
                    samples: samples,
                    keepArtifacts: keepArtifacts
                )
                let report = try orchestrator.runAll()
                var data = try SimulationJSON.encoder.encode(report)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
                if !report.passed { exit(EXIT_FAILURE) }
            case "shell":
                let orchestrator = try SimulationOrchestrator(
                    executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
                    samples: 500,
                    keepArtifacts: value(after: "--keep-artifacts", in: arguments)
                        .map { URL(fileURLWithPath: $0, isDirectory: true) }
                )
                try orchestrator.runShell()
            case "--help", "-h", "help":
                print(usage)
            default:
                throw SimulationFailure("Unknown mode: \(mode)\n\(usage)")
            }
        } catch {
            FileHandle.standardError.write(Data("UniSpaceSimulation: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static let usage = """
    Usage:
      UniSpaceSimulation run-two [--samples 500] [--json] [--keep-artifacts <directory>]
      UniSpaceSimulation shell [--keep-artifacts <directory>]
    """
}
