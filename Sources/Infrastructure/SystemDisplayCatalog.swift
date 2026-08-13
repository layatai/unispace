import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import UniSpaceApplication
import UniSpaceDomain

public struct SystemDisplayCatalog: DisplayCatalog {
    public init() {}

    public func currentDisplays(for deviceID: DeviceID) -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID).takeRetainedValue()
            guard let uuid = UUID(uuidString: CFUUIDCreateString(nil, displayUUID) as String) else { return nil }
            let frame = screen.frame
            return DisplayDescriptor(
                id: Self.stableIdentifier(deviceID: deviceID, displayUUID: uuid),
                deviceID: deviceID,
                name: screen.localizedName,
                frame: DisplayRect(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.size.width,
                    height: frame.size.height
                ),
                scaleFactor: screen.backingScaleFactor,
                isMain: screen == NSScreen.main
            )
        }
    }

    /// Core Graphics UUIDs identify a physical display on one Mac, but the
    /// same value may occur on another Mac. Include UniSpace's persistent Mac
    /// ID so display identity is stable and unique throughout a workspace.
    static func stableIdentifier(deviceID: DeviceID, displayUUID: UUID) -> DisplayID {
        let input = Data("\(deviceID.rawValue.uuidString):\(displayUUID.uuidString)".utf8)
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // RFC 9562 UUID version 8 (custom)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return DisplayID(rawValue: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}
