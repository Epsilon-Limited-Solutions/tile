import CoreGraphics
import Foundation
import Testing
@testable import TileCore

struct DesktopNumberingTests {
    // This machine docked: 5 + 2 + 3 desktops, in SkyLight order.
    let desk = DesktopNumbering([.init(role: "laptop", desktops: 5),
                                 .init(role: "vertical-right", desktops: 2),
                                 .init(role: "vertical-left", desktops: 3)])

    @Test func numbersFollowSkyLightOrder() {
        #expect(desk.number(of: DesktopRef(role: "laptop", index: 1)) == 1)
        #expect(desk.number(of: DesktopRef(role: "laptop", index: 5)) == 5)
        #expect(desk.number(of: DesktopRef(role: "vertical-right", index: 2)) == 7)
        #expect(desk.number(of: DesktopRef(role: "vertical-left", index: 1)) == 8)
        #expect(desk.number(of: DesktopRef(role: "vertical-left", index: 3)) == 10)
    }

    @Test func outOfRangeOrUnknownIsNil() {
        #expect(desk.number(of: DesktopRef(role: "vertical-right", index: 3)) == nil)
        #expect(desk.number(of: DesktopRef(role: "laptop", index: 0)) == nil)
        #expect(desk.number(of: DesktopRef(role: "nope", index: 1)) == nil)
        #expect(DesktopNumbering([.init(role: "a", desktops: 0)]).number(of: DesktopRef(role: "a", index: 1)) == nil)
    }

    @Test func displaysWithoutARoleStillCount() {
        let numbering = DesktopNumbering([.init(role: nil, desktops: 4), .init(role: "laptop", desktops: 2)])
        #expect(numbering.number(of: DesktopRef(role: "laptop", index: 1)) == 5)
    }
}

struct ArrangementCheckTests {
    let numbering = DesktopNumbering([.init(role: "laptop", desktops: 5),
                                      .init(role: "vertical-right", desktops: 2),
                                      .init(role: "vertical-left", desktops: 3)])

    func arrangement(_ desktops: [(String, Int)], endOn: [String: Int] = [:]) -> Arrangement {
        Arrangement(id: "work", profile: "desk", endOn: endOn,
                    desktops: desktops.map { DesktopPlacement(display: $0.0, desktop: $0.1, windows: []) })
    }

    @Test func runnable() {
        #expect(ArrangementCheck.problems(arrangement([("laptop", 1), ("vertical-left", 3)]),
                                          numbering: numbering, shortcutEnabled: { _ in true }).isEmpty)
    }

    @Test func tooFewDesktopsSaysHowManyToAdd() {
        let problems = ArrangementCheck.problems(arrangement([("vertical-right", 3)], endOn: ["laptop": 7]),
                                                 numbering: numbering, shortcutEnabled: { _ in true })
        #expect(problems == ["laptop needs 7 desktops, has 5: add 2 in Mission Control",
                             "vertical-right needs 3 desktops, has 2: add one in Mission Control"])
    }

    @Test func missingRole() {
        let problems = ArrangementCheck.problems(arrangement([("tv", 1)]), numbering: numbering, shortcutEnabled: { _ in true })
        #expect(problems == ["no display is playing 'tv'"])
    }

    @Test func everyTargetAndEndOnDesktopNeedsItsShortcut() {
        let problems = ArrangementCheck.problems(arrangement([("vertical-left", 2), ("laptop", 1)], endOn: ["vertical-right": 1]),
                                                 numbering: numbering, shortcutEnabled: { $0 != 9 && $0 != 6 })
        #expect(problems == [
            "vertical-left desktop 2 is Desktop 9, and its shortcut is off: turn on System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Switch to Desktop 9",
            "vertical-right desktop 1 is Desktop 6, and its shortcut is off: turn on System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Switch to Desktop 6",
        ])
    }

    @Test func desktopsPastSixteenHaveNoShortcut() {
        let big = DesktopNumbering([.init(role: "laptop", desktops: 16), .init(role: "tv", desktops: 2)])
        let problems = ArrangementCheck.problems(arrangement([("tv", 1)]), numbering: big, shortcutEnabled: { _ in true })
        #expect(problems == ["tv desktop 1 is Desktop 17, and macOS only has shortcuts up to Desktop 16"])
    }
}

