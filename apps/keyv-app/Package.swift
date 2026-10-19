// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KeyVApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CKeyV",
            publicHeadersPath: "include"
        ),
        .target(
            name: "KeyVCore",
            dependencies: ["CKeyV"]
        ),
        // Library: everything the host app + dev harnesses share.
        .target(
            name: "KeyVHostKit",
            dependencies: ["CKeyV", "KeyVCore"],
            resources: [.copy("KeyVIcon.png")]
        ),
        // Host app executable (menu-bar accessory).
        .executableTarget(
            name: "KeyVApp",
            dependencies: ["KeyVHostKit"],
            linkerSettings: [
                .unsafeFlags(["-L", "lib", "-lkeyv_core"])
            ]
        ),
        // P5: InputMethodKit helper (compile-only in P2/P3/P4; installed on opt-in)
        .executableTarget(
            name: "KeyVIME",
            dependencies: ["CKeyV", "KeyVCore"],
            linkerSettings: [
                .unsafeFlags(["-L", "lib", "-lkeyv_core"])
            ]
        ),
        // XCTest runtime ships only with full Xcode; this smoke runner
        // validates the FFI wrapper with plain assertions instead.
        .executableTarget(
            name: "KeyVSmoke",
            dependencies: ["KeyVCore", "KeyVHostKit"],
            linkerSettings: [
                .unsafeFlags(["-L", "lib", "-lkeyv_core"])
            ]
        ),
        // Dev-only: renders host-kit SwiftUI views to PNG for review.
        .executableTarget(
            name: "KeyVVisual",
            dependencies: ["CKeyV", "KeyVCore", "KeyVHostKit"],
            linkerSettings: [
                .unsafeFlags(["-L", "lib", "-lkeyv_core"])
            ]
        ),
    ]
)
