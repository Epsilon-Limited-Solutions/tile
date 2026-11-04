import CoreGraphics
import Foundation
@testable import TileCore

/// This machine's real displays (from tile://debug/spaces, 2026-11-03), plus
/// hypothetical ones above and below the laptop. NSScreen coordinates.
enum Fixtures {
    static func display(_ id: CGDirectDisplayID, _ name: String, frame: CGRect, visible: CGRect? = nil,
                        builtin: Bool = false, primary: Bool = false, rotation: Double = 0,
                        serial: UInt32 = 0) -> DisplayInfo {
        DisplayInfo(id: id, uuid: nil, name: name, isBuiltin: builtin, isPrimary: primary, rotation: rotation,
                    vendor: 0, model: 0, serial: serial, frame: frame, visibleFrame: visible ?? frame)
    }

    /// Primary. Menu bar 33pt at the top, Dock 81pt at the bottom.
    static let laptop = display(1, "Built-in Retina Display",
                                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                visible: CGRect(x: 0, y: 81, width: 1512, height: 868),
                                builtin: true, primary: true, serial: 4251086178)
    /// Portrait, left of the laptop, taller than it, negative origin.
    static let verticalLeft = display(2, "DELL S2722QC (1)",
                                      frame: CGRect(x: -1440, y: -279, width: 1440, height: 2560),
                                      visible: CGRect(x: -1440, y: -279, width: 1440, height: 2530),
                                      rotation: 270, serial: 810894658)
    /// Portrait, right of the laptop.
    static let verticalRight = display(3, "DELL S2722QC (2)",
                                       frame: CGRect(x: 1512, y: -205, width: 1440, height: 2560),
                                       visible: CGRect(x: 1512, y: -205, width: 1440, height: 2530),
                                       rotation: 90, serial: 825446978)
    static let above = display(4, "LG UltraFine", frame: CGRect(x: 0, y: 982, width: 1920, height: 1080))
    static let below = display(5, "LG UltraFine", frame: CGRect(x: -200, y: -1080, width: 1920, height: 1080))

    static let desk = [laptop, verticalLeft, verticalRight]

    static func config(_ json: String) throws -> Config {
        try Config.parse(Data(json.utf8))
    }

    /// The issues a config is rejected with, as "path: message" strings.
    static func issues(_ json: String) -> [String] {
        do {
            _ = try config(json)
            return []
        } catch let error as ConfigError {
            return error.issues.map(\.description)
        } catch {
            return ["unexpected error: \(error)"]
        }
    }
}
