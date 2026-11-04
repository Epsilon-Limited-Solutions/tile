import AppKit
import TileCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let permission = AccessibilityPermission()
    private let configStore = ConfigStore()
    private lazy var profiles = DisplayProfiles(configStore: configStore) { [unowned self] id in runArrangement(id) }
    private lazy var commands = WindowCommands(configStore: configStore, profiles: profiles) { [unowned self] id in
        runArrangement(id)
    }
    private lazy var hotkeys = HotkeyManager { [unowned self] combo in commands.press(combo) }
    private lazy var arranger = Arranger(configStore: configStore, profiles: profiles, hotkeys: hotkeys)
    private var watcher: ConfigWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        reloadConfig()
        watcher = ConfigWatcher(directory: ConfigStore.url.deletingLastPathComponent()) { [unowned self] in
            reloadConfig()
        }
        permission.requestIfNeeded()
        Log.app.info("Tile launched")
    }

    /// Loads the config file and re-registers every hotkey. A bad file keeps the last
    /// good config and turns the menu bar icon into a warning.
    private func reloadConfig() {
        configStore.load()
        profiles.configChanged()
        hotkeys.register(BindingTable(configStore.config.bindings).combos)
        let symbol = configStore.lastError == nil ? "rectangle.split.2x2" : "exclamationmark.triangle"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tile")
    }

    private func runArrangement(_ id: String) {
        arranger.run(id)
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
        case .apply(let layout):
            Task { await commands.apply(layoutID: layout) }
        case .action(let name):
            guard let action = WindowAction(rawValue: name) else {
                Log.app.error("unknown action '\(name, privacy: .public)'")
                NSSound.beep()
                return
            }
            Task { await commands.perform(action) }
        case .arrange(let id):
            runArrangement(id)
        case .capture(let name):
            Capture.run(named: name, configStore: configStore, profiles: profiles)
        case .profile(let id):
            profiles.setOverride(id)
        case .selftest:
            SelfTest.start(configStore: configStore, commands: commands)
        case .debug(command: "spaces", params: _):
            SpacesReport.write()
        case .debug(command: "spike", params: _):
            Spike.start()
        case .debug(command: "arrangetest", params: _):
            ArrangeTest.start(arranger: arranger, configStore: configStore, profiles: profiles)
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
        if let error = configStore.lastError {
            menu.addItem(disabled("Config error, using the last good config:"))
            for issue in error.split(separator: "\n") { menu.addItem(disabled("  \(issue)")) }
        }
        menu.addItem(disabled("Hotkeys: \(hotkeys.registeredCount) active"))
        for (combo, reason) in hotkeys.unavailable {
            menu.addItem(disabled("  \(combo) unavailable (\(reason))"))
        }

        menu.addItem(.separator())
        menu.addItem(arrangementsItem())
        menu.addItem(item("Capture Current Desktops into Arrangement…", #selector(capture)))
        menu.addItem(.separator())
        menu.addItem(profileItem())
        menu.addItem(item("Copy Current Displays as Profile JSON", #selector(copyProfileJSON)))

        menu.addItem(.separator())
        menu.addItem(item("Open Config File", #selector(openConfig)))
        menu.addItem(item("Reload Config", #selector(reloadConfigFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Run Selftest", #selector(runSelftest)))
        menu.addItem(item("Dump Spaces Report", #selector(dumpSpaces)))
        menu.addItem(item("Open Logs Folder", #selector(openLogs)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Tile", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    /// Each arrangement; the ones for another profile say which.
    private func arrangementsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Arrangements", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = profiles.match(DisplayInfo.all())?.profile.id
        for arrangement in configStore.config.arrangements {
            let suffix = arrangement.profile == current ? "" : " (\(arrangement.profile))"
            let entry = item(arrangement.id + suffix, #selector(runArrangementFromMenu(_:)))
            entry.representedObject = arrangement.id
            submenu.addItem(entry)
        }
        if submenu.items.isEmpty { submenu.addItem(disabled("None yet: capture one, or add it to config.json")) }
        parent.submenu = submenu
        return parent
    }

    /// "Profile: desk", with a submenu to pick one by hand.
    private func profileItem() -> NSMenuItem {
        let displays = DisplayInfo.all()
        let match = profiles.match(displays)
        let parent = NSMenuItem(title: "Profile: \(profiles.describe(match))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let automatic = item("Automatic", #selector(pickProfile(_:)))
        automatic.state = profiles.override == nil ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())
        for profile in configStore.config.profiles {
            let reason = profiles.availability(of: profile, displays: displays)
            let entry = item(profile.id + (reason.map { " (\($0))" } ?? ""), #selector(pickProfile(_:)))
            entry.representedObject = profile.id
            entry.state = profiles.override == profile.id ? .on : .off
            entry.isEnabled = reason == nil
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
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

    @objc private func runArrangementFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runArrangement(id)
    }

    @objc private func capture() {
        Capture.ask(configStore: configStore, profiles: profiles)
    }

    @objc private func pickProfile(_ sender: NSMenuItem) {
        profiles.setOverride(sender.representedObject as? String)
    }

    @objc private func copyProfileJSON() {
        let json = ProfileSkeleton.json(for: DisplayInfo.all())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        Log.app.info("copied profile JSON:\n\(json, privacy: .public)")
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(ConfigStore.url)
    }

    @objc private func reloadConfigFromMenu() {
        reloadConfig()
    }

    @objc private func runSelftest() {
        SelfTest.start(configStore: configStore, commands: commands)
    }

    @objc private func dumpSpaces() {
        NSWorkspace.shared.open(SpacesReport.write())
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: Reports.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Reports.directory)
    }
}
