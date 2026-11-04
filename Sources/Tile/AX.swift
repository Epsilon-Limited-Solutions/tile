import AppKit
import ApplicationServices

/// Thin wrappers over the AX C API. Main thread only.
@MainActor
enum AX {
    /// Keeps a hung app from freezing Tile.
    static let messagingTimeout: Float = 0.5

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func application(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    /// An attribute whose value is another element (focused window, a title-bar button, ...).
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let ref = value(element, attribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Window frame in AX coordinates (top-left origin of the primary display, y down).
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = axValue(window, kAXPositionAttribute),
              let size = axValue(window, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    @discardableResult
    static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    static func setSize(_ window: AXUIElement, _ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Frame of a title-bar button (`kAXCloseButtonAttribute`, `kAXZoomButtonAttribute`, ...), AX coordinates.
    static func buttonFrame(_ window: AXUIElement, _ attribute: String) -> CGRect? {
        element(window, attribute).flatMap(frame(of:))
    }

    static func pressCloseButton(_ window: AXUIElement) {
        guard let button = element(window, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let ref = value(element, attribute), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }
}
