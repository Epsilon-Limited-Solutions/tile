import CoreGraphics
import Testing
@testable import TileCore

struct BindingTests {
    /// One combo bound six ways, from no `when` up to display + orientation + profile.
    static let json = """
    {
      "profiles": [
        { "id": "laptop", "displays": { "laptop": { "builtin": true } } },
        { "id": "desk", "displays": {
            "laptop": { "builtin": true },
            "vertical-left": { "serial": 810894658 },
            "vertical-right": { "serial": 825446978 } } }
      ],
      "layouts": [
        { "id": "a", "rect": [0, 0, 1, 1] }, { "id": "b", "rect": [0, 0, 1, 1] },
        { "id": "c", "rect": [0, 0, 1, 1] }, { "id": "d", "rect": [0, 0, 1, 1] },
        { "id": "e", "rect": [0, 0, 1, 1] }, { "id": "f", "rect": [0, 0, 1, 1] }
      ],
      "bindings": [
        { "keys": "ctrl+opt+left", "layout": "a" },
        { "keys": "ctrl+opt+left", "when": { "profile": "desk" }, "layout": "b" },
        { "keys": "ctrl+opt+left", "when": { "orientation": "portrait" }, "layout": "c" },
        { "keys": "ctrl+opt+left", "when": { "display": "vertical-left" }, "layout": "d" },
        { "keys": "ctrl+opt+left", "when": { "display": "vertical-right", "orientation": "landscape" }, "layout": "e" },
        { "keys": "ctrl+opt+left", "when": { "profile": "desk", "orientation": "landscape" }, "layout": "f" },
        { "keys": "ctrl+opt+right", "when": { "profile": "desk" }, "layout": "a" },
        { "keys": "hyper+w", "action": "restore" }
      ]
    }
    """

    let table: BindingTable
    let left = try! KeyCombo(parsing: "ctrl+opt+left")
    let right = try! KeyCombo(parsing: "ctrl+opt+right")

    init() throws {
        table = BindingTable(try Fixtures.config(Self.json).bindings)
    }

    func resolved(_ combo: KeyCombo, profile: String? = nil, display: String? = nil,
                  orientation: Orientation? = nil) -> String? {
        guard let binding = table.resolve(combo, in: BindingContext(profile: profile, display: display, orientation: orientation))
        else { return nil }
        switch binding.target {
        case .layout(let id): return id
        default: return "\(binding.target)"
        }
    }

    @Test func eachComboIsListedOnceInConfigOrder() throws {
        #expect(table.combos == [left, right, try KeyCombo(parsing: "hyper+w")])
    }

    @Test func noWhenIsTheFallback() {
        #expect(resolved(left) == "a")
        #expect(resolved(left, profile: "laptop", display: "laptop", orientation: .landscape) == "a")
    }

    @Test func profileBeatsNothing() {
        #expect(resolved(left, profile: "desk") == "b")
    }

    @Test func orientationBeatsProfile() {
        #expect(resolved(left, profile: "desk", orientation: .portrait) == "c")
        #expect(resolved(left, profile: "laptop", orientation: .portrait) == "c")
    }

    @Test func displayBeatsOrientation() {
        #expect(resolved(left, profile: "desk", display: "vertical-left", orientation: .portrait) == "d")
    }

    @Test func combinedConditionsRankByTheirStrongestField() {
        // display + orientation (6) beats profile + orientation (3).
        #expect(resolved(left, profile: "desk", display: "vertical-right", orientation: .landscape) == "e")
        // profile + orientation (3) beats orientation-free profile (1).
        #expect(resolved(left, profile: "desk", display: "laptop", orientation: .landscape) == "f")
        // vertical-right in portrait: e needs landscape, so the orientation binding wins.
        #expect(resolved(left, profile: "desk", display: "vertical-right", orientation: .portrait) == "c")
    }

    @Test func noMatchingBindingResolvesToNil() {
        #expect(resolved(right) == nil)
        #expect(resolved(right, profile: "laptop") == nil)
        #expect(resolved(right, profile: "desk") == "a")
        #expect(resolved(try! KeyCombo(parsing: "ctrl+opt+up")) == nil)
    }

    @Test func noFocusedWindowOnlyMatchesBindingsThatDontNeedOne() {
        // display and orientation are nil without a focused window.
        #expect(resolved(left, profile: "desk") == "b")
    }

    @Test func defaultConfigFlipsArrowsOnPortraitDisplays() throws {
        let table = BindingTable(try Fixtures.config(Config.defaultJSON).bindings)
        let landscape = table.resolve(left, in: BindingContext(profile: "desk", display: "laptop", orientation: .landscape))
        let portrait = table.resolve(left, in: BindingContext(profile: "desk", display: "vertical-left", orientation: .portrait))
        #expect(landscape?.target == .cycle(["left-half", "left-third", "left-two-thirds"]))
        #expect(portrait?.target == .cycle(["top-half", "top-third", "top-two-thirds"]))
    }
}

struct CycleTests {
    let frame = CGRect(x: 0, y: 33, width: 756, height: 868)

    @Test func firstPressStartsAtTheFirstEntry() {
        #expect(Cycle.nextIndex(count: 3, last: nil, current: frame) == 0)
    }

    @Test func advancesWhileTheWindowStaysPut() {
        #expect(Cycle.nextIndex(count: 3, last: (0, frame), current: frame) == 1)
        #expect(Cycle.nextIndex(count: 3, last: (1, frame), current: frame) == 2)
        #expect(Cycle.nextIndex(count: 3, last: (2, frame), current: frame) == 0)
    }

    @Test func toleratesSmallDrift() {
        #expect(Cycle.nextIndex(count: 3, last: (0, frame), current: frame.offsetBy(dx: 3, dy: -4)) == 1)
        #expect(Cycle.nextIndex(count: 3, last: (0, frame), current: frame.insetBy(dx: 2, dy: 0)) == 1)
    }

    @Test func startsOverOnceTheWindowMoved() {
        #expect(Cycle.nextIndex(count: 3, last: (1, frame), current: frame.offsetBy(dx: 5, dy: 0)) == 0)
        #expect(Cycle.nextIndex(count: 3, last: (1, frame), current: CGRect(x: 756, y: 33, width: 756, height: 868)) == 0)
    }

    @Test func startsOverIfTheCycleGotShorter() {
        #expect(Cycle.nextIndex(count: 2, last: (2, frame), current: frame) == 0)
    }
}
