import AppKit
import TileCore

/// What to open to bring a window back: its document, an editor's workspace folder,
/// a terminal's working directory. Capture records it as the placement's `open`.
@MainActor
enum WindowDocuments {
    /// VS Code and its forks: one window per workspace folder, and AXDocument is the
    /// active file, so the folder is the file's ancestor named in the title
    /// ("Arranger.swift — tile"). The value is the app's folder in Application Support.
    private static let workspaceEditors: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.vscodium": "VSCodium",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
    ]

    /// Terminals: a window is its working directory, from AXDocument (Terminal) or a
    /// path in the title (Warp, iTerm, Ghostty).
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.googlecode.iterm2",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
    ]

    /// Web pages, mail and chat aren't reopened from a file even when AXDocument says
    /// one: the app restores them itself, and opening the page again would duplicate it.
    private static let neverOpen: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.apple.mail", "com.apple.finder",
    ]

    static func openItem(app: String, window: AXUIElement, title: String?) -> String? {
        guard !neverOpen.contains(app) else { return nil }
        let document = AX.document(window)
        let segments = OpenTarget.titleSegments(title ?? "")
        if let support = workspaceEditors[app] {
            return workspaceFolder(document: document, segments: segments, support: support)
        }
        if terminals.contains(app) {
            if let document, isFolder(document) { return document }
            return segments.lazy.compactMap(directory(named:)).first
        }
        guard let document, FileManager.default.fileExists(atPath: document) else { return nil }
        return document
    }

    private static func workspaceFolder(document: String?, segments: [String], support: String) -> String? {
        let names = Set(segments)
        if let document {
            var folder = (document as NSString).deletingLastPathComponent
            while folder.count > 1 {
                if names.contains((folder as NSString).lastPathComponent) { return folder }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        // No file open (or one outside the workspace): the editor's own list of open
        // folders, matched by name.
        return recentFolders(support: support).first { names.contains(($0 as NSString).lastPathComponent) }
    }

    /// Folders VS Code-style editors have open or had open recently, newest first.
    private static func recentFolders(support: String) -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(support)/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var uris: [String] = []
        if let state = json["windowsState"] as? [String: Any] {
            if let last = state["lastActiveWindow"] as? [String: Any], let folder = last["folder"] as? String { uris.append(folder) }
            for window in state["openedWindows"] as? [[String: Any]] ?? [] {
                if let folder = window["folder"] as? String { uris.append(folder) }
            }
        }
        if let backups = json["backupWorkspaces"] as? [String: Any] {
            for folder in backups["folders"] as? [[String: Any]] ?? [] {
                if let uri = folder["folderUri"] as? String { uris.append(uri) }
            }
        }
        if let associations = json["profileAssociations"] as? [String: Any],
           let workspaces = associations["workspaces"] as? [String: Any] {
            uris += workspaces.keys.sorted()
        }
        var seen: Set<String> = []
        return uris.compactMap { URL(string: $0) }.filter(\.isFileURL).map(\.path).filter { seen.insert($0).inserted && isFolder($0) }
    }

    /// A title piece that's a path to a directory: "~/epsilon/tile", "/tmp".
    private static func directory(named segment: String) -> String? {
        guard segment == "~" || segment.hasPrefix("~/") || segment.hasPrefix("/") else { return nil }
        let path = (segment as NSString).expandingTildeInPath
        return isFolder(path) ? (path as NSString).standardizingPath : nil
    }

    static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    /// Debug: what Capture would record for each window of the apps it reopens.
    /// Other apps' titles are left out; they can be mail subjects.
    static func report() -> String {
        var lines = ["Tile window documents  \(ISO8601DateFormatter().string(from: Date()))", ""]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            let windows = AX.windows(of: AX.application(pid: app.processIdentifier))
                .filter { AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
            guard !windows.isEmpty else { continue }
            let showTitles = workspaceEditors[bundleID] != nil || terminals.contains(bundleID)
            for window in windows {
                let title = AX.string(window, kAXTitleAttribute)
                lines.append("\(bundleID)" + (showTitles ? "  title=\"\(title ?? "")\"" : ""))
                lines.append("    AXDocument: \(AX.string(window, kAXDocumentAttribute) ?? "-")")
                lines.append("    open: \(openItem(app: bundleID, window: window, title: title) ?? "-")")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
