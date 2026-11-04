import CoreGraphics
import Foundation

// Hand-written decoding: every object rejects keys it doesn't know (a typo in a
// hand-edited file should fail loudly, not be ignored), and every error carries
// the path to the bad value. Checks that need the whole file, such as whether a
// layout id exists, are in ConfigValidation.swift.

struct JSONKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
    init(stringLiteral value: String) { self.init(value) }
}

typealias JSONObject = KeyedDecodingContainer<JSONKey>

extension Decoder {
    /// The JSON object at this position, which may only contain `allowed` keys.
    func object(allowing allowed: [String]) throws -> JSONObject {
        let object = try container(keyedBy: JSONKey.self)
        let unknown = object.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        if let key = unknown.first {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [JSONKey(key)],
                                                    debugDescription: "unknown key; expected \(list(allowed, or: true))"))
        }
        return object
    }
}

extension KeyedDecodingContainer where Key == JSONKey {
    func has(_ key: String) -> Bool { contains(JSONKey(key)) }

    func invalid(_ key: String, _ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath + [JSONKey(key)], debugDescription: message))
    }

    func invalid(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
    }

    func nonEmptyString(_ key: String) throws -> String {
        let value = try decode(String.self, forKey: JSONKey(key))
        guard !value.isEmpty else { throw invalid(key, "must not be empty") }
        return value
    }

    /// Exactly one of `keys` must be present; returns it.
    func oneOf(_ keys: [String]) throws -> String {
        let present = keys.filter(has)
        guard present.count == 1 else {
            let found = present.isEmpty ? "" : ", found \(list(present, or: false))"
            throw invalid("needs exactly one of \(list(keys, or: true))\(found)")
        }
        return present[0]
    }

    // Whole numbers are decoded as Double and checked here: JSONDecoder reports
    // -1 for a UInt32, or 1.5 for an Int, without saying where in the file it was.

    func wholeNumber(_ key: String) throws -> Int {
        guard let number = whole(try decode(Double.self, forKey: JSONKey(key))) else {
            throw invalid(key, "must be a whole number")
        }
        return number
    }

    /// Absent or null: nil, like `decodeIfPresent`.
    func wholeNumberIfPresent(_ key: String) throws -> Int? {
        guard has(key), try !decodeNil(forKey: JSONKey(key)) else { return nil }
        return try wholeNumber(key)
    }

    func wholeNumbers(_ key: String) throws -> [Int] {
        let values = try decode([Double].self, forKey: JSONKey(key))
        let numbers = values.compactMap(whole)
        guard numbers.count == values.count else { throw invalid(key, "must be whole numbers") }
        return numbers
    }

    /// `[x, y, width, height]` as fractions of the visible frame.
    func fractionRect(_ key: String) throws -> CGRect {
        let values = try decode([CGFloat].self, forKey: JSONKey(key))
        guard values.count == 4 else {
            throw invalid(key, "expected [x, y, width, height], got \(values.count) numbers")
        }
        guard values.allSatisfy({ (0...1).contains($0) }) else {
            throw invalid(key, "values are fractions of the screen, so each must be between 0 and 1")
        }
        let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard rect.width > 0, rect.height > 0 else { throw invalid(key, "width and height must be more than 0") }
        guard rect.maxX <= 1 + LayoutEngine.edgeTolerance, rect.maxY <= 1 + LayoutEngine.edgeTolerance else {
            throw invalid(key, "x + width and y + height must not exceed 1")
        }
        return rect
    }
}

/// `value` as an Int if it's a whole number that Double represents exactly.
func whole(_ value: Double) -> Int? {
    guard value == value.rounded(), abs(value) <= 9_007_199_254_740_992 else { return nil }
    return Int(value)
}

/// "a, b or c" (or: true) / "a and b" (or: false).
func list(_ items: [String], or: Bool) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items.last!
}

extension ConfigIssue {
    init(_ error: DecodingError) {
        switch error {
        case .typeMismatch(let type, let context):
            self.init(path: Self.render(context.codingPath), message: "expected \(Self.describe(type))")
        case .valueNotFound(let type, let context):
            self.init(path: Self.render(context.codingPath), message: "expected \(Self.describe(type)), found null")
        case .keyNotFound(let key, let context):
            self.init(path: Self.render(context.codingPath + [key]), message: "required")
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty, let underlying = context.underlyingError as NSError? {
                let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String ?? underlying.localizedDescription
                self.init(path: "", message: "not valid JSON: \(detail)")
            } else {
                self.init(path: Self.render(context.codingPath), message: context.debugDescription)
            }
        @unknown default:
            self.init(path: "", message: "\(error)")
        }
    }

