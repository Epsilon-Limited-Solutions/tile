import CoreGraphics

/// What a keypress is resolved against: the active profile, plus the role and
/// orientation of the display the focused window is on (nil when there's no window).
public struct BindingContext: Equatable, Sendable {
    public var profile: String?
    public var display: String?
    public var orientation: Orientation?

    public init(profile: String? = nil, display: String? = nil, orientation: Orientation? = nil) {
        self.profile = profile
        self.display = display
        self.orientation = orientation
    }
}

extension KeyBinding.Condition {
    /// Among bindings that share keys and match, the highest wins. Display role
    /// outranks orientation, which outranks profile, which outranks no `when`.
    var specificity: Int {
        (display != nil ? 4 : 0) + (orientation != nil ? 2 : 0) + (profile != nil ? 1 : 0)
    }

    func matches(_ context: BindingContext) -> Bool {
        (profile == nil || profile == context.profile)
            && (display == nil || display == context.display)
            && (orientation == nil || orientation == context.orientation)
    }
}

/// Bindings grouped by key combo. Each combo is registered as a hotkey once; which
/// binding it triggers is decided at press time.
public struct BindingTable: Sendable {
    /// Every distinct combo, in config order.
    public let combos: [KeyCombo]
    private let bindingsByCombo: [KeyCombo: [KeyBinding]]

    public init(_ bindings: [KeyBinding]) {
        var combos: [KeyCombo] = []
        var grouped: [KeyCombo: [KeyBinding]] = [:]
        for binding in bindings {
            if grouped[binding.keys] == nil { combos.append(binding.keys) }
            grouped[binding.keys, default: []].append(binding)
        }
        self.combos = combos
        bindingsByCombo = grouped
    }

    /// The most specific binding for `combo` that matches `context`, or nil.
    /// Validation guarantees no two matching bindings tie.
    public func resolve(_ combo: KeyCombo, in context: BindingContext) -> KeyBinding? {
        bindingsByCombo[combo]?
            .filter { $0.when.matches(context) }
            .max { $0.when.specificity < $1.when.specificity }
    }
}

public enum Cycle {
    /// Frames within this many points count as unchanged.
    public static let tolerance: CGFloat = 4

    /// Which entry of a `count`-long cycle to apply now. `last` is the entry the
    /// previous press applied to this window and the frame it ended up with. The
    /// cycle advances only while the window still has that frame; once it has moved,
    /// a press starts over at the first entry.
    public static func nextIndex(count: Int, last: (index: Int, frame: CGRect)?, current: CGRect) -> Int {
        guard let last, last.index < count, current.isClose(to: last.frame, within: tolerance) else { return 0 }
        return (last.index + 1) % count
    }
}
