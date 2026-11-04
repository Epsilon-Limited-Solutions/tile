import AppKit
import ColorSync
import TileCore

extension DisplayInfo {
    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let id = CGDirectDisplayID(number.uint32Value)
        self.init(id: id,
                  uuid: CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String },
                  name: screen.localizedName,
                  isBuiltin: CGDisplayIsBuiltin(id) != 0,
                  isPrimary: screen == NSScreen.screens.first,
                  rotation: CGDisplayRotation(id),
                  vendor: CGDisplayVendorNumber(id),
                  model: CGDisplayModelNumber(id),
                  serial: CGDisplaySerialNumber(id),
                  frame: screen.frame,
                  visibleFrame: screen.visibleFrame)
    }

    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap(DisplayInfo.init(screen:))
    }
}
