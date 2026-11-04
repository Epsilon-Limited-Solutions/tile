import CoreGraphics
import Testing
@testable import TileCore

struct ConfigTests {
    func issues(_ json: String) -> [String] { Fixtures.issues(json) }

    // MARK: Valid files

    @Test func defaultConfigIsValid() throws {
        let config = try Fixtures.config(Config.defaultJSON)
        #expect(config.gaps == Gaps(outer: 0, inner: 0))
        #expect(config.profiles.map(\.id) == ["laptop", "desk"])
        #expect(config.layouts.count == 21)
        #expect(config.bindings.count == 26)
        #expect(config.arrangements.isEmpty)
        #expect(config.layout("left-third")?.shape
                == .grid(columns: 3, rows: 1, cell: GridCell(column: 0, row: 0, columnSpan: 1, rowSpan: 1)))
        #expect(config.layout("center")?.shape == .center)
        let desk = try #require(config.profiles.last)
        #expect(desk.displays["vertical-left"] == DisplayMatcher(builtin: nil, name: "DELL S2722QC", serial: 810894658, rotation: nil))
    }

    @Test func emptyObjectIsAValidConfig() throws {
        let config = try Fixtures.config("{}")
        #expect(config == Config(gaps: Gaps(), ignoredApps: [], profiles: [], layouts: [], bindings: [], arrangements: []))
    }

    @Test func arrangementsParse() throws {
        let config = try Fixtures.config("""
        {
          "gaps": { "outer": 8, "inner": 6 },
          "ignoredApps": ["com.apple.systempreferences"],
          "profiles": [ { "id": "desk", "onActivate": "work", "displays": {
              "laptop": { "builtin": true }, "vertical-right": { "serial": 825446978 } } } ],
          "layouts": [ { "id": "top-60", "rect": [0, 0, 1, 0.6] }, { "id": "full", "rect": [0, 0, 1, 1] } ],
          "bindings": [ { "keys": "hyper+w", "arrange": "work" } ],
          "arrangements": [ { "id": "work", "profile": "desk",
              "endOn": { "vertical-right": 1, "laptop": 2 },
              "desktops": [
                { "display": "vertical-right", "desktop": 1, "windows": [
                  { "app": "com.microsoft.VSCode", "layout": "top-60", "open": ["~/epsilon"] },
                  { "app": "com.googlecode.iterm2", "title": "^zsh", "rect": [0, 0.6, 1, 0.4] } ] },
                { "display": "vertical-right", "desktop": 3, "windows": [] },
                { "display": "laptop", "desktop": 1, "windows": [ { "app": "com.google.Chrome", "layout": "full" } ] } ] } ]
        }
        """)
        #expect(config.gaps == Gaps(outer: 8, inner: 6))
        #expect(config.ignoredApps == ["com.apple.systempreferences"])
        #expect(config.profiles[0].onActivate == "work")
        #expect(config.layout("top-60")?.name == "top-60")
        #expect(config.bindings[0].target == .arrange("work"))

        let work = try #require(config.arrangements.first)
        #expect(work.endOn == ["vertical-right": 1, "laptop": 2])
        #expect(work.desktopsNeeded == ["vertical-right": 3, "laptop": 2])
        let windows = work.desktops[0].windows
        #expect(windows[0] == WindowPlacement(app: "com.microsoft.VSCode", title: nil, layout: .named("top-60"), open: ["~/epsilon"]))
        #expect(windows[1] == WindowPlacement(app: "com.googlecode.iterm2", title: "^zsh",
                                              layout: .rect(CGRect(x: 0, y: 0.6, width: 1, height: 0.4)), open: []))
    }

    // MARK: Errors while decoding: the first one, with its path

    @Test func syntaxErrorsGiveTheLine() {
        // Missing comma after line 2.
        let result = issues("{\n  \"gaps\": { \"outer\": 0 }\n  \"layouts\": []\n}")
        #expect(result == ["not valid JSON: Unexpected character '\"' in object around line 3, column 3."])
    }

    @Test func trailingCommasAreForgiven() throws {
        // JSONDecoder allows them; good, since this file is edited by hand.
        #expect(try Fixtures.config("{ \"gaps\": { \"outer\": 4, }, \"ignoredApps\": [\"a\",], }").gaps.outer == 4)
    }

    @Test func numbersOutOfRangeKeepTheirPath() {
        // JSONDecoder's own error for these has no path; Tile's must.
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": { "serial": -1 } } } ] }"#)
                == ["profiles[0].displays.x.serial: must be a whole number from 0 to 4294967295"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": { "serial": 4294967296 } } } ] }"#)
                == ["profiles[0].displays.x.serial: must be a whole number from 0 to 4294967295"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": { "rotation": 90.5 } } } ] }"#)
                == ["profiles[0].displays.x.rotation: must be a whole number"])
        #expect(issues(#"{ "layouts": [ { "id": "x", "grid": [3, 1], "cells": [0, 0, 1.5, 1] } ] }"#)
                == ["layouts[0].cells: must be whole numbers"])
        #expect(issues(#"{ "arrangements": [ { "id": "a", "profile": "p", "desktops": [ { "display": "x", "desktop": 1.5 } ] } ] }"#)
                == ["arrangements[0].desktops[0].desktop: must be a whole number"])
        #expect(issues(#"{ "arrangements": [ { "id": "a", "profile": "p", "endOn": { "x": 2.5 }, "desktops": [] } ] }"#)
                == ["arrangements[0].endOn: desktop for 'x' must be a whole number, 1 or more"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": { "serial": null, "builtin": true } } } ] }"#) == [])
    }

    @Test func topLevelMustBeAnObject() {
        #expect(issues("[]") == ["expected an object"])
    }

    @Test func unknownKeysAreTypos() {
        #expect(issues(#"{ "bindings": [ { "keys": "ctrl+opt+a", "layuot": "full" } ] }"#)
                == ["bindings[0].layuot: unknown key; expected keys, when, layout, cycle, action or arrange"])
        #expect(issues(#"{ "gap": {} }"#)
                == ["gap: unknown key; expected gaps, ignoredApps, profiles, layouts, bindings or arrangements"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": { "serail": 1 } } } ] }"#)
                == ["profiles[0].displays.x.serail: unknown key; expected builtin, name, serial or rotation"])
    }

    @Test func wrongTypesAndMissingKeys() {
        #expect(issues(#"{ "gaps": { "outer": "10" } }"#) == ["gaps.outer: expected a number"])
        #expect(issues(#"{ "layouts": [ { "name": "x", "rect": [0, 0, 1, 1] } ] }"#) == ["layouts[0].id: required"])
        #expect(issues(#"{ "layouts": { "id": "x" } }"#) == ["layouts: expected a list"])
        #expect(issues(#"{ "layouts": [ { "id": "", "rect": [0, 0, 1, 1] } ] }"#) == ["layouts[0].id: must not be empty"])
    }

    @Test func badKeyStringsSayWhy() {
        #expect(issues(#"{ "bindings": [ { "keys": "shift+a", "action": "restore" } ] }"#)
                == ["bindings[0].keys: 'shift+a' would take over a key you type with; add ctrl or cmd"])
        #expect(issues(#"{ "bindings": [ { "keys": "ctrl+opt+lft", "action": "restore" } ] }"#)
                == ["bindings[0].keys: unknown key 'lft' in 'ctrl+opt+lft'"])
    }

    @Test func bindingNeedsExactlyOneTarget() {
        #expect(issues(#"{ "bindings": [ { "keys": "ctrl+a" } ] }"#)
                == ["bindings[0]: needs exactly one of layout, cycle, action or arrange"])
        #expect(issues(#"{ "bindings": [ { "keys": "ctrl+a", "layout": "x", "cycle": ["x"] } ] }"#)
                == ["bindings[0]: needs exactly one of layout, cycle, action or arrange, found layout and cycle"])
        #expect(issues(#"{ "bindings": [ { "keys": "ctrl+a", "cycle": [] } ] }"#)
                == ["bindings[0].cycle: needs at least one layout id"])
        #expect(issues(#"{ "bindings": [ { "keys": "ctrl+a", "action": "maximize" } ] }"#)
                == ["bindings[0].action: unknown action 'maximize'; expected restore, next-display or previous-display"])
        #expect(issues(#"{ "bindings": [ { "keys": "ctrl+a", "action": "restore", "when": { "orientation": "vertical" } } ] }"#)
                == ["bindings[0].when.orientation: expected portrait or landscape"])
    }

    @Test func layoutShapes() {
        func layout(_ body: String) -> [String] { issues(#"{ "layouts": [ { "id": "x", \#(body) } ] }"#) }
        #expect(layout(#""name": "X""#) == ["layouts[0]: needs exactly one of rect, grid or center"])
        #expect(layout(#""rect": [0, 0, 1, 1], "center": true"#)
                == ["layouts[0]: needs exactly one of rect, grid or center, found rect and center"])
        #expect(layout(#""rect": [0, 0, 1]"#) == ["layouts[0].rect: expected [x, y, width, height], got 3 numbers"])
        #expect(layout(#""rect": [0, 0, 1.5, 1]"#)
                == ["layouts[0].rect: values are fractions of the screen, so each must be between 0 and 1"])
        #expect(layout(#""rect": [0.5, 0, 0.6, 1]"#) == ["layouts[0].rect: x + width and y + height must not exceed 1"])
        #expect(layout(#""rect": [0, 0, 0, 1]"#) == ["layouts[0].rect: width and height must be more than 0"])
        #expect(layout(#""rect": [0.6667, 0, 0.3334, 1]"#) == [], "within rounding of 1 is fine")
        #expect(layout(#""grid": [3, 1]"#) == ["layouts[0]: grid needs cells: [column, row, columnSpan, rowSpan]"])
        #expect(layout(#""grid": [3, 0], "cells": [0, 0, 1, 1]"#) == ["layouts[0].grid: expected [columns, rows], each at least 1"])
        #expect(layout(#""grid": [3, 1], "cells": [2, 0, 2, 1]"#)
                == ["layouts[0].cells: [2, 0, 2, 1] doesn't fit a 3x1 grid (columns and rows count from 0)"])
        #expect(layout(#""rect": [0, 0, 1, 1], "cells": [0, 0, 1, 1]"#) == ["layouts[0].cells: only goes with grid"])
        #expect(layout(#""center": false"#) == ["layouts[0].center: must be true; use rect or grid for anything else"])
    }

    @Test func gapsAndMatchers() {
        #expect(issues(#"{ "gaps": { "inner": -1 } }"#) == ["gaps.inner: must be between 0 and 200 points"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": {} } } ] }"#)
                == ["profiles[0].displays.x: would match any display; set builtin, name or serial"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": { "rotation": 45 } } } ] }"#)
                == ["profiles[0].displays.x.rotation: must be 0, 90, 180 or 270"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": {} } ] }"#) == ["profiles[0].displays: needs at least one display"])
    }

    @Test func arrangementShapes() {
        #expect(issues(#"{ "arrangements": [ { "id": "a", "profile": "p", "desktops": [ { "display": "x", "desktop": 0 } ] } ] }"#)
                == ["arrangements[0].desktops[0].desktop: desktops count from 1"])
        #expect(issues(#"{ "arrangements": [ { "id": "a", "profile": "p", "endOn": { "x": 0 }, "desktops": [] } ] }"#)
                == ["arrangements[0].endOn: desktop for 'x' must be a whole number, 1 or more"])
        #expect(issues(#"{ "arrangements": [ { "id": "a", "profile": "p", "desktops": [ { "display": "x", "desktop": 1, "windows": [ { "app": "a" } ] } ] } ] }"#)
                == ["arrangements[0].desktops[0].windows[0]: needs exactly one of layout or rect"])
    }

    // MARK: Errors across the file: all of them at once

    static let base = """
      "profiles": [
        { "id": "laptop", "displays": { "laptop": { "builtin": true } } },
        { "id": "desk", "displays": { "laptop": { "builtin": true }, "vertical": { "serial": 1 } } } ],
      "layouts": [ { "id": "full", "rect": [0, 0, 1, 1] }, { "id": "half", "rect": [0, 0, 0.5, 1] } ]
    """

    func validate(_ rest: String) -> [String] { issues("{ \(Self.base), \(rest) }") }

    @Test func baseIsValid() {
        #expect(issues("{ \(Self.base) }") == [])
    }

    @Test func duplicateIDs() {
        #expect(issues(#"{ "layouts": [ { "id": "a", "rect": [0, 0, 1, 1] }, { "id": "b", "rect": [0, 0, 1, 1] }, { "id": "a", "center": true } ] }"#)
                == ["layouts[2].id: 'a' is already the id of layouts[0]"])
        #expect(issues(#"{ "profiles": [ { "id": "p", "displays": { "x": { "builtin": true } } }, { "id": "p", "displays": { "x": { "builtin": true } } } ] }"#)
                == ["profiles[1].id: 'p' is already the id of profiles[0]"])
    }

    @Test func bindingReferences() {
        #expect(validate(#""bindings": [ { "keys": "ctrl+a", "layout": "ful" } ]"#) == ["bindings[0].layout: no layout has id 'ful'"])
        #expect(validate(#""bindings": [ { "keys": "ctrl+a", "cycle": ["half", "third"] } ]"#)
                == ["bindings[0].cycle[1]: no layout has id 'third'"])
        #expect(validate(#""bindings": [ { "keys": "ctrl+a", "arrange": "work" } ]"#) == ["bindings[0].arrange: no arrangement has id 'work'"])
        #expect(validate(#""bindings": [ { "keys": "ctrl+a", "layout": "full", "when": { "profile": "home" } } ]"#)
                == ["bindings[0].when.profile: no profile has id 'home'"])
        #expect(validate(#""bindings": [ { "keys": "ctrl+a", "layout": "full", "when": { "display": "vertical-left" } } ]"#)
                == ["bindings[0].when.display: no profile has a display 'vertical-left'"])
        #expect(validate(#""bindings": [ { "keys": "ctrl+a", "layout": "full", "when": { "profile": "laptop", "display": "vertical" } } ]"#)
                == ["bindings[0].when.display: profile 'laptop' has no display 'vertical'; it has laptop"])
        #expect(validate(#""bindings": [ { "keys": "ctrl+a", "layout": "full", "when": { "profile": "desk", "display": "vertical" } } ]"#) == [])
    }

    @Test func bindingsThatCouldNeverFire() {
        #expect(validate("""
            "bindings": [
              { "keys": "ctrl+opt+left", "layout": "half" },
              { "keys": "opt+ctrl+left", "layout": "full" } ]
            """) == ["bindings[1]: same keys (ctrl+opt+left) and same when as bindings[0], so one of them could never fire"])
        #expect(validate("""
            "bindings": [
              { "keys": "ctrl+opt+left", "when": { "display": "vertical", "orientation": "portrait" }, "layout": "half" },
              { "keys": "ctrl+opt+left", "when": { "orientation": "portrait", "display": "vertical" }, "layout": "full" } ]
            """) == ["bindings[1]: same keys (ctrl+opt+left) and same when as bindings[0], so one of them could never fire"])
        // An empty when is the same as none.
        #expect(validate("""
            "bindings": [ { "keys": "ctrl+a", "layout": "half" }, { "keys": "ctrl+a", "when": {}, "layout": "full" } ]
            """).count == 1)
    }

    @Test func sameKeysInDifferentScopesAreFine() {
        #expect(validate("""
            "bindings": [
              { "keys": "ctrl+opt+left", "layout": "half" },
              { "keys": "ctrl+opt+left", "when": { "orientation": "portrait" }, "layout": "full" },
              { "keys": "ctrl+opt+left", "when": { "orientation": "landscape" }, "layout": "full" },
              { "keys": "ctrl+opt+left", "when": { "profile": "desk", "display": "laptop" }, "layout": "full" },
              { "keys": "ctrl+opt+left", "when": { "profile": "laptop", "display": "laptop" }, "layout": "full" } ]
            """) == [])
    }

    @Test func arrangementReferences() {
        #expect(validate(#""arrangements": [ { "id": "work", "profile": "office", "desktops": [ { "display": "laptop", "desktop": 1, "windows": [ { "app": "x", "layout": "nope" } ] } ] } ]"#)
                == ["arrangements[0].profile: no profile has id 'office'",
                    "arrangements[0].desktops[0].windows[0].layout: no layout has id 'nope'"])
        #expect(validate(#""arrangements": [ { "id": "work", "profile": "desk", "endOn": { "vertical-left": 1 }, "desktops": [ { "display": "vertical-right", "desktop": 1 } ] } ]"#)
                == ["arrangements[0].desktops[0].display: profile 'desk' has no display 'vertical-right'; it has laptop and vertical",
                    "arrangements[0].endOn.vertical-left: profile 'desk' has no display 'vertical-left'; it has laptop and vertical"])
        #expect(validate(#""arrangements": [ { "id": "work", "profile": "desk", "desktops": [ { "display": "vertical", "desktop": 2 }, { "display": "laptop", "desktop": 2 }, { "display": "vertical", "desktop": 2 } ] } ]"#)
                == ["arrangements[0].desktops[2]: vertical desktop 2 is already listed at desktops[0]; merge them"])
        #expect(validate(#""arrangements": [ { "id": "work", "profile": "desk", "desktops": [ { "display": "laptop", "desktop": 1, "windows": [ { "app": "x", "title": "([a-z", "rect": [0, 0, 1, 1] } ] } ] } ]"#)
                == ["arrangements[0].desktops[0].windows[0].title: '([a-z' is not a valid regular expression"])
    }

    @Test func onActivateMustBeThisProfilesArrangement() {
        let profiles = """
          "profiles": [
            { "id": "laptop", "onActivate": "work", "displays": { "laptop": { "builtin": true } } },
            { "id": "desk", "onActivate": "gone", "displays": { "laptop": { "builtin": true } } } ],
          "arrangements": [ { "id": "work", "profile": "desk", "desktops": [] } ]
        """
        #expect(issues("{ \(profiles) }") == ["profiles[0].onActivate: arrangement 'work' is for profile 'desk'",
                                              "profiles[1].onActivate: no arrangement has id 'gone'"])
    }

    @Test func everyValidationIssueIsReportedAtOnce() {
        let result = validate("""
            "bindings": [ { "keys": "ctrl+a", "layout": "x" }, { "keys": "ctrl+b", "layout": "y" } ],
            "arrangements": [ { "id": "a", "profile": "z", "desktops": [] } ]
            """)
        #expect(result == ["bindings[0].layout: no layout has id 'x'",
                           "bindings[1].layout: no layout has id 'y'",
                           "arrangements[0].profile: no profile has id 'z'"])
    }
}
