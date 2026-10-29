import AppKit
import TileCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let permission = AccessibilityPermission()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Tile")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        permission.requestIfNeeded()
        Log.app.info("Tile launched")
    }

    // MARK: URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    private func handle(_ url: URL) {
        Log.app.info("url \(url.absoluteString, privacy: .public)")
        let route: Route
        do {
            route = try Route.parse(url)
        } catch {
            Log.app.error("\(String(describing: error), privacy: .public)")
            NSSound.beep()
            return
        }

        switch route {
        case .debug(command: "spaces", params: _):
            SpacesReport.write()
        case .debug(command: "spike", params: _):
            Spike.start()
        default:
            Log.app.error("route not implemented yet: \(String(describing: route), privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Menu (rebuilt on every open so status lines are current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if permission.isTrusted {
            menu.addItem(disabled("Accessibility: granted"))
        } else {
            menu.addItem(item("Accessibility: not granted. Open Settings…", #selector(openAccessibilitySettings)))
        }
        for check in MacSettings.checks() where !check.ok {
            menu.addItem(disabled("Needs fix: \(check.name) (\(check.detail))"))
        }

        menu.addItem(.separator())
        menu.addItem(item("Dump Spaces Report", #selector(dumpSpaces)))
        menu.addItem(item("Open Logs Folder", #selector(openLogs)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Tile", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openAccessibilitySettings() {
        permission.openSettings()
    }

    @objc private func dumpSpaces() {
        NSWorkspace.shared.open(SpacesReport.write())
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: Reports.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Reports.directory)
    }
}
