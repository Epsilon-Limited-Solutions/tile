import AppKit
import TileCore

/// Finds, reads and sets window frames through AX. AX coordinates throughout.
@MainActor
enum WindowMover {
    /// A window Tile may move.
    struct Window {
        let element: AXUIElement
        let pid: pid_t
        /// The window server id; nil if it couldn't be read, which only costs restore.
        let id: CGWindowID?

        @MainActor var frame: CGRect? { AX.frame(of: element) }
    }

    enum Refusal: Error, CustomStringConvertible {
        case noFrontmostApp
        case ignored(app: String)
        case noWindow(app: String)
        case notStandard(app: String, subrole: String)
        case fullscreen(app: String)
        case minimized(app: String)

        var description: String {
            switch self {
            case .noFrontmostApp: "no frontmost app"
            case .ignored(let app): "\(app) is in ignoredApps"
            case .noWindow(let app): "\(app) has no focused window"
            case .notStandard(let app, let subrole): "\(app)'s focused window is not a standard window (subrole \(subrole))"
            case .fullscreen(let app): "\(app)'s focused window is fullscreen"
            case .minimized(let app): "\(app)'s focused window is minimized"
            }
        }
    }

    /// A frame within this many points of the one asked for counts as placed.
    static let tolerance: CGFloat = 2

    /// The frontmost app's focused window (or main window), if Tile may move it.
    static func focusedWindow(ignoring ignoredApps: [String]) throws -> Window {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw Refusal.noFrontmostApp }
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        if let bundleID = app.bundleIdentifier, ignoredApps.contains(bundleID) { throw Refusal.ignored(app: name) }
        let appElement = AX.application(pid: app.processIdentifier)
        guard let element = AX.element(appElement, kAXFocusedWindowAttribute) ?? AX.element(appElement, kAXMainWindowAttribute)
        else { throw Refusal.noWindow(app: name) }

        // Sheets, panels, popovers and the like have other subroles. A fullscreen
        // window is its own Space and can't be resized.
        let subrole = AX.string(element, kAXSubroleAttribute) ?? "none"
        guard subrole == kAXStandardWindowSubrole else { throw Refusal.notStandard(app: name, subrole: subrole) }
        if AX.bool(element, "AXFullScreen") == true { throw Refusal.fullscreen(app: name) }
        if AX.bool(element, kAXMinimizedAttribute) == true { throw Refusal.minimized(app: name) }
        return Window(element: element, pid: app.processIdentifier, id: try? SkyLight.windowID(of: element))
    }

    /// Size, then position, then size again: the first size can be clamped by the
    /// display the window starts on, and the second fixes that once it's on the target
    /// display. Then waits for the window to get there or stop changing, and if it
    /// stopped short, sets it once more: the first big resize after a window lands on
    /// another display can come out short (selftest: 720x2325 for 720x2530, TextEdit).
    /// Returns where the window actually is, which apps with minimum sizes or
    /// character-cell sizing (terminals) may not put exactly at `frame`.
    @discardableResult
    static func setFrame(_ window: Window, to frame: CGRect) async -> CGRect? {
        // Chromium and Electron apps animate AX resizes, and land in the wrong place,
        // while AXEnhancedUserInterface is on.
        let app = AX.application(pid: window.pid)
        let enhanced = AX.bool(app, enhancedUserInterface) == true
        if enhanced { AX.setBool(app, enhancedUserInterface, false) }
        defer { if enhanced { AX.setBool(app, enhancedUserInterface, true) } }

        var result: CGRect?
        for attempt in 1...2 {
            AX.setSize(window.element, frame.size)
            AX.setPosition(window.element, frame.origin)
            AX.setSize(window.element, frame.size)
            result = await settle(window, toward: frame)
            if result?.isClose(to: frame, within: tolerance) ?? false { break }
            if attempt == 1 {
                Log.app.info("window took \(String(describing: result), privacy: .public) for \(String(describing: frame), privacy: .public); setting it again")
            }
        }
        return result
    }

    /// Polls until the window has `frame` or has held still for 100ms, up to 500ms.
    private static func settle(_ window: Window, toward frame: CGRect) async -> CGRect? {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(500)
        var last = window.frame
        var stillSince = clock.now
        while clock.now < deadline {
            if last?.isClose(to: frame, within: tolerance) ?? false { return last }
            try? await Task.sleep(for: .milliseconds(20))
            let now = window.frame
            if now != last {
                last = now
                stillSince = clock.now
            } else if clock.now - stillSince >= .milliseconds(100) {
                break
            }
        }
        return window.frame
    }

    private static let enhancedUserInterface = "AXEnhancedUserInterface"
}
