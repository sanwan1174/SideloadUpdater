// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdaterCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(name: "UpdaterCore", path: "App",
                exclude: ["UpdaterApp.swift", "Views.swift", "DeviceInventory.swift", "LocalPairingPort.swift", "LocalPairingHost.swift", "Assets.xcassets"],
                sources: ["StoreCatalog.swift", "DeviceApp.swift", "UpdaterModel.swift"],
                resources: [.process("en.lproj"), .process("ja.lproj"), .process("zh-Hans.lproj"), .process("zh-Hant.lproj")]),
        .testTarget(name: "UpdaterCoreTests", dependencies: ["UpdaterCore"], path: "Tests")
    ]
)
