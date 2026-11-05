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

    let on: (Int) -> Bool = { _ in true }

    @Test func runnable() {
        let work = arrangement([("laptop", 1), ("vertical-left", 3)])
        #expect(ArrangementCheck.missingDesktops(work, numbering: numbering).isEmpty)
        #expect(ArrangementCheck.unreachable(work, numbering: numbering, shortcutEnabled: on).isEmpty)
    }

    @Test func missingDesktopsCountsWhatEachRoleIsShort() {
        let work = arrangement([("vertical-right", 3), ("vertical-left", 2)], endOn: ["laptop": 7])
        #expect(ArrangementCheck.missingDesktops(work, numbering: numbering) == ["laptop": 2, "vertical-right": 1])
    }

    @Test func desktopsThatDontExistAreUnreachable() {
        let work = arrangement([("vertical-right", 3), ("laptop", 1)], endOn: ["laptop": 7])
        #expect(ArrangementCheck.unreachable(work, numbering: numbering, shortcutEnabled: on) == [
            DesktopRef(role: "vertical-right", index: 3): "vertical-right has 2 desktops: add one in Mission Control",
            DesktopRef(role: "laptop", index: 7): "laptop has 5 desktops: add 2 in Mission Control",
        ])
    }

    @Test func missingRole() {
        #expect(ArrangementCheck.unreachable(arrangement([("tv", 1)]), numbering: numbering, shortcutEnabled: on)
                == [DesktopRef(role: "tv", index: 1): "no display is playing 'tv'"])
        #expect(ArrangementCheck.missingDesktops(arrangement([("tv", 1)]), numbering: numbering).isEmpty)
    }

    @Test func everyTargetAndEndOnDesktopNeedsItsShortcut() {
        let unreachable = ArrangementCheck.unreachable(arrangement([("vertical-left", 2), ("laptop", 1)], endOn: ["vertical-right": 1]),
                                                       numbering: numbering, shortcutEnabled: { $0 != 9 && $0 != 6 })
        #expect(unreachable == [
            DesktopRef(role: "vertical-left", index: 2): "it's Desktop 9, and its shortcut is off: turn on System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Switch to Desktop 9",
            DesktopRef(role: "vertical-right", index: 1): "it's Desktop 6, and its shortcut is off: turn on System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Switch to Desktop 6",
        ])
    }

    @Test func desktopsPastSixteenHaveNoShortcut() {
        let big = DesktopNumbering([.init(role: "laptop", desktops: 16), .init(role: "tv", desktops: 2)])
        #expect(ArrangementCheck.unreachable(arrangement([("tv", 1)]), numbering: big, shortcutEnabled: on)
                == [DesktopRef(role: "tv", index: 1): "it's Desktop 17, and macOS only has shortcuts up to Desktop 16"])
    }
}

struct OpenTargetTests {
    let home = "/Users/tom"
    func target(_ item: String, folder: Bool) -> OpenTarget? {
        OpenTarget(item: item, home: home, isFolder: { _ in folder })
    }

    @Test func pathsAreExpandedAndStandardized() {
        #expect(target("~/epsilon/tile/", folder: true)?.path == "/Users/tom/epsilon/tile")
        #expect(target("~/epsilon/tile", folder: true)?.tildePath == "~/epsilon/tile")
        #expect(target("file:///Users/tom/notes.txt", folder: false)?.path == "/Users/tom/notes.txt")
        #expect(target("/tmp/../tmp/x", folder: true)?.path == "/tmp/x")
        #expect(target("~", folder: true)?.tildePath == "~")
    }

    @Test func webAndRelativeItemsAreNeverRecognised() {
        #expect(target("https://example.com", folder: false) == nil)
        #expect(target("notes.txt", folder: false) == nil)
    }

