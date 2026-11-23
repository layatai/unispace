import OSLog
import UniSpaceDomain

/// Unified-logging identity for clipboard routing diagnostics. Messages carry
/// device-ID prefixes, routing decisions, and byte counts, never clipboard
/// contents. Stream with:
/// `log stream --level info --predicate 'subsystem == "com.layatai.unispace" AND category BEGINSWITH "clipboard"'`
public enum ClipboardDiagnostics {
    public static let subsystem = "com.layatai.unispace"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Short, non-secret device label for logs.
    public static func label(_ deviceID: DeviceID?) -> String {
        deviceID.map { String($0.rawValue.uuidString.prefix(8)).lowercased() } ?? "none"
    }
}
