import CoreGraphics
import Foundation

/// The contents of ~/.config/tile/config.json, parsed and validated.
public struct Config: Equatable, Sendable {
    public var gaps: Gaps
    /// Bundle ids Tile never touches.
    public var ignoredApps: [String]
    public var profiles: [DisplayProfile]
    public var layouts: [WindowLayout]
    public var bindings: [KeyBinding]
    public var arrangements: [Arrangement]
    /// Bundle id -> where to hold its windows' title bar when carrying them to another
    /// desktop, as an offset from the window's top-left. For apps whose title bar is
    /// mostly tabs or buttons, where Tile's own pick would grab the wrong thing.
    public var grab: [String: CGPoint]

    public init(gaps: Gaps = Gaps(), ignoredApps: [String] = [], profiles: [DisplayProfile] = [],
                layouts: [WindowLayout] = [], bindings: [KeyBinding] = [], arrangements: [Arrangement] = [],
                grab: [String: CGPoint] = [:]) {
        self.gaps = gaps
        self.ignoredApps = ignoredApps
        self.profiles = profiles
        self.layouts = layouts
        self.bindings = bindings
        self.arrangements = arrangements
        self.grab = grab
    }

    /// Decodes and validates. Throws `ConfigError` listing what's wrong, with the
    /// path of each problem (`bindings[3].layout`) and, for syntax errors, the line.
    public static func parse(_ data: Data) throws -> Config {
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError(issues: [ConfigIssue(error)])
        }
        let issues = config.validationIssues()
        guard issues.isEmpty else { throw ConfigError(issues: issues) }
        return config
    }

    public func layout(_ id: String) -> WindowLayout? {
        layouts.first { $0.id == id }
    }
}

public struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    /// Where in the file, as `bindings[3].when.display`; empty for the whole file.
    public let path: String
    public let message: String

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let issues: [ConfigIssue]
    public var description: String { issues.map(\.description).joined(separator: "\n") }
}

/// A display setup (laptop only, docked, ...) and the role each display plays in it.
public struct DisplayProfile: Equatable, Sendable {
    public let id: String
    /// Role name -> how to recognize the display that plays it.
    public let displays: [String: DisplayMatcher]
    /// Arrangement to run when this profile becomes active.
    public let onActivate: String?
}

/// Recognizes a display. Every field that's set must match; at least one is set.
public struct DisplayMatcher: Equatable, Sendable {
    public let builtin: Bool?
    /// NSScreen.localizedName, ignoring the " (1)" macOS appends to identical monitors.
    public let name: String?
    /// CGDisplaySerialNumber. Tells identical monitors apart.
    public let serial: UInt32?
    /// Degrees: 0, 90, 180 or 270.
    public let rotation: Int?
}

public struct KeyBinding: Equatable, Sendable {
    public let keys: KeyCombo
    public let when: Condition
    public let target: Target

    public init(keys: KeyCombo, when: Condition = Condition(), target: Target) {
        self.keys = keys
        self.when = when
        self.target = target
    }

    public enum Target: Equatable, Sendable {
        case layout(String)
        /// Repeated presses step through these layout ids.
        case cycle([String])
        case action(WindowAction)
        case arrange(String)
    }

    /// Where a binding applies. Unset fields match anything.
    public struct Condition: Hashable, Sendable {
        public var profile: String?
        /// A display role from the profile.
        public var display: String?
        public var orientation: Orientation?

        public init(profile: String? = nil, display: String? = nil, orientation: Orientation? = nil) {
            self.profile = profile
            self.display = display
            self.orientation = orientation
        }
    }
}

public enum WindowAction: String, Sendable, CaseIterable {
    case restore
    case nextDisplay = "next-display"
    case previousDisplay = "previous-display"
}

/// Apps placed on specific desktops of specific displays, run with one hotkey.
public struct Arrangement: Equatable, Sendable {
    public let id: String
    public let profile: String
    /// Role -> desktop index to leave showing. Empty: go back to the desktops showing at the start.
    public let endOn: [String: Int]
    public let desktops: [DesktopPlacement]

    public init(id: String, profile: String, endOn: [String: Int] = [:], desktops: [DesktopPlacement]) {
        self.id = id
        self.profile = profile
        self.endOn = endOn
        self.desktops = desktops
    }

    /// Role -> how many desktops that display needs for this arrangement to run.
    public var desktopsNeeded: [String: Int] {
        var needed: [String: Int] = [:]
        for placement in desktops {
            needed[placement.display] = max(needed[placement.display] ?? 0, placement.desktop)
        }
        for (role, desktop) in endOn {
            needed[role] = max(needed[role] ?? 0, desktop)
        }
        return needed
    }
}

public struct DesktopPlacement: Equatable, Sendable {
    /// Display role.
    public let display: String
    /// 1-based, among that display's desktops in Mission Control order.
    public let desktop: Int
    public let windows: [WindowPlacement]

    public init(display: String, desktop: Int, windows: [WindowPlacement]) {
        self.display = display
        self.desktop = desktop
        self.windows = windows
    }
}

public struct WindowPlacement: Equatable, Sendable {
    /// Bundle id.
    public let app: String
    /// Regex picking one of the app's windows by title.
    public let title: String?
    public let layout: LayoutRef
    /// Paths or URLs to open with the app.
    public let open: [String]

    public init(app: String, title: String? = nil, layout: LayoutRef, open: [String] = []) {
        self.app = app
        self.title = title
        self.layout = layout
        self.open = open
    }
}

/// A layout by id, or an inline fractional rect (what Capture writes).
public enum LayoutRef: Equatable, Sendable {
    case named(String)
    case rect(CGRect)
}