    /// `bindings[3].when.display`
    static func render(_ path: [CodingKey]) -> String {
        path.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }

    private static func describe(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is Bool.Type: return "true or false"
        case is Int.Type, is UInt32.Type: return "a whole number"
        case is Double.Type, is CGFloat.Type: return "a number"
        default:
            let name = String(describing: type)
            if name.hasPrefix("Array") { return "a list" }
            if name.hasPrefix("Dictionary") { return "an object" }
            return name
        }
    }
}

extension Config: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["gaps", "ignoredApps", "profiles", "layouts", "bindings", "arrangements", "grab"])
        gaps = try c.decodeIfPresent(Gaps.self, forKey: "gaps") ?? Gaps()
        ignoredApps = try c.decodeIfPresent([String].self, forKey: "ignoredApps") ?? []
        profiles = try c.decodeIfPresent([DisplayProfile].self, forKey: "profiles") ?? []
        layouts = try c.decodeIfPresent([WindowLayout].self, forKey: "layouts") ?? []
        bindings = try c.decodeIfPresent([KeyBinding].self, forKey: "bindings") ?? []
        arrangements = try c.decodeIfPresent([Arrangement].self, forKey: "arrangements") ?? []
        var grab: [String: CGPoint] = [:]
        for (app, offset) in try c.decodeIfPresent([String: [Double]].self, forKey: "grab") ?? [:] {
            guard offset.count == 2, offset.allSatisfy({ $0 >= 0 }) else {
                throw c.invalid("grab", "'\(app)' needs [x, y]: points from the window's top-left corner")
            }
            grab[app] = CGPoint(x: offset[0], y: offset[1])
        }
        self.grab = grab
    }
}

extension Gaps: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["outer", "inner"])
        outer = try c.decodeIfPresent(CGFloat.self, forKey: "outer") ?? 0
        inner = try c.decodeIfPresent(CGFloat.self, forKey: "inner") ?? 0
        for (key, value) in [("outer", outer), ("inner", inner)] where !(0...200).contains(value) {
            throw c.invalid(key, "must be between 0 and 200 points")
        }
    }
}

extension DisplayProfile: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["id", "displays", "onActivate"])
        id = try c.nonEmptyString("id")
        displays = try c.decode([String: DisplayMatcher].self, forKey: "displays")
        guard !displays.isEmpty else { throw c.invalid("displays", "needs at least one display") }
        guard !displays.keys.contains("") else { throw c.invalid("displays", "a display role must not be empty") }
        onActivate = try c.decodeIfPresent(String.self, forKey: "onActivate")
    }
}

extension DisplayMatcher: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["builtin", "name", "serial", "rotation"])
        builtin = try c.decodeIfPresent(Bool.self, forKey: "builtin")
        name = try c.decodeIfPresent(String.self, forKey: "name")
        serial = try c.wholeNumberIfPresent("serial").map { number in
            guard let serial = UInt32(exactly: number) else {
                throw c.invalid("serial", "must be a whole number from 0 to \(UInt32.max)")
            }
            return serial
        }
        rotation = try c.wholeNumberIfPresent("rotation")
        if let rotation, ![0, 90, 180, 270].contains(rotation) {
            throw c.invalid("rotation", "must be 0, 90, 180 or 270")
        }
        guard builtin != nil || name != nil || serial != nil || rotation != nil else {
            throw c.invalid("would match any display; set builtin, name or serial")
        }
    }
}

