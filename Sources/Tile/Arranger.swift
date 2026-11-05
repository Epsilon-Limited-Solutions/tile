import AppKit
import TileCore

/// Runs arrangements: each app's window on its desktop and display, in its layout,
/// launching what isn't running. Built only on what the spike proved works on macOS
/// 26.2 without touching SIP (tile://debug/spike):
///
/// - Showing a desktop: post its "Switch to Desktop N" shortcut, poll until it shows.
/// - Another display: show the target desktop there, then move the window onto that
///   display through AX. It lands on the desktop showing.
/// - Another desktop of the same display: park the window on another display while the
///   target desktop comes up, then bring it back. With one display, carry it instead:
///   hold its title bar while switching desktops.
/// - Launching: show the target desktop first; the app's first window opens there.
/// - Missing desktops: added with Mission Control's add-desktop button (MissionControl).
///
/// The window server's own move calls are ignored unless the Dock makes them, so
/// there are none here.
@MainActor
final class Arranger {
    struct Report {
        var lines: [String] = []
        var placed = 0
        var alreadyInPlace = 0
        var failures: [String] = []
        /// Windows left alone because their app isn't open and the run doesn't launch.
        var skipped: [String] = []
        /// Desktop switches made, including carries. A rerun with everything in place makes none.
        var switches = 0
        /// Why the run stopped before placing anything, or was cancelled.
        var stopped: String?
    }

    private let configStore: ConfigStore
    private let profiles: DisplayProfiles
    private let hotkeys: HotkeyManager
    private let hud = ArrangeHUD()
    private(set) var isRunning = false

    // Kept across runs: an AX element keeps working while its window's desktop is
    // hidden (spike 4), which is what lets a second run fix a frame without a switch.
    fileprivate var elements: [CGWindowID: AXUIElement] = [:]
    fileprivate var titles: [CGWindowID: String] = [:]
    fileprivate var documents: [CGWindowID: String] = [:]
    fileprivate var nonStandard: Set<CGWindowID> = []
    /// For windows that can't take the exact frame (minimum sizes, terminals): what
    /// they took when asked for a frame, so a rerun counts them as in place.
    fileprivate var settled: [CGWindowID: (asked: CGRect, took: CGRect)] = [:]

    init(configStore: ConfigStore, profiles: DisplayProfiles, hotkeys: HotkeyManager) {
        self.configStore = configStore
        self.profiles = profiles
        self.hotkeys = hotkeys
    }

    /// Runs the arrangement with this id from the config.
    func run(_ id: String, launching: Bool = true) {
        guard let arrangement = configStore.config.arrangements.first(where: { $0.id == id }) else {
            Log.app.info("no arrangement has id '\(id, privacy: .public)'")
            NSSound.beep()
            return
        }
        Task { _ = await run(arrangement, launching: launching) }
    }

    /// Runs `arrangement` (from the config, or built by the arrange test) and returns
    /// what happened. Also written to ~/Library/Logs/Tile/arrange.txt.
    ///
    /// `launching` false only moves windows that are open (docking); true also opens
    /// apps and windows (login, the menu). `launchTimeout` is how long a launched app
    /// gets to show its window: at login everything starts at once and it's slow.
    func run(_ arrangement: Arrangement, launching: Bool = true, launchTimeout: Duration = .seconds(30)) async -> Report {
        guard !isRunning else {
            Log.app.info("an arrangement is already running")
            NSSound.beep()
            return Report(stopped: "an arrangement is already running")
        }
        isRunning = true
        defer { isRunning = false }

        hud.show("Arranging \(arrangement.id)…", "Esc to cancel")
        let run = Run(arranger: self, config: configStore.config, arrangement: arrangement, hud: hud,
                      launching: launching, launchTimeout: launchTimeout)
        hotkeys.holdEscape { [weak run] in
            run?.cancelled = true
            Log.app.info("arrangement cancelled with Esc")
        }
        let started = ContinuousClock.now
        await run.perform(match: profiles.match(DisplayInfo.all()))
        hotkeys.releaseEscape()

        var report = run.report
        let summary = report.stopped.map { "\(arrangement.id): \($0)" }
            ?? "Arranged \(arrangement.id): \(report.placed) placed, \(report.alreadyInPlace) already in place"
               + (report.failures.isEmpty ? "" : ", \(report.failures.count) failed")
               + (report.skipped.isEmpty ? "" : ", \(report.skipped.count) not open")
        report.lines.append("")
        report.lines.append("\(summary); \(report.switches) desktop switches; \(ContinuousClock.now - started)")
        hud.finish(summary, report.failures.joined(separator: "\n"),
                   seconds: report.failures.isEmpty && report.stopped == nil ? 2.5 : 10)
        Reports.write("arrange.txt", report.lines.joined(separator: "\n") + "\n")
        return report
    }
}

