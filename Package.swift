// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrendingTabKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrendingTabKit", targets: ["TrendingTabKit"]),
        .library(name: "TrendingTabCore", targets: ["TrendingTabCore"]),
        .library(name: "TrendingTabWidgetBridge", targets: ["TrendingTabWidgetBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.8.0"),
    ],
    targets: [
        .target(name: "TrendingTabCore"),
        .target(name: "TrendingTabNetworking", dependencies: ["TrendingTabCore"]),
        .target(
            name: "TrendingTabSources",
            dependencies: ["TrendingTabCore", "TrendingTabNetworking", "SwiftSoup"],
            resources: [.process("Fixtures")]
        ),
        .target(
            name: "TrendingTabPersistence",
            dependencies: ["TrendingTabCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "TrendingTabAggregation", dependencies: ["TrendingTabCore"]),
        .target(name: "TrendingTabIntelligence", dependencies: ["TrendingTabCore", "TrendingTabNetworking", "TrendingTabSources", "SwiftSoup"]),
        .target(name: "TrendingTabNotifications", dependencies: ["TrendingTabCore"]),
        .target(name: "TrendingTabWidgetBridge", dependencies: ["TrendingTabCore", "TrendingTabAggregation"]),
        .target(
            name: "TrendingTabKit",
            dependencies: [
                "TrendingTabCore", "TrendingTabNetworking", "TrendingTabSources",
                "TrendingTabPersistence", "TrendingTabAggregation", "TrendingTabIntelligence",
                "TrendingTabNotifications", "TrendingTabWidgetBridge",
            ]
        ),
        .executableTarget(name: "TrendingTabProbe", dependencies: ["TrendingTabKit"]),
        .testTarget(
            name: "TrendingTabKitTests",
            dependencies: ["TrendingTabKit"],
            resources: [.process("Fixtures")]
        ),
    ]
)
