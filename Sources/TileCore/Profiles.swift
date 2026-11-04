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
