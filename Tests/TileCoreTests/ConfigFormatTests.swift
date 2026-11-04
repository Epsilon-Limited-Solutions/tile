import CoreGraphics
import Foundation
import Testing
@testable import TileCore

struct ConfigFormatTests {
    static let arrangementJSON = """
    { "arrangements": [
        { "id": "work", "profile": "desk", "endOn": { "vertical-right": 1, "laptop": 2 },
          "desktops": [
            { "display": "vertical-right", "desktop": 1, "windows": [
                { "app": "com.microsoft.VSCode", "title": "^epsilon — .*$", "layout": "top-half", "open": ["~/epsilon"] },
                { "app": "com.googlecode.iterm2", "rect": [0, 0.6, 1, 0.4] } ] },
            { "display": "laptop", "desktop": 2, "windows": [] } ] },
        { "id": "solo", "profile": "laptop", "desktops": [
            { "display": "laptop", "desktop": 1, "windows": [ { "app": "com.apple.Safari", "layout": "full" } ] } ] }
      ],
      "profiles": [
        { "id": "laptop", "displays": { "laptop": { "builtin": true } } },
        { "id": "desk", "displays": { "laptop": { "builtin": true }, "vertical-right": { "serial": 825446978 } } } ],
      "layouts": [ { "id": "top-half", "rect": [0, 0, 1, 0.5] }, { "id": "full", "rect": [0, 0, 1, 1] } ] }
    """

    @Test func numbers() {
        #expect(ConfigFormat.number(0) == "0")
        #expect(ConfigFormat.number(1) == "1")
        #expect(ConfigFormat.number(0.5) == "0.5")
        #expect(ConfigFormat.number(1.0 / 3) == "0.333")
        #expect(ConfigFormat.number(0.6666) == "0.667")
        #expect(ConfigFormat.number(0.0004) == "0")
        #expect(ConfigFormat.number(0.9996) == "1")
        #expect(ConfigFormat.number(-0.25) == "-0.25")
    }

    @Test func strings() {
        #expect(ConfigFormat.string("a/b") == #""a/b""#)
        #expect(ConfigFormat.string(#"say "hi"\#n"#) == #""say \"hi\"\n""#)
        #expect(ConfigFormat.string("epsilon — Code") == #""epsilon — Code""#)
    }

    @Test func defaultLayoutsAndBindingsRoundTrip() throws {
        let original = try Fixtures.config(Config.defaultJSON)
        var text = try ConfigText.replacingValue(of: "layouts", with: ConfigFormat.layouts(original.layouts), in: Config.defaultJSON)
        text = try ConfigText.replacingValue(of: "bindings", with: ConfigFormat.bindings(original.bindings), in: text)
        #expect(try Fixtures.config(text) == original)
    }

    @Test func arrangementsRoundTrip() throws {
        let original = try Fixtures.config(Self.arrangementJSON)
        let formatted = ConfigFormat.arrangements(original.arrangements)
        let text = try ConfigText.replacingValue(of: "arrangements", with: formatted, in: Self.arrangementJSON)
        #expect(try Fixtures.config(text) == original)
    }

    @Test func arrangementLayout() throws {
        let config = try Fixtures.config(Self.arrangementJSON)
        #expect(ConfigFormat.arrangements([config.arrangements[0]]) == """
        [
            { "id": "work", "profile": "desk",
              "endOn": { "laptop": 2, "vertical-right": 1 },
              "desktops": [
                { "display": "vertical-right", "desktop": 1, "windows": [
                    { "app": "com.microsoft.VSCode", "title": "^epsilon — .*$", "layout": "top-half", "open": ["~/epsilon"] },
                    { "app": "com.googlecode.iterm2", "rect": [0, 0.6, 1, 0.4] } ] },
                { "display": "laptop", "desktop": 2, "windows": [] } ] }
          ]
        """)
        #expect(ConfigFormat.arrangements([]) == "[]")
    }
}

struct ConfigTextTests {
    @Test func replacesOnlyThatValue() throws {
        let text = """
        {
          "gaps": { "outer": 10,   "inner": 10 },
          "arrangements": [ 1, [2, {"x": "]"}] ],
          "ignoredApps": []
        }
        """
        let result = try ConfigText.replacingValue(of: "arrangements", with: "[]", in: text)
        #expect(result == """
        {
          "gaps": { "outer": 10,   "inner": 10 },
          "arrangements": [],
          "ignoredApps": []
        }
        """)
    }

    @Test func keyInsideAStringOrNestedObjectIsNotTheKey() throws {
        let text = #"{ "a": { "arrangements": 1 }, "b": "\"arrangements\": 2", "arrangements": 3 }"#
        #expect(try ConfigText.replacingValue(of: "arrangements", with: "4", in: text)
                == #"{ "a": { "arrangements": 1 }, "b": "\"arrangements\": 2", "arrangements": 4 }"#)
    }

    @Test func addsAMissingKeyAtTheEnd() throws {
        #expect(try ConfigText.replacingValue(of: "arrangements", with: "[]", in: "{\n  \"gaps\": {}\n}\n")
                == "{\n  \"gaps\": {},\n\n  \"arrangements\": []\n}\n")
        #expect(try ConfigText.replacingValue(of: "arrangements", with: "[]", in: "{ }")
                == "{\n  \"arrangements\": []\n}")
        // A trailing comma (which the parser forgives) doesn't get a second one.
        #expect(try ConfigText.replacingValue(of: "x", with: "1", in: #"{ "a": 1, }"#) == "{ \"a\": 1,\n\n  \"x\": 1, }")
    }

    @Test func refusesBrokenText() {
        #expect(throws: ConfigText.ScanError.self) { try ConfigText.replacingValue(of: "a", with: "1", in: #"{ "a": [1, 2 "#) }
        #expect(throws: ConfigText.ScanError.self) { try ConfigText.replacingValue(of: "a", with: "1", in: #"[ ]"#) }
        #expect(throws: ConfigText.ScanError.self) { try ConfigText.replacingValue(of: "a", with: "1", in: #"{ "a" 1 }"#) }
    }
}
