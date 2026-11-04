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
}
