import AppKit
import TileCore

/// Which display profile is in effect, re-evaluated when displays come and go.
/// Bindings ask `match(_:)` at press time, so they follow a change immediately; the
/// profile change itself (log line, `onActivate`) waits for the displays to settle.
@MainActor
final class DisplayProfiles {
    /// A profile picked from the menu; nil means automatic. Dropped when the
    /// connected displays no longer fit it.
    private(set) var override: String?
    /// The profile as of the last settled display change.
    private(set) var current: ProfileMatch?

    private let configStore: ConfigStore
    /// Runs a profile's `onActivate` arrangement.
    private let runArrangement: (String) -> Void
    private var settle: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    /// Docking brings displays up one at a time, and each one changes the screen
    /// parameters. Waiting this long keeps a half-connected dock from activating
    /// the one-monitor profile on the way to the desk profile.
    static let settleTime: Duration = .seconds(3)

    init(configStore: ConfigStore, runArrangement: @escaping (String) -> Void) {
        self.configStore = configStore
        self.runArrangement = runArrangement
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        current = match(DisplayInfo.all())
        Log.app.info("profile: \(self.describe(self.current), privacy: .public)")
    }

    private var profiles: [DisplayProfile] { configStore.config.profiles }

    /// The profile in effect for `displays`: the override when it fits, else the
    /// first profile that matches them exactly.
    func match(_ displays: [DisplayInfo]) -> ProfileMatch? {
        if let override, let match = ProfileMatching.overrideMatch(override, profiles: profiles, displays: displays) {
            return match
        }
        return ProfileMatching.activeProfile(profiles, displays: displays)
    }

    /// Picks a profile from the menu, or goes back to automatic with nil. Doesn't run
    /// `onActivate`: that's for docking, and the menu can run any arrangement directly.
    func setOverride(_ id: String?) {
        if let id {
            guard let profile = profiles.first(where: { $0.id == id }) else {
                return refuse("no profile has id '\(id)'")
            }
            if let reason = availability(of: profile, displays: DisplayInfo.all()) {
                return refuse("can't use profile '\(id)' with these displays: \(reason)")
            }
        }
        override = id
        Log.app.info("profile override: \(id ?? "automatic", privacy: .public)")
        evaluate(runOnActivate: false)
    }

    /// Re-evaluates after a config reload (profiles may have changed). Doesn't run
    /// `onActivate`, or editing the config would launch apps.
    func configChanged() {
        evaluate(runOnActivate: false)
    }

    private func screensChanged() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleTime)
            guard !Task.isCancelled else { return }
            self?.evaluate(runOnActivate: true)
        }
    }

    private func evaluate(runOnActivate: Bool) {
        let displays = DisplayInfo.all()
        if let override, ProfileMatching.overrideMatch(override, profiles: profiles, displays: displays) == nil {
            Log.app.info("profile override '\(override, privacy: .public)' doesn't fit the connected displays any more; back to automatic")
            self.override = nil
        }
        let previous = current
        current = match(displays)
        guard current?.profile.id != previous?.profile.id else { return }
        Log.app.info("profile: \(self.describe(previous), privacy: .public) -> \(self.describe(self.current), privacy: .public) (displays: \(displays.map(\.name).joined(separator: ", "), privacy: .public))")
        if runOnActivate, let arrangement = current?.profile.onActivate {
            Log.app.info("profile \(self.current!.profile.id, privacy: .public) activated: running '\(arrangement, privacy: .public)'")
            runArrangement(arrangement)
        }
    }

    private func refuse(_ reason: String) {
        Log.app.info("\(reason, privacy: .public)")
        NSSound.beep()
    }

    func describe(_ match: ProfileMatch?) -> String {
        guard let match else { return "none" }
        return match.profile.id + (override == match.profile.id ? " (manual)" : "")
    }

    /// Whether `profile` could be picked as an override with these displays, and if not, why.
    func availability(of profile: DisplayProfile, displays: [DisplayInfo]) -> String? {
        ProfileMatching.assignRoles(profile, displays: displays) == nil
            ? ProfileMatching.whyUnassignable(profile, displays: displays)
            : nil
    }
}
