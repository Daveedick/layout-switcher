// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LayoutSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LayoutSwitcherCore", targets: ["LayoutSwitcherCore"]),
        .executable(name: "LayoutSwitcher", targets: ["LayoutSwitcher"]),
    ],
    targets: [
        .target(name: "LayoutSwitcherCore", path: "Sources/LayoutSwitcherCore"),
        .executableTarget(name: "LayoutSwitcher", dependencies: ["LayoutSwitcherCore"], path: "Sources/LayoutSwitcher"),
        .executableTarget(name: "CoreChecks", dependencies: ["LayoutSwitcherCore"], path: "Tests/LayoutSwitcherCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
