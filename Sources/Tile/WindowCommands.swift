import AppKit
import TileCore

/// Layouts and actions applied to a window. The hotkeys, the URL scheme and the menu
/// act on the focused window; the selftest passes its own.
@MainActor
final class WindowCommands {
    private let configStore: ConfigStore
    private let profiles: DisplayProfiles
    /// Runs an arrangement by id (an `arrange` binding).
    private let arrange: (String) -> Void
    private var history = WindowHistory<CGWindowID>()
    /// Per window: the cycle binding last applied, which entry, and the frame it left.
    private var lastCycle: [CGWindowID: (binding: KeyBinding, index: Int, frame: CGRect)] = [:]
    private var pressQueue: Task<Void, Never>?

    init(configStore: ConfigStore, profiles: DisplayProfiles, arrange: @escaping (String) -> Void) {
        self.configStore = configStore
        self.profiles = profiles
        self.arrange = arrange
    }

    private var config: Config { configStore.config }

    // MARK: Hotkeys

    /// Handles presses one at a time, in order, so a quick double press steps a cycle twice.
    func press(_ combo: KeyCombo) {
        let previous = pressQueue
        pressQueue = Task {
            await previous?.value
            await handle(combo)
        }
    }

    /// Resolves the binding for `combo` against the active profile and the display the
    /// focused window is on, then runs it.
    private func handle(_ combo: KeyCombo) async {
        let displays = DisplayInfo.all()
        let geometry = ScreenGeometry(displays: displays)
        let match = profiles.match(displays)
        var context = BindingContext(profile: match?.profile.id)
        var window: WindowMover.Window?
        var noWindowReason = ""
        do {
            window = try WindowMover.focusedWindow(ignoring: config.ignoredApps)
        } catch {
            noWindowReason = "\(error)"
        }
        if let frame = window?.frame, let display = geometry.display(for: frame) {
            context.display = match?.role(of: display.id)
            context.orientation = Orientation(of: display.frame.size)
        }
        let scope = "profile \(context.profile ?? "none"), display \(context.display ?? "none"), \(context.orientation?.rawValue ?? "no window")"
        guard let binding = BindingTable(config.bindings).resolve(combo, in: context) else {
            return refuse("\(combo): no binding applies (\(scope))")
        }
        Log.app.info("\(combo.description, privacy: .public) (\(scope, privacy: .public)) -> \(String(describing: binding.target), privacy: .public)")

        if case .arrange(let id) = binding.target {
            return arrange(id)
        }
        guard let window else { return refuse(noWindowReason) }
        switch binding.target {
        case .layout(let id):
            guard let layout = config.layout(id) else { return refuse("no layout has id '\(id)'") }
            await apply(layout, to: window)
        case .cycle(let ids):
            await cycle(ids, of: binding, on: window)
        case .action(let action):
            await perform(action, on: window)
        case .arrange:
            break
        }
    }

    /// Repeated presses step through `ids` while the window stays where the last press put it.
    private func cycle(_ ids: [String], of binding: KeyBinding, on window: WindowMover.Window) async {
        guard let current = window.frame else { return refuse("can't read the window's frame") }
        let last = window.id.flatMap { lastCycle[$0] }.flatMap { $0.binding == binding ? ($0.index, $0.frame) : nil }
        let index = Cycle.nextIndex(count: ids.count, last: last, current: current)
        guard let layout = config.layout(ids[index]) else { return refuse("no layout has id '\(ids[index])'") }
        let placed = await apply(layout, to: window)
        if let id = window.id, let placed { lastCycle[id] = (binding, index, placed) }
    }

    // MARK: Focused window. Beeps when there's nothing to act on.

    func apply(layoutID: String) async {
        guard let layout = config.layout(layoutID) else { return refuse("no layout has id '\(layoutID)'") }
        guard let window = focusedWindow() else { return }
        await apply(layout, to: window)
    }

    func perform(_ action: WindowAction) async {
        guard let window = focusedWindow() else { return }
        await perform(action, on: window)
    }

    // MARK: Any window. Return where the window ended up, nil if nothing moved.

    @discardableResult
    func apply(_ layout: WindowLayout, to window: WindowMover.Window) async -> CGRect? {
        guard let current = window.frame else { refuse("can't read the window's frame"); return nil }
        let geometry = ScreenGeometry(displays: DisplayInfo.all())
        guard let display = geometry.display(for: current) else { refuse("no displays"); return nil }
        let target = LayoutEngine.frame(for: layout.shape, in: geometry.axVisibleFrame(of: display),
                                        gaps: config.gaps, currentSize: current.size)
        return await move(window, from: current, to: target)
    }

    @discardableResult
    func perform(_ action: WindowAction, on window: WindowMover.Window) async -> CGRect? {
        guard let current = window.frame else { refuse("can't read the window's frame"); return nil }
        switch action {
        case .restore:
            guard let id = window.id, let original = history.takeOriginal(id) else {
                refuse("nothing to restore: Tile hasn't moved this window")
                return nil
            }
            return await WindowMover.setFrame(window, to: original)
        case .nextDisplay, .previousDisplay:
            let geometry = ScreenGeometry(displays: DisplayInfo.all())
            guard let display = geometry.display(for: current),
                  let next = geometry.display(action == .nextDisplay ? 1 : -1, from: display)
            else { refuse("no displays"); return nil }
            let target = ScreenGeometry.map(current, from: geometry.axVisibleFrame(of: display),
                                            to: geometry.axVisibleFrame(of: next))
            return await move(window, from: current, to: target)
        }
    }

    private func move(_ window: WindowMover.Window, from current: CGRect, to target: CGRect) async -> CGRect? {
        let actual = await WindowMover.setFrame(window, to: target)
        guard let actual else { return nil }
        if let id = window.id { history.record(id, from: current, to: actual) }
        if !actual.isClose(to: target, within: WindowMover.tolerance) {
            Log.app.info("asked for \(String(describing: target), privacy: .public), window took \(String(describing: actual), privacy: .public)")
        }
        return actual
    }

    private func focusedWindow() -> WindowMover.Window? {
        do {
            return try WindowMover.focusedWindow(ignoring: config.ignoredApps)
        } catch {
            refuse("\(error)")
            return nil
        }
    }

    private func refuse(_ reason: String) {
        Log.app.info("\(reason, privacy: .public)")
        NSSound.beep()
    }
}
