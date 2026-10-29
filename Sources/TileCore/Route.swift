import Foundation

/// A parsed `tile://` URL. The URL scheme is both the automation hook
/// (Raycast, Shortcuts, `open tile://...`) and the test harness.
public enum Route: Equatable, Sendable {
    case apply(layout: String)
    case action(name: String)
    case arrange(id: String)
    case capture(name: String)
    case selftest
    /// `tile://debug/<command>?key=value`: diagnostics and Spaces experiments.
    case debug(command: String, params: [String: String])
}

public enum RouteError: Error, Equatable, CustomStringConvertible {
    case notTileURL(String)
    case unknownRoute(String)
    case missingParameter(route: String, name: String)

    public var description: String {
        switch self {
        case .notTileURL(let url): "not a tile:// URL: \(url)"
        case .unknownRoute(let route): "unknown route '\(route)'"
        case .missingParameter(let route, let name): "tile://\(route) needs a '\(name)' parameter"
        }
    }
}

extension Route {
    public static func parse(_ url: URL) throws -> Route {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "tile",
              let host = components.host?.lowercased(), !host.isEmpty
        else { throw RouteError.notTileURL(url.absoluteString) }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }
        func require(_ name: String) throws -> String {
            guard let value = params[name], !value.isEmpty else {
                throw RouteError.missingParameter(route: host, name: name)
            }
            return value
        }

        switch host {
        case "apply": return .apply(layout: try require("layout"))
        case "action": return .action(name: try require("name"))
        case "arrange": return .arrange(id: try require("id"))
        case "capture": return .capture(name: try require("name"))
        case "selftest": return .selftest
        case "debug":
            guard let command = components.path.split(separator: "/").first.map(String.init) else {
                throw RouteError.unknownRoute("debug")
            }
            return .debug(command: command, params: params)
        default:
            throw RouteError.unknownRoute(host)
        }
    }
}
