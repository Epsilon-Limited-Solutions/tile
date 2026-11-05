import AppKit
import ServiceManagement
import TileCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let permission = AccessibilityPermission()
    private let configStore = ConfigStore()
    /// Docking runs the new profile's `onActivate` with only the windows that are open.
    private lazy var profiles: DisplayProfiles = DisplayProfiles(configStore: configStore) { [unowned self] id in
        guard !login.isPending, !arranger.isRunning else {
            return Log.app.info("not running '\(id, privacy: .public)' for the display change: an arrangement is under way")
        }
        arranger.run(id, launching: false)
    }
    private lazy var commands: WindowCommands = WindowCommands(configStore: configStore, profiles: profiles) { [unowned self] id in
        runArrangement(id)
    }
    private lazy var hotkeys: HotkeyManager = HotkeyManager { [unowned self] combo in commands.press(combo) }
    private lazy var arranger: Arranger = Arranger(configStore: configStore, profiles: profiles, hotkeys: hotkeys)
    private lazy var login: LoginArrangement = LoginArrangement(configStore: configStore, profiles: profiles, arranger: arranger)
    private lazy var settings = SettingsWindow(configStore: configStore, profiles: profiles, hotkeys: hotkeys) { [unowned self] in
        registerHotkeys()
    }
    /// The app that was frontmost when the menu opened (the menu doesn't change it).
    private var frontmostBundleID: String?
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
        if LoginSession.isFirstLaunchThisSession() {
            login.start()
        }
    }

    /// Loads the config file and re-registers every hotkey. A bad file keeps the last
    /// good config and turns the menu bar icon into a warning.
    private func reloadConfig() {
        configStore.load()
        profiles.configChanged()
        registerHotkeys()
        settings.configReloaded()
        let symbol = configStore.lastError == nil ? "rectangle.split.2x2" : "exclamationmark.triangle"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tile")
    }

    private func registerHotkeys() {
        hotkeys.register(BindingTable(configStore.config.bindings).combos)
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
        case .settings:
            settings.show()
        case .selftest:
            SelfTest.start(configStore: configStore, commands: commands)
        case .debug(command: "spaces", params: _):
            SpacesReport.write()
        case .debug(command: "spike", params: _):
            Spike.start()
        case .debug(command: "login", params: _):
            login.start()
        case .debug(command: "windows", params: _):
            _ = Reports.write("windows.txt", WindowDocuments.report())
        case .debug(command: "missioncontrol", params: _):
            Task { _ = Reports.write("missioncontrol.txt", await MissionControl.describe()) }
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
        menu.addItem(layoutsItem())
        menu.addItem(arrangementsItem())
        menu.addItem(item("Capture Current Desktops into Arrangement…", #selector(capture)))
        menu.addItem(.separator())
        menu.addItem(profileItem())
        menu.addItem(item("Copy Current Displays as Profile JSON", #selector(copyProfileJSON)))
        if let ignore = ignoreItem() {
            menu.addItem(.separator())
            menu.addItem(ignore)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Open Config File", #selector(openConfig)))
        menu.addItem(item("Reload Config", #selector(reloadConfigFromMenu)))
        let login = item(launchAtLoginTitle, #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(debugItem())
        menu.addItem(item("Quit Tile", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    /// Every layout; clicking one applies it to the frontmost app's focused window.
    private func layoutsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Layouts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let keys = Dictionary(configStore.config.bindings.compactMap { binding -> (String, String)? in
            guard case .layout(let id) = binding.target, binding.when == .init() else { return nil }
            return (id, binding.keys.description)
        }, uniquingKeysWith: { first, _ in first })
        for layout in configStore.config.layouts {
            let entry = item(layout.name + (keys[layout.id].map { "    \($0)" } ?? ""), #selector(applyLayout(_:)))
            entry.representedObject = layout.id
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    /// "Ignore Slack" for the app that was frontmost, or "Stop Ignoring Slack".
    private func ignoreItem() -> NSMenuItem? {
        let app = NSWorkspace.shared.frontmostApplication
        guard let app, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return nil }
        frontmostBundleID = bundleID
        let name = app.localizedName ?? bundleID
        let ignored = configStore.config.ignoredApps.contains(bundleID)
        return item(ignored ? "Stop Ignoring \(name)" : "Ignore \(name)", #selector(toggleIgnore))
    }

    private var launchAtLoginTitle: String {
        SMAppService.mainApp.status == .requiresApproval
            ? "Launch at Login (approve in System Settings > Login Items)"
            : "Launch at Login"
    }

    private func debugItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(item("Run Selftest (moves a test window)", #selector(runSelftest)))
        submenu.addItem(item("Run Arrangement Test (switches desktops)", #selector(runArrangeTest)))
        submenu.addItem(item("Run Login Arrangement (launches apps)", #selector(runLoginArrangement)))
        submenu.addItem(item("Dump Spaces Report", #selector(dumpSpaces)))
        submenu.addItem(item("Open Logs Folder", #selector(openLogs)))
        parent.submenu = submenu
        return parent
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

    @objc private func applyLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { await commands.apply(layoutID: id) }
    }

    @objc private func toggleIgnore() {
        guard let bundleID = frontmostBundleID else { return }
        do {
            try configStore.replaceSection("ignoredApps") { current in
                let apps = current.ignoredApps.contains(bundleID)
                    ? current.ignoredApps.filter { $0 != bundleID }
                    : current.ignoredApps + [bundleID]
                return ConfigFormat.strings(apps)
            }
        } catch {
            alert("Couldn't change the ignore list", "\(error)")
        }
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
            Log.app.info("launch at login: \(String(describing: service.status), privacy: .public)")
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    @objc private func runLoginArrangement() {
        login.start()
    }

    @objc private func runArrangeTest() {
        ArrangeTest.start(arranger: arranger, configStore: configStore, profiles: profiles)
    }

    private func alert(_ title: String, _ detail: String) {
        Log.app.error("\(title, privacy: .public): \(detail, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
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
