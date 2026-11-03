import Foundation
import Testing

@Suite final class ModuleBoundaryTests {
    private let root: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static let forbiddenFrameworks: Set<String> = [
        "AVFoundation",
        "CoreMedia",
        "CoreAudio",
        "ScreenCaptureKit",
        "AppKit",
        "SwiftUI",
        "Combine",
        "MLX"
    ]

    struct PackageDump: Decodable {
        struct Target: Decodable {
            struct Setting: Decodable {
                struct Kind: Decodable {
                    struct LinkedFramework: Decodable {
                        let _0: String
                    }
                    let linkedFramework: LinkedFramework?
                }
                let kind: Kind?
            }
            let name: String
            let settings: [Setting]?
        }
        let targets: [Target]
    }

    enum GuardError: Error, LocalizedError {
        case evaluationFailed(String)
        case decodeFailed(String)
        case missingTarget(String)

        var errorDescription: String? {
            switch self {
            case .evaluationFailed(let msg): return "Package evaluation failed: \(msg)"
            case .decodeFailed(let msg): return "JSON decode failed: \(msg)"
            case .missingTarget(let name): return "Missing required target: \(name)"
            }
        }
    }

    static func dumpPackageJSON(forManifestAt manifestURL: URL) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let targetManifest = tempDir.appendingPathComponent("Package.swift")
        try FileManager.default.copyItem(at: manifestURL, to: targetManifest)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["package", "--package-path", tempDir.path, "dump-package"]
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        process.environment = env
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw GuardError.evaluationFailed(err)
        }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    static func findForbiddenLinkedFrameworks(inDumpData data: Data, targetName: String = "MeetingCompanionCore") throws -> [String] {
        let dump: PackageDump
        do {
            dump = try JSONDecoder().decode(PackageDump.self, from: data)
        } catch {
            throw GuardError.decodeFailed(error.localizedDescription)
        }
        guard let target = dump.targets.first(where: { $0.name == targetName }) else {
            throw GuardError.missingTarget(targetName)
        }
        var violations: [String] = []
        for setting in target.settings ?? [] {
            if let fw = setting.kind?.linkedFramework?._0, forbiddenFrameworks.contains(fw) {
                violations.append(fw)
            }
        }
        return violations
    }

    static func findForbiddenLinkedFrameworks(at packageOrDir: URL, targetName: String = "MeetingCompanionCore") throws -> [String] {
        let manifestFile = packageOrDir.hasDirectoryPath ? packageOrDir.appendingPathComponent("Package.swift") : packageOrDir
        let data = try dumpPackageJSON(forManifestAt: manifestFile)
        return try findForbiddenLinkedFrameworks(inDumpData: data, targetName: targetName)
    }

    static func findForbiddenLinkedFrameworks(in manifestContent: String, targetName: String = "MeetingCompanionCore") throws -> [String] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manifestFile = tempDir.appendingPathComponent("Package.swift")
        try Data(manifestContent.utf8).write(to: manifestFile)
        let data = try dumpPackageJSON(forManifestAt: manifestFile)
        return try findForbiddenLinkedFrameworks(inDumpData: data, targetName: targetName)
    }

    static func runShellBoundaryCheck(targetPath: String? = nil) throws -> (exitCode: Int32, output: String) {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/check-module-boundaries.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [script.path]
        if let targetPath { args.append(targetPath) }
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, out)
    }

    
    @Test func testMeetingCompanionApplicationHasNoForbiddenImports() throws {
        let appDir = root.appendingPathComponent("Sources/MeetingCompanionApplication")
        let fileURLs = try FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var violations: [String] = []

        for url in fileURLs {
            let content = try String(contentsOf: url, encoding: .utf8)
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for framework in Self.forbiddenFrameworks {
                    if trimmed.hasPrefix("import \(framework)") ||
                       trimmed.hasPrefix("@preconcurrency import \(framework)") {
                        violations.append("\(url.lastPathComponent): \(trimmed)")
                    }
                }
            }
        }

        #expect(violations.isEmpty, "MeetingCompanionApplication must not import forbidden frameworks: \(violations)")
    }

    @Test func testMeetingCompanionCoreHasNoForbiddenImports() throws {
        let coreDir = root.appendingPathComponent("Sources/MeetingCompanionCore")
        let fileURLs = try FileManager.default.contentsOfDirectory(at: coreDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var violations: [String] = []

        for url in fileURLs {
            let content = try String(contentsOf: url, encoding: .utf8)
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for framework in Self.forbiddenFrameworks {
                    if trimmed.hasPrefix("import \(framework)") ||
                       trimmed.hasPrefix("@preconcurrency import \(framework)") {
                        violations.append("\(url.lastPathComponent): \(trimmed)")
                    }
                }
            }
        }

        #expect(violations.isEmpty, "MeetingCompanionCore must not import forbidden frameworks: \(violations)")
    }

    @Test func testMeetingCompanionCoreHasNoForbiddenLinkedFrameworks() throws {
        let packageURL = root.appendingPathComponent("Package.swift")
        let violations = try Self.findForbiddenLinkedFrameworks(at: packageURL)
        #expect(violations.isEmpty, "MeetingCompanionCore must not link forbidden frameworks: \(violations)")
    }

    @Test func testModuleBoundaryGuardRejectsCoreAudioCounterexample() throws {
        let counterexample = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MeetingCompanion",
            targets: [
                .target(
                    name: "MeetingCompanionCore",
                    linkerSettings: [.linkedFramework("CoreAudio")]
                )
            ]
        )
        """
        let violations = try Self.findForbiddenLinkedFrameworks(in: counterexample)
        #expect(violations == ["CoreAudio"], "Guard must reject CoreAudio linked in MeetingCompanionCore")
    }

    @Test func testModuleBoundaryGuardRejectsFoundationThenAVFoundationCounterexample() throws {
        let counterexample = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MeetingCompanion",
            targets: [
                .target(
                    name: "MeetingCompanionCore",
                    linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AVFoundation")]
                )
            ]
        )
        """
        let violations = try Self.findForbiddenLinkedFrameworks(in: counterexample)
        #expect(violations == ["AVFoundation"], "Guard must reject AVFoundation even when preceded by Foundation in linkerSettings")
    }

    @Test func testModuleBoundaryGuardRejectsConditionalCoreAudio() throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MeetingCompanion",
            targets: [
                .target(
                    name: "MeetingCompanionCore",
                    linkerSettings: [.linkedFramework("CoreAudio", .when(platforms: [.macOS]))]
                )
            ]
        )
        """
        let violations = try Self.findForbiddenLinkedFrameworks(in: manifest)
        #expect(violations.contains("CoreAudio"), "Guard must reject conditional CoreAudio in MeetingCompanionCore")
    }

    @Test func testModuleBoundaryGuardRejectsWhitespaceCoreAudio() throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MeetingCompanion",
            targets: [
                .target(
                    name: "MeetingCompanionCore",
                    linkerSettings: [.linkedFramework( "CoreAudio" )]
                )
            ]
        )
        """
        let violations = try Self.findForbiddenLinkedFrameworks(in: manifest)
        #expect(violations.contains("CoreAudio"), "Guard must reject CoreAudio with extra whitespace in MeetingCompanionCore")
    }

    @Test func testModuleBoundaryGuardRejectsCommentParenthesisCoreAudio() throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MeetingCompanion",
            targets: [
                .target(
                    name: "MeetingCompanionCore",
                    // )
                    linkerSettings: [.linkedFramework("CoreAudio")]
                )
            ]
        )
        """
        let violations = try Self.findForbiddenLinkedFrameworks(in: manifest)
        #expect(violations.contains("CoreAudio"), "Guard must reject CoreAudio preceded by comment containing parenthesis in MeetingCompanionCore")
    }

    @Test func testModuleBoundaryGuardRejectsAllForbiddenFrameworksRegardlessOfOrder() throws {
        for forbidden in Self.forbiddenFrameworks {
            let snippet = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "MeetingCompanion",
                targets: [
                    .target(
                        name: "MeetingCompanionCore",
                        linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("\(forbidden)")]
                    )
                ]
            )
            """
            let violations = try Self.findForbiddenLinkedFrameworks(in: snippet)
            #expect(violations.contains(forbidden), "Guard must reject \(forbidden) in MeetingCompanionCore")
        }
    }

    @Test func testModuleBoundaryGuardFailsClosedOnEvaluationOrMissingTargetError() throws {
        let invalidManifest = """
        // Invalid Swift manifest that cannot evaluate
        syntax error
        """
        #expect(throws: Error.self) {
            _ = try Self.findForbiddenLinkedFrameworks(in: invalidManifest)
        }

        let missingCoreManifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MeetingCompanion",
            targets: [
                .target(name: "SomeOtherTarget")
            ]
        )
        """
        #expect(throws: Error.self) {
            _ = try Self.findForbiddenLinkedFrameworks(in: missingCoreManifest)
        }
    }

    private static let platformAdapters = [
        "AudioCapture.swift", "RecorderCore.swift", "SourceAudioFiles.swift",
        "Transcription.swift", "TranscriptAVPlayerTransport.swift"
    ]

    static func makeShellFixture(coreLinkerSettings: String = "", missing: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let platformTarget = missing == "target" ? "" : """
        , .target(name: "MeetingCompanionPlatform", dependencies: ["MeetingCompanionCore"],
                  linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"),
                                   .linkedFramework("CoreMedia"), .linkedFramework("ScreenCaptureKit")])
        """
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "BoundaryFixture", targets: [
            .target(name: "MeetingCompanionCore", linkerSettings: [\(coreLinkerSettings)]),
            .target(name: "MeetingCompanionApplication", dependencies: ["MeetingCompanionCore"])
            \(platformTarget)
        ])
        """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        let core = directory.appendingPathComponent("Sources/MeetingCompanionCore")
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try Data("// Foundation-only fixture\n".utf8).write(to: core.appendingPathComponent("Core.swift"))
        let app = directory.appendingPathComponent("Sources/MeetingCompanionApplication")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("// Foundation-only fixture\n".utf8).write(to: app.appendingPathComponent("App.swift"))
        if missing != "directory" {
            let platform = directory.appendingPathComponent("Sources/MeetingCompanionPlatform")
            try FileManager.default.createDirectory(at: platform, withIntermediateDirectories: true)
            for adapter in platformAdapters where adapter != missing {
                try Data("// Platform adapter fixture\n".utf8).write(to: platform.appendingPathComponent(adapter))
            }
        }
        return directory
    }

    @Test(arguments: ["target", "directory"] + platformAdapters)
    func testShellBoundaryCheckRequiresPlatform(missing: String) throws {
        let fixture = try Self.makeShellFixture(missing: missing)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let run = try Self.runShellBoundaryCheck(targetPath: fixture.path)
        #expect(run.exitCode != 0, "Must reject missing Platform \(missing): \(run.output)")
        let expected = missing == "target" ? "MISSING_TARGET: MeetingCompanionPlatform" :
            missing == "directory" ? "MISSING_PLATFORM_DIRECTORY:" : "REQUIRED_PLATFORM_FILE:"
        #expect(run.output.contains(expected), "Must fail the required Platform assertion: \(run.output)")
        if Self.platformAdapters.contains(missing) {
            #expect(run.output.contains(missing))
        }
    }

    @Test func testShellBoundaryCheckEntrypointValidatesRepositoryAndRejectsVariants() throws {
        let cleanRun = try Self.runShellBoundaryCheck()
        #expect(cleanRun.exitCode == 0, "No-argument shell boundary check must pass on repository root: \(cleanRun.output)")

        let allowed = try Self.makeShellFixture()
        defer { try? FileManager.default.removeItem(at: allowed) }
        let allowedRun = try Self.runShellBoundaryCheck(targetPath: allowed.path)
        #expect(allowedRun.exitCode == 0, "Platform frameworks must remain allowed: \(allowedRun.output)")

        let variants = [
            ".linkedFramework(\"CoreAudio\")",
            ".linkedFramework(\"CoreAudio\", .when(platforms: [.macOS]))",
            ".linkedFramework( \"CoreAudio\" )",
            "// )\n.linkedFramework(\"CoreAudio\")",
            ".linkedFramework(\"Foundation\"), .linkedFramework(\"CoreAudio\")"
        ]
        for variant in variants {
            let fixture = try Self.makeShellFixture(coreLinkerSettings: variant)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let run = try Self.runShellBoundaryCheck(targetPath: fixture.path)
            #expect(run.exitCode != 0, "Shell boundary check must reject \(variant): \(run.output)")
            #expect(run.output.contains("FORBIDDEN_CORE_FRAMEWORKS:"), "Must reject the evaluated framework: \(run.output)")
            #expect(run.output.contains("CoreAudio"), "Must identify CoreAudio: \(run.output)")
        }
    }
}
