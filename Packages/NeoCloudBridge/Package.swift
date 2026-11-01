// swift-tools-version: 6.0
import PackageDescription

/// The cross-product code shared by the iOS app, the macOS bridge and their tests.
///
/// Nothing in here talks to CloudKit or Hermes at import time: `CloudBridgeCore` is pure domain
/// logic (plus the system SQLite wrapper the local store needs), `CloudBridgeSync` wraps CloudKit
/// behind an injectable adapter, and `HermesBridgeClient` speaks to a loopback `hermes serve`.
/// Keeping them separate is what lets the iOS target depend on the mailbox without dragging in the
/// Mac-side client.
let package = Package(
    name: "NeoCloudBridge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CloudBridgeCore", targets: ["CloudBridgeCore"]),
        .library(name: "CloudBridgeSync", targets: ["CloudBridgeSync"]),
        .library(name: "HermesBridgeClient", targets: ["HermesBridgeClient"]),
    ],
    targets: [
        .target(name: "CloudBridgeCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "CloudBridgeSync", dependencies: ["CloudBridgeCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CloudBridgeCoreTests", dependencies: ["CloudBridgeCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "HermesBridgeClient", dependencies: ["CloudBridgeCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CloudBridgeSyncTests", dependencies: ["CloudBridgeSync", "CloudBridgeCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HermesBridgeClientTests", dependencies: ["HermesBridgeClient", "CloudBridgeCore"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
