import Foundation
import MeetingCompanionCore

enum RecordingAudioRetention {
    static func removal(for entry: RecordingEntry, before cutoff: Date) throws -> RecordingAudioRemoval? {
        let folder = try RecordingAudioDirectory(entry.folder)
        let stem = entry.base.lastPathComponent
        let sourceSuffixes = ["host_record.wav", "remote_record.wav", "host_record.aec.wav", "host.capture.caf", "remote.capture.caf"]
        let sourceNames = Set(sourceSuffixes.map { stem + "." + $0 })
        let mixedNames = Set([stem + ".m4a", stem + ".mp4"])

        var files = try folder.audioFiles(in: entry.folder) {
            mixedNames.contains($0) || sourceNames.contains($0) || RecordingPaths.isTemporaryMixedAudio($0)
        }
        if let raw = try folder.child("raw") {
            files += try raw.audioFiles(in: entry.folder) { sourceNames.contains($0) }
            if let results = try raw.child("transcripts") {
                files += try resultAudio(in: results, folder: entry.folder)
            }
        }
        guard !files.isEmpty, files.allSatisfy({ $0.modifiedAt <= cutoff }) else { return nil }
        return RecordingAudioRemoval(folder: entry.folder, files: files)
    }

    private static func resultAudio(in results: RecordingAudioDirectory, folder: URL) throws -> [RecordingAudioRemoval.File] {
        var files: [RecordingAudioRemoval.File] = []
        let versions = try results.names().compactMap { try results.child($0) }
        let published = Dictionary(uniqueKeysWithValues: versions.compactMap { directory -> (String, TranscriptDocument)? in
            let name = directory.url.lastPathComponent
            guard !name.hasPrefix("."), let document = versionDocument(in: directory, folder: folder, id: name)
            else { return nil }
            return (name, document)
        })
        for directory in versions {
            let name = directory.url.lastPathComponent
            if let version = published[name] {
                let base = "raw/transcripts/\(name)/"
                let mix = version.playback.mixPath == base + "mix.m4a"
                let aec = version.sources.contains { $0.recognitionAudioPath == base + "host_aec.wav" }
                files += try directory.audioFiles(in: folder) {
                    $0 == "mix.m4a" && mix || $0 == "host_aec.wav" && aec
                }
            } else if name.hasPrefix(".staging-") {
                let id = String(name.dropFirst(".staging-".count))
                let publisherID = id.count > 37 && UUID(uuidString: String(id.suffix(36))) != nil && id.dropLast(36).last == "-"
                    ? String(id.dropLast(37)) : nil
                let resultID = published[id] == nil ? publisherID ?? id : id
                let native = resultID.range(of: "^res_[0-9a-f]{8}$", options: .regularExpression) != nil
                guard native || published[resultID] != nil || directory.fileIdentity(RecordingPaths.transcriptionStagingMarker) != nil
                        || versionDocument(in: directory, folder: folder, id: resultID) != nil else { continue }
                files += try directory.audioFiles(in: folder) { name in
                    name == "mix.m4a" || name == "host_aec.wav" || isTemporaryPipelineAudio(name)
                }
            }
        }

        return files
    }

    private static func versionDocument(in directory: RecordingAudioDirectory, folder: URL, id: String) -> TranscriptDocument? {
        guard directory.fileIdentity("result.json") != nil, (try? directory.validateLocation()) != nil,
              let document = try? TranscriptDocument.load(from: directory.url.appendingPathComponent("result.json"),
                                                          recordingDirectory: folder),
              document.resultID == id else { return nil }
        return document
    }

    private static func isTemporaryPipelineAudio(_ name: String) -> Bool {
        let base = name.dropLast(4)
        let prefixes = name.hasSuffix(".m4a") ? [".mix-temp-"] : name.hasSuffix(".wav")
            ? [".mix-temp-", ".mix-temp-dec-", ".aec-"] : []
        return prefixes.contains { prefix in
            base.hasPrefix(prefix) && UUID(uuidString: String(base.dropFirst(prefix.count))) != nil
        }
    }
}