struct WindowMatchingTests {
    let target = DesktopRef(role: "vertical-right", index: 2)
    let elsewhere = DesktopRef(role: "laptop", index: 1)
    let frame = CGRect(x: 1522, y: 10, width: 1420, height: 1255)

    func window(_ id: UInt32, _ app: String = "com.tinyspeck.slackmacgap", on desktop: DesktopRef?,
                frame: CGRect = .init(x: 0, y: 0, width: 800, height: 600), title: String? = nil,
                visible: Bool = false) -> WindowState {
        WindowState(id: id, app: app, desktop: desktop, frame: frame, title: title, visible: visible)
    }

    func choose(_ placement: WindowPlacement, _ windows: [WindowState], claimed: Set<UInt32> = []) -> WindowChoice {
        WindowMatching.choose(placement, target: target, among: windows, claimed: claimed) {
            $0.desktop == target && $0.frame == frame
        }
    }

    let slack = WindowPlacement(app: "com.tinyspeck.slackmacgap", layout: .named("top-half"))
    let code = WindowPlacement(app: "com.microsoft.VSCode", title: "^epsilon", layout: .named("full"))

    @Test func noWindowMeansOpen() {
        #expect(choose(slack, []) == .open)
        #expect(choose(slack, [window(1, "com.apple.Safari", on: target)]) == .open)
    }

    @Test func prefersInPlaceThenTargetDesktopThenVisibleThenAny() {
        let any = window(1, on: elsewhere)
        let visible = window(2, on: elsewhere, visible: true)
        let onTarget = window(3, on: target)
        let inPlace = window(4, on: target, frame: frame)
        #expect(choose(slack, [any, visible, onTarget, inPlace]) == .window(4))
        #expect(choose(slack, [any, visible, onTarget]) == .window(3))
        #expect(choose(slack, [any, visible]) == .window(2))
        #expect(choose(slack, [any]) == .window(1))
    }

    @Test func neverTakesAClaimedWindow() {
        #expect(choose(slack, [window(1, on: target, frame: frame)], claimed: [1]) == .open)
    }

    @Test func titleMustMatchWhenKnown() {
        let other = window(1, "com.microsoft.VSCode", on: target, frame: frame, title: "mosaic-clone — Code", visible: true)
        let mine = window(2, "com.microsoft.VSCode", on: elsewhere, title: "epsilon — Code", visible: true)
        #expect(choose(code, [other, mine]) == .window(2))
        #expect(choose(code, [other]) == .open)
    }

    @Test func unknownTitlesMeanVisitTheirDesktops() {
        let hidden1 = window(1, "com.microsoft.VSCode", on: elsewhere)
        let hidden2 = window(2, "com.microsoft.VSCode", on: DesktopRef(role: "laptop", index: 3))
        let hidden3 = window(3, "com.microsoft.VSCode", on: elsewhere)
        let nowhere = window(4, "com.microsoft.VSCode", on: nil)
        #expect(choose(code, [hidden1, hidden2, hidden3, nowhere])
                == .needsTitles([elsewhere, DesktopRef(role: "laptop", index: 3)]))
        #expect(choose(code, [nowhere]) == .open)
    }

    @Test func unknownTitleAlreadyInPlaceIsTrusted() {
        // Second run: the window placed last time sits on a hidden desktop, title unreadable.
        let placed = window(1, "com.microsoft.VSCode", on: target, frame: frame)
        let hidden = window(2, "com.microsoft.VSCode", on: elsewhere)
        #expect(choose(code, [hidden, placed]) == .window(1))
    }
}

struct CaptureBuilderTests {
    let visible = CGRect(x: 1512, y: 0, width: 1440, height: 2530)

    @Test func framesBecomeRoundedFractions() {
        let placements = CaptureBuilder.placements(
            [CapturedWindow(app: "com.apple.Safari", title: "Apple", frame: CGRect(x: 1522, y: 10, width: 1420, height: 1255))],
            visibleFrame: visible, gaps: Gaps(), appsWithSeveralWindows: [])
        #expect(placements == [WindowPlacement(app: "com.apple.Safari", layout: .rect(CGRect(x: 0.007, y: 0.004, width: 0.986, height: 0.496)))])
    }

