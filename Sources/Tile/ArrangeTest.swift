import AppKit
import TileCore

/// `tile://debug/arrangetest`: the Arranger's selftest. Builds a throwaway arrangement
/// of TextEdit documents (plus Calculator, when it isn't running, for launch in place)
/// across the desktops of the connected displays, runs it, checks where every window
/// landed, runs it again to check a second run switches no desktops, then cleans up.
/// Writes ~/Library/Logs/Tile/arrangetest.txt.
///
/// It switches desktops and may carry windows by their title bar: hands off while it runs.
@MainActor
final class ArrangeTest {
    static let reportName = "arrangetest.txt"
    private static var isRunning = false

    private let arranger: Arranger
    private let configStore: ConfigStore
    private let profiles: DisplayProfiles
    private var report = ""
    private var passed = 0
    private var failed = 0

    private init(arranger: Arranger, configStore: ConfigStore, profiles: DisplayProfiles) {
        self.arranger = arranger
        self.configStore = configStore
        self.profiles = profiles
    }

    static func start(arranger: Arranger, configStore: ConfigStore, profiles: DisplayProfiles) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await ArrangeTest(arranger: arranger, configStore: configStore, profiles: profiles).run()
            isRunning = false
        }
    }

    private struct Target {
        let name: String
        let ref: DesktopRef
        let space: SkyLight.SpaceID
        let rect: CGRect
        let display: DisplayInfo
    }

    private func run() async {
        let started = ContinuousClock.now
        line("Tile arrange test  \(ISO8601DateFormatter().string(from: Date()))")
        let start = Spaces.currentSpaces()
        await tests()
        for (identifier, space) in start where Spaces.currentSpaces()[identifier] != space {
            await show(space, on: identifier)
        }
        line()
        line("desktops back where they started: \(Spaces.currentSpaces() == start)")
        line("\(failed == 0 ? "PASS" : "FAIL"): \(passed) passed, \(failed) failed, \(ContinuousClock.now - started)")
        Reports.write(Self.reportName, report)
    }

    private func tests() async {
        guard AX.isTrusted else { return abort("Accessibility not granted") }
        guard !SkyLight.screenIsLocked else { return abort("screen is locked") }
        let displays = DisplayInfo.all()
        guard let match = profiles.match(displays) else { return abort("no profile matches the connected displays") }
        guard let snapshot = try? Spaces.snapshot() else { return abort("can't read desktops") }
        let geometry = ScreenGeometry(displays: displays)

        // Roles left to right, with their desktops.
        let roles: [(role: String, display: DisplayInfo, desktops: [SpaceInfo])] = geometry.orderedDisplays.compactMap { display in
            guard let role = match.role(of: display.id), let uuid = display.uuid,
                  let spaces = snapshot.first(where: { $0.displayIdentifier.caseInsensitiveCompare(uuid) == .orderedSame })
            else { return nil }
            return (role, display, spaces.spaces.filter { $0.desktopIndex != nil })
        }
        guard let first = roles.max(by: { $0.desktops.count < $1.desktops.count }) else { return abort("no displays") }
        line("profile \(match.profile.id); " + roles.map { "\($0.role): \($0.desktops.count) desktops" }.joined(separator: ", "))

        func target(_ name: String, _ entry: (role: String, display: DisplayInfo, desktops: [SpaceInfo]), _ index: Int,
                    _ landscape: CGRect, _ portrait: CGRect) -> Target {
            let index = min(index, entry.desktops.count)
            let rect = Orientation(of: entry.display.frame.size) == .portrait ? portrait : landscape
            return Target(name: name, ref: DesktopRef(role: entry.role, index: index),
                          space: entry.desktops[index - 1].id, rect: rect, display: entry.display)
        }
        var targets = [
            target("tile-arrange-a", first, 2, CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0, y: 0, width: 1, height: 0.5)),
            target("tile-arrange-b", first, 1, CGRect(x: 0.5, y: 0, width: 0.5, height: 1), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
        ]
        if let second = roles.first(where: { $0.role != first.role }) {
            targets.append(target("tile-arrange-c", second, 2, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                  CGRect(x: 0, y: 0.25, width: 1, height: 0.5)))
        }
        let calculator = "com.apple.calculator"
        let launchCalculator = NSRunningApplication.runningApplications(withBundleIdentifier: calculator).isEmpty
        let calculatorTarget = target("Calculator", roles.last!, 1, CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3),
                                      CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3))

        // The documents open wherever TextEdit puts new windows; the arrangement has to move them.
        var documents: [TestDocument] = []
        defer { cleanUp(documents) }
        for target in targets {
            do {
                documents.append(try await TestDocument.open(named: target.name, text: "Tile arrange test. Safe to close.\n"))
            } catch {
                return abort("\(error)")
            }
        }
        for (document, target) in zip(documents, targets) {
            line("\(target.name) opened on \(label(document.id)), going to \(target.ref)")
        }

        var placements = Dictionary(grouping: targets.map { target in
            (target.ref, WindowPlacement(app: "com.apple.TextEdit", title: "^" + NSRegularExpression.escapedPattern(for: target.name),
                                         layout: .rect(target.rect)))
        }, by: \.0).mapValues { $0.map(\.1) }
        if launchCalculator {
            placements[calculatorTarget.ref, default: []].append(
                WindowPlacement(app: calculator, layout: .rect(calculatorTarget.rect)))
            line("Calculator isn't running: launching it on \(calculatorTarget.ref)")
        }
        let arrangement = Arrangement(id: "arrangetest", profile: match.profile.id, desktops: placements
            .sorted { ($0.key.role, $0.key.index) < ($1.key.role, $1.key.index) }
            .map { DesktopPlacement(display: $0.key.role, desktop: $0.key.index, windows: $0.value) })
        let count = placements.values.reduce(0) { $0 + $1.count }

        line()
        line("== first run ==")
        let firstRun = await arranger.run(arrangement)
        log(firstRun)
        check("first run placed every window", firstRun.placed + firstRun.alreadyInPlace == count && firstRun.failures.isEmpty,
              "\(firstRun.placed) placed, \(firstRun.alreadyInPlace) in place, \(firstRun.failures.count) failed")
        for (document, target) in zip(documents, targets) {
            verify(document.id, target, geometry: geometry, frame: true)
        }
        if launchCalculator,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: calculator).first,
           let window = Spaces.serverWindows().first(where: { $0.pid == app.processIdentifier }) {
            verify(window.id, calculatorTarget, geometry: geometry, frame: false)
        }

        line()
        line("== second run (should change nothing) ==")
        let secondRun = await arranger.run(arrangement)
        log(secondRun)
        check("second run found everything in place", secondRun.alreadyInPlace == count && secondRun.placed == 0,
              "\(secondRun.placed) placed, \(secondRun.alreadyInPlace) in place")
        check("second run switched no desktops", secondRun.switches == 0, "\(secondRun.switches) switches")

        if launchCalculator {
            NSRunningApplication.runningApplications(withBundleIdentifier: calculator).first?.terminate()
        }
    }

    private func cleanUp(_ documents: [TestDocument]) {
        for document in documents.reversed() { document.close() }
    }

    private func verify(_ id: CGWindowID, _ target: Target, geometry: ScreenGeometry, frame checkFrame: Bool) {
        let spaces = (try? SkyLight.spaces(forWindow: id)) ?? []
        check("\(target.name) on \(target.ref)", spaces == [target.space], "on \(spaces)")
        guard checkFrame, let bounds = Spaces.serverWindows(minimumSize: 0).first(where: { $0.id == id })?.bounds else { return }
        let expected = LayoutEngine.frame(for: .rect(target.rect), in: geometry.axVisibleFrame(of: target.display),
                                          gaps: configStore.config.gaps, currentSize: bounds.size)
        check("\(target.name) frame", bounds.isClose(to: expected, within: 4), "expected \(fmt(expected)), got \(fmt(bounds))")
    }

    private func log(_ run: Arranger.Report) {
        for text in run.lines { line("  " + text) }
        if let stopped = run.stopped { line("  stopped: \(stopped)") }
    }

    private func show(_ space: SkyLight.SpaceID, on identifier: String) async {
        let snapshot = (try? Spaces.snapshot()) ?? []
        guard let number = Spaces.predictedShortcutNumbers(snapshot).first(where: { $0.value.space == space })?.key,
              let shortcut = MacSettings.desktopShortcut(number) else { return }
        _ = await Spaces.switchDesktop(using: shortcut) { Spaces.currentSpaces()[identifier] == space }
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passed += 1 } else { failed += 1 }
        line("\(ok ? "PASS" : "FAIL") \(name)" + (ok ? "" : ": \(detail)"))
    }

    private func abort(_ reason: String) {
        failed += 1
        line("ABORT: \(reason)")
    }

    private func label(_ id: CGWindowID) -> String {
        guard let location = Spaces.location(ofWindow: id) else { return "no single desktop" }
        let name = DisplayInfo.all().first { $0.uuid?.caseInsensitiveCompare(location.display) == .orderedSame }?.name ?? location.display
        return "\(name) desktop \(location.desktopIndex)"
    }

    private func line(_ text: String = "") {
        report += text + "\n"
        Log.app.info("arrangetest: \(text, privacy: .public)")
    }

    private func fmt(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}
