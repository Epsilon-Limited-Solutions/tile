import AppKit

/// One Space (desktop or fullscreen app) on one display.
struct SpaceInfo {
    let id: SkyLight.SpaceID
    let uuid: String
    /// 0 = user desktop, 4 = fullscreen app.
    let type: Int
    /// 1-based position among every Space on its display, in Mission Control order.
    let position: Int
    /// 1-based position among the user desktops on its display; nil for fullscreen Spaces.
    let desktopIndex: Int?
}

/// The Spaces of one display, in Mission Control order.
struct DisplaySpaces {
    /// Display UUID string (matches `DisplayInfo.uuid`), or "Main" when displays share Spaces.
    let displayIdentifier: String
    let currentSpace: SkyLight.SpaceID
    let spaces: [SpaceInfo]
}

/// A window as the window server sees it. Unlike AX, this covers windows on every Space.
struct ServerWindow {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    /// Nil for other apps' windows unless Tile has Screen Recording permission.
    let title: String?
    /// Global coordinates, top-left origin (same space as AX).
    let bounds: CGRect
    let isOnscreen: Bool
}

enum Spaces {
    static func snapshot() throws -> [DisplaySpaces] {
        try SkyLight.managedDisplaySpaces().map { display in
            let identifier = display["Display Identifier"] as? String ?? "?"
            let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID) ?? 0
            var desktopCount = 0
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).enumerated().map { offset, space in
                let type = (space["type"] as? NSNumber)?.intValue ?? -1
                var desktopIndex: Int?
                if type == 0 {
                    desktopCount += 1
                    desktopIndex = desktopCount
                }
                return SpaceInfo(id: spaceID(space) ?? 0,
                                 uuid: space["uuid"] as? String ?? "",
                                 type: type,
                                 position: offset + 1,
                                 desktopIndex: desktopIndex)
            }
            return DisplaySpaces(displayIdentifier: identifier, currentSpace: current, spaces: spaces)
        }
    }

    private static func spaceID(_ space: [String: Any]) -> SkyLight.SpaceID? {
        ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }

    /// Normal-layer windows at least `minimumSize` points on each side, on every Space.
    static func serverWindows(minimumSize: CGFloat = 50) -> [ServerWindow] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= minimumSize, bounds.height >= minimumSize
            else { return nil }
            return ServerWindow(id: id,
                                pid: pid,
                                ownerName: info[kCGWindowOwnerName as String] as? String ?? "?",
                                title: info[kCGWindowName as String] as? String,
                                bounds: bounds,
                                isOnscreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
    }
}
