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

/// A specific desktop on a specific display.
struct DesktopTarget: Equatable {
    let display: String
    let space: SkyLight.SpaceID
    let desktopIndex: Int
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

    /// Display identifier -> the Space it's showing.
    static func currentSpaces() -> [String: SkyLight.SpaceID] {
        let snapshot = (try? snapshot()) ?? []
        return Dictionary(snapshot.map { ($0.displayIdentifier, $0.currentSpace) }, uniquingKeysWith: { a, _ in a })
    }

    /// The display and Space a window is on. Nil for windows on no Space, or on several.
    static func location(ofWindow id: CGWindowID) -> DesktopTarget? {
        guard let spaces = try? SkyLight.spaces(forWindow: id), spaces.count == 1 else { return nil }
        for display in (try? snapshot()) ?? [] {
            if let space = display.spaces.first(where: { $0.id == spaces[0] }) {
                return DesktopTarget(display: display.displayIdentifier, space: space.id, desktopIndex: space.desktopIndex ?? 0)
            }
        }
        return nil
    }

    /// "Switch to Desktop N" numbers user desktops 1...N across displays, in
    /// SkyLight's display order (not left-to-right). Verified by the spike on
    /// macOS 26.2 with 5 + 2 + 3 desktops: built-in, then Vertical-Right, then Vertical-Left.
    static func predictedShortcutNumbers(_ snapshot: [DisplaySpaces]) -> [Int: DesktopTarget] {
        var result: [Int: DesktopTarget] = [:]
        var number = 0
        for display in snapshot {
            for space in display.spaces {
                guard let index = space.desktopIndex else { continue }
                number += 1
                result[number] = DesktopTarget(display: display.displayIdentifier, space: space.id, desktopIndex: index)
            }
        }
        return result
    }

    /// Time for the switch animation to finish after SkyLight reports the new Space.
    static let settleDelay: Duration = .milliseconds(250)

    /// Posts the Desktop N shortcut and waits until `arrived` is true.
    @MainActor
    static func switchDesktop(using shortcut: MacSettings.DesktopShortcut, until arrived: () -> Bool) async -> Bool {
        Events.postKey(shortcut.keyCode, flags: shortcut.flags)
        let ok = await waitUntil(timeout: .seconds(2), arrived)
        if ok { try? await Task.sleep(for: settleDelay) }
        return ok
    }

    /// Grab point relative to a window's top-left: just right of the zoom button, at
    /// its vertical center. On macOS 26 the close button spans (8,8)-(24,24), so a
    /// fixed offset near the corner clicks it; the spike lost two test windows that way.
    @MainActor
    static func grabOffset(for window: AXUIElement, frame: CGRect) -> CGPoint {
        if let zoom = AX.buttonFrame(window, kAXZoomButtonAttribute) {
            return CGPoint(x: zoom.maxX - frame.minX + 12, y: zoom.midY - frame.minY)
        }
        return CGPoint(x: frame.width / 2, y: 12)
    }

    /// Grab and switch: hold the window by its title bar, switch desktops, let go.
    /// The window rides along. The mouse button is always released and the
    /// cursor put back, whatever happens in between.
    /// `whileHeld` runs after the drag starts and before the switch (diagnostics).
    @MainActor
    static func carry(windowFrame frame: CGRect, grabOffset: CGPoint,
                      using shortcut: MacSettings.DesktopShortcut, whileHeld: () -> Void = {},
                      until arrived: () -> Bool) async -> Bool {
        let original = Events.cursorLocation
        var held = CGPoint(x: frame.minX + grabOffset.x, y: frame.minY + grabOffset.y)
        Events.postMouse(.mouseMoved, at: held)
        Events.postMouse(.leftMouseDown, at: held)
        defer {
            Events.postMouse(.leftMouseUp, at: held)
            Events.warpCursor(to: original)
        }
        // Move past the drag threshold so the window server starts a window drag;
        // a drag event with no movement doesn't start one.
        for _ in 1...3 {
            try? await Task.sleep(for: .milliseconds(15))
            held.x += 2
            Events.postMouse(.leftMouseDragged, at: held, delta: CGPoint(x: 2, y: 0))
        }
        try? await Task.sleep(for: .milliseconds(80))
        whileHeld()
        Events.postKey(shortcut.keyCode, flags: shortcut.flags)
        let ok = await waitUntil(timeout: .seconds(2), arrived)
        try? await Task.sleep(for: settleDelay)
        return ok
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
