import AppKit
import SwiftUI
import TileCore

/// Settings: bindings with a shortcut recorder, a layout editor, and the ignore list.
/// Edits a copy of those three sections and writes them back with Save; profiles and
/// arrangements stay in the JSON (or come from Capture).
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let model: SettingsModel

    init(configStore: ConfigStore, profiles: DisplayProfiles, hotkeys: HotkeyManager, resumeHotkeys: @escaping () -> Void) {
        model = SettingsModel(configStore: configStore, profiles: profiles, hotkeys: hotkeys, resumeHotkeys: resumeHotkeys)
    }

    func show() {
        model.load()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Tile Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// After a reload from disk, so the window doesn't save over someone else's edit
    /// with stale contents. Unsaved changes are kept.
    func configReloaded() {
        if !model.isDirty { model.load() }
    }
}

// MARK: Model

struct EditableBinding: Identifiable, Equatable {
    let id = UUID()
    var keys: KeyCombo?
    var when: KeyBinding.Condition
    var target: KeyBinding.Target
}

struct EditableLayout: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case rect, grid, center }

    let id = UUID()
    var layoutID: String
    var name: String
    var kind: Kind
    var rect: CGRect
    var columns: Int
    var rows: Int
    var cell: GridCell

    init(_ layout: WindowLayout) {
        layoutID = layout.id
        name = layout.name
        rect = layout.shape.fractionsForEditing ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        columns = 2
        rows = 2
        cell = GridCell(column: 0, row: 0, columnSpan: 1, rowSpan: 1)
        switch layout.shape {
        case .rect: kind = .rect
        case .grid(let columns, let rows, let cell):
            kind = .grid
            self.columns = columns
            self.rows = rows
            self.cell = cell
        case .center: kind = .center
        }
    }

    var shape: WindowLayout.Shape {
        switch kind {
        case .rect: .rect(rect)
        case .grid: .grid(columns: columns, rows: rows, cell: cell)
        case .center: .center
        }
    }

    var layout: WindowLayout { WindowLayout(id: layoutID, name: name, shape: shape) }
}

private extension WindowLayout.Shape {
    var fractionsForEditing: CGRect? {
        switch self {
        case .rect(let rect): rect
        case .grid(let columns, let rows, let cell):
            CGRect(x: CGFloat(cell.column) / CGFloat(columns), y: CGFloat(cell.row) / CGFloat(rows),
                   width: CGFloat(cell.columnSpan) / CGFloat(columns), height: CGFloat(cell.rowSpan) / CGFloat(rows))
        case .center: nil
        }
    }
}

@MainActor
@Observable
final class SettingsModel {
    var bindings: [EditableBinding] = []
    var layouts: [EditableLayout] = []
    var ignoredApps: [String] = []
    var selectedLayout: EditableLayout.ID?
    var message: String?
    var messageIsError = false
    /// The binding whose shortcut is being recorded.
    var recording: EditableBinding.ID?

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let profiles: DisplayProfiles
    @ObservationIgnored private let hotkeys: HotkeyManager
    @ObservationIgnored private let resumeHotkeys: () -> Void
    @ObservationIgnored private var loaded: (bindings: [EditableBinding], layouts: [EditableLayout], ignored: [String]) = ([], [], [])

    init(configStore: ConfigStore, profiles: DisplayProfiles, hotkeys: HotkeyManager, resumeHotkeys: @escaping () -> Void) {
        self.configStore = configStore
        self.profiles = profiles
        self.hotkeys = hotkeys
        self.resumeHotkeys = resumeHotkeys
    }

    var config: Config { configStore.config }

    var isDirty: Bool {
        bindings != loaded.bindings || layouts != loaded.layouts || ignoredApps != loaded.ignored
    }

    func load() {
        bindings = config.bindings.map { EditableBinding(keys: $0.keys, when: $0.when, target: $0.target) }
        layouts = config.layouts.map(EditableLayout.init)
        ignoredApps = config.ignoredApps
        loaded = (bindings, layouts, ignoredApps)
        if selectedLayout == nil || !layouts.contains(where: { $0.id == selectedLayout }) {
            selectedLayout = layouts.first?.id
        }
        message = configStore.lastError.map { "config.json has errors, showing the last good config:\n\($0)" }
        messageIsError = message != nil
    }

