// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sempre",
    platforms: [.macOS(.v14)],
    targets: [
        // Data model, storage, statistics and the Tyme importer. No UI.
        .target(name: "SempreCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The menu bar app.
        .executableTarget(name: "Sempre", dependencies: ["SempreCore"]),
        .testTarget(name: "SempreCoreTests", dependencies: ["SempreCore"]),
    ]
)
