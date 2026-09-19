// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProgrammeKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ProgrammeCore", targets: ["ProgrammeCore"]),
        .library(name: "ProgrammePersistence", targets: ["ProgrammePersistence"]),
        .library(name: "ProgrammeExport", targets: ["ProgrammeExport"]),
        .library(name: "ProgrammeUI", targets: ["ProgrammeUI"]),
        .library(name: "ProgrammeCollaboration", targets: ["ProgrammeCollaboration"]),
    ],
    targets: [
        // Pure domain. No SwiftUI, no SwiftData, no Foundation-heavy dependencies.
        .target(name: "ProgrammeCore"),
        .target(name: "ProgrammePersistence", dependencies: ["ProgrammeCore"]),
        .target(name: "ProgrammeExport", dependencies: ["ProgrammeCore"]),
        .target(name: "ProgrammeUI", dependencies: ["ProgrammeCore"]),
        // CloudKit replication. Depends on Core values only: no CloudKit in
        // Core, no stat engines here, no model objects cross the boundary.
        .target(name: "ProgrammeCollaboration", dependencies: ["ProgrammeCore"]),
        .testTarget(name: "ProgrammeCoreTests", dependencies: ["ProgrammeCore"]),
        .testTarget(name: "ProgrammeExportTests", dependencies: ["ProgrammeCore", "ProgrammeExport"]),
        .testTarget(
            name: "ProgrammePersistenceTests",
            dependencies: ["ProgrammeCore", "ProgrammePersistence", "ProgrammeExport"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "ProgrammeCollaborationTests",
            dependencies: ["ProgrammeCore", "ProgrammeCollaboration"]),
    ],
    swiftLanguageModes: [.v6]
)
