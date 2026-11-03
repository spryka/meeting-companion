#!/usr/bin/env swift
import Foundation

let files = FileManager.default

func recordingsRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
    let preferences = home.appendingPathComponent("Library/Preferences/local.meeting-companion.plist")
    if files.fileExists(atPath: preferences.path) {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferences), format: nil)
        if let configured = (object as? [String: Any])?["recordingsDirectory"] as? String, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
    }
    return home.appendingPathComponent("Downloads/Meetings")
}

func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

func isDirectory(_ url: URL) -> Bool {
    (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}

func isFile(_ url: URL) -> Bool {
    (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

func latest(_ root: URL) throws -> [String: Any] {
    let stem = #"meeting_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#
    var candidates: Set<URL> = []
    // A missing root has the same result as an empty one; never choose an older fallback meeting.
    if isDirectory(root) {
        for month in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where matches(month.lastPathComponent, #"^20[0-9]{2}-[0-9]{2}$"#) && isDirectory(month) {
            for day in try files.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)
                where matches(day.lastPathComponent, #"^[0-9]{2}$"#) && isDirectory(day) {
                for entry in try files.contentsOfDirectory(at: day, includingPropertiesForKeys: nil) {
                    if isDirectory(entry), matches(entry.lastPathComponent, "^\(stem)$") {
                        candidates.insert(entry.appendingPathComponent(entry.lastPathComponent))
                    } else if isFile(entry), matches(entry.lastPathComponent, "^\(stem)(?:\\.m4a|\\.sources\\.transcript\\.txt)$") {
                        candidates.insert(day.appendingPathComponent(String(entry.lastPathComponent.split(separator: ".", maxSplits: 1)[0])))
                    }
                }
            }
        }
    }
    guard let base = candidates.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
        throw NSError(domain: "RecordingFinder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No recordings in \(root.path)"])
    }
    func sibling(_ suffix: String) -> URL { base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + suffix) }
    var log = base.deletingLastPathComponent().appendingPathComponent("raw/" + base.lastPathComponent + ".transcription.log")
    if !isFile(log) { log = sibling(".transcription.log") }
    let transcript = sibling(".sources.transcript.txt")
    return ["recording": base.path, "transcript": transcript.path, "ready": isFile(transcript),
            "context": sibling(".context.json").path, "log": log.path]
}

func selfTest() throws {
    func samePath(_ actual: Any?, _ expected: URL) -> Bool {
        guard let actual = actual as? String else { return false }
        func resolved(_ url: URL) -> String {
            url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        return resolved(URL(fileURLWithPath: actual)) == resolved(expected)
    }
    let home = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recording-finder-\(UUID().uuidString)")
    try files.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: home) }
    let defaultRoot = try recordingsRoot(home: home)
    precondition(defaultRoot == home.appendingPathComponent("Downloads/Meetings"))
    let preferences = home.appendingPathComponent("Library/Preferences/local.meeting-companion.plist")
    try files.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
    for values: [String: String] in [[:], ["recordingsDirectory": home.appendingPathComponent("custom").path]] {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: preferences)
        let expected = values["recordingsDirectory"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Downloads/Meetings")
        let configuredRoot = try recordingsRoot(home: home)
        precondition(configuredRoot == expected)
    }
    do { _ = try latest(home); preconditionFailure("Empty root accepted") } catch {}
    let day = home.appendingPathComponent("2026-10/18")
    try files.createDirectory(at: day, withIntermediateDirectories: true)
    let old = day.appendingPathComponent("meeting_2026-10-18_10-00-00.sources.transcript.txt")
    try Data().write(to: old)
    let legacy = try latest(home)
    precondition(legacy["ready"] as? Bool == true && samePath(legacy["transcript"], old))
    let name = "meeting_2026-10-18_11-00-00"
    let folder = day.appendingPathComponent(name)
    let raw = folder.appendingPathComponent("raw")
    try files.createDirectory(at: raw, withIntermediateDirectories: true)
    let log = raw.appendingPathComponent(name + ".transcription.log")
    try Data().write(to: log)
    let experiment = day.appendingPathComponent("experiments/meeting_2099-01-01_00-00-00.sources.transcript.txt")
    try files.createDirectory(at: experiment.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: experiment)
    let result = try latest(home)
    precondition(result["ready"] as? Bool == false && samePath(result["recording"], folder.appendingPathComponent(name)))
    precondition(samePath(result["log"], log))
    try files.removeItem(at: log)
    let fallback = try latest(home)
    precondition(samePath(fallback["log"], folder.appendingPathComponent(name + ".transcription.log")))
    try files.createSymbolicLink(at: folder.appendingPathComponent(name + ".sources.transcript.txt"), withDestinationURL: old)
    let linked = try latest(home)
    guard linked["ready"] as? Bool == true else {
        throw NSError(domain: "RecordingFinder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Symlink transcript must remain readable"])
    }
    print("Recording finder: preferences, latest unfinished, flat TXT, ignored experiments and log paths passed")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] {
        try selfTest()
    } else {
        let root: URL
        if arguments.isEmpty { root = try recordingsRoot() }
        else if arguments.count == 2 && arguments[0] == "--root" { root = URL(fileURLWithPath: arguments[1]) }
        else { throw NSError(domain: "RecordingFinder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: find-recording.swift [--root PATH | --self-test]"]) }
        let data = try JSONSerialization.data(withJSONObject: latest(root), options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
