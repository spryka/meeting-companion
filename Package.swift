// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingCompanion",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "meeting-companion", targets: ["InterviewRecorderCLI"]),
        .executable(name: "interview-recorder", targets: ["InterviewRecorderCLI"]),
        .executable(name: "InterviewRecorderApp", targets: ["InterviewRecorderApp"])
    ],
    targets: [
        .target(
            name: "InterviewRecorderCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .executableTarget(
            name: "InterviewRecorderCLI",
            dependencies: ["InterviewRecorderCore"]
        ),
        .executableTarget(
            name: "InterviewRecorderApp",
            dependencies: ["InterviewRecorderCore"],
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
