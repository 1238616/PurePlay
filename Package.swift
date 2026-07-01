// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PurePlay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PurePlayCore", targets: ["PurePlayCore"]),
        .executable(name: "PurePlay", targets: ["PurePlayApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0")
    ],
    targets: [
        .target(
            name: "PurePlayCore",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/PurePlayCore"
        ),
        .executableTarget(
            name: "PurePlayApp",
            dependencies: ["PurePlayCore"],
            path: "Sources/PurePlayApp"
        ),
        .executableTarget(
            name: "PurePlayTests",
            dependencies: ["PurePlayCore"],
            path: "Tests/PurePlayCoreTests"
        )
    ]
)
