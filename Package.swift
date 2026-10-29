// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tile",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic (geometry, layouts, config, key strings, routing). No AppKit,
        // no AX, so everything here is unit-testable.
        .target(name: "TileCore"),
        // The menu-bar app: AppKit, AX, SkyLight, event posting.
        .executableTarget(name: "Tile", dependencies: ["TileCore"]),
        .testTarget(name: "TileCoreTests", dependencies: ["TileCore"]),
    ],
    swiftLanguageModes: [.v5]
)
