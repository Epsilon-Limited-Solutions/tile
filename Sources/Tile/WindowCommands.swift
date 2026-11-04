import AppKit
import TileCore

/// Layouts and actions applied to a window. The hotkeys, the URL scheme and the menu
/// act on the focused window; the selftest passes its own.
@MainActor
final class WindowCommands {
    private let configStore: ConfigStore
    private var history = WindowHistory<CGWindowID>()

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    private var config: Config { configStore.config }

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
