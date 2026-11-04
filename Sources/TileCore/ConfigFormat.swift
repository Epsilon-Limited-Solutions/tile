import CoreGraphics
import Foundation

/// Writes config sections back as JSON text laid out like the default config: one
/// layout or binding per line, arrangements nested by desktop. Capture and the
/// settings window rewrite one section at a time (see `ConfigText`), so the rest of
/// the file keeps the user's own formatting.
public enum ConfigFormat {
    /// A JSON string literal.
    public static func string(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    /// Up to three decimals, no trailing zeros: 0.5, 1, 0.333.
    public static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.3f", rounded)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    public static func strings(_ values: [String]) -> String {
        "[" + values.map(string).joined(separator: ", ") + "]"
    }

    /// A list of items, one per line, closing bracket at `indent`.
    static func list(_ items: [String], indent: Int) -> String {
        guard !items.isEmpty else { return "[]" }
        let pad = String(repeating: " ", count: indent + 2)
        return "[\n" + items.map { pad + $0 }.joined(separator: ",\n") + "\n" + String(repeating: " ", count: indent) + "]"
    }

    static func rect(_ rect: CGRect) -> String {
        "[" + [rect.minX, rect.minY, rect.width, rect.height].map { number(Double($0)) }.joined(separator: ", ") + "]"
    }

    // MARK: Sections

    public static func layouts(_ layouts: [WindowLayout], indent: Int = 2) -> String {
        list(layouts.map(layout), indent: indent)
    }

    public static func layout(_ layout: WindowLayout) -> String {
        var fields = ["\"id\": \(string(layout.id))", "\"name\": \(string(layout.name))"]
        switch layout.shape {
        case .rect(let r):
            fields.append("\"rect\": \(rect(r))")
        case .grid(let columns, let rows, let cell):
            fields.append("\"grid\": [\(columns), \(rows)]")
            fields.append("\"cells\": [\(cell.column), \(cell.row), \(cell.columnSpan), \(cell.rowSpan)]")
        case .center:
            fields.append("\"center\": true")
        }
        return "{ " + fields.joined(separator: ", ") + " }"
    }

    public static func bindings(_ bindings: [KeyBinding], indent: Int = 2) -> String {
        list(bindings.map(binding), indent: indent)
    }

    public static func binding(_ binding: KeyBinding) -> String {
        var fields = ["\"keys\": \(string(binding.keys.description))"]
        if let when = condition(binding.when) { fields.append("\"when\": \(when)") }
        switch binding.target {
        case .layout(let id): fields.append("\"layout\": \(string(id))")
        case .cycle(let ids): fields.append("\"cycle\": \(strings(ids))")
        case .action(let action): fields.append("\"action\": \(string(action.rawValue))")
        case .arrange(let id): fields.append("\"arrange\": \(string(id))")
        }
        return "{ " + fields.joined(separator: ", ") + " }"
    }

    static func condition(_ when: KeyBinding.Condition) -> String? {
        var fields: [String] = []
        if let profile = when.profile { fields.append("\"profile\": \(string(profile))") }
        if let display = when.display { fields.append("\"display\": \(string(display))") }
        if let orientation = when.orientation { fields.append("\"orientation\": \(string(orientation.rawValue))") }
        return fields.isEmpty ? nil : "{ " + fields.joined(separator: ", ") + " }"
    }

    public static func arrangements(_ arrangements: [Arrangement], indent: Int = 2) -> String {
        list(arrangements.map { arrangement($0, indent: indent + 2) }, indent: indent)
    }

