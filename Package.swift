// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingCompanion",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "meeting-companion", targets: ["MeetingCompanionCLI"]),
        .executable(name: "MeetingCompanionApp", targets: ["MeetingCompanionApp"]),
        .executable(name: "MeetingTranscriptionWorker", targets: ["MeetingTranscriptionWorker"]),
        .library(name: "MeetingTranscriptionPipeline", targets: ["MeetingTranscriptionPipeline"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/apple/swift-numerics.git", exact: "1.1.1"),
        .package(path: "Vendor/mlx-audio-swift")
    ],
    targets: [
        .target(
            name: "MeetingCompanionCore"
        ),
        .target(
            name: "MeetingCompanionApplication",
            dependencies: [
                "MeetingCompanionCore"
            ]
        ),
        .target(
            name: "MeetingCompanionPlatform",
            dependencies: [
                "MeetingCompanionCore"
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .target(
            name: "GigaAMKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "Numerics", package: "swift-numerics")
            ],
            path: "Vendor/GigaAMKit"
        ),
        .target(
            name: "Nemotron",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift")
            ],
            path: "Vendor/Nemotron"
        ),
        .target(
            name: "MeetingTranscriptionPipeline",
            dependencies: [
                "MeetingCompanionCore",
                "GigaAMKit",
                "Nemotron",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "MeetingTranscriptionWorker",
            dependencies: [
                "MeetingTranscriptionPipeline"
            ]
        ),
        .testTarget(
            name: "MeetingTranscriptionPipelineTests",
            dependencies: [
                "MeetingCompanionApplication",
                "MeetingTranscriptionPipeline",
                "MeetingCompanionCore",
                "MeetingCompanionPlatform"
            ]
        ),
        .testTarget(
            name: "MeetingCompanionCoreTests",
            dependencies: [
                "MeetingCompanionCore",
                "MeetingCompanionApplication",
                "TranscriptLockHelper"
            ]
        ),
        .testTarget(
            name: "MeetingCompanionAppTests",
            dependencies: ["MeetingCompanionApp"]
        ),
        .testTarget(
            name: "ModelVendorTests",
            dependencies: [
                "GigaAMKit",
                "Nemotron",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift")
            ],
            path: "Tests/ModelVendorTests"
        ),
        .executableTarget(
            name: "TranscriptLockHelper",
            dependencies: ["MeetingCompanionCore"],
            path: "Tests/TranscriptLockHelper"
        ),
        .executableTarget(
            name: "MeetingCompanionCLI",
            dependencies: [
                "MeetingCompanionCore",
                "MeetingCompanionApplication",
                "MeetingCompanionPlatform"
            ]
        ),
        .executableTarget(
            name: "MeetingCompanionApp",
            dependencies: [
                "MeetingCompanionCore",
                "MeetingCompanionApplication",
                "MeetingCompanionPlatform",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("EventKit"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
