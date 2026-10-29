import AppKit
import ColorSync

/// What Tile knows about one connected display.
struct DisplayInfo {
    let id: CGDirectDisplayID
    /// Matches "Display Identifier" in SkyLight's managed display spaces.
    let uuid: String?
    let name: String
    let isBuiltin: Bool
    let isPrimary: Bool
    let rotation: Double
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// NSScreen coordinates (bottom-left origin).
    let frame: CGRect
    let visibleFrame: CGRect

    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let id = CGDirectDisplayID(number.uint32Value)
        self.id = id
        uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
            CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        }
        name = screen.localizedName
        isBuiltin = CGDisplayIsBuiltin(id) != 0
        isPrimary = screen == NSScreen.screens.first
        rotation = CGDisplayRotation(id)
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
        frame = screen.frame
        visibleFrame = screen.visibleFrame
    }

    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap(DisplayInfo.init(screen:))
    }
}
