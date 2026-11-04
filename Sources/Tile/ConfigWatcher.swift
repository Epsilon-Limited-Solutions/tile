import CoreServices
import Foundation

/// Calls `onChange` when anything in a directory changes. Watches the directory, not
/// the file: editors save by writing a temp file and renaming it over the original,
/// which would leave a watch on the old file looking at nothing.
@MainActor
final class ConfigWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(directory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info).takeUnretainedValue()
            // Delivered on the main queue (FSEventStreamSetDispatchQueue below).
            MainActor.assumeIsolated { watcher.onChange() }
        }
        // FSEvents reports real paths, so a symlinked ~/.config has to be resolved first.
        let path = directory.resolvingSymlinksInPath().path
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else {
            Log.app.error("can't watch \(path, privacy: .public); edit the config and use Reload Config")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        Log.app.info("watching \(path, privacy: .public)")
    }
}