/// One run of one arrangement.
@MainActor
private final class Run {
    var cancelled = false
    private(set) var report = Arranger.Report()

    private unowned let arranger: Arranger
    private let config: Config
    private let arrangement: Arrangement
    private let hud: ArrangeHUD
    private let launching: Bool
    private let launchTimeout: Duration

    /// A connected display, with its Spaces identifier and its role in the profile.
    private struct Screen {
        let info: DisplayInfo
        let identifier: String
        let role: String?
    }

    private var screens: [Screen] = []
    private var geometry = ScreenGeometry(displays: [])
    private var snapshot: [DisplaySpaces] = []
    private var claimed: Set<CGWindowID> = []
    /// Where a window found by `windowStates` is, by window server terms.
    private var located: [CGWindowID: (pid: pid_t, space: SkyLight.SpaceID, identifier: String)] = [:]
    /// Desktops the arrangement uses that can't be shown, with why.
    private var unreachable: [DesktopRef: String] = [:]

    init(arranger: Arranger, config: Config, arrangement: Arrangement, hud: ArrangeHUD,
         launching: Bool, launchTimeout: Duration) {
        self.arranger = arranger
        self.config = config
        self.arrangement = arrangement
        self.hud = hud
        self.launching = launching
        self.launchTimeout = launchTimeout
    }

    // MARK: Run

    func perform(match: ProfileMatch?) async {
        line("Tile arrangement '\(arrangement.id)'  \(ISO8601DateFormatter().string(from: Date()))")
        guard await prepare(match: match) else { return }
        let start = Spaces.currentSpaces()

        for desktop in arrangement.desktops {
            let ref = DesktopRef(role: desktop.display, index: desktop.desktop)
            for placement in desktop.windows {
                if cancelled { break }
                hud.show("Arranging \(arrangement.id)…  Esc to cancel", "\(appName(placement.app)) → \(ref)")
                let outcome = await place(placement, on: ref)
                switch outcome {
                case .placed:
                    report.placed += 1
                    line("\(appName(placement.app)): placed on \(ref)")
                case .inPlace:
                    report.alreadyInPlace += 1
                    line("\(appName(placement.app)): already in place on \(ref)")
                case .skipped(let reason):
                    report.skipped.append("\(appName(placement.app)) → \(ref)")
                    line("\(appName(placement.app)): \(reason), left for login or the menu to open")
                case .failed(let reason):
                    let failure = "\(appName(placement.app)) → \(ref): \(reason)"
                    report.failures.append(failure)
                    line("FAILED \(failure)")
                    Log.app.error("arrangement \(self.arrangement.id, privacy: .public): \(failure, privacy: .public)")
                }
            }
        }

        if cancelled {
            report.stopped = "cancelled"
            line("cancelled; returning to the starting desktops")
            await restore(start)
        } else if arrangement.endOn.isEmpty {
            await restore(start)
        } else {
            for (role, index) in arrangement.endOn.sorted(by: { $0.key < $1.key }) {
                let ref = DesktopRef(role: role, index: index)
                guard let (screen, space) = locate(ref) else { continue }
                if !(await show(space, on: screen.identifier)) { line("couldn't end on \(ref)") }
            }
        }
    }