extension WindowLayout: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["id", "name", "rect", "grid", "cells", "center"])
        id = try c.nonEmptyString("id")
        name = try c.decodeIfPresent(String.self, forKey: "name") ?? id
        let kind = try c.oneOf(["rect", "grid", "center"])
        if kind != "grid", c.has("cells") { throw c.invalid("cells", "only goes with grid") }
        switch kind {
        case "rect":
            shape = .rect(try c.fractionRect("rect"))
        case "grid":
            let grid = try c.wholeNumbers("grid")
            guard grid.count == 2, grid.allSatisfy({ $0 >= 1 }) else {
                throw c.invalid("grid", "expected [columns, rows], each at least 1")
            }
            guard c.has("cells") else { throw c.invalid("grid needs cells: [column, row, columnSpan, rowSpan]") }
            let cells = try c.wholeNumbers("cells")
            guard cells.count == 4 else { throw c.invalid("cells", "expected [column, row, columnSpan, rowSpan]") }
            let cell = GridCell(column: cells[0], row: cells[1], columnSpan: cells[2], rowSpan: cells[3])
            guard cell.column >= 0, cell.row >= 0, cell.columnSpan >= 1, cell.rowSpan >= 1,
                  cell.column + cell.columnSpan <= grid[0], cell.row + cell.rowSpan <= grid[1] else {
                throw c.invalid("cells", "\(cells) doesn't fit a \(grid[0])x\(grid[1]) grid (columns and rows count from 0)")
            }
            shape = .grid(columns: grid[0], rows: grid[1], cell: cell)
        default:
            guard try c.decode(Bool.self, forKey: "center") else {
                throw c.invalid("center", "must be true; use rect or grid for anything else")
            }
            shape = .center
        }
    }
}

extension KeyBinding: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["keys", "when", "layout", "cycle", "action", "arrange"])
        do {
            keys = try KeyCombo(parsing: try c.decode(String.self, forKey: "keys"))
        } catch let error as KeyComboError {
            throw c.invalid("keys", error.message)
        }
        when = try c.decodeIfPresent(Condition.self, forKey: "when") ?? Condition()
        switch try c.oneOf(["layout", "cycle", "action", "arrange"]) {
        case "layout":
            target = .layout(try c.nonEmptyString("layout"))
        case "cycle":
            let ids = try c.decode([String].self, forKey: "cycle")
            guard !ids.isEmpty else { throw c.invalid("cycle", "needs at least one layout id") }
            target = .cycle(ids)
        case "action":
            let name = try c.decode(String.self, forKey: "action")
            guard let action = WindowAction(rawValue: name) else {
                throw c.invalid("action", "unknown action '\(name)'; expected \(list(WindowAction.allCases.map(\.rawValue), or: true))")
            }
            target = .action(action)
        default:
            target = .arrange(try c.nonEmptyString("arrange"))
        }
    }
}

extension KeyBinding.Condition: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["profile", "display", "orientation"])
        profile = try c.decodeIfPresent(String.self, forKey: "profile")
        display = try c.decodeIfPresent(String.self, forKey: "display")
        if let name = try c.decodeIfPresent(String.self, forKey: "orientation") {
            guard let orientation = Orientation(rawValue: name) else {
                throw c.invalid("orientation", "expected portrait or landscape")
            }
            self.orientation = orientation
        }
    }
}

extension Arrangement: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["id", "profile", "endOn", "desktops"])
        id = try c.nonEmptyString("id")
        profile = try c.nonEmptyString("profile")
        var endOn: [String: Int] = [:]
        for (role, value) in try c.decodeIfPresent([String: Double].self, forKey: "endOn") ?? [:] {
            guard let desktop = whole(value), desktop >= 1 else {
                throw c.invalid("endOn", "desktop for '\(role)' must be a whole number, 1 or more")
            }
            endOn[role] = desktop
        }
        self.endOn = endOn
        desktops = try c.decode([DesktopPlacement].self, forKey: "desktops")
    }
}

extension DesktopPlacement: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["display", "desktop", "windows"])
        display = try c.nonEmptyString("display")
        desktop = try c.wholeNumber("desktop")
        guard desktop >= 1 else { throw c.invalid("desktop", "desktops count from 1") }
        windows = try c.decodeIfPresent([WindowPlacement].self, forKey: "windows") ?? []
    }
}

extension WindowPlacement: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.object(allowing: ["app", "title", "layout", "rect", "open"])
        app = try c.nonEmptyString("app")
        title = try c.decodeIfPresent(String.self, forKey: "title")
        layout = try c.oneOf(["layout", "rect"]) == "layout"
            ? .named(try c.nonEmptyString("layout"))
            : .rect(try c.fractionRect("rect"))
        open = try c.decodeIfPresent([String].self, forKey: "open") ?? []
    }
}
