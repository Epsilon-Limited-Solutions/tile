import CoreGraphics
import Foundation

extension DisplayMatcher {
    public func matches(_ display: DisplayInfo) -> Bool {
        if let builtin, builtin != display.isBuiltin { return false }
        if let serial, serial != display.serial { return false }
        if let rotation, rotation != Int(display.rotation.rounded()) { return false }
        if let name, Self.baseName(name).caseInsensitiveCompare(Self.baseName(display.name)) != .orderedSame {
            return false
        }
        return true
    }

    /// macOS names identical monitors "DELL S2722QC (1)" and "DELL S2722QC (2)", and
    /// the numbers can swap between connections, so they're ignored.
    static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
    }
}

/// A profile that fits the connected displays, and which display plays each role.
public struct ProfileMatch: Equatable, Sendable {
    public let profile: DisplayProfile
    /// Role -> display.
    public let roles: [String: CGDirectDisplayID]

    public func role(of display: CGDirectDisplayID) -> String? {
        roles.first { $0.value == display }?.key
    }
}

public enum ProfileMatching {
    /// The first profile, in config order, with exactly as many roles as there are
    /// displays and every role matched to a different display.
    public static func activeProfile(_ profiles: [DisplayProfile], displays: [DisplayInfo]) -> ProfileMatch? {
        for profile in profiles where profile.displays.count == displays.count {
            if let roles = assignRoles(profile, displays: displays) {
                return ProfileMatch(profile: profile, roles: roles)
            }
        }
        return nil
    }

    /// Every role matched to a different display, or nil if that's impossible.
    /// Displays left over are ignored, which is what a manual override wants.
    public static func assignRoles(_ profile: DisplayProfile, displays: [DisplayInfo]) -> [String: CGDirectDisplayID]? {
        // Most constrained role first, then by name, so the result is deterministic.
        let candidates = profile.displays
            .map { role, matcher in (role: role, ids: displays.filter(matcher.matches).map(\.id)) }
            .sorted { ($0.ids.count, $0.role) < ($1.ids.count, $1.role) }
        var roles: [String: CGDirectDisplayID] = [:]
        var used: Set<CGDirectDisplayID> = []
        func assign(_ index: Int) -> Bool {
            guard index < candidates.count else { return true }
            let candidate = candidates[index]
            for id in candidate.ids where !used.contains(id) {
                roles[candidate.role] = id
                used.insert(id)
                if assign(index + 1) { return true }
                roles[candidate.role] = nil
                used.remove(id)
            }
            return false
        }
        return assign(0) ? roles : nil
    }
}

extension ProfileMatching {
    /// The profile picked from the menu, if every one of its roles still has a display.
    /// Displays it has no role for are ignored.
    public static func overrideMatch(_ id: String, profiles: [DisplayProfile], displays: [DisplayInfo]) -> ProfileMatch? {
        guard let profile = profiles.first(where: { $0.id == id }),
              let roles = assignRoles(profile, displays: displays) else { return nil }
        return ProfileMatch(profile: profile, roles: roles)
    }

    /// Why `profile` can't be assigned to `displays`, for error messages.
    public static func whyUnassignable(_ profile: DisplayProfile, displays: [DisplayInfo]) -> String {
        let missing = profile.displays.filter { _, matcher in !displays.contains(where: matcher.matches) }.keys.sorted()
        if missing.isEmpty { return "two of its roles need the same display" }
        return "no display connected for \(list(missing.map { "'\($0)'" }, or: false))"
    }
}

/// "Copy current displays as profile JSON": a profile for the connected displays,
/// ready to paste into "profiles".
public enum ProfileSkeleton {
    /// Roles are "laptop" for the built-in display and the monitor's name otherwise,
    /// left to right. Identical monitors are told apart by serial (or by rotation when
    /// they report no serial).
    public static func json(for displays: [DisplayInfo], id: String = "new-profile") -> String {
        let ordered = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        func base(_ display: DisplayInfo) -> String { DisplayMatcher.baseName(display.name) }
        var seen: [String: Int] = [:]
        let lines = ordered.map { display -> String in
            if display.isBuiltin { return "\(ConfigFormat.string("laptop")): { \"builtin\": true }" }
            let name = base(display)
            let twins = ordered.filter { !$0.isBuiltin && base($0) == name }
            var role = slug(name)
            var fields = ["\"name\": \(ConfigFormat.string(name))"]
            if twins.count > 1 {
                seen[name, default: 0] += 1
                role += "-\(seen[name]!)"
                if display.serial != 0 {
                    fields.append("\"serial\": \(display.serial)")
                } else {
                    fields.append("\"rotation\": \(Int(display.rotation.rounded()))")
                }
            }
            return "\(ConfigFormat.string(role)): { " + fields.joined(separator: ", ") + " }"
        }
        return "{ \"id\": \(ConfigFormat.string(id)), \"displays\": {\n"
            + lines.map { "    " + $0 }.joined(separator: ",\n") + " } }"
    }

    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "display" : words.joined(separator: "-")
    }
}
