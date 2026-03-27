// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clawdebar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Clawdebar",
            path: "StatusBar",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
