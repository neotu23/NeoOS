// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HermesIOSCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "HermesIOSCore", targets: ["HermesIOSCore"])],
    dependencies: [.package(path: "Packages/NeoCloudBridge")],
    targets: [
        .target(name: "NeoOSCloudChat", dependencies: [
            .product(name: "CloudBridgeCore", package: "NeoCloudBridge"),
            .product(name: "CloudBridgeSync", package: "NeoCloudBridge")
        ], path: "HermesIOS/Features/Cloud", exclude: ["CloudChatView.swift", "CloudConnectionView.swift"]),
        .testTarget(name: "NeoOSCloudChatTests", dependencies: ["NeoOSCloudChat"], path: "HermesIOSCloudTests"),
        .target(name: "HermesIOSCore", path: "HermesIOS/Core"),
        .testTarget(name: "HermesIOSCoreTests", dependencies: ["HermesIOSCore"], path: "HermesIOSTests", exclude: ["Fixtures"])
    ]
)
