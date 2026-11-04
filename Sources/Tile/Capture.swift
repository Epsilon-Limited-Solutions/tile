import AppKit
import TileCore

/// "Capture current desktops into arrangement…": records the desktop showing on each
/// display of the active profile, with every standard window on it, as an arrangement
/// in the config. Arrange by hand, capture, swipe to the next desktop, capture again.
@MainActor
enum Capture {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static var lastName: String?
    private static let hud = ArrangeHUD()

    /// Asks for the arrangement's name, then captures into it.
    static func ask(configStore: ConfigStore, profiles: DisplayProfiles) {
        let existing = configStore.config.arrangements.map(\.id)
        let alert = NSAlert()
        alert.messageText = "Capture current desktops"
        alert.informativeText = "Saves the desktop showing on each display, with its windows, into an arrangement. "
            + "Swipe to another desktop and capture again to add it."
            + (existing.isEmpty ? "" : "\n\nExisting: \(existing.joined(separator: ", "))")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = lastName ?? existing.first ?? "work"
        field.placeholderString = "arrangement name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run(named: name, configStore: configStore, profiles: profiles)
    }

    /// Captures into arrangement `name` and shows how it went.
    static func run(named name: String, configStore: ConfigStore, profiles: DisplayProfiles) {
        lastName = name
        do {
            let summary = try capture(named: name, configStore: configStore, profiles: profiles)
            Log.app.info("\(summary, privacy: .public)")
            hud.finish(summary, "Saved to config.json", seconds: 3)
        } catch {
            Log.app.error("capture failed: \(String(describing: error), privacy: .public)")
            hud.finish("Capture failed", "\(error)", seconds: 10)
        }
    }

    private static func capture(named name: String, configStore: ConfigStore, profiles: DisplayProfiles) throws -> String {
        guard AX.isTrusted else { throw Failure(description: "Accessibility isn't granted") }
        let displays = DisplayInfo.all()
        guard let match = profiles.match(displays) else {
            throw Failure(description: "no profile matches these displays: use Copy Current Displays as Profile JSON, add it to profiles, then capture")
        }
        let geometry = ScreenGeometry(displays: displays)
        let snapshot = try Spaces.snapshot()

        // The desktop showing on each display with a role.
        var desktops: [(role: String, index: Int, space: SkyLight.SpaceID, display: DisplayInfo)] = []
        var skipped: [String] = []
        for display in displays.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            guard let role = match.role(of: display.id), let uuid = display.uuid,
                  let spaces = snapshot.first(where: { $0.displayIdentifier.caseInsensitiveCompare(uuid) == .orderedSame })
            else { continue }
            guard let index = spaces.spaces.first(where: { $0.id == spaces.currentSpace })?.desktopIndex else {
                skipped.append("\(role) is showing a fullscreen app")
                continue
            }
            desktops.append((role, index, spaces.currentSpace, display))
        }

        // Every standard window of every regular app, by the desktop it's on.
        var windows: [SkyLight.SpaceID: [CapturedWindow]] = [:]
        let ignored = Set(configStore.config.ignoredApps + [Bundle.main.bundleIdentifier ?? ""])
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            guard let bundleID = app.bundleIdentifier, !ignored.contains(bundleID) else { continue }
            for element in AX.windows(of: AX.application(pid: app.processIdentifier)) {
                guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      AX.bool(element, kAXMinimizedAttribute) != true,
                      AX.bool(element, "AXFullScreen") != true,
                      let frame = AX.frame(of: element), frame.width >= 100, frame.height >= 100,
                      let id = try? SkyLight.windowID(of: element),
                      let spaces = try? SkyLight.spaces(forWindow: id), spaces.count == 1,
                      desktops.contains(where: { $0.space == spaces[0] })
                else { continue }
                windows[spaces[0], default: []].append(
                    CapturedWindow(app: bundleID, title: AX.string(element, kAXTitleAttribute), frame: frame))
            }
        }
        let counts = Dictionary(windows.values.flatMap { $0 }.map { ($0.app, 1) }, uniquingKeysWith: +)
        let several = Set(counts.filter { $0.value > 1 }.keys)

        let captured = desktops.map { desktop in
            let found = (windows[desktop.space] ?? []).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            return DesktopPlacement(display: desktop.role, desktop: desktop.index,
                                    windows: CaptureBuilder.placements(found, visibleFrame: geometry.axVisibleFrame(of: desktop.display),
                                                                       gaps: configStore.config.gaps, appsWithSeveralWindows: several))
        }
        guard !captured.isEmpty else { throw Failure(description: skipped.first ?? "no display has a desktop showing") }

        try configStore.replaceSection("arrangements") { current in
            ConfigFormat.arrangements(try CaptureBuilder.merge(captured, into: current.arrangements,
                                                               id: name, profile: match.profile.id))
        }
        let windowCount = captured.reduce(0) { $0 + $1.windows.count }
        let places = captured.map { "\($0.display) \($0.desktop)" }.joined(separator: ", ")
        return "Captured \(windowCount) windows into '\(name)' (\(places))"
            + (skipped.isEmpty ? "" : "; skipped: \(skipped.joined(separator: ", "))")
    }
}
