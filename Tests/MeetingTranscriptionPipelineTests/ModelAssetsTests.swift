import XCTest
import Foundation
import CryptoKit
@testable import MeetingTranscriptionPipeline
import MeetingCompanionPlatform

final class ModelAssetsTests: XCTestCase {
    func testModelSpecsPinnedIntegrity() {
        let specs = [
            ModelAssets.gigaamSpec,
            ModelAssets.vadSpec,
            ModelAssets.nemotronSpec,
            ModelAssets.parakeetSpec
        ]

        for spec in specs {
            XCTAssertFalse(spec.name.isEmpty, "Model name should not be empty")
            XCTAssertFalse(spec.repo.isEmpty, "Repo should not be empty")
            XCTAssertEqual(spec.revision.count, 40, "Revision should be a 40-char commit SHA: \(spec.revision)")
            XCTAssertFalse(spec.files.isEmpty, "Spec files should not be empty for \(spec.name)")

            for file in spec.files {
                XCTAssertFalse(file.filename.isEmpty)
                XCTAssertEqual(file.sha256.count, 64, "SHA256 should be 64 hex chars for \(file.filename)")
                let isHex = file.sha256.allSatisfy { $0.isHexDigit }
                XCTAssertTrue(isHex, "SHA256 should be valid lowercase hex: \(file.sha256)")
            }
        }
    }

    func testComputeSHA256Streaming() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sha-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.bin")
        let testData = Data("Hello, Meeting Companion native transcription!".utf8)
        try testData.write(to: testFile)

        let expectedSHA = SHA256.hash(data: testData).map { String(format: "%02x", $0) }.joined()
        let actualSHA = try ModelAssets.computeSHA256(at: testFile)

        XCTAssertEqual(actualSHA, expectedSHA)
    }

    func testCheckAvailabilityMissingAndEmpty() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("avail-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Completely empty directory
        let (emptyReady, emptyMissing) = ModelAssets.checkAvailability(modelRoot: tempDir, parakeet: false)
        XCTAssertFalse(emptyReady)
        XCTAssertFalse(emptyMissing.isEmpty)

        // Create empty file for gigaam manifest
        let gigaDir = tempDir.appendingPathComponent("gigaam")
        try FileManager.default.createDirectory(at: gigaDir, withIntermediateDirectories: true)
        let emptyManifest = gigaDir.appendingPathComponent("manifest.json")
        try Data().write(to: emptyManifest)

        let (_, partialMissing) = ModelAssets.checkAvailability(modelRoot: tempDir, parakeet: false)
        XCTAssertTrue(partialMissing.contains("gigaam/manifest.json (empty)"))
    }

    func testCheckAvailabilityDetectsCorruption() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gigaDir = tempDir.appendingPathComponent("gigaam")
        try FileManager.default.createDirectory(at: gigaDir, withIntermediateDirectories: true)
        let corruptManifest = gigaDir.appendingPathComponent("manifest.json")
        try Data("corrupted content".utf8).write(to: corruptManifest)

        let (_, missing) = ModelAssets.checkAvailability(modelRoot: tempDir, parakeet: false, verifyChecksums: true)
        XCTAssertTrue(missing.contains("gigaam/manifest.json (corrupt checksum)"))
    }

    func testPreparePathContainment() {
        let invalidRoot = URL(fileURLWithPath: "/tmp/foo/../bar")
        XCTAssertThrowsError(
            try ModelAssets.prepare(modelRoot: invalidRoot, sourceRoot: nil, parakeet: false, allowDownload: false)
        ) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "ModelAssets")
            XCTAssertEqual(ns.code, 3)
        }
    }

    func testPrepareFromSourceWithMockFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("prep-test-\(UUID().uuidString)")
        let sourceRoot = tempRoot.appendingPathComponent("source")
        let destRoot = tempRoot.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // If files are missing from source and download is disabled, it throws error 1
        XCTAssertThrowsError(
            try ModelAssets.prepare(modelRoot: destRoot, sourceRoot: sourceRoot, parakeet: false, allowDownload: false)
        ) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "ModelAssets")
            XCTAssertEqual(ns.code, 1)
        }
    }

    func testCancellationInPrepare() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        XCTAssertThrowsError(
            try ModelAssets.prepare(
                modelRoot: tempRoot,
                sourceRoot: nil,
                parakeet: false,
                allowDownload: false,
                isCancelled: { true }
            )
        ) { error in
            let desc = error.localizedDescription.lowercased()
            XCTAssertTrue(desc.contains("отменено") || desc.contains("cancel"), "Error description should reflect cancellation: \(error)")
        }
    }

    func testSymlinkTraversalRejected() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("symlink-test-\(UUID().uuidString)")
        let outsideDir = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        // Create a symlink at destRoot/gigaam pointing outside
        let gigaamSymlink = tempRoot.appendingPathComponent("gigaam")
        try FileManager.default.createSymbolicLink(at: gigaamSymlink, withDestinationURL: outsideDir)

        XCTAssertThrowsError(
            try ModelAssets.prepare(
                modelRoot: tempRoot,
                sourceRoot: nil,
                parakeet: false,
                allowDownload: false
            )
        ) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "ModelAssets")
            XCTAssertEqual(ns.code, 3)
            XCTAssertTrue(ns.localizedDescription.contains("символической ссылкой"), "Should reject symlink directory: \(ns.localizedDescription)")
        }
    }

    func testOldSnapshotPreservedOnFailure() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("preserve-test-\(UUID().uuidString)")
        let destRoot = tempRoot.appendingPathComponent("destination")
        let sourceRoot = tempRoot.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Setup existing model folder in destRoot with custom preserved file
        let existingGigaDir = destRoot.appendingPathComponent("gigaam")
        try FileManager.default.createDirectory(at: existingGigaDir, withIntermediateDirectories: true)
        let preservedMarker = existingGigaDir.appendingPathComponent("marker.txt")
        let originalContent = "original-working-model-data"
        try Data(originalContent.utf8).write(to: preservedMarker)

        // Attempt prepare from an incomplete source with downloads disabled (will fail)
        XCTAssertThrowsError(
            try ModelAssets.prepare(
                modelRoot: destRoot,
                sourceRoot: sourceRoot,
                parakeet: false,
                allowDownload: false
            )
        )

        // Verify the existing gigaam directory and its marker are preserved intact
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedMarker.path), "Existing directory must remain intact upon failure")
        let readContent = try String(contentsOf: preservedMarker, encoding: .utf8)
        XCTAssertEqual(readContent, originalContent, "Existing model contents must not be overwritten or corrupted on failure")
    }

    func testSubprocessRunnerBoundedTermination() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]

        let runner = SubprocessRunner(process: process)
        try process.run()
        XCTAssertTrue(process.isRunning)

        let startTime = Date()
        runner.terminate(timeoutSeconds: 0.2)

        // Wait for process to exit
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(elapsed, 3.0, "Subprocess termination must complete within bounded timeout")
    }
}
