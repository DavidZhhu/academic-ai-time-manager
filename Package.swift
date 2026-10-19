// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AcademicTimeManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AcademicTimeManager", targets: ["AcademicTimeManager"]), .library(name: "AcademicCore", targets: ["AcademicCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CZlib"),
        .target(name: "AcademicCore", dependencies: ["CSQLite", "CZlib"], path: "Sources/AcademicCore"),
        .executableTarget(name: "AcademicTimeManager", dependencies: ["AcademicCore"], resources: [.process("Resources")]),
        .testTarget(name: "AcademicTimeManagerTests", dependencies: ["AcademicCore"])
    ]
)
