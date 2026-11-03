import Foundation
import Testing
@preconcurrency import MLX
import GigaAMKit
import Nemotron
import PipelineSilero
import MLXAudioSTT
import CryptoKit

@Suite(.serialized) struct ModelVendorGraphTests {
    private let root: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    @Test func testPackageResolvedPinsSingleMLX0323() throws {
        let resolvedURL = root.appendingPathComponent("Package.resolved")
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))

        let data = try Data(contentsOf: resolvedURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = (json?["pins"] as? [[String: Any]]) ?? []

        let mlxPins = pins.filter { ($0["identity"] as? String) == "mlx-swift" }
        #expect(mlxPins.count == 1, "Expected exactly 1 mlx-swift pin")

        if let pin = mlxPins.first, let state = pin["state"] as? [String: Any] {
            let version = state["version"] as? String
            #expect(version == "0.32.3", "Expected mlx-swift pinned to 0.32.3, got \(String(describing: version))")
        } else {
            Issue.record("Could not read mlx-swift pin state")
        }

        let sparklePins = pins.filter { ($0["identity"] as? String) == "sparkle" }
        #expect(sparklePins.count == 1, "Expected Sparkle pin retained")
        if let pin = sparklePins.first, let state = pin["state"] as? [String: Any] {
            let version = state["version"] as? String
            #expect(version == "2.9.6", "Expected sparkle pinned to 2.9.6, got \(String(describing: version))")
        }

        let expectedPinnedVersions: [String: String] = [
            "swift-huggingface": "0.12.0",
            "swift-transformers": "1.3.4",
            "swift-jinja": "2.5.1",
            "swift-collections": "1.7.1",
            "swift-numerics": "1.1.1",
            "yyjson": "0.12.0",
            "zstd": "1.5.7"
        ]

        for (identity, expectedVer) in expectedPinnedVersions {
            let matching = pins.filter { ($0["identity"] as? String) == identity }
            #expect(matching.count == 1, "Expected pin for \(identity)")
            if let pin = matching.first, let state = pin["state"] as? [String: Any] {
                let version = state["version"] as? String
                #expect(version == expectedVer, "Expected \(identity) pinned to \(expectedVer), got \(String(describing: version))")
            }
        }
    }

    @Test func testAppAndCLIIsolationFromMLXAndVendors() throws {
        // Create an isolated temporary copy of the package manifest to prevent .build lock contention
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pkgSource = root.appendingPathComponent("Package.swift")
        let pkgDest = tempDir.appendingPathComponent("Package.swift")
        try FileManager.default.copyItem(at: pkgSource, to: pkgDest)

        // Create symlinks to local target and vendor trees
        for dirName in ["Vendor", "Sources", "Tests"] {
            let src = root.appendingPathComponent(dirName)
            let dst = tempDir.appendingPathComponent(dirName)
            try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
        }

        let dumpProcess = Process()
        dumpProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        dumpProcess.arguments = ["swift", "package", "dump-package"]
        dumpProcess.currentDirectoryURL = tempDir

        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        dumpProcess.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        dumpProcess.standardOutput = stdoutPipe
        dumpProcess.standardError = stderrPipe

        try dumpProcess.run()

        // Drain stdout and stderr before waiting for exit to prevent pipe buffer deadlock
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        dumpProcess.waitUntilExit()

        #expect(dumpProcess.terminationStatus == 0)
        let packageJSON = try JSONSerialization.jsonObject(with: outputData) as? [String: Any]
        let targets = (packageJSON?["targets"] as? [[String: Any]]) ?? []

        let targetMap = Dictionary(uniqueKeysWithValues: targets.compactMap { target -> (String, [[String: Any]])? in
            guard let name = target["name"] as? String,
                  let deps = target["dependencies"] as? [[String: Any]] else { return nil }
            return (name, deps)
        })

        let forbiddenTargetNames: Set<String> = [
            "MLX", "MLXNN", "MLXFast", "MLXFFT", "MLXRandom",
            "GigaAMKit", "Nemotron", "PipelineSilero", "MLXAudioSTT",
            "MLXAudioCore", "MLXAudioCodecs", "MLXAudioTTS", "MLXAudioVAD", "MLXAudioUI"
        ]

        func collectTransitiveDeps(for targetName: String, visited: inout Set<String>) {
            guard !visited.contains(targetName), let directDeps = targetMap[targetName] else { return }
            visited.insert(targetName)

            for dep in directDeps {
                if let byName = dep["byName"] as? [Any], let depName = byName.first as? String {
                    collectTransitiveDeps(for: depName, visited: &visited)
                } else if let targetDep = dep["target"] as? [Any], let depName = targetDep.first as? String {
                    collectTransitiveDeps(for: depName, visited: &visited)
                } else if let productDep = dep["product"] as? [Any], let depName = productDep.first as? String {
                    visited.insert(depName)
                }
            }
        }

        for isolatedTarget in ["MeetingCompanionCore", "MeetingCompanionPlatform", "MeetingCompanionApp", "MeetingCompanionCLI"] {
            var visited = Set<String>()
            collectTransitiveDeps(for: isolatedTarget, visited: &visited)
            visited.remove(isolatedTarget)

            let violations = visited.intersection(forbiddenTargetNames)
            #expect(violations.isEmpty, "Target \(isolatedTarget) transitively depends on forbidden MLX/vendor targets: \(violations)")
        }
    }

    @Test func testVendorManifestIntegrity() throws {
        let manifestURL = root.appendingPathComponent("Vendor/vendor-manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = (json?["files"] as? [[String: Any]]) ?? []

        #expect(files.count >= 750, "Expected at least 750 files in vendor manifest, found \(files.count)")

        for fileEntry in files {
            guard let relPath = fileEntry["path"] as? String,
                  let expectedSHA = fileEntry["sha256"] as? String else {
                Issue.record("Invalid file entry in vendor manifest: \(fileEntry)")
                continue
            }

            // Assert no competing size_bytes field exists
            #expect(fileEntry["size_bytes"] == nil, "Found competing 'size_bytes' field in manifest entry: \(relPath)")

            let fileURL = root.appendingPathComponent(relPath)
            #expect(FileManager.default.fileExists(atPath: fileURL.path), "File missing on disk: \(relPath)")

            let fileData = try Data(contentsOf: fileURL)
            let actualSHA = SHA256.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
            #expect(actualSHA == expectedSHA, "SHA mismatch for \(relPath): expected \(expectedSHA), got \(actualSHA)")

            // Assert single size field matches actual file byte count
            if let expectedSize = fileEntry["size"] as? Int {
                #expect(fileData.count == expectedSize, "Size mismatch for \(relPath): expected \(expectedSize), got \(fileData.count)")
            } else {
                Issue.record("Missing single 'size' field in manifest entry: \(relPath)")
            }
        }
    }

    @Test func testGPUSmokeEvalAndSync() throws {
        // Look up compiled metallib from build outputs if needed
        let defaultMetallib = root.appendingPathComponent(".build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        if FileManager.default.fileExists(atPath: defaultMetallib.path) {
            GPU.metallib = defaultMetallib
        }

        let a = MLXArray([1.0, 2.0, 3.0, 4.0] as [Float])
        let b = MLXArray([10.0, 20.0, 30.0, 40.0] as [Float])
        let c = a + b
        eval(c)
        Stream.gpu.synchronize()

        let expected: [Float] = [11.0, 22.0, 33.0, 44.0]
        #expect(c.asArray(Float.self) == expected)
    }

    @Test func testDependencyLicensesMatchPackageResolved() throws {
        let licensesURL = root.appendingPathComponent("Vendor/dependency-licenses.json")
        #expect(FileManager.default.fileExists(atPath: licensesURL.path))
        let licData = try Data(contentsOf: licensesURL)
        let licJSON = try JSONSerialization.jsonObject(with: licData) as? [String: Any]
        let deps = (licJSON?["dependencies"] as? [[String: Any]]) ?? []

        let resolvedURL = root.appendingPathComponent("Package.resolved")
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))
        let resData = try Data(contentsOf: resolvedURL)
        let resJSON = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let pins = (resJSON?["pins"] as? [[String: Any]]) ?? []

        let depMap = Dictionary(uniqueKeysWithValues: deps.compactMap { d -> (String, [String: Any])? in
            guard let name = d["name"] as? String else { return nil }
            return (name, d)
        })

        // Check each package pin in Package.resolved against dependency-licenses.json
        for pin in pins {
            guard let identity = pin["identity"] as? String,
                  let state = pin["state"] as? [String: Any] else { continue }
            if identity == "sparkle" { continue } // App-only dependency

            guard let depEntry = depMap[identity] else {
                Issue.record("Missing dependency entry in dependency-licenses.json for pin '\(identity)'")
                continue
            }

            if let expectedVersion = state["version"] as? String {
                let recordedVersion = depEntry["version"] as? String
                #expect(recordedVersion == expectedVersion, "Version mismatch for '\(identity)': expected \(expectedVersion), got \(String(describing: recordedVersion))")
            }

            if let expectedRevision = state["revision"] as? String {
                let recordedRevision = depEntry["revision"] as? String
                #expect(recordedRevision == expectedRevision, "Revision mismatch for '\(identity)': expected \(expectedRevision), got \(String(describing: recordedRevision))")
            }
        }
    }

    @Test func testEmbeddedLicensesInventoryAndFilesExist() throws {
        let licensesURL = root.appendingPathComponent("Vendor/dependency-licenses.json")
        let licData = try Data(contentsOf: licensesURL)
        let licJSON = try JSONSerialization.jsonObject(with: licData) as? [String: Any]
        let embedded = (licJSON?["embedded_licenses"] as? [[String: Any]]) ?? []

        #expect(!embedded.isEmpty, "Expected embedded_licenses list in dependency-licenses.json")

        let expectedLicenses: [String] = [
            "Vendor/LICENSES/mlx-swift/metal-cpp-LICENSE.txt",
            "Vendor/LICENSES/mlx-swift/json-LICENSE.MIT",
            "Vendor/LICENSES/mlx-swift/fmt-LICENSE",
            "Vendor/LICENSES/mlx-swift/mlx-c-LICENSE",
            "Vendor/LICENSES/mlx-swift/mlx-LICENSE",
            "Vendor/LICENSES/MLXAudio-Phonon2-Apache-LICENSE.txt",
            "Vendor/LICENSES/MLXAudio-Phonon2-NOTICE.txt"
        ]

        for licRelPath in expectedLicenses {
            let fileURL = root.appendingPathComponent(licRelPath)
            #expect(FileManager.default.fileExists(atPath: fileURL.path), "Required license file missing: \(licRelPath)")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int {
                #expect(size > 0, "License file is empty: \(licRelPath)")
            }
        }

        // Verify metal-cpp descriptor is Apache-2.0 without LLVM exception
        if let metalCpp = embedded.first(where: { ($0["component"] as? String) == "metal-cpp" }) {
            let license = metalCpp["license"] as? String
            #expect(license == "Apache-2.0", "metal-cpp license descriptor must be exactly Apache-2.0 without exception, got \(String(describing: license))")
        } else {
            Issue.record("Missing metal-cpp in embedded_licenses")
        }
    }

    @Test func testBaselineMelExtractorProvenance() throws {
        let manifestURL = root.appendingPathComponent("Vendor/vendor-manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = (json?["files"] as? [[String: Any]]) ?? []

        guard let melEntry = files.first(where: { ($0["path"] as? String) == "Vendor/Nemotron/BaselineMelExtractor.swift" }) else {
            Issue.record("Missing Vendor/Nemotron/BaselineMelExtractor.swift in vendor manifest")
            return
        }

        let provenancePath = melEntry["dsp_source_path"] as? String
        let provenanceSHA = melEntry["dsp_source_sha256"] as? String

        #expect(provenancePath == "mlx_audio/vad/models/nemotron_diarization/nemotron_diarization.py", "Expected frozen Python DSP path in BaselineMelExtractor entry")
        #expect(provenanceSHA == "e56ab019f0d3400cb19ebc2deefcd7575b418dec60a6ab4bdafe322579636683", "Expected frozen Python DSP SHA-256 in BaselineMelExtractor entry")
    }
}
