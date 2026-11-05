import AppKit
import Darwin
import TileCore

/// Fills the desktops after a restart: the first time Tile starts in a login session,
/// it waits for the displays to settle, then runs the active profile's `onActivate`
/// arrangement with launching on, so every app it names opens onto its desktop.
/// Restarting Tile later in the same session doesn't run it again, so apps closed on
/// purpose stay closed.
@MainActor
final class LoginArrangement {
    private(set) var isPending = false

    private let configStore: ConfigStore
    private let profiles: DisplayProfiles
    private let arranger: Arranger

    /// A dock brings its displays up one by one after login; this long without a
    /// change counts as settled.
    static let quietTime: Duration = .seconds(6)
    static let settleLimit: Duration = .seconds(45)
    /// Everything launches at once at login, so apps are slow to show a window.
    static let launchTimeout: Duration = .seconds(60)

    init(configStore: ConfigStore, profiles: DisplayProfiles, arranger: Arranger) {
        self.configStore = configStore
        self.profiles = profiles
        self.arranger = arranger
    }

    func start() {
        guard !isPending else { return }
        isPending = true
        Task {
            await run()
            isPending = false
        }
    }

    private func run() async {
        Log.app.info("login: waiting for Accessibility and the displays to settle")
        guard await Self.poll(.seconds(120), { AX.isTrusted }) else {
            return Log.app.info("login: Accessibility isn't granted; not arranging")
        }
        await settleDisplays()
        guard await Self.poll(.seconds(30), { (try? Spaces.snapshot())?.isEmpty == false }) else {
            return Log.app.error("login: can't read desktops; not arranging")
        }
        guard let match = profiles.match(DisplayInfo.all()) else {
            return Log.app.info("login: no profile matches these displays; nothing to arrange")
        }
        guard let id = match.profile.onActivate else {
            return Log.app.info("login: profile \(match.profile.id, privacy: .public) has no onActivate; nothing to arrange")
        }
        guard let arrangement = configStore.config.arrangements.first(where: { $0.id == id }) else {
            return Log.app.error("login: profile \(match.profile.id, privacy: .public) wants arrangement '\(id, privacy: .public)', and there's none")
        }
        Log.app.info("login: profile \(match.profile.id, privacy: .public), running '\(id, privacy: .public)'")
        _ = await arranger.run(arrangement, launching: true, launchTimeout: Self.launchTimeout)
    }

    private func settleDisplays() async {
        func signature() -> String {
            DisplayInfo.all().map { "\($0.id)@\($0.frame)" }.sorted().joined(separator: ";")
        }
        let clock = ContinuousClock()
        let limit = clock.now + Self.settleLimit
        var last = signature()
        var since = clock.now
        while clock.now < limit, clock.now - since < Self.quietTime {
            try? await Task.sleep(for: .milliseconds(500))
            let now = signature()
            if now != last {
                last = now
                since = clock.now
            }
        }
    }

    private static func poll(_ limit: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return condition()
    }
}

/// Which login session this is, to tell Tile's first start after logging in from a
/// restart of Tile later on.
enum LoginSession {
    private static let key = "loginSession"

    /// True the first time it's asked in a login session. The very first time Tile
    /// asks at all (just installed, nothing arranged yet) counts as not first, so
    /// installing doesn't launch apps mid-session.
    static func isFirstLaunchThisSession() -> Bool {
        let session = (loginTime() ?? bootTime())?.timeIntervalSince1970 ?? 0
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key) as? Double
        defaults.set(session, forKey: key)
        guard let previous else { return false }
        return abs(previous - session) > 1
    }

    /// When the current user logged in at the console (utmpx, what `last` reads).
    static func loginTime() -> Date? {
        setutxent()
        defer { endutxent() }
        let user = NSUserName()
        var latest: Date?
        while let entry = getutxent() {
            guard Int32(entry.pointee.ut_type) == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: entry.pointee.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", name == user else { continue }
            let time = Date(timeIntervalSince1970: TimeInterval(entry.pointee.ut_tv.tv_sec))
            if latest.map({ time > $0 }) ?? true { latest = time }
        }
        return latest
    }

    private static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }
}
