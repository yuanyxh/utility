// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "utility",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "utility",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.copy("Resources")]
        )
    ]
)
