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
            name: "PiSwiftCodingAgentTui",
            targets: ["PiSwiftCodingAgentTui"]
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
            name: "PiExtensionSDK",
            type: .dynamic,
            targets: ["PiExtensionSDK"]
        ),
        .executable(
            name: "pi-ai",
            targets: ["PiSwiftAICLI"]
        ),
        .executable(
            name: "pi-coding-agent",
            targets: ["PiSwiftCodingAgentCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main"),
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(path: "../MiniTui"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PiSwift",
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
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiSwiftCodingAgentTui",
            dependencies: [
                "PiSwiftAI",
                "PiSwiftAgent",
                "PiSwiftCodingAgent",
                "PiSwiftSyntaxHighlight",
                .product(name: "MiniTui", package: "MiniTui"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "PiMCPAdapter",
            dependencies: [
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
        .executableTarget(
            name: "PiSwiftCodingAgentCLI",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftCodingAgentTui",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftAITests",
            dependencies: ["PiSwiftAI"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftAgentTests",
            dependencies: ["PiSwiftAgent"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftCodingAgentTests",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftAI",
                "PiSwiftAgent",
            ],
            resources: [
                .copy("fixtures")
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftCodingAgentCLITests",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftCodingAgentCLI",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftCodingAgentTuiTests",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftCodingAgentTui",
                .product(name: "MiniTui", package: "MiniTui"),
            ],
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
            name: "PiSwiftTests",
            dependencies: ["PiSwift"],
            swiftSettings: strictConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
