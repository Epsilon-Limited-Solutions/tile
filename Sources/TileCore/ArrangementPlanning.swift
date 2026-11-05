import CoreGraphics
import Foundation

/// A desktop by display role and its 1-based position among that display's desktops.
public struct DesktopRef: Hashable, Sendable, CustomStringConvertible {
    public let role: String
    public let index: Int

    public init(role: String, index: Int) {
        self.role = role
        self.index = index
    }

    public var description: String { "\(role) desktop \(index)" }
}

/// How "Switch to Desktop N" numbers desktops: every user desktop of every display,
/// in SkyLight's display order (verified by the spike: built-in, then Vertical-Right,
/// then Vertical-Left; not left to right).
public struct DesktopNumbering: Equatable, Sendable {
    public struct Display: Equatable, Sendable {
        /// Nil for a display the profile has no role for. Its desktops still count.
        public let role: String?
        public let desktops: Int

        public init(role: String?, desktops: Int) {
            self.role = role
            self.desktops = desktops
        }
    }

    public let displays: [Display]

    public init(_ displays: [Display]) {
        self.displays = displays
    }

    /// macOS offers "Switch to Desktop" shortcuts for Desktops 1 to 16.
    public static let shortcutLimit = 16

    public func desktops(for role: String) -> Int? {
        displays.first { $0.role == role }?.desktops
    }

    public func number(of desktop: DesktopRef) -> Int? {
        var before = 0
        for display in displays {
            if display.role == desktop.role {
                return desktop.index >= 1 && desktop.index <= display.desktops ? before + desktop.index : nil
            }
            before += display.desktops
        }
        return nil
    }
}

public enum ArrangementCheck {
    /// How many desktops each display role is short of, for the arrangement's
    /// placements and `endOn`. macOS drops an external display's extra desktops when
    /// it disconnects, so a redocked display often comes back with one.
    public static func missingDesktops(_ arrangement: Arrangement, numbering: DesktopNumbering) -> [String: Int] {
        var missing: [String: Int] = [:]
        for (role, want) in arrangement.desktopsNeeded {
            if let have = numbering.desktops(for: role), have < want { missing[role] = want - have }
        }
        return missing
    }

    /// The desktops the arrangement uses that Tile can't show, each with why. Every
    /// desktop it places windows on or ends on needs a working Desktop N shortcut,
    /// because that's the only way Tile can show it. Windows bound for these desktops
    /// fail; the rest of the arrangement still runs.
    public static func unreachable(_ arrangement: Arrangement, numbering: DesktopNumbering,
                                   shortcutEnabled: (Int) -> Bool) -> [DesktopRef: String] {
        var result: [DesktopRef: String] = [:]
        let targets = Set(arrangement.desktops.map { DesktopRef(role: $0.display, index: $0.desktop) }
            + arrangement.endOn.map { DesktopRef(role: $0.key, index: $0.value) })
        for target in targets {
            guard let have = numbering.desktops(for: target.role) else {
                result[target] = "no display is playing '\(target.role)'"
                continue
            }
            guard let number = numbering.number(of: target) else {
                let missing = target.index - have == 1 ? "one" : "\(target.index - have)"
                result[target] = "\(target.role) has \(have) desktop\(have == 1 ? "" : "s"): add \(missing) in Mission Control"
                continue
            }
            if number > DesktopNumbering.shortcutLimit {
                result[target] = "it's Desktop \(number), and macOS only has shortcuts up to Desktop \(DesktopNumbering.shortcutLimit)"
            } else if !shortcutEnabled(number) {
                result[target] = "it's Desktop \(number), and its shortcut is off: turn on System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Switch to Desktop \(number)"
            }
        }
        return result
    }
}

/// A file or folder a window shows, for placements that `open` one: the Arranger
/// opens it to make the window, and recognises the window by it afterwards.
public struct OpenTarget: Equatable, Sendable {
    /// Absolute, standardized, no trailing slash.
    public let path: String
    public let isFolder: Bool
    /// `path` with the home folder as `~`, as terminals put it in titles.
    public let tildePath: String