    func save() {
        let bindings = self.bindings.compactMap { binding in
            binding.keys.map { KeyBinding(keys: $0, when: binding.when, target: binding.target) }
        }
        let layouts = self.layouts.map(\.layout)
        let ignored = ignoredApps
        do {
            try configStore.replaceSections { _ in [
                ("layouts", ConfigFormat.layouts(layouts)),
                ("bindings", ConfigFormat.bindings(bindings)),
                ("ignoredApps", ConfigFormat.strings(ignored)),
            ] }
            message = "Saved"
            messageIsError = false
            // The watcher reloads the file; take what was written as the new baseline.
            self.bindings.removeAll { $0.keys == nil }
            loaded = (self.bindings, self.layouts, ignoredApps)
        } catch {
            message = "\(error)"
            messageIsError = true
        }
    }

    // MARK: Bindings

    /// Problems Tile can see before saving: same keys and same `when` as another
    /// binding (one could never fire), or a shortcut another app holds.
    func status(of binding: EditableBinding) -> String? {
        guard let keys = binding.keys else { return "no shortcut: removed on save" }
        if let other = bindings.firstIndex(where: { $0.id != binding.id && $0.keys == keys && $0.when == binding.when }) {
            return "same keys and scope as #\(other + 1)"
        }
        if let unavailable = hotkeys.unavailable.first(where: { $0.combo == keys }) {
            return "unavailable (\(unavailable.reason))"
        }
        return nil
    }

    func startRecording(_ id: EditableBinding.ID) {
        // Tile's own hotkeys would fire instead of reaching the recorder.
        hotkeys.register([])
        recording = id
    }

    func stopRecording() {
        recording = nil
        resumeHotkeys()
    }

    var roles: [String] { Array(Set(config.profiles.flatMap(\.displays.keys))).sorted() }
    var profileIDs: [String] { config.profiles.map(\.id) }
    var arrangementIDs: [String] { config.arrangements.map(\.id) }
    var layoutIDs: [String] { layouts.map(\.layoutID) }

    // MARK: Layouts

    func addLayout() {
        var layout = EditableLayout(WindowLayout(id: "new-layout", name: "New Layout", shape: .rect(CGRect(x: 0, y: 0, width: 0.5, height: 1))))
        var n = 2
        while layouts.contains(where: { $0.layoutID == layout.layoutID }) {
            layout.layoutID = "new-layout-\(n)"
            n += 1
        }
        layouts.append(layout)
        selectedLayout = layout.id
    }

    func deleteSelectedLayout() {
        layouts.removeAll { $0.id == selectedLayout }
        selectedLayout = layouts.first?.id
    }

    /// Displays to preview layouts on: the active profile's, else all connected.
    var previewDisplays: [(name: String, visible: CGRect)] {
        let displays = DisplayInfo.all()
        let geometry = ScreenGeometry(displays: displays)
        let match = profiles.match(displays)
        return geometry.orderedDisplays.compactMap { display in
            if let match, match.role(of: display.id) == nil { return nil }
            return (match?.role(of: display.id) ?? display.name, geometry.axVisibleFrame(of: display))
        }
    }

    // MARK: Ignored apps

    var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .filter { !ignoredApps.contains($0.bundleID) && $0.bundleID != Bundle.main.bundleIdentifier }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? bundleID
    }
}