    @Test func folderMatchesDocumentInsideItOrItsNameInTheTitle() {
        let tile = target("~/epsilon/applications/tile", folder: true)!
        // VS Code: AXDocument is the active file, the title names the workspace folder.
        #expect(tile.matches(document: "/Users/tom/epsilon/applications/tile/Sources/Tile/Arranger.swift",
                             title: "Arranger.swift — tile"))
        #expect(tile.matches(document: nil, title: "Welcome — tile"))
        // A file from elsewhere open in the tile window: the title still says tile.
        #expect(tile.matches(document: "/Users/tom/.config/tile/config.json", title: "config.json — tile"))
        // Warp and other terminals: the directory in the title.
        #expect(tile.matches(document: nil, title: "~/epsilon/applications/tile"))
        #expect(!tile.matches(document: "/Users/tom/epsilon/applications/momentum/App.swift", title: "App.swift — momentum"))
        #expect(!tile.matches(document: nil, title: "tiles — Code"))
        // Not a prefix of a sibling folder.
        #expect(!tile.matches(document: "/Users/tom/epsilon/applications/tile-old/x.swift", title: "x.swift — tile-old"))
    }

    @Test func fileMatchesItsDocumentOrItsNameWhenTheWindowDoesntSay() {
        let notes = target("/Users/tom/notes.txt", folder: false)!
        #expect(notes.matches(document: "/Users/tom/notes.txt", title: "anything"))
        #expect(notes.matches(document: nil, title: "notes.txt"))
        #expect(!notes.matches(document: "/Users/tom/old/notes.txt", title: "notes.txt"))
    }

    @Test func titleSegmentsSplitOnTheUsualSeparators() {
        #expect(OpenTarget.titleSegments("a.swift — tile — Visual Studio Code")
                == ["a.swift — tile — Visual Studio Code", "a.swift", "tile", "Visual Studio Code"])
        #expect(OpenTarget.titleSegments("~/src - zsh") == ["~/src - zsh", "~/src", "zsh"])
        #expect(OpenTarget.titleSegments("plain") == ["plain"])
        #expect(OpenTarget.titleSegments("") == [])
    }
}

struct WindowMatchingTests {
    let target = DesktopRef(role: "vertical-right", index: 2)
    let elsewhere = DesktopRef(role: "laptop", index: 1)
    let frame = CGRect(x: 1522, y: 10, width: 1420, height: 1255)

    func window(_ id: UInt32, _ app: String = "com.tinyspeck.slackmacgap", on desktop: DesktopRef?,
                frame: CGRect = .init(x: 0, y: 0, width: 800, height: 600), title: String? = nil,
                document: String? = nil, visible: Bool = false) -> WindowState {
        WindowState(id: id, app: app, desktop: desktop, frame: frame, title: title, document: document, visible: visible)
    }

    func choose(_ placement: WindowPlacement, _ windows: [WindowState], claimed: Set<UInt32> = []) -> WindowChoice {
        let opens = placement.open.compactMap { OpenTarget(item: $0, home: "/Users/tom", isFolder: { !$0.hasSuffix(".txt") }) }
        return WindowMatching.choose(placement, opens: opens, target: target, among: windows, claimed: claimed) {
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

    let tile = WindowPlacement(app: "com.microsoft.VSCode", layout: .named("full"), open: ["~/src/tile"])

    @Test func openPlacementTakesTheWindowShowingIt() {
        let momentum = window(1, "com.microsoft.VSCode", on: target, frame: frame, title: "App.swift — momentum",
                              document: "/Users/tom/src/momentum/App.swift", visible: true)
        let mine = window(2, "com.microsoft.VSCode", on: elsewhere, title: "Arranger.swift — tile",
                          document: "/Users/tom/src/tile/Arranger.swift", visible: true)
        #expect(choose(tile, [momentum, mine]) == .window(2))
        #expect(choose(tile, [momentum]) == .open)
    }

    @Test func openPlacementWithHiddenWindowsVisitsTheirDesktops() {
        let hidden = window(1, "com.microsoft.VSCode", on: elsewhere)
        #expect(choose(tile, [hidden]) == .needsTitles([elsewhere]))
    }

    @Test func webPagesInOpenDontNameAWindow() {
        // Nothing to recognise it by: any window of the app does.
        let page = WindowPlacement(app: "com.apple.Safari", layout: .named("full"), open: ["https://example.com"])
        #expect(choose(page, [window(1, "com.apple.Safari", on: elsewhere, title: "Example", visible: true)]) == .window(1))
    }

    @Test func titleAndOpenMustBothMatch() {
        let both = WindowPlacement(app: "com.microsoft.VSCode", title: "^Arr", layout: .named("full"), open: ["~/src/tile"])
        let wrongTitle = window(1, "com.microsoft.VSCode", on: target, title: "Main.swift — tile",
                                document: "/Users/tom/src/tile/Main.swift", visible: true)
        let right = window(2, "com.microsoft.VSCode", on: elsewhere, title: "Arranger.swift — tile",
                           document: "/Users/tom/src/tile/Arranger.swift", visible: true)
        #expect(choose(both, [wrongTitle, right]) == .window(2))
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

    @Test func aWindowThatKnowsItsFolderOpensItInsteadOfATitle() {
        let windows = [CapturedWindow(app: "code", title: "Arranger.swift — tile", frame: visible, open: "/Users/tom/src/tile"),
                       CapturedWindow(app: "code", title: "Welcome", frame: visible)]
        let placements = CaptureBuilder.placements(windows, visibleFrame: visible, gaps: Gaps(), appsWithSeveralWindows: ["code"])
        #expect(placements.map(\.open) == [["/Users/tom/src/tile"], []])
        #expect(placements.map(\.title) == [nil, "^Welcome$"])
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
