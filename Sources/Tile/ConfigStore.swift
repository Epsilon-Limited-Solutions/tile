import Foundation
import TileCore

/// ~/.config/tile/config.json. A bad file never replaces a good config: Tile keeps
/// running on the last one that loaded and shows the error in the menu.
@MainActor
final class ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/tile/config.json")

    /// The last config that parsed and validated; the defaults until one does.
    private(set) var config = Config.defaults
    /// Why the file on disk isn't the one in use, or nil when it is.
    private(set) var lastError: String?

    /// Reads the file, writing the default config first if there isn't one.
    func load() {
        do {
            if !FileManager.default.fileExists(atPath: Self.url.path) {
                try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Config.defaultJSON.write(to: Self.url, atomically: true, encoding: .utf8)
                Log.app.info("wrote the default config to \(Self.url.path, privacy: .public)")
            }
            config = try Config.parse(Data(contentsOf: Self.url))
            lastError = nil
            Log.app.info("loaded config: \(self.config.layouts.count) layouts, \(self.config.bindings.count) bindings, \(self.config.profiles.count) profiles, \(self.config.arrangements.count) arrangements")
        } catch {
            lastError = "\(error)"
            Log.app.error("config not loaded, keeping the last good one: \(String(describing: error), privacy: .public)")
        }
    }

    struct WriteError: Error, CustomStringConvertible {
        let description: String
    }

    /// Rewrites one top-level section of the file (Capture, Settings) and leaves the
    /// rest of the text as the user wrote it. `section` gets the config as it is on
    /// disk and returns the section's new JSON. Refuses if the file has errors now or
    /// the result wouldn't load. The watcher sees the write and reloads.
    func replaceSection(_ key: String, with section: (Config) throws -> String) throws {
        // Through a symlink (dotfiles), so the write doesn't replace the link with a file.
        let url = Self.url.resolvingSymlinksInPath()
        let text = try String(contentsOf: url, encoding: .utf8)
        let current: Config
        do {
            current = try Config.parse(Data(text.utf8))
        } catch {
            throw WriteError(description: "config.json has errors; fix them first:\n\(error)")
        }
        let updated = try ConfigText.replacingValue(of: key, with: try section(current), in: text)
        do {
            _ = try Config.parse(Data(updated.utf8))
        } catch {
            throw WriteError(description: "the new \(key) wouldn't load, so nothing was written:\n\(error)")
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        Log.app.info("rewrote \(key, privacy: .public) in \(url.path, privacy: .public)")
    }
}
