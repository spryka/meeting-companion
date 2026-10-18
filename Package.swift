// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingCompanion",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "meeting-companion", targets: ["MeetingCompanionCLI"]),
        .executable(name: "MeetingCompanionApp", targets: ["MeetingCompanionApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(
            name: "MeetingCompanionCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .executableTarget(
            name: "MeetingCompanionCLI",
            dependencies: ["MeetingCompanionCore"]
        ),
        .executableTarget(
            name: "MeetingCompanionApp",
            dependencies: ["MeetingCompanionCore", .product(name: "Sparkle", package: "Sparkle")],
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
