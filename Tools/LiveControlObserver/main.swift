import Foundation
import CoreGraphics

// Passive OS observation only: this tool never posts or warps an input event.
let duration = Double(CommandLine.arguments.dropFirst().first ?? "90") ?? 90
let started = DispatchTime.now().uptimeNanoseconds
var samples = 0
while Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 < duration {
    if let point = CGEvent(source: nil)?.location {
        let value: [String: Any] = ["kind": "cursor", "monotonicNanos": DispatchTime.now().uptimeNanoseconds,
                                  "x": point.x, "y": point.y]
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
        samples += 1
    }
    Thread.sleep(forTimeInterval: 0.02)
}
if samples == 0 { exit(2) }
