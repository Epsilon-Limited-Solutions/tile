import AppKit
import TileCore

/// `tile://selftest`: applies every layout on every display to a throwaway TextEdit
/// window, steps it through the displays with next-display and previous-display,
/// restores it, and reads back every frame. Writes ~/Library/Logs/Tile/selftest.txt.
///
/// It moves a window around every display for a few seconds but posts no events and
/// switches no desktops.
@MainActor
final class SelfTest {
    static let reportName = "selftest.txt"
    private static var isRunning = false

    private let configStore: ConfigStore
    private let commands: WindowCommands
    private var report = ""
    private var passed = 0
    private var failed = 0
    private var geometry = ScreenGeometry(displays: [])
    private var roles: ProfileMatch?

    private init(configStore: ConfigStore, commands: WindowCommands) {
        self.configStore = configStore
        self.commands = commands
    }

    static func start(configStore: ConfigStore, commands: WindowCommands) {
        guard !isRunning else {
            Log.app.error("selftest already running")
            return
        }
        isRunning = true
        Task { @MainActor in
            await SelfTest(configStore: configStore, commands: commands).run()
            isRunning = false
        }
    }

    private func run() async {
        let started = ContinuousClock.now
        line("Tile selftest  \(ISO8601DateFormatter().string(from: Date()))")
        await tests()
        line()
        line("\(failed == 0 ? "PASS" : "FAIL"): \(passed) passed, \(failed) failed, \(ContinuousClock.now - started)")
        Reports.write(Self.reportName, report)
    }

    private func tests() async {
        guard AX.isTrusted else { return abort("Accessibility not granted") }
        guard !SkyLight.screenIsLocked else { return abort("screen is locked") }

        configStore.load()
        if let error = configStore.lastError {
            line("config file has errors, testing the last good config instead:")
            line(error)
        }
        let config = configStore.config
        let displays = DisplayInfo.all()
        geometry = ScreenGeometry(displays: displays)
        roles = ProfileMatching.activeProfile(config.profiles, displays: displays)
        line("profile: \(roles?.profile.id ?? "none matches the connected displays")")
        line("gaps: outer \(config.gaps.outer), inner \(config.gaps.inner)")

        let document: TestDocument
        do {
            document = try await TestDocument.open(named: "tile-selftest", text: "Tile selftest window. Safe to close.\n")
        } catch {
            return abort("\(error)")
        }
        defer { document.close() }
        let window = document.window

        for display in geometry.orderedDisplays {
            let visible = geometry.axVisibleFrame(of: display)
            line()
            line("== layouts on \(label(display)), visible frame \(fmt(visible)) ==")
            // Layouts apply to whichever display the window is on, so put it on this one first.
            let start = CGRect(x: visible.midX - 400, y: visible.midY - 300, width: 800, height: 600)
            check("move here", expected: start, actual: await WindowMover.setFrame(window, to: start), on: display)
            for layout in config.layouts {
                let size = window.frame?.size ?? .zero
                let expected = LayoutEngine.frame(for: layout.shape, in: visible, gaps: config.gaps, currentSize: size)
                let actual = await commands.apply(layout, to: window)
                check(layout.id, expected: expected, actual: actual, on: display)
            }
        }

        line()
        line("== next-display, previous-display, restore ==")
        let ordered = geometry.orderedDisplays
        let firstVisible = geometry.axVisibleFrame(of: ordered[0])
        // Moved without Tile's history knowing, like a drag by hand: restore should come back here.
        await WindowMover.setFrame(window, to: CGRect(x: firstVisible.minX + 40, y: firstVisible.minY + 40, width: 700, height: 500))
        let home = window.frame ?? .zero
        var from = ordered[0]
        var frame = home
        for step in 1...ordered.count {
            let to = ordered[step % ordered.count]
            let expected = ScreenGeometry.map(frame, from: geometry.axVisibleFrame(of: from), to: geometry.axVisibleFrame(of: to))
            let actual = await commands.perform(.nextDisplay, on: window)
            check("next-display to \(label(to))", expected: expected, actual: actual, on: to)
            (from, frame) = (to, actual ?? expected)
        }
        let last = ordered[ordered.count - 1]
        let expected = ScreenGeometry.map(frame, from: geometry.axVisibleFrame(of: from), to: geometry.axVisibleFrame(of: last))
        check("previous-display to \(label(last))", expected: expected,
              actual: await commands.perform(.previousDisplay, on: window), on: last)
        check("restore", expected: home, actual: await commands.perform(.restore, on: window), on: ordered[0])
    }

    private func check(_ name: String, expected: CGRect, actual: CGRect?, on display: DisplayInfo) {
        guard let actual else {
            failed += 1
            line("FAIL \(name): couldn't read the frame back")
            return
        }
        let landedOn = geometry.display(for: actual)
        if actual.isClose(to: expected, within: WindowMover.tolerance), landedOn?.id == display.id {
            passed += 1
            line("PASS \(name) \(fmt(actual))")
        } else {
            failed += 1
            let elsewhere = landedOn?.id == display.id ? "" : " on \(landedOn.map(label) ?? "no display")"
            line("FAIL \(name): expected \(fmt(expected)), got \(fmt(actual))\(elsewhere)")
        }
    }

    private func abort(_ reason: String) {
        failed += 1
        line("ABORT: \(reason)")
    }

    private func label(_ display: DisplayInfo) -> String {
        roles?.role(of: display.id).map { "\($0) (\(display.name))" } ?? display.name
    }

    private func line(_ text: String = "") {
        report += text + "\n"
        Log.app.info("selftest: \(text, privacy: .public)")
    }

    private func fmt(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}
