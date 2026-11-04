import CoreGraphics
import Foundation

/// The macOS settings that arrangements depend on. Read straight from the
/// preference domains, so a `defaults write` shows up on the next check.
enum MacSettings {
    struct Check {
        let name: String
        let ok: Bool
        let detail: String
        let fix: String
    }

    /// The key combo macOS has bound to "Switch to Desktop N".
    struct DesktopShortcut {
        let number: Int
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// Nil when the shortcut is disabled or not configured.
    static func desktopShortcut(_ number: Int) -> DesktopShortcut? {
        guard desktopShortcutNumbers.contains(number),
              let entry = symbolicHotkeys()[String(switchToDesktopBaseID + number - 1)] as? [String: Any],
              (entry["enabled"] as? Bool) == true,
              let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
              parameters.count == 3
        else { return nil }
        // parameters = [ASCII character, virtual key code, modifier flags]
        return DesktopShortcut(number: number,
                               keyCode: CGKeyCode(parameters[1].intValue),
                               flags: CGEventFlags(rawValue: parameters[2].uint64Value))
    }

    /// "When switching to an application, switch to a Space with open windows for the application".
    static var switchesSpaceOnActivate: Bool {
        (CFPreferencesCopyAppValue("AppleSpacesSwitchOnActivate" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
    }

    private static func symbolicHotkeys() -> [String: Any] {
        value("AppleSymbolicHotKeys", "com.apple.symbolichotkeys") as? [String: Any] ?? [:]
    }

    /// `Switch to Desktop N` shortcuts live in com.apple.symbolichotkeys under ids
    /// 118 + N - 1 (verified for 1 to 10 on macOS 26.2).
    static let switchToDesktopBaseID = 118
    /// macOS offers the shortcut for Desktops 1 to 16.
    static let desktopShortcutNumbers = 1...16

    static func checks() -> [Check] {
        [rearrangeSpaces(), separateSpaces()] + desktopShortcuts()
    }

    /// The settings without which desktop indices don't mean anything.
    static func missionControlChecks() -> [Check] {
        [rearrangeSpaces(), separateSpaces()]
    }

    /// Bundle ids (lowercased, as the Dock stores them) assigned to a desktop or to all
    /// desktops through the Dock icon's Options > Assign To.
    static func dockAssignedApps() -> Set<String> {
        let bindings = value("app-bindings", "com.apple.spaces") as? [String: Any] ?? [:]
        return Set(bindings.keys.map { $0.lowercased() })
    }

    private static func value(_ key: String, _ domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    private static func rearrangeSpaces() -> Check {
        // Unset means the default, which is on.
        let on = (value("mru-spaces", "com.apple.dock") as? Bool) ?? true
        return Check(
            name: "Automatically rearrange Spaces is off",
            ok: !on,
            detail: on ? "on: desktop numbers will shuffle with use" : "off",
            fix: "defaults write com.apple.dock mru-spaces -bool false && killall Dock")
    }

    private static func separateSpaces() -> Check {
        // spans-displays = true means "Displays have separate Spaces" is OFF.
        let spans = (value("spans-displays", "com.apple.spaces") as? Bool) ?? false
        return Check(
            name: "Displays have separate Spaces is on",
            ok: !spans,
            detail: spans ? "off: all displays share one set of Spaces" : "on",
            fix: "System Settings > Desktop & Dock > Mission Control > Displays have separate Spaces (then log out)")
    }

    /// One check per desktop that exists (all displays together), up to 16.
    private static func desktopShortcuts() -> [Check] {
        let hotkeys = symbolicHotkeys()
        let desktops = ((try? Spaces.snapshot()) ?? []).reduce(0) { $0 + $1.spaces.filter { $0.desktopIndex != nil }.count }
        let numbers = 1...min(max(desktops, 1), desktopShortcutNumbers.upperBound)
        return numbers.map { n in
            let entry = hotkeys[String(switchToDesktopBaseID + n - 1)] as? [String: Any]
            let enabled = (entry?["enabled"] as? Bool) ?? false
            return Check(
                name: "Switch to Desktop \(n) shortcut is enabled",
                ok: enabled,
                detail: entry == nil ? "not configured" : (enabled ? "enabled" : "disabled"),
                fix: "System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Switch to Desktop \(n)")
        }
    }
}
