import Carbon.HIToolbox
import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ctrl = Modifiers(rawValue: 1 << 0)
    public static let opt = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let cmd = Modifiers(rawValue: 1 << 3)
    public static let hyper: Modifiers = [.ctrl, .opt, .shift, .cmd]

    /// The modifier mask `RegisterEventHotKey` takes.
    public var carbonFlags: UInt32 {
        var flags = 0
        if contains(.ctrl) { flags |= controlKey }
        if contains(.opt) { flags |= optionKey }
        if contains(.shift) { flags |= shiftKey }
        if contains(.cmd) { flags |= cmdKey }
        return UInt32(flags)
    }
}

public struct KeyComboError: Error, Equatable, CustomStringConvertible {
    public let message: String
    init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A shortcut written as "ctrl+opt+left" or "hyper+w". `keyCode` is a `kVK_*`
/// virtual key code, assuming a US layout.
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public let keyCode: UInt32
    public let modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Case-insensitive; modifiers in any order, key last.
    public init(parsing string: String) throws {
        let parts = string.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !parts.contains("") else {
            throw KeyComboError("'\(string)' has an empty part")
        }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = Self.modifiersByName[part] else {
                if Self.codesByName[part] != nil {
                    throw KeyComboError("'\(string)': the key goes last, after the modifiers")
                }
                throw KeyComboError("unknown modifier '\(part)' in '\(string)'; expected ctrl, opt, shift, cmd or hyper")
            }
            modifiers.formUnion(modifier)
        }
        guard let code = Self.codesByName[keyName] else {
            if Self.modifiersByName[keyName] != nil {
                throw KeyComboError("'\(string)' has modifiers but no key")
            }
            throw KeyComboError("unknown key '\(keyName)' in '\(string)'")
        }
        // opt and opt+shift alone are allowed: macOS 15 was reported to refuse them for
        // RegisterEventHotKey, but 26.2 registers them, and Mosaic users bind opt+letter.
        if modifiers.isSubset(of: [.shift]), !Self.functionKeys.contains(code) {
            throw KeyComboError("'\(string)' would take over a key you type with; add ctrl or cmd")
        }
        self.init(keyCode: code, modifiers: modifiers)
    }

    /// The canonical spelling: modifiers as ctrl+opt+shift+cmd (all four as hyper), then the key.
    public var description: String {
        let names = modifiers == .hyper
            ? ["hyper"]
            : Self.modifierOrder.filter { modifiers.contains($0.modifier) }.map(\.name)
        return (names + [Self.namesByCode[keyCode] ?? "key\(keyCode)"]).joined(separator: "+")
    }

    private static let modifierOrder: [(name: String, modifier: Modifiers)] = [
        ("ctrl", .ctrl), ("opt", .opt), ("shift", .shift), ("cmd", .cmd),
    ]

    private static let modifiersByName: [String: Modifiers] = [
        "ctrl": .ctrl, "control": .ctrl,
        "opt": .opt, "option": .opt, "alt": .opt,
        "shift": .shift,
        "cmd": .cmd, "command": .cmd,
        "hyper": .hyper,
    ]

    /// Canonical name, key code, other accepted spellings.
    private static let keys: [(name: String, code: Int, aliases: [String])] = {
        let letters = zip("abcdefghijklmnopqrstuvwxyz", [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
            kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
            kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
            kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ]).map { (String($0), $1, [String]()) }
        let digits = zip("0123456789", [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]).map { (String($0), $1, [String]()) }
        let named: [(String, Int, [String])] = [
            ("left", kVK_LeftArrow, []), ("right", kVK_RightArrow, []),
            ("up", kVK_UpArrow, []), ("down", kVK_DownArrow, []),
            ("return", kVK_Return, ["enter"]), ("space", kVK_Space, []), ("tab", kVK_Tab, []),
            ("escape", kVK_Escape, ["esc"]), ("delete", kVK_Delete, ["backspace"]),
            ("-", kVK_ANSI_Minus, ["minus"]), ("=", kVK_ANSI_Equal, ["equal", "equals"]),
            ("[", kVK_ANSI_LeftBracket, ["leftbracket"]), ("]", kVK_ANSI_RightBracket, ["rightbracket"]),
            ("\\", kVK_ANSI_Backslash, ["backslash"]), (";", kVK_ANSI_Semicolon, ["semicolon"]),
            ("'", kVK_ANSI_Quote, ["quote"]), (",", kVK_ANSI_Comma, ["comma"]),
            (".", kVK_ANSI_Period, ["period"]), ("/", kVK_ANSI_Slash, ["slash"]),
            ("`", kVK_ANSI_Grave, ["grave", "backtick"]),
        ]
        let functionKeys = functionKeyCodes.enumerated().map { ("f\($0.offset + 1)", $0.element, [String]()) }
        return letters + digits + named + functionKeys
    }()

    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Keys that don't type anything, so they may be bound without ctrl or cmd.
    private static let functionKeys = Set(functionKeyCodes.map { UInt32($0) })

    private static let codesByName: [String: UInt32] = Dictionary(
        uniqueKeysWithValues: keys.flatMap { key in ([key.name] + key.aliases).map { ($0, UInt32(key.code)) } })

    private static let namesByCode: [UInt32: String] = Dictionary(
        uniqueKeysWithValues: keys.map { (UInt32($0.code), $0.name) })
}
