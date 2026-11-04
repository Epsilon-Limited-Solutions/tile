import CoreGraphics

/// The frame each window had before Tile started moving it, so `restore` can put it
/// back. A run of Tile moves keeps the first frame; once the window has been moved
/// some other way (by hand, by the app), the next Tile move starts a new run.
public struct WindowHistory<Key: Hashable> {
    private struct Entry {
        var original: CGRect
        /// Where Tile's last move left the window.
        var placed: CGRect
    }

    /// A window counts as where Tile left it within this many points.
    public static var tolerance: CGFloat { 4 }

    private var entries: [Key: Entry] = [:]

    public init() {}

    /// Tile moved `key` from `current` and it ended up at `placed`.
    public mutating func record(_ key: Key, from current: CGRect, to placed: CGRect) {
        if let entry = entries[key], current.isClose(to: entry.placed, within: Self.tolerance) {
            entries[key]?.placed = placed
        } else {
            entries[key] = Entry(original: current, placed: placed)
        }
    }

    /// The frame to restore `key` to, forgetting it; nil if Tile never moved it.
    public mutating func takeOriginal(_ key: Key) -> CGRect? {
        entries.removeValue(forKey: key)?.original
    }
}
