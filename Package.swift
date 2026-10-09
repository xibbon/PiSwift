// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
    name: "PiSwift",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PiSwift",
            targets: ["PiSwift"]
        ),
        .library(name: "PiSwiftDurable", targets: ["PiSwiftDurable"]),
        .library(
            name: "PiSwiftChord",
            targets: ["PiSwiftChord"]
        ),
        .library(
            name: "PiSwiftAI",
            targets: ["PiSwiftAI"]
        ),
        .library(
            name: "PiSwiftAgent",
            targets: ["PiSwiftAgent"]
        ),
        .library(
            name: "PiSwiftCodingAgent",
            targets: ["PiSwiftCodingAgent"]
        ),
        .library(
            name: "PiSwiftSyntaxHighlight",
            targets: ["PiSwiftSyntaxHighlight"]
        ),
        .library(
            name: "PiMCPAdapter",
            targets: ["PiMCPAdapter"]
        ),
        .library(
            name: "PiSwiftMCP",
            targets: ["PiSwiftMCP"]
        ),
        .library(
            name: "PiExtensionSDK",
            type: .dynamic,
            targets: ["PiExtensionSDK"]
        ),
        .library(
            name: "PiReviewExtension",
            targets: ["PiReviewExtension"]
        ),
        .executable(
            name: "pi-ai",
            targets: ["PiSwiftAICLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", revision: "4ed3ea99ff9dfd2a760509ddb31020f4b153ef93"),
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", revision: "4f9e21b94e491138003903ff6c14ab4f04b6ba6c"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PiSwift",
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftDurable",
            dependencies: ["PiSwiftAI", "PiSwiftChord"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftDurableTesting",
            dependencies: ["PiSwiftDurable", "PiSwiftChord"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftChord",
            path: "Sources/PiSwiftChord",
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftAI",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftAgent",
            dependencies: ["PiSwiftAI"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftCodingAgent",
            dependencies: [
                "PiSwiftAI",
                "PiSwiftAgent",
                "PiSwiftMCP",
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftMCP",
            dependencies: ["PiSwiftAI"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiMCPAdapter",
            dependencies: [
                "PiSwiftMCP",
                "PiSwiftCodingAgent",
                "PiSwiftAI",
                "PiSwiftAgent",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiExtensionSDK",
            dependencies: [
                "PiSwiftAI",
                "PiSwiftAgent",
                "PiSwiftCodingAgent",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiReviewExtension",
            dependencies: [
                "PiSwiftAI",
                "PiSwiftAgent",
                "PiSwiftCodingAgent",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftSyntaxHighlight",
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "PiSwiftAICLI",
            dependencies: [
                "PiSwiftAI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftDurableTests",
            dependencies: ["PiSwiftDurable", "PiSwiftDurableTesting", "PiSwiftChord", "PiSwiftAI"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftChordTests",
            dependencies: ["PiSwiftChord"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftAITests",
            dependencies: ["PiSwiftAI", "TestEnvironmentSupport"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftAgentTests",
            dependencies: ["PiSwiftAgent"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftSyntaxHighlightTests",
            dependencies: ["PiSwiftSyntaxHighlight"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftCodingAgentTests",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftAI",
                "PiSwiftAgent",
                "TestEnvironmentSupport",
            ],
            resources: [
                .copy("fixtures"),
                .process("Resources")
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftMCPTests",
            dependencies: ["PiSwiftMCP", "PiSwiftAI"],
            resources: [.copy("fixtures")],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiMCPAdapterTests",
            dependencies: [
                "PiMCPAdapter",
                "PiSwiftCodingAgent",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiReviewExtensionTests",
            dependencies: [
                "PiReviewExtension",
                "PiSwiftCodingAgent",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftTests",
            dependencies: ["PiSwift"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "TestEnvironmentSupport",
            path: "Tests/Support",
            swiftSettings: strictConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