    /// Checks everything that would stop the run before anything moves, and adds the
    /// desktops it needs. False (with `report.stopped` set) when it can't run.
    private func prepare(match: ProfileMatch?) async -> Bool {
        func stop(_ reason: String) -> Bool {
            report.stopped = reason
            line("STOPPED: \(reason)")
            return false
        }
        guard AX.isTrusted else { return stop("Accessibility isn't granted") }
        guard !SkyLight.screenIsLocked else { return stop("the screen is locked") }
        for check in MacSettings.missionControlChecks() where !check.ok {
            return stop("\(check.name) needs fixing (\(check.detail)): \(check.fix)")
        }
        let displays = DisplayInfo.all()
        geometry = ScreenGeometry(displays: displays)
        let roles: [String: CGDirectDisplayID]
        if let match, match.profile.id == arrangement.profile {
            roles = match.roles
        } else if let profile = config.profiles.first(where: { $0.id == arrangement.profile }) {
            guard let assigned = ProfileMatching.assignRoles(profile, displays: displays) else {
                return stop("it's for profile '\(profile.id)': \(ProfileMatching.whyUnassignable(profile, displays: displays))")
            }
            roles = assigned
        } else {
            return stop("no profile has id '\(arrangement.profile)'")
        }
        func read() -> String? {
            do {
                snapshot = try Spaces.snapshot()
            } catch {
                return "can't read desktops: \(error)"
            }
            screens = displays.compactMap { info in
                guard let uuid = info.uuid,
                      let spaces = snapshot.first(where: { $0.displayIdentifier.caseInsensitiveCompare(uuid) == .orderedSame })
                else { return nil }
                return Screen(info: info, identifier: spaces.displayIdentifier, role: roles.first { $0.value == info.id }?.key)
            }
            return nil
        }
        func numbering() -> DesktopNumbering {
            DesktopNumbering(snapshot.map { display in
                DesktopNumbering.Display(role: screens.first { $0.identifier == display.displayIdentifier }?.role,
                                         desktops: display.spaces.filter { $0.desktopIndex != nil }.count)
            })
        }
        if let error = read() { return stop(error) }

        let missing = ArrangementCheck.missingDesktops(arrangement, numbering: numbering())
        if !missing.isEmpty {
            for (role, count) in missing.sorted(by: { $0.key < $1.key }) {
                guard let screen = screens.first(where: { $0.role == role }) else { continue }
                let have = numbering().desktops(for: role) ?? 0
                line("\(role) has \(have) desktop\(have == 1 ? "" : "s"), needs \(have + count): adding \(count) in Mission Control")
                do {
                    try await MissionControl.addDesktops(count, to: screen.info) {
                        let spaces = (try? Spaces.snapshot())?.first { $0.displayIdentifier == screen.identifier }
                        return spaces?.spaces.filter { $0.desktopIndex != nil }.count ?? 0
                    }
                } catch {
                    line("  couldn't: \(error)")
                }
            }
            // Mission Control's closing animation, and the desktop numbers shift.
            try? await Task.sleep(for: .milliseconds(600))
            if let error = read() { return stop(error) }
        }
        unreachable = ArrangementCheck.unreachable(arrangement, numbering: numbering()) {
            MacSettings.desktopShortcut($0) != nil
        }
        for (ref, reason) in unreachable.sorted(by: { ($0.key.role, $0.key.index) < ($1.key.role, $1.key.index) }) {
            line("can't use \(ref): \(reason)")
        }

        let assigned = MacSettings.dockAssignedApps()
        for app in Set(arrangement.desktops.flatMap { $0.windows.map(\.app) }) where assigned.contains(app.lowercased()) {
            line("warning: \(appName(app)) is assigned to a desktop in its Dock menu (Options > Assign To); set it to None or macOS will move it back")
        }
        line("profile '\(arrangement.profile)': " + screens.compactMap { s in s.role.map { "\($0) = \(s.info.name)" } }.joined(separator: ", "))
        return true
    }

    // MARK: One placement

    private enum Outcome {
        case placed, inPlace
        case skipped(String)
        case failed(String)
    }

    private func place(_ placement: WindowPlacement, on ref: DesktopRef) async -> Outcome {
        if let reason = unreachable[ref] { return .failed(reason) }
        guard let (screen, targetSpace) = locate(ref) else { return .failed("\(ref) doesn't exist") }
        guard let shape = shape(of: placement.layout) else { return .failed("no layout '\(placement.layout)'") }
        guard !config.ignoredApps.contains(placement.app) else { return .failed("it's in ignoredApps") }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: placement.app) else {
            return .failed("no app with bundle id \(placement.app) is installed")
        }
        func isInPlace(_ window: WindowState) -> Bool {
            window.desktop == ref && fits(window.id, window.frame, frame(shape, on: screen, size: window.frame.size))
        }
        let opens = placement.open.compactMap {
            OpenTarget(item: $0, home: NSHomeDirectory(), isFolder: WindowDocuments.isFolder)
        }

