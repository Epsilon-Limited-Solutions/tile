import Foundation

/// Checks that need the whole file: ids that must be unique, references that must
/// resolve, bindings that would shadow each other. Collects every problem rather than
/// stopping at the first, so one reload shows everything to fix.
extension Config {
    func validationIssues() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        func flag(_ path: String, _ message: String) {
            issues.append(ConfigIssue(path: path, message: message))
        }
        func flagDuplicateIDs(_ ids: [String], in section: String) {
            var first: [String: Int] = [:]
            for (index, id) in ids.enumerated() {
                if let earlier = first[id] {
                    flag("\(section)[\(index)].id", "'\(id)' is already the id of \(section)[\(earlier)]")
                } else {
                    first[id] = index
                }
            }
        }
        flagDuplicateIDs(layouts.map(\.id), in: "layouts")
        flagDuplicateIDs(profiles.map(\.id), in: "profiles")
        flagDuplicateIDs(arrangements.map(\.id), in: "arrangements")

        let layoutIDs = Set(layouts.map(\.id))
        let profilesByID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let arrangementsByID = Dictionary(arrangements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allRoles = Set(profiles.flatMap(\.displays.keys))

        func checkLayout(_ id: String, _ path: String) {
            if !layoutIDs.contains(id) { flag(path, "no layout has id '\(id)'") }
        }
        func checkRole(_ role: String, in profile: DisplayProfile, _ path: String) {
            if profile.displays[role] == nil {
                flag(path, "profile '\(profile.id)' has no display '\(role)'; it has \(list(profile.displays.keys.sorted(), or: false))")
            }
        }

        for (index, profile) in profiles.enumerated() {
            guard let id = profile.onActivate else { continue }
            if let arrangement = arrangementsByID[id] {
                if arrangement.profile != profile.id {
                    flag("profiles[\(index)].onActivate", "arrangement '\(id)' is for profile '\(arrangement.profile)'")
                }
            } else {
                flag("profiles[\(index)].onActivate", "no arrangement has id '\(id)'")
            }
        }

        var scopes: [BindingScope: Int] = [:]
        for (index, binding) in bindings.enumerated() {
            let path = "bindings[\(index)]"
            switch binding.target {
            case .layout(let id):
                checkLayout(id, "\(path).layout")
            case .cycle(let ids):
                for (position, id) in ids.enumerated() { checkLayout(id, "\(path).cycle[\(position)]") }
            case .arrange(let id):
                if arrangementsByID[id] == nil { flag("\(path).arrange", "no arrangement has id '\(id)'") }
            case .action:
                break
            }

            if let profileID = binding.when.profile {
                if let profile = profilesByID[profileID] {
                    if let role = binding.when.display { checkRole(role, in: profile, "\(path).when.display") }
                } else {
                    flag("\(path).when.profile", "no profile has id '\(profileID)'")
                }
            } else if let role = binding.when.display, !allRoles.contains(role) {
                flag("\(path).when.display", "no profile has a display '\(role)'")
            }

            let scope = BindingScope(keys: binding.keys, when: binding.when)
            if let earlier = scopes[scope] {
                flag(path, "same keys (\(binding.keys)) and same when as bindings[\(earlier)], so one of them could never fire")
            } else {
                scopes[scope] = index
            }
        }

        for (index, arrangement) in arrangements.enumerated() {
            let path = "arrangements[\(index)]"
            let profile = profilesByID[arrangement.profile]
            if profile == nil { flag("\(path).profile", "no profile has id '\(arrangement.profile)'") }

            var seen: [String: Int] = [:]
            for (position, placement) in arrangement.desktops.enumerated() {
                let placementPath = "\(path).desktops[\(position)]"
                if let profile { checkRole(placement.display, in: profile, "\(placementPath).display") }
                let key = "\(placement.display) \(placement.desktop)"
                if let earlier = seen[key] {
                    flag(placementPath, "\(placement.display) desktop \(placement.desktop) is already listed at desktops[\(earlier)]; merge them")
                } else {
                    seen[key] = position
                }
                for (windowIndex, window) in placement.windows.enumerated() {
                    let windowPath = "\(placementPath).windows[\(windowIndex)]"
                    if case .named(let id) = window.layout { checkLayout(id, "\(windowPath).layout") }
                    if let title = window.title, (try? NSRegularExpression(pattern: title)) == nil {
                        flag("\(windowPath).title", "'\(title)' is not a valid regular expression")
                    }
                }
            }
            if let profile {
                for role in arrangement.endOn.keys.sorted() { checkRole(role, in: profile, "\(path).endOn.\(role)") }
            }
        }
        return issues
    }
}

/// Two bindings with equal keys and equal `when` both match in exactly the same
/// places at the same specificity, so the later one could never win.
private struct BindingScope: Hashable {
    let keys: KeyCombo
    let when: KeyBinding.Condition
}