    /// Nil for a URL that isn't a file (a web page): those are opened, never recognised.
    public init?(item: String, home: String, isFolder: (String) -> Bool) {
        let raw: String
        if item.hasPrefix("file://") {
            guard let url = URL(string: item), url.isFileURL else { return nil }
            raw = url.path
        } else if item.contains("://") {
            return nil
        } else if item == "~" || item.hasPrefix("~/") {
            raw = home + item.dropFirst()
        } else {
            raw = item
        }
        guard raw.hasPrefix("/") else { return nil }
        let path = Self.standardize(raw)
        self.path = path
        self.isFolder = isFolder(path)
        let home = Self.standardize(home)
        tildePath = path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Whether a window showing `document` (a file path; nil when it shows none) with
    /// `title` is this target's window. A folder matches a document inside it, or a
    /// title naming it (editors put the workspace folder's name in the title, and
    /// terminals the working directory); a file matches its document, or its name in
    /// the title when the window doesn't say which document it shows.
    public func matches(document: String?, title: String) -> Bool {
        if let document {
            let document = Self.standardize(document)
            if document == path || (isFolder && document.hasPrefix(path + "/")) { return true }
            if !isFolder { return false }
        }
        let name = (path as NSString).lastPathComponent
        return Self.titleSegments(title).contains { $0 == name || $0 == path || $0 == tildePath }
    }

    /// The parts of a window title: the whole title, and each piece between the
    /// separators apps use ("file — folder — App", "dir - zsh", "Doc | App").
    public static func titleSegments(_ title: String) -> [String] {
        var segments = [title.trimmingCharacters(in: .whitespaces)]
        var pieces = [title]
        for separator in [" — ", " – ", " - ", " | "] {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        if pieces.count > 1 { segments += pieces.map { $0.trimmingCharacters(in: .whitespaces) } }
        return segments.filter { !$0.isEmpty }
    }

    static func standardize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}

/// A window as the Arranger sees it before placing one.
public struct WindowState: Equatable, Sendable {
    public let id: UInt32
    /// Bundle id.
    public let app: String
    /// Nil when the window isn't on exactly one desktop of a display with a role.
    public let desktop: DesktopRef?
    /// AX coordinates.
    public let frame: CGRect
    /// Nil when unknown: AX only sees windows on the desktops showing now.
    public let title: String?
    /// The file it shows (AXDocument), read along with the title; nil when unknown or none.
    public let document: String?
    /// On a desktop that's showing now.
    public let visible: Bool

    public init(id: UInt32, app: String, desktop: DesktopRef?, frame: CGRect, title: String?,
                document: String? = nil, visible: Bool) {
        self.id = id
        self.app = app
        self.desktop = desktop
        self.frame = frame
        self.title = title
        self.document = document
        self.visible = visible
    }
}

public enum WindowChoice: Equatable, Sendable {
    case window(UInt32)
    /// The app has windows whose titles are unknown on these desktops; show them and choose again.
    case needsTitles([DesktopRef])
    /// No window fits: open one.
    case open
}

public enum WindowMatching {
    /// Picks the window for `placement`, never one in `claimed`. Prefers, in order: a
    /// window already in place, one already on the target desktop, one on a desktop
    /// showing now (no switch needed to reach it), then any.
    ///
    /// A placement with a `title` or with files and folders to `open` (`opens`) only
    /// takes a window it recognises: title matching, and showing one of `opens`.
    /// Except that a window whose title is unknown, already in place, is assumed to be
    /// the one placed there last time, so a second run doesn't have to visit desktops
    /// to read titles.
    public static func choose(_ placement: WindowPlacement, opens: [OpenTarget] = [], target: DesktopRef,
                              among windows: [WindowState], claimed: Set<UInt32>,
                              isInPlace: (WindowState) -> Bool) -> WindowChoice {
        let candidates = windows.filter { $0.app == placement.app && !claimed.contains($0.id) }
        func best(_ list: [WindowState]) -> WindowState? {
            list.first(where: isInPlace) ?? list.first { $0.desktop == target } ?? list.first(where: \.visible) ?? list.first
        }
        guard placement.title != nil || !opens.isEmpty else {
            return best(candidates).map { .window($0.id) } ?? .open
        }
        guard let recognise = recogniser(placement, opens: opens) else { return .open }
        let known = candidates.filter { window in window.title.map { recognise($0, window.document) } ?? false }
        if let window = best(known) { return .window(window.id) }
        let unknown = candidates.filter { $0.title == nil }
        if let window = unknown.first(where: isInPlace) { return .window(window.id) }
        var desktops: [DesktopRef] = []
        for desktop in unknown.compactMap(\.desktop) where !desktops.contains(desktop) {
            desktops.append(desktop)
        }
        return desktops.isEmpty ? .open : .needsTitles(desktops)
    }

    /// Whether a window with this title and document is `placement`'s window, or nil
    /// when the title pattern doesn't compile. Always true for a placement that says
    /// neither.
    public static func recogniser(_ placement: WindowPlacement, opens: [OpenTarget])
        -> ((_ title: String, _ document: String?) -> Bool)? {
        var regex: NSRegularExpression?
        if let pattern = placement.title {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
            regex = compiled
        }
        return { title, document in
            if let regex, regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) == nil { return false }
            return opens.isEmpty || opens.contains { $0.matches(document: document, title: title) }
        }
    }
}

/// A window found by Capture on a display's showing desktop.
public struct CapturedWindow: Equatable, Sendable {
    public let app: String
    public let title: String?
    /// AX coordinates.
    public let frame: CGRect
    /// The file or folder that brings this window back when opened with the app
    /// (a document, an editor's workspace folder, a terminal's directory), or nil.
    public let open: String?

