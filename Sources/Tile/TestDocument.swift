import AppKit

/// A throwaway TextEdit document window, for the spike and the selftest.
@MainActor
struct TestDocument {
    let element: AXUIElement
    let id: CGWindowID
    let pid: pid_t
    let file: URL
    private let quitTextEdit: Bool

    var window: WindowMover.Window { WindowMover.Window(element: element, pid: pid, id: id) }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let textEdit = "com.apple.TextEdit"

    /// Writes `<name>.txt` to the temp directory, opens it in TextEdit and waits up
    /// to 10s for its window.
    static func open(named name: String, text: String) async throws -> TestDocument {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(name).txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).isEmpty
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEdit) else {
            throw Failure(description: "TextEdit not found")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)

        var found: TestDocument?
        _ = await waitUntil(timeout: .seconds(10)) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).first else {
                return false
            }
            for element in AX.windows(of: AX.application(pid: app.processIdentifier))
            where (AX.string(element, kAXTitleAttribute) ?? "").hasPrefix(name) {
                if let id = try? SkyLight.windowID(of: element) {
                    found = TestDocument(element: element, id: id, pid: app.processIdentifier,
                                         file: file, quitTextEdit: !wasRunning)
                    return true
                }
            }
            return false
        }
        guard let found else { throw Failure(description: "the TextEdit window for \(name).txt never appeared") }
        return found
    }

    /// Quits TextEdit if it wasn't running before, otherwise closes just this window.
    func close() {
        if quitTextEdit, let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            AX.pressCloseButton(element)
        }
        try? FileManager.default.removeItem(at: file)
    }
}
