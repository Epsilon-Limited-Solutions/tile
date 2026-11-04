import CoreGraphics

/// What Tile knows about one connected display. Built from NSScreen in the app target.
public struct DisplayInfo: Equatable, Sendable {
    public let id: CGDirectDisplayID
    /// Matches "Display Identifier" in SkyLight's managed display spaces.
    public let uuid: String?
    public let name: String
    public let isBuiltin: Bool
    public let isPrimary: Bool
    public let rotation: Double
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    /// NSScreen coordinates (bottom-left origin).
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: CGDirectDisplayID, uuid: String?, name: String, isBuiltin: Bool, isPrimary: Bool,
                rotation: Double, vendor: UInt32, model: UInt32, serial: UInt32,
                frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.isBuiltin = isBuiltin
        self.isPrimary = isPrimary
        self.rotation = rotation
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}
