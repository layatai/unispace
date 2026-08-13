import AppKit
import CoreGraphics
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
                id: DisplayID(rawValue: uuid),
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
}
