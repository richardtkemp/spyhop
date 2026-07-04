// swift-tools-version:5.9
import PackageDescription

// Native SpriteKit renderer for the spyhop wallpaper. Built with Command Line Tools
// (no full Xcode needed): `swift build -c release`, then wrapped into a .app bundle by
// build.sh. See ../mac/README or the plan for why SPM+CLT over an Xcode project.
let package = Package(
    name: "Spyhop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Spyhop",
            path: "Sources/Spyhop",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SpriteKit")
            ]
        )
    ]
)
