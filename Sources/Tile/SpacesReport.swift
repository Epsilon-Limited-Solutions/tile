import AppKit
import TileCore

/// `tile://debug/spaces`: everything Tile can see about displays, Spaces and
/// windows, written to ~/Library/Logs/Tile/spaces.txt.
@MainActor
enum SpacesReport {
    static let fileName = "spaces.txt"

    @discardableResult
    static func write() -> URL {
        Reports.write(fileName, generate())
    }

    static func generate() -> String {
        var out = ""
        func line(_ text: String = "") { out += text + "\n" }

        line("Tile spaces report  \(ISO8601DateFormatter().string(from: Date()))")
        line("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line("Accessibility: \(AX.isTrusted ? "granted" : "NOT granted")")
        line()

        line("== macOS settings ==")
        for check in MacSettings.checks() {
            line("[\(check.ok ? " OK " : "FAIL")] \(check.name): \(check.detail)")
            if !check.ok { line("       fix: \(check.fix)") }
        }
        line()

        let displays = DisplayInfo.all()
        line("== Displays (NSScreen order; first is primary) ==")
        for d in displays {
            line("\(d.name)  id=\(d.id)  uuid=\(d.uuid ?? "?")  builtin=\(d.isBuiltin)  rotation=\(Int(d.rotation))"
                 + "  vendor=\(d.vendor) model=\(d.model) serial=\(d.serial)")
            line("  frame \(format(d.frame))  visible \(format(d.visibleFrame))  (NSScreen coords)")
        }
        line()

        line("== Spaces (SkyLight) ==")
        var spaceLabels: [SkyLight.SpaceID: String] = [:]
        do {
            line("connection \(try SkyLight.mainConnectionID())  active space \(try SkyLight.activeSpace())")
            for display in try Spaces.snapshot() {
                let name = displays.first {
                    $0.uuid?.caseInsensitiveCompare(display.displayIdentifier) == .orderedSame
                }?.name ?? display.displayIdentifier
                let direct = (try? SkyLight.currentSpace(forDisplay: display.displayIdentifier)).map(String.init) ?? "error"
                line("\(name)  [\(display.displayIdentifier)]  current=\(display.currentSpace)  (direct query: \(direct))")
                for space in display.spaces {
                    let label = space.desktopIndex.map { "desktop \($0)" } ?? "fullscreen(type \(space.type))"
                    let marker = space.id == display.currentSpace ? "  <- current" : ""
                    line("  pos \(space.position)  \(label)  id=\(space.id)  uuid=\(space.uuid)\(marker)")
                    spaceLabels[space.id] = "\(name) \(label)"
                }
            }
        } catch {
            line("ERROR: \(error)")
        }
        line()

        line("== Windows (window server, every Space, regular apps only) ==")
        var skipped = 0
        let windows = Spaces.serverWindows().sorted { $0.ownerName < $1.ownerName }
        for window in windows {
            guard let app = NSRunningApplication(processIdentifier: window.pid), app.activationPolicy == .regular else {
                skipped += 1
                continue
            }
            let spaces = (try? SkyLight.spaces(forWindow: window.id)) ?? []
            let location = spaces.map { spaceLabels[$0] ?? "space \($0)" }.joined(separator: ", ")
            line("wid \(window.id)  \(app.bundleIdentifier ?? window.ownerName)  \"\(window.title ?? "<no title>")\""
                 + "  \(format(window.bounds))  \(window.isOnscreen ? "onscreen" : "offscreen")"
                 + "  on: \(location.isEmpty ? "-" : location)")
        }
        line("(\(skipped) windows from non-regular apps skipped)")
        line()

        line("== AX windows (hypothesis: only windows on visible Spaces) ==")
        if AX.isTrusted {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let element = AX.application(pid: app.processIdentifier)
                for window in AX.windows(of: element) {
                    let id: String
                    do { id = try SkyLight.windowID(of: window).map(String.init) ?? "none" } catch { id = "\(error)" }
                    let title = AX.string(window, kAXTitleAttribute) ?? "<no title>"
                    let subrole = AX.string(window, kAXSubroleAttribute) ?? "?"
                    let frame = AX.frame(of: window).map(format) ?? "?"
                    line("\(app.bundleIdentifier ?? "?")  wid \(id)  \"\(title)\"  subrole=\(subrole)  \(frame)")
                }
            }
        } else {
            line("skipped: Accessibility not granted")
        }
        return out
    }

    private static func format(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}
