import AppKit
import ApplicationServices

/// Asks for Accessibility once, then polls until the grant arrives, so no relaunch is needed.
@MainActor
final class AccessibilityPermission {
    private(set) var isTrusted = AX.isTrusted
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    func requestIfNeeded() {
        // The prompt option also adds Tile to the list in System Settings.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        Log.app.info("accessibility trusted at launch: \(self.isTrusted, privacy: .public)")
        if !isTrusted {
            openSettings()
            startPolling()
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard AX.isTrusted else { return }
        timer?.invalidate()
        timer = nil
        isTrusted = true
        Log.app.info("accessibility granted")
        onChange?(true)
    }
}
