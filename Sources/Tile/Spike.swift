import AppKit
import TileCore

/// `tile://debug/spike`: build step 2 of PROMPT.md. Runs the Spaces experiments
/// against a throwaway TextEdit document (and Calculator for the launch test) and
/// writes the evidence to ~/Library/Logs/Tile/spike.txt.
///
/// It switches desktops and drags the test window, so hands off while it runs.
/// Every experiment verifies its result through SkyLight instead of trusting
/// that an API call or event did what it should.
@MainActor
final class Spike {
    static let reportName = "spike.txt"
    private static let testFile = FileManager.default.temporaryDirectory.appending(path: "tile-spike.txt")
    private static var isRunning = false

    private struct TestWindow {
        let element: AXUIElement
        let id: CGWindowID
        let pid: pid_t
    }

    private var report = ""
    private var displays: [DisplayInfo] = []
    private var startSpaces: [String: SkyLight.SpaceID] = [:]
    /// Desktop N shortcut -> where it actually went, as observed in experiment 1.
    private var observed: [Int: DesktopTarget] = [:]

    static func start() {
        guard !isRunning else {
            Log.spaces.error("spike already running")
            return
        }
        isRunning = true
        Task { @MainActor in
            await Spike().run()
            isRunning = false
        }
    }

    private func run() async {
        let started = ContinuousClock.now
        line("Tile spaces spike  \(ISO8601DateFormatter().string(from: Date()))")
        line("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        await experiments()
        await restoreStartingDesktops()
        if Events.isLeftMouseDown {
            line("WARNING: left mouse button still down at the end; releasing it")
            Events.postMouse(.leftMouseUp, at: Events.cursorLocation)
        }
        line()
        line("finished in \(ms(ContinuousClock.now - started))")
        Reports.write(Self.reportName, report)
    }

    private func experiments() async {
        guard AX.isTrusted else { line("ABORT: Accessibility not granted"); return }
        guard !SkyLight.screenIsLocked else { line("ABORT: screen is locked"); return }
        guard let snapshot = try? Spaces.snapshot(), !snapshot.isEmpty else { line("ABORT: could not read Spaces"); return }
        displays = DisplayInfo.all()
        startSpaces = Spaces.currentSpaces()

        line()
        line("== setup ==")
        for display in snapshot {
            let desktops = display.spaces.filter { $0.desktopIndex != nil }.count
            line("\(name(display.displayIdentifier)): \(desktops) desktops, showing \(label(display.currentSpace))")
        }
        line("switch to an app's Space on activate: \(MacSettings.switchesSpaceOnActivate ? "on" : "off")")

        await experimentSwitching(Spaces.predictedShortcutNumbers(snapshot))
        guard !observed.isEmpty else { line("ABORT: no desktop switch worked; nothing else can be tested"); return }

        let textEditWasRunning = isRunning("com.apple.TextEdit")
        guard let window = await openTestWindow() else { line("ABORT: TextEdit test window never appeared"); return }
        await experimentPrivateMove(window)
        await experimentCarry(window)
        await experimentCrossDisplay(window)
        await experimentLaunchInPlace(window)
        closeTestWindow(window, quitTextEdit: !textEditWasRunning)
    }

    // MARK: 1. Switching

    private func experimentSwitching(_ predicted: [Int: DesktopTarget]) async {
        line()
        line("== 1. Switch desktops by posting the Desktop N shortcut ==")
        line("hypothesis: Desktop N counts user desktops across displays, in SkyLight display order")
        var pending = predicted.keys.sorted()
        for _ in 1...2 {
            var alreadyShowing: [Int] = []
            for number in pending {
                let prediction = predicted[number]!
                guard let shortcut = MacSettings.desktopShortcut(number) else {
                    line("Desktop \(number) (predicted \(label(prediction.space))): shortcut not enabled, skipped")
                    continue
                }
                let before = Spaces.currentSpaces()
                if before[prediction.display] == prediction.space {
                    // A switch to the desktop already showing is invisible; retry once others have moved.
                    alreadyShowing.append(number)
                    continue
                }
                let started = ContinuousClock.now
                let changed = await Spaces.switchDesktop(using: shortcut) { Spaces.currentSpaces() != before }
                let elapsed = ContinuousClock.now - started
                let moved = Spaces.currentSpaces().filter { before[$0.key] != $0.value }

                guard changed, moved.count == 1, let (display, space) = moved.first else {
                    line("Desktop \(number) (predicted \(label(prediction.space))): "
                         + (changed ? "AMBIGUOUS, \(moved.count) displays changed" : "NO CHANGE after 2s"))
                    continue
                }
                let actual = DesktopTarget(display: display, space: space, desktopIndex: desktopIndex(of: space))
                observed[number] = actual
                let verdict = actual == prediction ? "OK" : "MISMATCH (predicted \(label(prediction.space)))"
                line("Desktop \(number) -> \(label(space)): \(verdict), \(ms(elapsed)) incl. \(ms(Spaces.settleDelay)) settle")
            }
            pending = alreadyShowing
            if pending.isEmpty { break }
        }
        for number in pending {
            line("Desktop \(number): already showing on both passes, unverified")
        }
    }

    // MARK: 2a. Private SkyLight writes

    private func experimentPrivateMove(_ window: TestWindow) async {
        line()
        line("== 2a. Move the test window with private SkyLight writes ==")
        guard let home = Spaces.location(ofWindow: window.id),
              let other = otherDesktop(on: home.display, than: home.space) else {
            line("skipped: need the test window on one desktop and a second desktop on that display")
            return
        }
        line("test window on \(label(home.space)), target \(label(other))")

        do {
            try SkyLight.moveWindows([window.id], toManagedSpace: other)
            try? await Task.sleep(for: .milliseconds(300))
            let now = spacesOf(window)
            line("MoveWindowsToManagedSpace: window now on \(label(now)): \(now == [other] ? "WORKS" : "no effect")")
        } catch {
            line("MoveWindowsToManagedSpace: \(error)")
        }
        await repair(window, home: home.space)

        do {
            try SkyLight.addWindows([window.id], toSpaces: [other])
            try SkyLight.removeWindows([window.id], fromSpaces: [home.space])
            try? await Task.sleep(for: .milliseconds(300))
            let now = spacesOf(window)
            line("AddWindowsToSpaces + RemoveWindowsFromSpaces: window now on \(label(now)): "
                 + (now == [other] ? "WORKS" : now.contains(other) ? "PARTIAL (added, not removed)" : "no effect"))
        } catch {
            line("AddWindowsToSpaces + RemoveWindowsFromSpaces: \(error)")
        }
        await repair(window, home: home.space)
    }

    /// Puts the test window back on `home` if a private write moved it anywhere else.
    private func repair(_ window: TestWindow, home: SkyLight.SpaceID) async {
        let now = spacesOf(window)
        guard now != [home] else { return }
        try? SkyLight.moveWindows([window.id], toManagedSpace: home)
        try? SkyLight.addWindows([window.id], toSpaces: [home])
        try? SkyLight.removeWindows([window.id], fromSpaces: now.filter { $0 != home })
        try? await Task.sleep(for: .milliseconds(300))
        line("  restored test window: now on \(label(spacesOf(window)))")
    }

    // MARK: 2b. Grab and switch, 4. AX visibility

    private func experimentCarry(_ window: TestWindow) async {
        line()
        line("== 2b. Grab and switch: hold the title bar, switch desktop, let go ==")
        guard let home = Spaces.location(ofWindow: window.id),
              let other = otherDesktop(on: home.display, than: home.space),
              let homeShortcut = shortcut(for: home.space),
              let otherShortcut = shortcut(for: other)
        else {
            line("skipped: need verified shortcuts for two desktops on the test window's display")
            return
        }
        await show(home.space, on: home.display)
        guard let start = AX.frame(of: window.element),
              let close = AX.buttonFrame(window.element, kAXCloseButtonAttribute),
              let zoom = AX.buttonFrame(window.element, kAXZoomButtonAttribute) else {
            line("skipped: can't read the test window or its title-bar buttons")
            return
        }
        // Title-bar geometry relative to the window's top-left, so grab points avoid the buttons.
        let closeRel = close.offsetBy(dx: -start.minX, dy: -start.minY)
        let zoomRel = zoom.offsetBy(dx: -start.minX, dy: -start.minY)
        line("title bar buttons (relative): close \(fmt(closeRel)), zoom \(fmt(zoomRel))")
        let barY = zoomRel.midY
        var offsets: [(name: String, offset: CGPoint)] = [
            ("right of zoom button", Spaces.grabOffset(for: window.element, frame: start)),
            ("title bar center", CGPoint(x: start.width / 2, y: barY)),
        ]
        if closeRel.minX >= 10 {
            offsets.append(("left of close button", CGPoint(x: closeRel.minX / 2, y: barY)))
        }

        var carried = false
        for (name, offset) in offsets {
            await show(home.space, on: home.display)
            await bringToFront(window)
            guard let frame = AX.frame(of: window.element) else {
                line("can't read the test window frame before '\(name)'; it's on \(label(spacesOf(window)))")
                return
            }
            let cursorBefore = Events.cursorLocation
            var buttonDown = false
            var serverWhileHeld: CGRect?

            let switched = await Spaces.carry(windowFrame: frame, grabOffset: offset, using: otherShortcut,
                                              whileHeld: {
                                                  buttonDown = Events.isLeftMouseDown
                                                  serverWhileHeld = serverBounds(window)
                                              }) {
                Spaces.currentSpaces()[home.display] == other
            }
            let after = spacesOf(window)
            let cursorAfter = Events.cursorLocation
            carried = after == [other]
            line("carry Desktop \(homeShortcut.number) -> \(otherShortcut.number), grab \(name) "
                 + "(\(Int(offset.x)),\(Int(offset.y))): switched=\(switched), window now on \(label(after)): "
                 + (carried ? "WORKS" : "FAILED"))
            line("  while held: button down=\(buttonDown), server bounds \(serverWhileHeld.map(fmt) ?? "?") "
                 + "vs \(fmt(frame)) before (followed drag=\(serverWhileHeld.map { $0.origin != frame.origin } ?? false))")
            line("  after: mouse released=\(!Events.isLeftMouseDown), "
                 + "cursor restored=\(hypot(cursorBefore.x - cursorAfter.x, cursorBefore.y - cursorAfter.y) < 2), "
                 + "server bounds \(serverBounds(window).map(fmt) ?? "GONE"), raw spaces \(after)")
            if carried { break }
            if serverBounds(window) == nil {
                line("  test window no longer exists (a click hit a title-bar button?); stopping 2b")
                return
            }
        }
        guard carried else {
            // Leave the window's desktop showing so the remaining experiments can reach it.
            await show(home.space, on: home.display)
            return
        }

        line()
        line("== 4. AX and windows on hidden desktops ==")
        await show(home.space, on: home.display)
        line("window on a hidden desktop listed in AX windows: \(axLists(window))  (hypothesis: false)")
        if let hidden = AX.frame(of: window.element) {
            let error = AX.setPosition(window.element, CGPoint(x: hidden.minX + 40, y: hidden.minY + 40))
            try? await Task.sleep(for: .milliseconds(200))
            let bounds = Spaces.serverWindows().first { $0.id == window.id }?.bounds
            line("setPosition through a held element while hidden: AXError \(error.rawValue), "
                 + "window server bounds \(bounds.map(fmt) ?? "?") (was \(fmt(hidden)))")
            AX.setPosition(window.element, hidden.origin)
        } else {
            line("held element can't read the frame while hidden")
        }
        await show(other, on: home.display)
        line("window on the visible desktop listed in AX windows: \(axLists(window))  (hypothesis: true)")

        line()
        line("== 2b. Carry it back ==")
        await bringToFront(window)
        guard let frameBack = AX.frame(of: window.element) else { return }
        let back = await Spaces.carry(windowFrame: frameBack,
                                      grabOffset: Spaces.grabOffset(for: window.element, frame: frameBack),
                                      using: homeShortcut) {
            Spaces.currentSpaces()[home.display] == home.space
        }
        let final = spacesOf(window)
        line("carry Desktop \(otherShortcut.number) -> \(homeShortcut.number): switched=\(back), "
             + "window now on \(label(final)): \(final == [home.space] ? "WORKS" : "FAILED")")
    }

    // MARK: 3. Cross-display

    private func experimentCrossDisplay(_ window: TestWindow) async {
        line()
        line("== 3. Cross-display: show the target desktop on the other display, then AX setPosition ==")
        guard let home = Spaces.location(ofWindow: window.id) else {
            line("skipped: test window isn't on exactly one Space")
            return
        }
        let snapshot = (try? Spaces.snapshot()) ?? []
        guard let destination = snapshot.first(where: { $0.displayIdentifier != home.display }),
              let screen = displays.first(where: { $0.uuid?.caseInsensitiveCompare(destination.displayIdentifier) == .orderedSame })
        else {
            line("skipped: only one display connected")
            return
        }
        // Prefer a desktop that isn't showing yet, so switching it is part of the test.
        let target = destination.spaces.first {
            $0.desktopIndex != nil && $0.id != destination.currentSpace && shortcut(for: $0.id) != nil
        }?.id ?? destination.currentSpace
        await show(target, on: destination.displayIdentifier)
        line("\(screen.name) showing \(label(Spaces.currentSpaces()[destination.displayIdentifier] ?? 0))")

        guard let original = AX.frame(of: window.element) else {
            line("skipped: can't read the test window frame (its desktop isn't showing?)")
            return
        }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: screen.visibleFrame.minX + 40, y: primaryMaxY - screen.visibleFrame.maxY + 40)
        let error = AX.setPosition(window.element, point)
        try? await Task.sleep(for: .milliseconds(300))
        let landed = spacesOf(window)
        line("setPosition onto \(screen.name) at (\(Int(point.x)),\(Int(point.y))): AXError \(error.rawValue), "
             + "window now on \(label(landed)): \(landed == [target] ? "WORKS" : "FAILED")")
        line("  frame now \(AX.frame(of: window.element).map(fmt) ?? "?")")

        AX.setPosition(window.element, original.origin)
        try? await Task.sleep(for: .milliseconds(300))
        let back = spacesOf(window)
        line("moved back: window on \(label(back)): \(back == [home.space] ? "WORKS" : "FAILED")")
    }

