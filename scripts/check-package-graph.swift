import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// SwiftPM uses associated enum values in both keyed and array representations.
func associatedName(_ value: Any?) -> String? {
    if let array = value as? [Any] { return array.first as? String }
    if let object = value as? [String: Any] { return object["_0"] as? String }
    return value as? String
}

func dependencies(_ target: [String: Any]) -> [String?] {
    (target["dependencies"] as? [[String: Any]] ?? []).map { dependency in
        for key in ["byName", "target", "product"] {
            if let name = associatedName(dependency[key]) { return name }
        }
        return nil
    }
}

func frameworks(_ target: [String: Any]) -> Set<String> {
    Set((target["settings"] as? [[String: Any]] ?? []).compactMap { setting in
        let kind = setting["kind"] as? [String: Any]
        return associatedName(kind?["linkedFramework"])
    })
}

do {
    let object = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())
    guard let dump = object as? [String: Any], let rows = dump["targets"] as? [[String: Any]] else {
        fail("JSON_DECODE_ERROR: expected package targets")
    }
    var targets: [String: [String: Any]] = [:]
    for target in rows {
        guard let name = target["name"] as? String else { fail("JSON_DECODE_ERROR: missing target name") }
        targets[name] = target
    }
    func required(_ name: String) -> [String: Any] {
        guard let target = targets[name] else { fail("MISSING_TARGET: \(name) target not found in package manifest") }
        return target
    }
    let forbidden: Set<String> = ["AVFoundation", "CoreMedia", "CoreAudio", "ScreenCaptureKit", "AppKit", "SwiftUI", "Combine", "MLX"]
    for (name, label) in [("MeetingCompanionCore", "CORE"), ("MeetingCompanionApplication", "APPLICATION")] {
        let violations = frameworks(required(name)).intersection(forbidden)
        if !violations.isEmpty { fail("FORBIDDEN_\(label)_FRAMEWORKS: \(violations.sorted())") }
    }
    for dependency in dependencies(required("MeetingCompanionApplication")) where dependency != "MeetingCompanionCore" {
        fail("FORBIDDEN_APPLICATION_DEPENDENCY: \(dependency ?? "unknown") (Application may only depend on Core)")
    }
    let expected: Set<String> = ["AVFoundation", "CoreAudio", "CoreMedia", "ScreenCaptureKit"]
    let found = frameworks(required("MeetingCompanionPlatform"))
    if !expected.isSubset(of: found) { fail("PLATFORM_FRAMEWORKS_MISSING: expected \(expected.sorted()), found \(found.sorted())") }
    let isolated: Set<String> = ["MLX", "MeetingTranscriptionPipeline", "GigaAMKit", "Nemotron", "PipelineSilero"]
    for name in ["MeetingCompanionApp", "MeetingCompanionCLI"] {
        guard let target = targets[name] else { continue }
        for dependency in dependencies(target) {
            if let dependency, isolated.contains(dependency) { fail("FORBIDDEN_TARGET_DEPENDENCY: \(name) directly depends on \(dependency)") }
        }
    }
    print("PACKAGE_GRAPH_VALID")
} catch {
    fail("JSON_DECODE_ERROR: \(error.localizedDescription)")
}