// MARK: Views

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                BindingsTab(model: model).tabItem { Text("Bindings") }
                LayoutsTab(model: model).tabItem { Text("Layouts") }
                IgnoredTab(model: model).tabItem { Text("Ignored Apps") }
            }
            .padding([.horizontal, .top])
            HStack(alignment: .top) {
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(model.messageIsError ? .red : .secondary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }
                Button("Revert") { model.load() }.disabled(!model.isDirty)
                Button("Save") { model.save() }.keyboardShortcut("s").disabled(!model.isDirty)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

private struct BindingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(Array($model.bindings.enumerated()), id: \.element.id) { index, $binding in
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        ShortcutRecorder(model: model, binding: $binding).frame(width: 170)
                        WhenMenu(model: model, when: $binding.when).frame(width: 190, alignment: .leading)
                        TargetMenu(model: model, target: $binding.target).frame(width: 240, alignment: .leading)
                        if let status = model.status(of: binding) {
                            Text(status).foregroundStyle(.red).font(.caption)
                        }
                        Spacer()
                        Button {
                            model.bindings.removeAll { $0.id == binding.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("Add Binding") {
                    let binding = EditableBinding(keys: nil, when: .init(), target: .layout(model.layoutIDs.first ?? "full"))
                    model.bindings.append(binding)
                    model.startRecording(binding.id)
                }
                Text("Click a shortcut to record a new one. Esc cancels, Delete clears. The most specific scope wins: display, then orientation, then profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Records a shortcut with a local keyDown monitor while it's active.
private struct ShortcutRecorder: View {
    let model: SettingsModel
    @Binding var binding: EditableBinding
    @State private var monitor: Any?
    @State private var problem: String?

    private var isRecording: Bool { model.recording == binding.id }

    var body: some View {
        Button {
            isRecording ? stop() : model.startRecording(binding.id)
        } label: {
            Text(isRecording ? (problem ?? "Type a shortcut…") : (binding.keys?.description ?? "Record shortcut"))
                .foregroundStyle(problem != nil && isRecording ? .red : .primary)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: isRecording, initial: true) { _, recording in
            recording ? start() : removeMonitor()
        }
        .help(problem ?? "")
    }

    private func start() {
        problem = nil
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.ctrl) }
        if flags.contains(.option) { modifiers.insert(.opt) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.cmd) }
        let code = UInt32(event.keyCode)
        if modifiers.isEmpty, code == 53 { return stop() } // Esc
        if modifiers.isEmpty, code == 51 || code == 117 { // Delete, forward delete
            binding.keys = nil
            return stop()
        }
        do {
            // Through the parser, so a recorded shortcut obeys the same rules as a typed one.
            binding.keys = try KeyCombo(parsing: KeyCombo(keyCode: code, modifiers: modifiers).description)
            stop()
        } catch {
            problem = "\(error)".hasPrefix("unknown key") ? "That key isn't supported" : "\(error)"
        }
    }

    private func stop() {
        removeMonitor()
        problem = nil
        model.stopRecording()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct WhenMenu: View {
    let model: SettingsModel
    @Binding var when: KeyBinding.Condition

    private var summary: String {
        var parts: [String] = []
        if let profile = when.profile { parts.append("profile \(profile)") }
        if let display = when.display { parts.append(display) }
        if let orientation = when.orientation { parts.append(orientation.rawValue) }
        return parts.isEmpty ? "everywhere" : parts.joined(separator: ", ")
    }

    var body: some View {
        Menu(summary) {
            Picker("Profile", selection: $when.profile) {
                Text("Any").tag(String?.none)
                ForEach(model.profileIDs, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Display", selection: $when.display) {
                Text("Any").tag(String?.none)
                ForEach(model.roles, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Orientation", selection: $when.orientation) {
                Text("Any").tag(Orientation?.none)
                Text("portrait").tag(Orientation?.some(.portrait))
                Text("landscape").tag(Orientation?.some(.landscape))
            }
        }
    }
}

private struct TargetMenu: View {
    let model: SettingsModel
    @Binding var target: KeyBinding.Target

    private var summary: String {
        switch target {
        case .layout(let id): id
        case .cycle(let ids): "cycle: " + ids.joined(separator: ", ")
        case .action(let action): action.rawValue
        case .arrange(let id): "arrange \(id)"
        }
    }

    var body: some View {
        Menu(summary) {
            Menu("Layout") {
                ForEach(model.layoutIDs, id: \.self) { id in Button(id) { target = .layout(id) } }
            }
            Menu("Action") {
                ForEach(WindowAction.allCases, id: \.self) { action in Button(action.rawValue) { target = .action(action) } }
            }
            if !model.arrangementIDs.isEmpty {
                Menu("Arrangement") {
                    ForEach(model.arrangementIDs, id: \.self) { id in Button(id) { target = .arrange(id) } }
                }
            }
            Text("Cycles are edited in config.json")
        }
        .help(summary)
    }
}

private struct LayoutsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HSplitView {
            VStack(spacing: 4) {
                List(selection: $model.selectedLayout) {
                    ForEach(model.layouts) { layout in
                        Text(layout.name).tag(layout.id)
                    }
                }
                HStack {
                    Button { model.addLayout() } label: { Image(systemName: "plus") }
                    Button { model.deleteSelectedLayout() } label: { Image(systemName: "minus") }
                        .disabled(model.selectedLayout == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 180, maxWidth: 240)

            if let index = model.layouts.firstIndex(where: { $0.id == model.selectedLayout }) {
                LayoutEditor(model: model, layout: $model.layouts[index])
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("No layout selected").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct LayoutEditor: View {
    let model: SettingsModel
    @Binding var layout: EditableLayout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    TextField("Name", text: $layout.name)
                    TextField("ID", text: $layout.layoutID)
                    Picker("Shape", selection: $layout.kind) {
                        Text("Rect").tag(EditableLayout.Kind.rect)
                        Text("Grid").tag(EditableLayout.Kind.grid)
                        Text("Center (keeps size)").tag(EditableLayout.Kind.center)
                    }
                    .pickerStyle(.segmented)
                }
                switch layout.kind {
                case .rect:
                    HStack {
                        fraction("x", \.origin.x)
                        fraction("y", \.origin.y)
                        fraction("width", \.size.width)
                        fraction("height", \.size.height)
                    }
                    Text("Fractions of the screen, from its top-left corner.").font(.caption).foregroundStyle(.secondary)
                case .grid:
                    HStack {
                        Stepper("Columns: \(layout.columns)", value: $layout.columns, in: 1...24)
                        Stepper("Rows: \(layout.rows)", value: $layout.rows, in: 1...24)
                    }
                    .onChange(of: [layout.columns, layout.rows]) { clampCell() }
                    GridPicker(columns: layout.columns, rows: layout.rows, cell: $layout.cell)
                        .frame(width: 320, height: 200)
                    Text("Drag across the cells the window should cover.").font(.caption).foregroundStyle(.secondary)
                case .center:
                    Text("Centers the window on its display without resizing it.").foregroundStyle(.secondary)
                }
                Text("Preview").font(.headline)
                HStack(alignment: .bottom, spacing: 16) {
                    ForEach(model.previewDisplays, id: \.name) { display in
                        VStack {
                            LayoutPreview(shape: layout.shape, visible: display.visible, gaps: model.config.gaps)
                            Text(display.name).font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func fraction(_ label: String, _ path: WritableKeyPath<CGRect, CGFloat>) -> some View {
        TextField(label, value: Binding(
            get: { Double(layout.rect[keyPath: path]) },
            set: { layout.rect[keyPath: path] = CGFloat(min(max($0, 0), 1)) }
        ), format: .number.precision(.fractionLength(0...3)))
        .frame(width: 70)
    }

    private func clampCell() {
        let column = min(layout.cell.column, layout.columns - 1)
        let row = min(layout.cell.row, layout.rows - 1)
        layout.cell = GridCell(column: column, row: row,
                               columnSpan: min(layout.cell.columnSpan, layout.columns - column),
                               rowSpan: min(layout.cell.rowSpan, layout.rows - row))
    }
}

/// An N×M grid; drag across cells to pick the block a layout covers.
private struct GridPicker: View {
    let columns: Int
    let rows: Int
    @Binding var cell: GridCell
    @State private var anchor: (column: Int, row: Int)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(columns)
            let height = geometry.size.height / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                ForEach(0..<rows, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { column in
                        Rectangle()
                            .fill(contains(column, row) ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.15))
                            .border(Color.gray.opacity(0.5), width: 0.5)
                            .frame(width: width, height: height)
                            .offset(x: CGFloat(column) * width, y: CGFloat(row) * height)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                func at(_ point: CGPoint) -> (Int, Int) {
                    (min(max(Int(point.x / width), 0), columns - 1), min(max(Int(point.y / height), 0), rows - 1))
                }
                let start = anchor ?? at(drag.startLocation)
                anchor = start
                let end = at(drag.location)
                cell = GridCell(column: min(start.0, end.0), row: min(start.1, end.1),
                                columnSpan: abs(end.0 - start.0) + 1, rowSpan: abs(end.1 - start.1) + 1)
            }.onEnded { _ in anchor = nil })
        }
    }

    private func contains(_ column: Int, _ row: Int) -> Bool {
        (cell.column..<cell.column + cell.columnSpan).contains(column) && (cell.row..<cell.row + cell.rowSpan).contains(row)
    }
}

/// A display in its own aspect ratio, with where the layout would put a window.
private struct LayoutPreview: View {
    let shape: WindowLayout.Shape
    let visible: CGRect
    let gaps: Gaps

    var body: some View {
        let scale = min(220 / visible.width, 160 / visible.height)
        let size = CGSize(width: visible.width * scale, height: visible.height * scale)
        // A centered window has no size of its own here; show a typical one.
        let frame = LayoutEngine.frame(for: shape, in: visible, gaps: gaps,
                                       currentSize: CGSize(width: visible.width * 0.5, height: visible.height * 0.5))
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.gray.opacity(0.2))
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: max(frame.width * scale, 1), height: max(frame.height * scale, 1))
                .offset(x: (frame.minX - visible.minX) * scale, y: (frame.minY - visible.minY) * scale)
        }
        .frame(width: size.width, height: size.height)
        .border(Color.gray)
    }
}

private struct IgnoredTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Tile never moves windows of these apps, and Capture skips them.")
                .foregroundStyle(.secondary)
            List {
                ForEach(model.ignoredApps, id: \.self) { bundleID in
                    HStack {
                        Text(model.appName(bundleID))
                        Text(bundleID).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button {
                            model.ignoredApps.removeAll { $0 == bundleID }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Menu("Add a Running App") {
                ForEach(model.runningApps, id: \.bundleID) { app in
                    Button(app.name) { model.ignoredApps.append(app.bundleID) }
                }
            }
            .fixedSize()
        }
    }
}
