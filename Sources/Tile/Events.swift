import CoreGraphics

/// Synthetic keyboard and mouse events, posted at the HID level so the window
/// server treats them like hardware input (needed for Mission Control shortcuts
/// and title-bar drags). Requires Accessibility.
@MainActor
enum Events {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// `point` is in global coordinates, top-left origin (same as AX).
    static func postMouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }

    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static var isLeftMouseDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    static func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// Polls `condition` every 20ms until it's true or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