    /// `indent` is the column the arrangement's opening brace sits at.
    static func arrangement(_ arrangement: Arrangement, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent + 2)
        var text = "{ \"id\": \(string(arrangement.id)), \"profile\": \(string(arrangement.profile)),\n"
        if !arrangement.endOn.isEmpty {
            let endOn = arrangement.endOn.sorted { $0.key < $1.key }.map { "\(string($0.key)): \($0.value)" }
            text += pad + "\"endOn\": { " + endOn.joined(separator: ", ") + " },\n"
        }
        let desktops = arrangement.desktops.map { pad + "  " + desktop($0, indent: indent + 4) }
        text += pad + "\"desktops\": " + (desktops.isEmpty ? "[]" : "[\n" + desktops.joined(separator: ",\n") + " ]")
        return text + " }"
    }

    static func desktop(_ desktop: DesktopPlacement, indent: Int) -> String {
        let head = "{ \"display\": \(string(desktop.display)), \"desktop\": \(desktop.desktop), \"windows\": "
        guard !desktop.windows.isEmpty else { return head + "[] }" }
        let pad = String(repeating: " ", count: indent + 4)
        return head + "[\n" + desktop.windows.map { pad + window($0) }.joined(separator: ",\n") + " ] }"
    }

    public static func window(_ window: WindowPlacement) -> String {
        var fields = ["\"app\": \(string(window.app))"]
        if let title = window.title { fields.append("\"title\": \(string(title))") }
        switch window.layout {
        case .named(let id): fields.append("\"layout\": \(string(id))")
        case .rect(let r): fields.append("\"rect\": \(rect(r))")
        }
        if !window.open.isEmpty { fields.append("\"open\": \(strings(window.open))") }
        return "{ " + fields.joined(separator: ", ") + " }"
    }
}

/// Edits one top-level value of the config file's text and leaves every other byte
/// alone, so rewriting the arrangements doesn't reformat the user's layouts.
public enum ConfigText {
    public struct ScanError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "config.json isn't valid JSON (\(message)); fix it first" }
    }

    /// `text` with the value of top-level `key` replaced by `value`. A missing key is
    /// added as the last member.
    public static func replacingValue(of key: String, with value: String, in text: String) throws -> String {
        var scanner = Scanner(Array(text.unicodeScalars))
        scanner.skipWhitespace()
        try scanner.expect("{")
        var lastValueEnd: Int?
        while true {
            scanner.skipWhitespace()
            if scanner.peek == "}" { break }
            let name = try scanner.string()
            scanner.skipWhitespace()
            try scanner.expect(":")
            scanner.skipWhitespace()
            let start = scanner.index
            try scanner.skipValue()
            if name == key {
                return scanner.text(0..<start) + value + scanner.text(scanner.index..<scanner.count)
            }
            lastValueEnd = scanner.index
            scanner.skipWhitespace()
            if scanner.peek == "," { scanner.index += 1; continue }
            if scanner.peek == "}" { break }
            throw ScanError(message: "expected , or } after \(ConfigFormat.string(name))")
        }
        let member = "\(ConfigFormat.string(key)): \(value)"
        guard let lastValueEnd else {
            let close = scanner.index
            return scanner.text(0..<close).trimmingTrailingWhitespace() + "\n  " + member + "\n" + scanner.text(close..<scanner.count)
        }
        return scanner.text(0..<lastValueEnd) + ",\n\n  " + member + scanner.text(lastValueEnd..<scanner.count)
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0
        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var count: Int { scalars.count }
        var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        func text(_ range: Range<Int>) -> String {
            var string = ""
            string.unicodeScalars.append(contentsOf: scalars[range])
            return string
        }

        mutating func skipWhitespace() {
            while let c = peek, c == " " || c == "\n" || c == "\t" || c == "\r" { index += 1 }
        }

        mutating func expect(_ c: Unicode.Scalar) throws {
            guard peek == c else { throw ScanError(message: "expected \(c) at character \(index)") }
            index += 1
        }

        /// A string literal's raw contents (escapes kept as written).
        mutating func string() throws -> String {
            try expect("\"")
            let start = index
            while let c = peek {
                if c == "\\" { index += 2; continue }
                if c == "\"" {
                    let contents = text(start..<index)
                    index += 1
                    return contents
                }
                index += 1
            }
            throw ScanError(message: "unterminated string")
        }

        mutating func skipValue() throws {
            switch peek {
            case "\"":
                _ = try string()
            case "{", "[":
                var depth = 0
                while let c = peek {
                    if c == "\"" { _ = try string(); continue }
                    if c == "{" || c == "[" { depth += 1 }
                    if c == "}" || c == "]" { depth -= 1 }
                    index += 1
                    if depth == 0 { return }
                }
                throw ScanError(message: "unclosed bracket")
            case nil:
                throw ScanError(message: "unexpected end")
            default:
                // Number, true, false, null.
                let start = index
                while let c = peek, !(c == "," || c == "}" || c == "]" || c == " " || c == "\n" || c == "\t" || c == "\r") {
                    index += 1
                }
                if index == start { throw ScanError(message: "expected a value at character \(index)") }
            }
        }
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var copy = self
        while let last = copy.last, last.isWhitespace { copy.removeLast() }
        return copy
    }
}
