import ApplicationServices
import Foundation

/// Private SkyLight (window server) and HIServices symbols.
///
/// This file is the only place Tile touches private API. Every symbol is resolved
/// with `dlsym` at first use, so a symbol Apple removes in a future macOS turns
/// into a thrown error instead of a crash at launch. Everything here is read-only
/// except the "Writes" section, and none of it requires SIP to be disabled.
enum SkyLight {
    typealias ConnectionID = Int32
    typealias SpaceID = UInt64

    struct MissingSymbol: Error, CustomStringConvertible {
        let names: [String]
        var description: String { "private symbol not found: \(names.joined(separator: " / "))" }
    }

    /// Selector for `CopySpacesForWindows`: current | others | user spaces.
    static let allSpacesMask: Int32 = 0x7

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    /// `RTLD_DEFAULT`, which the Swift Darwin overlay doesn't export.
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    /// Looks up the first of `names` that resolves. SkyLight exports `SLS*` names;
    /// the older `CGS*` aliases are tried as a fallback.
    private static func resolve<T>(_ names: [String], as type: T.Type) throws -> T {
        for name in names {
            if let pointer = dlsym(handle, name) ?? dlsym(defaultHandle, name) {
                return unsafeBitCast(pointer, to: type)
            }
        }
        throw MissingSymbol(names: names)
    }

    private typealias MainConnectionIDFn = @convention(c) () -> ConnectionID
    private typealias GetActiveSpaceFn = @convention(c) (ConnectionID) -> SpaceID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias ManagedDisplayGetCurrentSpaceFn = @convention(c) (ConnectionID, CFString) -> SpaceID
    private typealias CopySpacesForWindowsFn = @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias MoveWindowsToManagedSpaceFn = @convention(c) (ConnectionID, CFArray, SpaceID) -> Void
    private typealias WindowsAndSpacesFn = @convention(c) (ConnectionID, CFArray, CFArray) -> Void

    static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static func mainConnectionID() throws -> ConnectionID {
        try resolve(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionIDFn.self)()
    }

    /// The Space that currently has focus (on the display with keyboard focus).
    static func activeSpace() throws -> SpaceID {
        let fn = try resolve(["SLSGetActiveSpace", "CGSGetActiveSpace"], as: GetActiveSpaceFn.self)
        return fn(try mainConnectionID())
    }

    /// One dictionary per display: "Display Identifier", "Current Space", "Spaces".
    static func managedDisplaySpaces() throws -> [[String: Any]] {
        let fn = try resolve(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"],
                             as: CopyManagedDisplaySpacesFn.self)
        guard let array = fn(try mainConnectionID())?.takeRetainedValue() else { return [] }
        return (array as? [[String: Any]]) ?? []
    }

    /// The Space a display is currently showing. `displayIdentifier` is the
    /// display UUID string from `managedDisplaySpaces()`.
    static func currentSpace(forDisplay displayIdentifier: String) throws -> SpaceID {
        let fn = try resolve(["SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"],
                             as: ManagedDisplayGetCurrentSpaceFn.self)
        return fn(try mainConnectionID(), displayIdentifier as CFString)
    }

    /// The Spaces a window is on (more than one if it's assigned to all desktops).
    static func spaces(forWindow windowID: CGWindowID) throws -> [SpaceID] {
        let fn = try resolve(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"],
                             as: CopySpacesForWindowsFn.self)
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let array = fn(try mainConnectionID(), allSpacesMask, ids)?.takeRetainedValue() else { return [] }
        return ((array as? [NSNumber]) ?? []).map(\.uint64Value)
    }

    /// The window server id behind an AX window element.
    static func windowID(of element: AXUIElement) throws -> CGWindowID? {
        let fn = try resolve(["_AXUIElementGetWindow"], as: AXUIElementGetWindowFn.self)
        var id: CGWindowID = 0
        return fn(element, &id) == .success ? id : nil
    }

    // MARK: Writes. Experimental: the window server may silently ignore these
    // from any process other than the Dock. Verify the result, never assume it.

    static func moveWindows(_ ids: [CGWindowID], toManagedSpace space: SpaceID) throws {
        let fn = try resolve(["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"],
                             as: MoveWindowsToManagedSpaceFn.self)
        fn(try mainConnectionID(), numbers(ids), space)
    }

    static func addWindows(_ ids: [CGWindowID], toSpaces spaces: [SpaceID]) throws {
        let fn = try resolve(["SLSAddWindowsToSpaces", "CGSAddWindowsToSpaces"], as: WindowsAndSpacesFn.self)
        fn(try mainConnectionID(), numbers(ids), numbers(spaces))
    }

    static func removeWindows(_ ids: [CGWindowID], fromSpaces spaces: [SpaceID]) throws {
        let fn = try resolve(["SLSRemoveWindowsFromSpaces", "CGSRemoveWindowsFromSpaces"], as: WindowsAndSpacesFn.self)
        fn(try mainConnectionID(), numbers(ids), numbers(spaces))
    }

    private static func numbers<T: BinaryInteger>(_ values: [T]) -> CFArray {
        values.map { NSNumber(value: UInt64($0)) } as CFArray
    }
}