        // A title placement may need a look at hidden desktops first; each look makes
        // more titles known, so a few rounds always settle it.
        for _ in 1...4 {
            let states = windowStates(of: placement.app)
            switch WindowMatching.choose(placement, opens: opens, target: ref, among: states, claimed: claimed,
                                         isInPlace: isInPlace) {
            case .window(let id):
                claimed.insert(id)
                let state = states.first { $0.id == id }!
                if isInPlace(state) { return .inPlace }
                return await move(id, to: targetSpace, on: screen, shape: shape)
            case .needsTitles(let desktops):
                for desktop in desktops {
                    guard let (other, space) = locate(desktop) else { continue }
                    line("  reading \(appName(placement.app)) window titles on \(desktop)")
                    _ = await show(space, on: other.identifier)
                }
            case .open:
                guard launching else {
                    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: placement.app).isEmpty
                    return .skipped(running ? "its window isn't open" : "not running")
                }
                return await open(placement, opens: opens, appURL: appURL, space: targetSpace, on: screen, shape: shape)
            }
        }
        return .failed("couldn't read its window titles")
    }

    /// Moves a window that's already open to `space` on `screen` and gives it its frame.
    private func move(_ id: CGWindowID, to space: SkyLight.SpaceID, on screen: Screen,
                      shape: WindowLayout.Shape) async -> Outcome {
        guard let source = located[id] else { return .failed("lost track of its window") }
        if let app = NSRunningApplication(processIdentifier: source.pid), app.isHidden {
            app.unhide()
            try? await Task.sleep(for: .milliseconds(200))
        }
        let sameSpace = source.space == space
        // Moving between desktops needs the source desktop showing; fixing the frame doesn't.
        guard let element = await reach(id, pid: source.pid, space: source.space, on: source.identifier,
                                        mustShow: !sameSpace) else {
            return .failed("can't get hold of its window")
        }
        if AX.bool(element, kAXMinimizedAttribute) == true {
            AX.setBool(element, kAXMinimizedAttribute, false)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let window = WindowMover.Window(element: element, pid: source.pid, id: id)
        // Parking can shrink it; `center` keeps the size it had.
        let size = window.frame?.size ?? .zero

        if !sameSpace {
            if source.identifier != screen.identifier {
                // Both desktops can show at once, one per display.
                guard await show(space, on: screen.identifier) else { return .failed("couldn't show its desktop") }
            } else if let spare = parking(awayFrom: screen.identifier), await park(window, on: spare) {
                guard await show(space, on: screen.identifier) else { return .failed("couldn't show its desktop") }
            } else {
                guard await carry(window, to: space, on: screen) else {
                    return .failed("carrying it to its desktop didn't work")
                }
            }
        }
        return await finish(window, space: space, on: screen, shape: shape, size: size)
    }

    /// Opens the app (or a new window of it) with its desktop showing, so the window
    /// starts there.
    private func open(_ placement: WindowPlacement, opens: [OpenTarget], appURL: URL, space: SkyLight.SpaceID,
                      on screen: Screen, shape: WindowLayout.Shape) async -> Outcome {
        guard await show(space, on: screen.identifier) else { return .failed("couldn't show its desktop") }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: placement.app)
        let before = Set(Spaces.serverWindows().filter { w in running.contains { $0.processIdentifier == w.pid } }.map(\.id))
        let configuration = NSWorkspace.OpenConfiguration()
        // Activating a running app makes macOS switch to a desktop where it has windows.
        configuration.activates = running.isEmpty
        configuration.addsToRecentItems = false
        let urls = placement.open.map(Self.url)
        line("  \(running.isEmpty ? "launching" : "opening a window of") \(appName(placement.app))"
             + (urls.isEmpty ? "" : " with \(placement.open.joined(separator: ", "))"))
        let app: NSRunningApplication
        do {
            app = urls.isEmpty
                ? try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                : try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
        } catch {
            return .failed("couldn't open it: \(error.localizedDescription)")
        }
        // A placement that names its window takes it whether it's new or not: opening a
        // folder an editor already has open brings that window forward instead.
        let named = placement.title != nil || !opens.isEmpty
        let recognise = WindowMatching.recogniser(placement, opens: opens) ?? { _, _ in false }
        let pid = app.processIdentifier
        let element = await WindowWaiter.wait(pid: pid, timeout: launchTimeout) {
            AX.windows(of: AX.application(pid: pid)).first { element in
                guard let id = try? SkyLight.windowID(of: element), !claimed.contains(id),
                      named || !before.contains(id),
                      AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      let frame = AX.frame(of: element), frame.width >= 100, frame.height >= 100 else { return false }
                return !named || recognise(AX.string(element, kAXTitleAttribute) ?? "", AX.document(element))
            }
        }
        guard let element, let id = try? SkyLight.windowID(of: element) else {
            let what = placement.title.map { "matching \($0)" } ?? (placement.open.isEmpty ? "" : "showing \(placement.open.joined(separator: ", "))")
            return .failed("no window \(what.isEmpty ? "" : what + " ")appeared within \(launchTimeout)")
        }
        arranger.elements[id] = element
        claimed.insert(id)
        let landed = (try? SkyLight.spaces(forWindow: id)) ?? []
        if landed != [space] {
            // Restored to wherever it was last time: move it like any other window.
            line("  its window opened on \(label(landed)); moving it")
            _ = windowStates(of: placement.app)
            return await move(id, to: space, on: screen, shape: shape)
        }
        let window = WindowMover.Window(element: element, pid: pid, id: id)
        return await finish(window, space: space, on: screen, shape: shape, size: window.frame?.size ?? .zero)
    }

    /// Sets the window's frame on its new desktop and checks it really is there.
    private func finish(_ window: WindowMover.Window, space: SkyLight.SpaceID, on screen: Screen,
                        shape: WindowLayout.Shape, size: CGSize) async -> Outcome {
        guard let id = window.id else { return .failed("lost track of its window") }
        let target = frame(shape, on: screen, size: size)
        guard let took = await WindowMover.setFrame(window, to: target) else { return .failed("can't read its frame") }
        let now = await spaces(of: id, settlingOn: space)
        guard now == [space] else { return .failed("it ended up on \(label(now)), not \(label([space]))") }
        arranger.settled[id] = (target, took)
        if !took.isClose(to: target, within: WindowMover.tolerance) {
            line("  asked for \(fmt(target)), it took \(fmt(took))")
        }
        return .placed
    }

    /// The window's desktops, waiting up to a second for them to become `[space]`: after
    /// a move onto another display the window server reports the old desktop for a few
    /// hundred milliseconds.
    private func spaces(of id: CGWindowID, settlingOn space: SkyLight.SpaceID) async -> [SkyLight.SpaceID] {
        let deadline = ContinuousClock.now + .seconds(1)
        while true {
            let now = (try? SkyLight.spaces(forWindow: id)) ?? []
            if now == [space] || ContinuousClock.now >= deadline { return now }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Moving between desktops

    /// Another display to park a window on, showing a desktop (not a fullscreen app).
    private func parking(awayFrom identifier: String) -> Screen? {
        screens.first { screen in
            guard screen.identifier != identifier,
                  let display = snapshot.first(where: { $0.displayIdentifier == screen.identifier }) else { return false }
            let current = Spaces.currentSpaces()[screen.identifier]
            return display.spaces.contains { $0.id == current && $0.desktopIndex != nil }
        }
    }

    /// Moves the window onto `screen`'s showing desktop, sized to fit there.
    private func park(_ window: WindowMover.Window, on screen: Screen) async -> Bool {
        guard let id = window.id, let current = window.frame else { return false }
        let visible = geometry.axVisibleFrame(of: screen.info)
        let size = CGSize(width: min(current.width, visible.width * 0.9), height: min(current.height, visible.height * 0.9))
        let frame = CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        _ = await WindowMover.setFrame(window, to: frame)
        let showing = Spaces.currentSpaces()[screen.identifier] ?? 0
        let parked = await spaces(of: id, settlingOn: showing) == [showing]
        line("  parked on \(screen.info.name): \(parked ? "ok" : "didn't take, carrying instead")")
        return parked
    }

    /// Grab and switch: holds the title bar while the display switches to `space`.
    private func carry(_ window: WindowMover.Window, to space: SkyLight.SpaceID, on screen: Screen) async -> Bool {
        guard let number = shortcutNumber(of: space), let shortcut = MacSettings.desktopShortcut(number) else { return false }
        AX.raise(window.element)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        try? await Task.sleep(for: .milliseconds(300))
        guard let frame = window.frame else { return false }
        let app = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
        let offset = config.grab[app] ?? Spaces.safeGrabOffset(for: window.element, pid: window.pid, frame: frame)
        report.switches += 1
        let switched = await Spaces.carry(windowFrame: frame, grabOffset: offset, using: shortcut) {
            Spaces.currentSpaces()[screen.identifier] == space
        }
        var landed = false
        if let id = window.id { landed = await spaces(of: id, settlingOn: space) == [space] }
        line("  carried with Desktop \(number), grabbing at (\(Int(offset.x)),\(Int(offset.y))): \(landed ? "ok" : switched ? "the desktop switched without it" : "the switch timed out")")
        return landed
    }

    // MARK: Desktops

    /// Shows `space` on its display. True if it's showing afterwards.
    private func show(_ space: SkyLight.SpaceID, on identifier: String) async -> Bool {
        if Spaces.currentSpaces()[identifier] == space { return true }
        guard let number = shortcutNumber(of: space), let shortcut = MacSettings.desktopShortcut(number) else {
            line("  can't show \(label([space])): no Desktop N shortcut for it")
            return false
        }
        report.switches += 1
        let ok = await Spaces.switchDesktop(using: shortcut) { Spaces.currentSpaces()[identifier] == space }
        if !ok { line("  switching to \(label([space])) with Desktop \(number) timed out") }
        return ok
    }

    private func restore(_ start: [String: SkyLight.SpaceID]) async {
        for (identifier, space) in start.sorted(by: { $0.key < $1.key }) where Spaces.currentSpaces()[identifier] != space {
            _ = await show(space, on: identifier)
        }
    }

    private func shortcutNumber(of space: SkyLight.SpaceID) -> Int? {
        Spaces.predictedShortcutNumbers(snapshot).first { $0.value.space == space }?.key
    }

    private func locate(_ ref: DesktopRef) -> (Screen, SkyLight.SpaceID)? {
        guard let screen = screens.first(where: { $0.role == ref.role }),
              let display = snapshot.first(where: { $0.displayIdentifier == screen.identifier }),
              let space = display.spaces.first(where: { $0.desktopIndex == ref.index })
        else { return nil }
        return (screen, space.id)
    }

    // MARK: Windows

    /// Every window of `app` on a desktop, with what's known about it. Reads titles and
    /// AX elements for the ones on desktops showing now, and remembers them.
    private func windowStates(of app: String) -> [WindowState] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: app).map(\.processIdentifier))
        for pid in pids {
            for element in AX.windows(of: AX.application(pid: pid)) {
                guard let id = try? SkyLight.windowID(of: element) else { continue }
                arranger.elements[id] = element
                if AX.string(element, kAXSubroleAttribute) != kAXStandardWindowSubrole {
                    arranger.nonStandard.insert(id)
                } else if let title = AX.string(element, kAXTitleAttribute) {
                    arranger.titles[id] = title
                    arranger.documents[id] = AX.document(element)
                }
            }
        }
        let current = Spaces.currentSpaces()
        return Spaces.serverWindows(minimumSize: 100).compactMap { window in
            guard pids.contains(window.pid), !arranger.nonStandard.contains(window.id),
                  let spaces = try? SkyLight.spaces(forWindow: window.id), spaces.count == 1 else { return nil }
            for display in snapshot {
                guard let space = display.spaces.first(where: { $0.id == spaces[0] }) else { continue }
                // Fullscreen windows are their own Space and can't be moved.
                guard let index = space.desktopIndex else { return nil }
                located[window.id] = (window.pid, space.id, display.displayIdentifier)
                let role = screens.first { $0.identifier == display.displayIdentifier }?.role
                let visible = current[display.displayIdentifier] == space.id
                return WindowState(id: window.id, app: app, desktop: role.map { DesktopRef(role: $0, index: index) },
                                   frame: window.bounds, title: arranger.titles[window.id],
                                   document: arranger.documents[window.id], visible: visible)
            }
            return nil
        }
    }

    /// The window's AX element: remembered from before, or looked up with its desktop
    /// showing. `mustShow` shows its desktop even when the element is remembered.
    private func reach(_ id: CGWindowID, pid: pid_t, space: SkyLight.SpaceID, on identifier: String,
                       mustShow: Bool) async -> AXUIElement? {
        if !mustShow, let element = arranger.elements[id], AX.frame(of: element) != nil { return element }
        guard await show(space, on: identifier) else { return nil }
        let element = AX.windows(of: AX.application(pid: pid)).first { (try? SkyLight.windowID(of: $0)) == id }
        if let element { arranger.elements[id] = element }
        return element
    }

    // MARK: Frames

    private func shape(of layout: LayoutRef) -> WindowLayout.Shape? {
        switch layout {
        case .named(let id): config.layout(id)?.shape
        case .rect(let rect): .rect(rect)
        }
    }

    private func frame(_ shape: WindowLayout.Shape, on screen: Screen, size: CGSize) -> CGRect {
        LayoutEngine.frame(for: shape, in: geometry.axVisibleFrame(of: screen.info), gaps: config.gaps, currentSize: size)
    }

    /// At `target`, or where it settled last time it was asked for `target`.
    private func fits(_ id: CGWindowID, _ frame: CGRect, _ target: CGRect) -> Bool {
        if frame.isClose(to: target, within: 4) { return true }
        guard let settled = arranger.settled[id] else { return false }
        return settled.asked.isClose(to: target, within: 1) && settled.took.isClose(to: frame, within: 4)
    }

    // MARK: Reporting

    private static func url(_ item: String) -> URL {
        if item.contains("://"), let url = URL(string: item) { return url }
        return URL(fileURLWithPath: (item as NSString).expandingTildeInPath)
    }

    private func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? bundleID
    }

    private func label(_ spaces: [SkyLight.SpaceID]) -> String {
        guard spaces.count == 1 else { return spaces.isEmpty ? "no desktop" : "\(spaces.count) desktops" }
        for display in snapshot {
            guard let space = display.spaces.first(where: { $0.id == spaces[0] }) else { continue }
            let screen = screens.first { $0.identifier == display.displayIdentifier }
            let name = screen?.role ?? screen?.info.name ?? display.displayIdentifier
            return "\(name) " + (space.desktopIndex.map { "desktop \($0)" } ?? "fullscreen Space")
        }
        return "space \(spaces[0])"
    }

    private func fmt(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    private func line(_ text: String) {
        report.lines.append(text)
        Log.spaces.info("arrange: \(text, privacy: .public)")
    }
}

/// Waits for an app to show a window: woken by kAXWindowCreatedNotification, and
/// checking every 250ms anyway, since an app that's still launching may not accept
/// an observer yet.
@MainActor
enum WindowWaiter {
    private final class Flag {
        var fired = false
    }

    static func wait(pid: pid_t, timeout: Duration, _ find: () -> AXUIElement?) async -> AXUIElement? {
        let flag = Flag()
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Flag>.fromOpaque(refcon).takeUnretainedValue().fired = true
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var nextCheck = clock.now
        defer {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        while clock.now < deadline {
            if flag.fired || clock.now >= nextCheck {
                flag.fired = false
                nextCheck = clock.now + .milliseconds(250)
                if let found = find() { return found }
                if observer == nil { observer = observe(pid, callback, flag) }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return find()
    }

    private static func observe(_ pid: pid_t, _ callback: AXObserverCallback, _ flag: Flag) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer,
              AXObserverAddNotification(observer, AX.application(pid: pid), kAXWindowCreatedNotification as CFString,
                                        Unmanaged.passUnretained(flag).toOpaque()) == .success
        else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return observer
    }
}
