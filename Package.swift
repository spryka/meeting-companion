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
            dependencies: ["MeetingCompanionCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("EventKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