    // MARK: 5. Launch in place

    private func experimentLaunchInPlace(_ window: TestWindow) async {
        line()
        line("== 5. Launch an app while the target desktop is showing ==")
        let bundleID = "com.apple.calculator"
        guard !isRunning(bundleID) else { line("skipped: Calculator is already running"); return }
        guard let home = Spaces.location(ofWindow: window.id),
              let other = otherDesktop(on: home.display, than: home.space),
              shortcut(for: other) != nil, shortcut(for: home.space) != nil,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            line("skipped: need two verified desktops on one display, and Calculator")
            return
        }
        await show(other, on: home.display)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) else {
            line("Calculator failed to launch")
            return
        }
        var windowID: CGWindowID?
        _ = await waitUntil(timeout: .seconds(10)) {
            windowID = AX.windows(of: AX.application(pid: app.processIdentifier))
                .lazy.compactMap { try? SkyLight.windowID(of: $0) }.first
            return windowID != nil
        }
        if let windowID {
            let spaces = (try? SkyLight.spaces(forWindow: windowID)) ?? []
            line("Calculator window opened on \(label(spaces)): \(spaces == [other] ? "WORKS" : "FAILED (expected \(label(other)))")")
        } else {
            line("Calculator window never appeared")
        }
        app.terminate()
        _ = await waitUntil(timeout: .seconds(5)) { app.isTerminated }
        await show(home.space, on: home.display)
    }

    // MARK: Setup and cleanup

    private func openTestWindow() async -> TestWindow? {
        line()
        line("== test window ==")
        try? "Tile spike test window. Safe to close.\n".write(to: Self.testFile, atomically: true, encoding: .utf8)
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([Self.testFile], withApplicationAt: textEdit, configuration: configuration)
        } catch {
            line("opening the test file failed: \(error)")
            return nil
        }
        var found: TestWindow?
        _ = await waitUntil(timeout: .seconds(10)) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
                return false
            }
            for element in AX.windows(of: AX.application(pid: app.processIdentifier))
            where (AX.string(element, kAXTitleAttribute) ?? "").hasPrefix("tile-spike") {
                if let id = try? SkyLight.windowID(of: element) {
                    found = TestWindow(element: element, id: id, pid: app.processIdentifier)
                    return true
                }
            }
            return false
        }
        if let found {
            line("TextEdit window \(found.id) opened on \(label(spacesOf(found)))")
        }
        return found
    }

    private func closeTestWindow(_ window: TestWindow, quitTextEdit: Bool) {
        if quitTextEdit, let app = NSRunningApplication(processIdentifier: window.pid) {
            app.terminate()
        } else {
            AX.pressCloseButton(window.element)
        }
        try? FileManager.default.removeItem(at: Self.testFile)
    }

    private func restoreStartingDesktops() async {
        // Nothing was switched if the run aborted before recording where it started.
        guard !startSpaces.isEmpty else { return }
        for (display, space) in startSpaces where Spaces.currentSpaces()[display] != space {
            await show(space, on: display)
        }
        line()
        line("== end state ==")
        for (display, space) in Spaces.currentSpaces() {
            let note = startSpaces[display] == space ? "" : "  (NOT the starting desktop)"
            line("\(name(display)) showing \(label(space))\(note)")
        }
    }

    // MARK: Helpers

    /// Switches `display` to `space` with the shortcut observed in experiment 1.
    private func show(_ space: SkyLight.SpaceID, on display: String) async {
        guard Spaces.currentSpaces()[display] != space else { return }
        guard let shortcut = shortcut(for: space) else {
            line("  can't show \(label(space)): no verified shortcut")
            return
        }
        if !(await Spaces.switchDesktop(using: shortcut) { Spaces.currentSpaces()[display] == space }) {
            line("  switching to \(label(space)) with Desktop \(shortcut.number) timed out")
        }
    }

    private func shortcut(for space: SkyLight.SpaceID) -> MacSettings.DesktopShortcut? {
        observed.first { $0.value.space == space }.flatMap { MacSettings.desktopShortcut($0.key) }
    }

    /// Another desktop on `display`, preferring one with a verified shortcut.
    private func otherDesktop(on display: String, than space: SkyLight.SpaceID) -> SkyLight.SpaceID? {
        let desktops = ((try? Spaces.snapshot()) ?? [])
            .first { $0.displayIdentifier == display }?
            .spaces.filter { $0.desktopIndex != nil && $0.id != space }.map(\.id) ?? []
        return desktops.first { shortcut(for: $0) != nil } ?? desktops.first
    }

    private func bringToFront(_ window: TestWindow) async {
        AX.raise(window.element)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func axLists(_ window: TestWindow) -> Bool {
        AX.windows(of: AX.application(pid: window.pid)).contains { (try? SkyLight.windowID(of: $0)) == window.id }
    }

    /// Where the window server has the window (works on hidden desktops too); nil if it's gone.
    private func serverBounds(_ window: TestWindow) -> CGRect? {
        Spaces.serverWindows(minimumSize: 0).first { $0.id == window.id }?.bounds
    }

    private func spacesOf(_ window: TestWindow) -> [SkyLight.SpaceID] {
        (try? SkyLight.spaces(forWindow: window.id)) ?? []
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func desktopIndex(of space: SkyLight.SpaceID) -> Int {
        ((try? Spaces.snapshot()) ?? []).lazy.compactMap { $0.spaces.first { $0.id == space }?.desktopIndex }.first ?? 0
    }

    private func name(_ displayIdentifier: String) -> String {
        displays.first { $0.uuid?.caseInsensitiveCompare(displayIdentifier) == .orderedSame }?.name ?? displayIdentifier
    }

    private func label(_ space: SkyLight.SpaceID) -> String {
        for display in (try? Spaces.snapshot()) ?? [] {
            if let info = display.spaces.first(where: { $0.id == space }) {
                return "\(name(display.displayIdentifier)) " + (info.desktopIndex.map { "desktop \($0)" } ?? "fullscreen Space")
            }
        }
        return "space \(space)"
    }

    private func label(_ spaces: [SkyLight.SpaceID]) -> String {
        spaces.isEmpty ? "no Space" : spaces.map(label).joined(separator: " + ")
    }

    private func line(_ text: String = "") {
        report += text + "\n"
        Log.spaces.info("spike: \(text, privacy: .public)")
    }

    private func fmt(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    private func ms(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return "\(seconds * 1000 + attoseconds / 1_000_000_000_000_000)ms"
    }
}
