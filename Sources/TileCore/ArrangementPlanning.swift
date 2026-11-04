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
    /// What stops `arrangement` from running, each as an instruction. Empty when it can run.
    /// Every desktop it places windows on or ends on needs a working Desktop N shortcut,
    /// because that's the only way Tile can show it.
    public static func problems(_ arrangement: Arrangement, numbering: DesktopNumbering,
                                shortcutEnabled: (Int) -> Bool) -> [String] {
        var problems: [String] = []
        let needed = arrangement.desktopsNeeded
        for role in needed.keys.sorted() {
            guard let have = numbering.desktops(for: role) else {
                problems.append("no display is playing '\(role)'")
                continue
            }
            let want = needed[role]!
            if have < want {
                let missing = want - have == 1 ? "one" : "\(want - have)"
                problems.append("\(role) needs \(want) desktops, has \(have): add \(missing) in Mission Control")
            }
        }
        guard problems.isEmpty else { return problems }

        let targets = Set(arrangement.desktops.map { DesktopRef(role: $0.display, index: $0.desktop) }
            + arrangement.endOn.map { DesktopRef(role: $0.key, index: $0.value) })
        for target in targets.sorted(by: { ($0.role, $0.index) < ($1.role, $1.index) }) {
            guard let number = numbering.number(of: target) else { continue }
            if number > DesktopNumbering.shortcutLimit {
                problems.append("\(target) is Desktop \(number), and macOS only has shortcuts up to Desktop \(DesktopNumbering.shortcutLimit)")
            } else if !shortcutEnabled(number) {
                problems.append("\(target) is Desktop \(number), and its shortcut is off: turn on System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Switch to Desktop \(number)")
            }
        }
        return problems
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
    /// On a desktop that's showing now.
    public let visible: Bool

    public init(id: UInt32, app: String, desktop: DesktopRef?, frame: CGRect, title: String?, visible: Bool) {
        self.id = id
        self.app = app
        self.desktop = desktop
        self.frame = frame
        self.title = title
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
    /// showing now (no switch needed to reach it), then any. A `title` placement only
    /// takes a window whose title matches, except that a window of unknown title
    /// already in place is assumed to be the one placed there last time, so a second
    /// run doesn't have to visit desktops to read titles.
    public static func choose(_ placement: WindowPlacement, target: DesktopRef, among windows: [WindowState],
                              claimed: Set<UInt32>, isInPlace: (WindowState) -> Bool) -> WindowChoice {
        let candidates = windows.filter { $0.app == placement.app && !claimed.contains($0.id) }
        func best(_ list: [WindowState]) -> WindowState? {
            list.first(where: isInPlace) ?? list.first { $0.desktop == target } ?? list.first(where: \.visible) ?? list.first
        }
        guard let pattern = placement.title else {
            return best(candidates).map { .window($0.id) } ?? .open
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .open }
        let known = candidates.filter { window in
            window.title.map { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false
        }
        if let window = best(known) { return .window(window.id) }
        let unknown = candidates.filter { $0.title == nil }
        if let window = unknown.first(where: isInPlace) { return .window(window.id) }
        var desktops: [DesktopRef] = []
        for desktop in unknown.compactMap(\.desktop) where !desktops.contains(desktop) {
            desktops.append(desktop)
        }
        return desktops.isEmpty ? .open : .needsTitles(desktops)
    }
}

/// A window found by Capture on a display's showing desktop.
public struct CapturedWindow: Equatable, Sendable {
    public let app: String
    public let title: String?
    /// AX coordinates.
    public let frame: CGRect

    public init(app: String, title: String?, frame: CGRect) {
        self.app = app
        self.title = title
        self.frame = frame
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
    /// A title is kept, as an exact-match pattern, only when the app has another
    /// window in the same capture: titles change (web pages, documents, Slack
    /// channels), and a stale one would stop the window matching.
    /// `appsWithSeveralWindows` covers every desktop captured at once.
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
