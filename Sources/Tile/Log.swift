import Foundation
import os

/// Watch with: log stream --predicate 'subsystem == "com.epsilonlimited.tile"'
enum Log {
    private static let subsystem = "com.epsilonlimited.tile"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let spaces = Logger(subsystem: subsystem, category: "spaces")
}

/// Plain-text reports in ~/Library/Logs/Tile, written for the selftest and debug routes.
enum Reports {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Tile", directoryHint: .isDirectory)

    @discardableResult
    static func write(_ name: String, _ text: String) -> URL {
        let url = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            Log.app.info("wrote report \(url.path, privacy: .public)")
        } catch {
            Log.app.error("could not write report \(url.path, privacy: .public): \(error, privacy: .public)")
        }
        return url
    }
}