    /// Capture then arrange must put a window back where it was, gaps and all, or every
    /// run would nudge it. Within 2pt: 0.001 of a 2530pt-tall display is 2.5pt, and the
    /// Arranger counts anything within 4pt as in place.
    @Test(arguments: [Gaps(), Gaps(outer: 10, inner: 10), Gaps(outer: 32, inner: 16)])
    func captureUndoesTheGaps(gaps: Gaps) throws {
        let layouts = try Fixtures.config(Config.defaultJSON).layouts.filter { $0.shape != .center }
        for display in [Fixtures.laptop, Fixtures.verticalLeft] {
            let visible = ScreenGeometry(displays: Fixtures.desk).axVisibleFrame(of: display)
            for layout in layouts {
                let placed = LayoutEngine.frame(for: layout.shape, in: visible, gaps: gaps)
                let captured = CaptureBuilder.placements([CapturedWindow(app: "a", title: nil, frame: placed)],
                                                         visibleFrame: visible, gaps: gaps, appsWithSeveralWindows: [])
                guard case .rect(let rect) = try #require(captured.first).layout else { Issue.record("not a rect"); continue }
                let replayed = LayoutEngine.frame(for: .rect(rect), in: visible, gaps: gaps)
                #expect(replayed.isClose(to: placed, within: 2), "\(layout.id) on \(display.name): \(placed) -> \(rect) -> \(replayed)")
            }
        }
    }

    @Test func windowsHangingOffTheScreenAreClipped() {
        let placements = CaptureBuilder.placements(
            [CapturedWindow(app: "a", title: nil, frame: CGRect(x: 1400, y: -50, width: 832, height: 3000)),
             CapturedWindow(app: "b", title: nil, frame: CGRect(x: 0, y: 0, width: 100, height: 100))],
            visibleFrame: visible, gaps: Gaps(), appsWithSeveralWindows: [])
        #expect(placements == [WindowPlacement(app: "a", layout: .rect(CGRect(x: 0, y: 0, width: 0.5, height: 1)))])
    }

    @Test func titlesOnlyForAppsWithSeveralWindows() {
        let windows = [CapturedWindow(app: "code", title: "epsilon (main) — Code", frame: visible),
                       CapturedWindow(app: "safari", title: "Apple", frame: visible)]
        let placements = CaptureBuilder.placements(windows, visibleFrame: visible, gaps: Gaps(), appsWithSeveralWindows: ["code"])
        #expect(placements.map(\.title) == [#"^epsilon \(main\) — Code$"#, nil])
        // The pattern matches the title it came from.
        let regex = try! NSRegularExpression(pattern: placements[0].title!)
        let title = "epsilon (main) — Code"
        #expect(regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil)
    }

    @Test func mergeReplacesRecapturedDesktopsAndKeepsTheRest() throws {
        let safari = WindowPlacement(app: "safari", layout: .named("full"))
        let slack = WindowPlacement(app: "slack", layout: .named("full"))
        let existing = [Arrangement(id: "work", profile: "desk", endOn: ["laptop": 1], desktops: [
            DesktopPlacement(display: "laptop", desktop: 1, windows: [safari]),
            DesktopPlacement(display: "laptop", desktop: 2, windows: [safari]),
        ])]
        let merged = try CaptureBuilder.merge([DesktopPlacement(display: "laptop", desktop: 2, windows: [slack]),
                                               DesktopPlacement(display: "vertical-left", desktop: 1, windows: [slack])],
                                              into: existing, id: "work", profile: "desk")
        #expect(merged == [Arrangement(id: "work", profile: "desk", endOn: ["laptop": 1], desktops: [
            DesktopPlacement(display: "laptop", desktop: 1, windows: [safari]),
            DesktopPlacement(display: "laptop", desktop: 2, windows: [slack]),
            DesktopPlacement(display: "vertical-left", desktop: 1, windows: [slack]),
        ])])
    }

    @Test func newNameMakesANewArrangement() throws {
        let captured = [DesktopPlacement(display: "laptop", desktop: 1, windows: [])]
        let merged = try CaptureBuilder.merge(captured, into: [], id: "solo", profile: "laptop")
        #expect(merged == [Arrangement(id: "solo", profile: "laptop", desktops: captured)])
    }

    @Test func refusesToMergeAcrossProfiles() {
        let existing = [Arrangement(id: "work", profile: "desk", desktops: [])]
        #expect(throws: CaptureBuilder.Conflict.self) {
            try CaptureBuilder.merge([], into: existing, id: "work", profile: "laptop")
        }
    }
}
