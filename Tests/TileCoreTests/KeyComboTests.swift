import Carbon.HIToolbox
import Testing
@testable import TileCore

struct KeyComboTests {
    func parse(_ string: String) throws -> KeyCombo {
        try KeyCombo(parsing: string)
    }

    func error(_ string: String) -> String? {
        do {
            _ = try parse(string)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func parsesModifiersAndKey() throws {
        let combo = try parse("ctrl+opt+left")
        #expect(combo.keyCode == UInt32(kVK_LeftArrow))
        #expect(combo.modifiers == [.ctrl, .opt])
        #expect(try parse("cmd+shift+4") == KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: [.cmd, .shift]))
        #expect(try parse("ctrl+opt+cmd+right").modifiers == [.ctrl, .opt, .cmd])
    }

    @Test func hyperIsAllFourModifiers() throws {
        #expect(try parse("hyper+w") == KeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: [.ctrl, .opt, .shift, .cmd]))
        #expect(try parse("ctrl+opt+shift+cmd+w") == parse("hyper+w"))
        #expect(try parse("hyper+shift+w") == parse("hyper+w"))
    }

    @Test func orderCaseAndSpacingDontMatter() throws {
        #expect(try parse("Opt+Ctrl+Left") == parse("ctrl+opt+left"))
        #expect(try parse(" ctrl + opt + left ") == parse("ctrl+opt+left"))
        #expect(try parse("CONTROL+OPTION+COMMAND+A") == parse("ctrl+opt+cmd+a"))
        #expect(try parse("ctrl+alt+a") == parse("ctrl+opt+a"))
    }

    @Test func aliases() throws {
        #expect(try parse("ctrl+opt+backspace") == parse("ctrl+opt+delete"))
        #expect(try parse("ctrl+opt+enter") == parse("ctrl+opt+return"))
        #expect(try parse("ctrl+esc") == parse("ctrl+escape"))
        #expect(try parse("ctrl+opt+comma") == parse("ctrl+opt+,"))
        #expect(try parse("ctrl+opt+equal") == parse("ctrl+opt+="))
        #expect(try parse("cmd+backtick") == parse("cmd+`"))
    }

    @Test(arguments: [
        ("left", kVK_LeftArrow), ("right", kVK_RightArrow), ("up", kVK_UpArrow), ("down", kVK_DownArrow),
        ("return", kVK_Return), ("space", kVK_Space), ("tab", kVK_Tab), ("escape", kVK_Escape),
        ("delete", kVK_Delete), ("a", kVK_ANSI_A), ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("9", kVK_ANSI_9),
        ("f1", kVK_F1), ("f12", kVK_F12), ("f20", kVK_F20),
        ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
        ("\\", kVK_ANSI_Backslash), (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma),
        (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash), ("`", kVK_ANSI_Grave),
    ])
    func everyKeyRoundTrips(name: String, code: Int) throws {
        let combo = try parse("ctrl+\(name)")
        #expect(combo.keyCode == UInt32(code))
        #expect(combo.description == "ctrl+\(name)")
        #expect(try parse(combo.description) == combo)
    }

    @Test func formatsCanonically() throws {
        #expect(try parse("cmd+opt+ctrl+left").description == "ctrl+opt+cmd+left")
        #expect(try parse("shift+cmd+ctrl+a").description == "ctrl+shift+cmd+a")
        #expect(try parse("ctrl+opt+shift+cmd+w").description == "hyper+w")
        #expect(try parse("ctrl+opt+backspace").description == "ctrl+opt+delete")
        #expect(try parse("ctrl+opt+comma").description == "ctrl+opt+,")
    }

    @Test func carbonFlags() throws {
        #expect(try parse("ctrl+a").modifiers.carbonFlags == UInt32(controlKey))
        #expect(try parse("hyper+a").modifiers.carbonFlags == UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(try parse("f13").modifiers.carbonFlags == 0)
    }

    @Test func functionKeysNeedNoModifier() throws {
        #expect(try parse("f13").modifiers == [])
        #expect(try parse("shift+f5").modifiers == [.shift])
    }

    @Test func rejectsOptOnlyBecauseMacOSDoes() {
        #expect(error("opt+a")?.contains("macOS 15 and later refuse") == true)
        #expect(error("opt+shift+left")?.contains("opt or opt+shift") == true)
        #expect(error("opt+f1")?.contains("macOS 15") == true)
        #expect(error("ctrl+opt+a") == nil)
        #expect(error("cmd+opt+shift+a") == nil)
    }

    @Test func rejectsKeysYouTypeWith() {
        #expect(error("a")?.contains("would take over a key you type with") == true)
        #expect(error("shift+a")?.contains("would take over") == true)
        #expect(error("space")?.contains("would take over") == true)
    }

    @Test func rejectsMalformedStrings() {
        #expect(error("ctrl+opt+lft") == "unknown key 'lft' in 'ctrl+opt+lft'")
        #expect(error("ctrl+super+a") == "unknown modifier 'super' in 'ctrl+super+a'; expected ctrl, opt, shift, cmd or hyper")
        #expect(error("ctrl+opt") == "'ctrl+opt' has modifiers but no key")
        #expect(error("ctrl+left+opt") == "'ctrl+left+opt': the key goes last, after the modifiers")
        #expect(error("ctrl+a+b") == "'ctrl+a+b': the key goes last, after the modifiers")
        #expect(error("") == "'' has an empty part")
        #expect(error("ctrl++") == "'ctrl++' has an empty part")
        #expect(error("ctrl+opt+") == "'ctrl+opt+' has an empty part")
    }
}
