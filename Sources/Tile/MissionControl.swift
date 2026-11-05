import AppKit
import TileCore

/// Adds desktops the way a person does: opens Mission Control and presses the
/// add-desktop button at the end of a display's Spaces bar, through the Dock's own
/// Accessibility tree. No private API and nothing that needs SIP off; it's what
/// Hammerspoon's hs.spaces does.
///
/// The Dock's tree, while Mission Control is open (macOS 26):
///   AXGroup "mc"
///     AXGroup "mc.display" (AXDisplayID), one per display
///       AXGroup "mc.spaces"
///         AXList "mc.spaces.list"   one button per desktop
///         AXButton "mc.spaces.add"
@MainActor
enum MissionControl {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    /// Adds `count` desktops to the end of `display`'s desktops, and closes Mission
    /// Control again. Checks each one arrived with `desktopCount`, read from the window
    /// server (not the Dock's tree, which lags).
    static func addDesktops(_ count: Int, to display: DisplayInfo, desktopCount: () -> Int) async throws {
        guard count > 0 else { return }
        guard let dock = dockApplication() else { throw Failure(description: "the Dock isn't running") }
        let start = desktopCount()
        try await open(dock)
        var failure: Failure?
        for added in 1...count {
            guard let group = displayGroup(dock, for: display),
                  let button = find(in: group, depth: 0, { AX.string($0, "AXIdentifier") == "mc.spaces.add" }) else {
                failure = Failure(description: "can't find Mission Control's add-desktop button for \(display.name)")
                break
            }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard await poll(seconds: 3, { desktopCount() >= start + added }) else {
                failure = Failure(description: "pressed add-desktop on \(display.name), and no desktop arrived")
                break
            }
        }
        await close(dock)
        if let failure { throw failure }
    }

    /// Removes `display`'s last desktop, as its close button in Mission Control does
    /// (AXRemoveDesktop); windows on it move to another desktop. For the arrange test's
    /// cleanup.
    static func removeLastDesktop(of display: DisplayInfo, desktopCount: () -> Int) async throws {
        guard let dock = dockApplication() else { throw Failure(description: "the Dock isn't running") }
        let start = desktopCount()
        try await open(dock)
        var failure: Failure?
        if let group = displayGroup(dock, for: display),
           let list = find(in: group, depth: 0, { AX.string($0, "AXIdentifier") == "mc.spaces.list" }),
           let last = AX.children(list).last {
            AXUIElementPerformAction(last, "AXRemoveDesktop" as CFString)
            if !(await poll(seconds: 3, { desktopCount() < start })) {
                failure = Failure(description: "asked to remove \(display.name)'s last desktop, and it's still there")
            }
        } else {
            failure = Failure(description: "can't find \(display.name)'s desktops in Mission Control")
        }
        await close(dock)
        if let failure { throw failure }
    }

    /// Debug: opens Mission Control and describes the Dock's tree, without window
    /// thumbnails (they carry other apps' window titles).
    static func describe() async -> String {
        guard let dock = dockApplication() else { return "the Dock isn't running\n" }
        do {
            try await open(dock)
        } catch {
            return "\(error)\n"
        }
        var lines: [String] = []
        var budget = 400
        func walk(_ element: AXUIElement, depth: Int) {
            guard budget > 0, depth < 8 else { return }
            budget -= 1
            let identifier = AX.string(element, "AXIdentifier") ?? ""
            var parts = [AX.string(element, kAXRoleAttribute) ?? "?"]
            if let subrole = AX.string(element, kAXSubroleAttribute) { parts.append(subrole) }
            if !identifier.isEmpty { parts.append("id=\(identifier)") }
            if let display = AX.value(element, "AXDisplayID") { parts.append("AXDisplayID=\(display)") }
            if identifier.hasPrefix("mc.spaces") || identifier.isEmpty {
                for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
                    if let text = AX.string(element, attribute), !text.isEmpty { parts.append("\(attribute)=\"\(text.prefix(40))\"") }
                }
            }
            if let frame = AX.frame(of: element) { parts.append("frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))") }
            var actions: CFArray?
            if AXUIElementCopyActionNames(element, &actions) == .success, let names = actions as? [String], !names.isEmpty {
                parts.append("actions=\(names.joined(separator: ","))")
            }
            let children = AX.children(element)
            parts.append("children=\(children.count)")
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            if identifier == "mc.windows" || identifier.hasPrefix("mc.window") { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        for child in AX.children(dock) { walk(child, depth: 0) }
        await close(dock)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: -

    private static func dockApplication() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        return AX.application(pid: dock.processIdentifier)
    }

    private static func missionControl(_ dock: AXUIElement) -> AXUIElement? {
        AX.children(dock).first { AX.string($0, "AXIdentifier") == "mc" }
    }

    private static func open(_ dock: AXUIElement) async throws {
        if missionControl(dock) != nil { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        guard await poll(seconds: 3, { missionControl(dock) != nil }) else {
            throw Failure(description: "Mission Control didn't open")
        }
        // Its animation: buttons pressed mid-flight are ignored.
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// Opening it again toggles it off; Esc if that didn't.
    private static func close(_ dock: AXUIElement) async {
        guard missionControl(dock) != nil else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        if await poll(seconds: 2, { missionControl(dock) == nil }) { return }
        Events.postKey(53, flags: [])
        _ = await poll(seconds: 2) { missionControl(dock) == nil }
    }

    private static func displayGroup(_ dock: AXUIElement, for display: DisplayInfo) -> AXUIElement? {
        guard let mc = missionControl(dock) else { return nil }
        let displays = AX.children(mc).filter { AX.string($0, "AXIdentifier") == "mc.display" }
        let group = displays.first { (AX.value($0, "AXDisplayID") as? NSNumber)?.uint32Value == display.id }
            ?? displays.first { element in
                // Older layouts without AXDisplayID: the group covering the display.
                guard let frame = AX.frame(of: element) else { return false }
                let bounds = CGDisplayBounds(display.id)
                return frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            }
            ?? (displays.count == 1 ? displays.first : nil)
        return group
    }

    private static func find(in element: AXUIElement, depth: Int, _ test: (AXUIElement) -> Bool) -> AXUIElement? {
        if test(element) { return element }
        guard depth < 4 else { return nil }
        for child in AX.children(element) {
            if let found = find(in: child, depth: depth + 1, test) { return found }
        }
        return nil
    }

    private static func poll(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
