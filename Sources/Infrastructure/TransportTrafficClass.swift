import Darwin

/// Voice-class traffic marking for realtime input sockets.
///
/// TwinDesk protocol.md §Priority: WMM classifies DSCP EF (0xB8) packets as
/// voice, so APs queue pointer input ahead of bulk file/video traffic.
/// Windows/Linux mirrors are tracked in macifier issue #39.
enum TransportTrafficClass {
    /// Best-effort DSCP EF (Expedited Forwarding) marking. Purely a local
    /// socket option with no wire significance to older peers — legacy
    /// receivers are unaffected when the option is unsupported or fails.
    static func markVoiceClass(_ fileDescriptor: Int32) {
        var tos: Int32 = 0xB8
        _ = setsockopt(
            fileDescriptor,
            IPPROTO_IP,
            IP_TOS,
            &tos,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
}