    public init(app: String, title: String?, frame: CGRect, open: String? = nil) {
        self.app = app
        self.title = title
        self.frame = frame
        self.open = open
    }
}

public enum CaptureBuilder {
    public struct Conflict: Error, CustomStringConvertible {
        public let description: String
    }

    /// Placements for the windows on one desktop, as fractional rects rounded to
    /// 0.001: the rects that put each window back where it is once `LayoutEngine`
    /// adds the gaps. An edge within the outer gap of the screen edge counts as on it.
    ///
    /// A window that knows its file or folder gets it as `open`, which both reopens
    /// it and recognises it later. Otherwise a title is kept, as an exact-match
    /// pattern, only when the app has another window in the same capture: titles
    /// change (web pages, documents, Slack channels), and a stale one would stop the
    /// window matching. `appsWithSeveralWindows` covers every desktop captured at once.
    public static func placements(_ windows: [CapturedWindow], visibleFrame: CGRect, gaps: Gaps,
                                  appsWithSeveralWindows: Set<String>) -> [WindowPlacement] {
        let area = visibleFrame.insetBy(dx: gaps.outer, dy: gaps.outer)
        let half = gaps.inner / 2
        func rounded(_ value: CGFloat) -> CGFloat { min(max((value * 1000).rounded() / 1000, 0), 1) }
        // The inverse of LayoutEngine.frame, edge by edge.
        func low(_ edge: CGFloat, _ origin: CGFloat, _ length: CGFloat) -> CGFloat {
            edge <= origin + 1 ? 0 : rounded((edge - half - origin) / length)
        }
        func high(_ edge: CGFloat, _ origin: CGFloat, _ length: CGFloat) -> CGFloat {
            edge >= origin + length - 1 ? 1 : rounded((edge + half - origin) / length)
        }
        return windows.compactMap { window in
            let frame = window.frame
            guard frame.intersects(visibleFrame), area.width > 0, area.height > 0 else { return nil }
            let minX = low(frame.minX, area.minX, area.width)
            let minY = low(frame.minY, area.minY, area.height)
            let maxX = high(frame.maxX, area.minX, area.width)
            let maxY = high(frame.maxY, area.minY, area.height)
            guard maxX > minX, maxY > minY else { return nil }
            let rect = CGRect(x: minX, y: minY, width: ((maxX - minX) * 1000).rounded() / 1000,
                              height: ((maxY - minY) * 1000).rounded() / 1000)
            if let open = window.open {
                return WindowPlacement(app: window.app, layout: .rect(rect), open: [open])
            }
            let title = appsWithSeveralWindows.contains(window.app)
                ? window.title.flatMap { $0.isEmpty ? nil : "^" + NSRegularExpression.escapedPattern(for: $0) + "$" }
                : nil
            return WindowPlacement(app: window.app, title: title, layout: .rect(rect))
        }
    }

    /// `arrangements` with the captured desktops merged into arrangement `id`: each
    /// (display, desktop) captured again replaces the old entry in place, new ones go
    /// at the end, and everything else is kept. A new id becomes a new arrangement
    /// for `profile`.
    public static func merge(_ captured: [DesktopPlacement], into arrangements: [Arrangement],
                             id: String, profile: String) throws -> [Arrangement] {
        guard let index = arrangements.firstIndex(where: { $0.id == id }) else {
            return arrangements + [Arrangement(id: id, profile: profile, desktops: captured)]
        }
        let existing = arrangements[index]
        guard existing.profile == profile else {
            throw Conflict(description: "arrangement '\(id)' is for profile '\(existing.profile)', and the displays now are '\(profile)': capture under another name")
        }
        var desktops = existing.desktops
        for desktop in captured {
            if let slot = desktops.firstIndex(where: { $0.display == desktop.display && $0.desktop == desktop.desktop }) {
                desktops[slot] = desktop
            } else {
                desktops.append(desktop)
            }
        }
        var result = arrangements
        result[index] = Arrangement(id: id, profile: profile, endOn: existing.endOn, desktops: desktops)
        return result
    }
}
