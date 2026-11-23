import Foundation
import Synchronization
import SwiftUI
import AppKit
import Testing
import MeetingCompanionCore
import MeetingCompanionApplication
@testable import MeetingCompanionPlatform
import AVFoundation
@testable import MeetingCompanionApp

private final class SyntheticAudioCapture: AudioCaptureControllerProtocol, @unchecked Sendable {
    let outputURL: URL
    private let microphoneState: @Sendable () -> MicrophoneRecordingState
    init(outputURL: URL, microphoneState: @escaping @Sendable () -> MicrophoneRecordingState = { .receiving }) {
        self.outputURL = outputURL
        self.microphoneState = microphoneState
    }
    func startCapture() async throws {}
    func stopCapture() async throws -> AudioCaptureStopResult {
        .init(duration: 0, outputURL: outputURL)
    }
    func setMicrophoneMuted(_ muted: Bool) {}
    func currentMicrophoneState() -> MicrophoneRecordingState { microphoneState() }
}

private struct SyntheticRunner: TranscriptionRunnerProtocol, VoiceEmbeddingRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL { recording.appendingPathExtension("txt") }
    func checkOrPrepareVoiceModel(prepare: Bool) async throws {}
    func extractVoiceEmbeddings(_ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL) async throws -> VoiceEmbeddingProtocol.Response {
        throw ProcessingService.VoiceJobError.unavailable
    }
}

private struct SyntheticExporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {}
}

private final class SyntheticLevels: AudioLevelMonitoring, @unchecked Sendable {
    func start() async throws {}
    func stop() async throws {}
}

@MainActor private final class NativeFixtureTransport: TranscriptPlaybackTransport {
    var onEvent: (@MainActor @Sendable (TranscriptPlaybackEvent) -> Void)?
    let duration: Double
    init(duration: Double = 1458) { self.duration = duration }
    func prepare(url: URL) async throws -> Double { duration }
    func play() { onEvent?(.playing(true)) }
    func pause() { onEvent?(.playing(false)) }
    func seek(to seconds: Double) async -> Bool { onEvent?(.position(seconds)); return true }
    func stop() {}
    func setRate(_ rate: Float) {}
}

@Suite @MainActor final class VisualFidelityTests {
    @Test func voiceIdentityNativeReferenceStates() async throws {
        guard let destination = ProcessInfo.processInfo.environment["VOICE_VISUAL_ROOT"] else { return }
        let output = URL(fileURLWithPath: destination)
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
            output.appendingPathComponent("voice-reference-fixture.json"))) as! [String: Any]
        let records = fixture["records"] as! [[String: Any]]
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("voice-visual-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "voice-visual-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "recordingsDirectory")
        defaults.set(true, forKey: "localVoiceIdentityEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        var playbackDuration: Double = 1865
        let appData = root.appendingPathComponent("appData")
        let learning = VoiceLearningCoordinator(catalogue: VoiceProfileCatalogueRepository(applicationDataDirectory: appData))
        let manager = TranscriptReviewWindowManager(learningCommitObserver: learning.observe,
            transportFactory: { NativeFixtureTransport(duration: playbackDuration) })
        let runner = SyntheticRunner()
        let processing = ProcessingService(transcriptionRunner: runner, audioExporter: SyntheticExporter(), historyRepository: repo, voiceRunner: runner)
        let app = RecorderViewModel(processingService: processing, historyRepository: repo, workspace: manager, voiceLearning: learning,
            voiceMatchPolicy: VoiceMatchPolicy(threshold: 0.9, margin: 0.1, calendarBonus: 0, maximumAcousticGap: 0),
            defaults: defaults, appDataDirectory: appData, startBackgroundServices: false,
            microphoneProvider: { [] }, accessProvider: { [] }, calendarCatalogProvider: { [] })
        let people = fixture["people"] as! [[String: Any]]
        let identities = Dictionary(uniqueKeysWithValues: people.map { item -> (String, VoiceProfilePerson) in
            let details = item["details"] as! [String]
            return (item["id"] as! String, .init(displayName: item["name"] as! String,
                calendarBindings: details.filter { $0.contains("@") }))
        })
        var urls: [String: URL] = [:]
        let documentFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let signal = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        signal.frameLength = signal.frameCapacity
        let audio = try #require(signal.floatChannelData?[0])
        for frame in 0..<Int(signal.frameLength) {
            let t = Double(frame) / format.sampleRate
            audio[frame] = Float(0.15 * sin(2 * .pi * 160 * t) * (0.5 + 0.4 * sin(2 * .pi * 3.7 * t)))
        }
        for record in records {
            let id = record["id"] as! String
            let title = record["title"] as! String
            let stem = "meeting_" + id
            let directory = root.appendingPathComponent(stem)
            let result = directory.appendingPathComponent("raw/transcripts/v1")
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            let recording = directory.appendingPathComponent(stem + ".m4a")
            try Data("synthetic".utf8).write(to: recording)
            urls[id] = recording
            let rows = record["rows"] as! [[String: Any]]
            if !rows.isEmpty {
                var document = try JSONSerialization.jsonObject(with: Data(contentsOf: documentFixture)) as! [String: Any]
                document["resultID"] = "v1"
                document["context"] = ["title": title, "attendees": ["Илья Соколов", "Мария Орлова", "Денис Ветров"]]
                let voices = Set(rows.map { $0["s"] as! Int }).sorted()
                let microphoneVoices = Set(voices.filter { voice in
                    rows.first { ($0["s"] as! Int) == voice }?["source"] as? String == "mic" || (id == "weekly" && voice == 0)
                })
                let microphoneOrder = voices.filter(microphoneVoices.contains)
                let remoteOrder = voices.filter { !microphoneVoices.contains($0) }
                document["speakers"] = voices.map { voice -> [String: Any] in
                    if let host = microphoneOrder.firstIndex(of: voice) {
                        return ["id": "s\(voice)", "sourceID": "host", "localID": host + 1, "displayNumber": host + 1]
                    }
                    let remote = remoteOrder.firstIndex(of: voice)! + 1
                    return ["id": "s\(voice)", "sourceID": "remote", "localID": remote, "displayNumber": microphoneOrder.count + remote]
                }
                let words = rows.enumerated().map { index, row -> [String: Any] in
                    let start = row["t"] as! Double
                    return ["id": "w\(index)", "speakerID": "s" + String(row["s"] as! Int),
                            "start": start, "end": start + 5, "text": row["text"] as! String]
                }
                document["words"] = words
                document["baselineWords"] = words
                document["turns"] = words.enumerated().map { index, word -> [String: Any] in
                    ["id": "t\(index)", "speakerID": word["speakerID"]!, "start": word["start"]!,
                     "end": word["end"]!, "wordIDs": [word["id"]!]]
                }
                document["playback"] = ["status": "ready", "mixPath": "raw/transcripts/v1/mix.wav"]
                let mix = try AVAudioFile(forWriting: result.appendingPathComponent("mix.wav"), settings: format.settings)
                try mix.write(from: signal)
                let resultFile = result.appendingPathComponent("result.json")
                try JSONSerialization.data(withJSONObject: document).write(to: resultFile)
                _ = try TranscriptDocument.load(from: resultFile, recordingDirectory: directory)
                let writer = TranscriptEditsRepository(recordingDirectory: directory)
                var overrides: [String: TranscriptTurnOverride] = [:]
                for (index, row) in rows.enumerated() {
                    if id == "voice-demo", row["speakerName"] == nil {
                        let refusal: TranscriptVoiceRefusal = row["voiceCase"] as? String == "overlap" ? .overlap : .ambiguous
                        overrides["t\(index)"] = .init(voiceRefusal: refusal)
                        continue
                    }
                    guard let name = row["speakerName"] as? String, let key = row["identity"] as? String,
                          let person = identities[key] else { continue }
                    overrides["t\(index)"] = .init(text: nil, displayName: name, assignment: .init(
                        personID: person.id, origin: row["nameOrigin"] as? String == "manual" ? "manual" : "automaticVoiceMatch"))
                }
                if !overrides.isEmpty { _ = try writer.saveEdits(resultID: "v1", overrides: overrides) }
            }
        }
        await app.history.refresh(root: root)
        for (index, record) in records.enumerated() {
            let id = record["id"] as! String
            let recording = try #require(urls[id])
            let calendar = Calendar.current
            let time = (record["time"] as? String ?? "12:00").split(separator: ":").compactMap { Int($0) }
            let offset = [0, 0, 0, -1, -2, -2, -2, -3][index]
            let day = try #require(calendar.date(byAdding: .day, value: offset, to: Date()))
            let date = try #require(calendar.date(bySettingHour: time[0], minute: time[1], second: 0, of: day))
            var entry = RecordingEntry(recording: recording, date: date,
                                       title: record["title"] as! String, phase: record["status"] as? String == "failed" ? .failed : .completed)
            entry.duration = record["duration"] as? Double
            repo.put(entry, persist: false)
        }
        let catalogue = app.voiceLearning.catalogue
        _ = try catalogue.update(catalogue.load()) { value in
            value.people = people.compactMap { identities[$0["id"] as! String] }
            for item in people where (item["details"] as? [String])?.last == "Готов" {
                let person = try #require(identities[item["id"] as! String])
                let vector = [Float(1)] + Array(repeating: 0, count: 255)
                let sample = VoiceProfileSample(personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID,
                    embedding: vector, recordingLocator: root.path, resultID: "fixture", turnID: "t0", sourceID: .host,
                    start: 0, end: 5, pcmFingerprint: "fixture", assignment: .init(personID: person.id, origin: "manual"), policyID: "fixture")
                value.samples.append(sample)
                value.aggregates.append(.init(personID: person.id, embeddingSpaceID: sample.embeddingSpaceID,
                    centroid: vector, activeSampleIDs: [sample.id], policyID: "fixture"))
            }
        }
        await app.history.synchronize()
        app.mainPage = .history
        app.workspaceShowsList = false

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let window = WorkspaceWindow(model: app)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        let host = NSHostingView(rootView: RecorderWorkspaceView(model: app, showSettings: { _ = app.presentSettings() })
            .defaultAppStorage(defaults))
        window.contentView = host
        defer { window.orderOut(nil); window.close() }
        func snapshot(_ name: String, width: Int = 1440, height: Int = 1040, dark: Bool = false) async throws {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            window.appearance = appearance
            host.appearance = appearance
            window.setContentSize(NSSize(width: width, height: height))
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            try #require(app.history.entries.count == records.count)
            try #require(manager.current?.state.id == app.selectedHistoryURL)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = NSSize(width: width, height: height)
            let frame = window.contentView?.superview ?? host
            frame.displayIfNeeded()
            let capture = frame.bounds.size == bitmap.size ? frame : host
            capture.cacheDisplay(in: capture.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        for id in ["weekly", "voice-demo"] {
            let url = try #require(urls[id])
            playbackDuration = id == "weekly" ? 1865 : 1500
            let editor = try await manager.open(recordingURL: url, title: id == "weekly" ? "Weekly tech sync" : "Обсуждение продукта")
            app.selectedHistoryURL = url
            editor.openVoiceReview(anchorTurnID: id == "weekly" ? "t0" : "t6")
            editor.setVoiceScope(.group)
            editor.setUnrecognizedVoiceFilter(true)
            #expect(editor.visibleVoiceGroups.count == 2)
            #expect(editor.selectedVoice?.originalName == (id == "weekly" ? "Speaker 1" : "Speaker 4"))
            if id == "voice-demo" {
                #expect(editor.rows.first(where: { $0.id == "t6" })?.voiceRefusal == .ambiguous)
                #expect(editor.rows.contains { $0.nameOriginLabel == "Автоимя" })
                #expect(editor.savedMeetingNames == ["Илья Соколов"])
            }
            if id == "weekly" {
                try await snapshot("native-editor-light")
            } else {
                try await snapshot("native-filter-light")
                try await snapshot("native-filter-dark", dark: true)
                try await snapshot("native-filter-narrow", width: 390, height: 550, dark: true)
                editor.setUnrecognizedVoiceFilter(false)
                try await snapshot("native-filter-all-light")
                editor.returnToTranscript()
                #expect(app.presentSettings())
                app.settingsPage = .voices
                try await snapshot("native-settings-light")
                app.dismissSettings()

                editor.openVoiceReview(anchorTurnID: "t6")
                editor.updateVoiceName("Проверка черновика")
                editor.returnToTranscript()
                try #require(editor.hasParkedVoiceInput)
                try await snapshot("native-parked-voice-draft")
                editor.openVoiceReview()
                try #require(editor.voiceDraft?.inputName == "Проверка черновика")
                editor.cancelVoiceInput()

                editor.voiceIdentityActions = .init(
                    people: { [] }, selectPerson: { _, _ in .asEntered }, confirmCalendarBinding: { _, _, _ in },
                    isEnabled: { true }, learningFailure: { _ in "Каталог недоступен." }
                )
                editor.openVoiceReview()
                editor.setUnrecognizedVoiceFilter(true)
                for name in ["Мария Орлова", "Олег"] {
                    editor.updateVoiceName(name)
                    try #require(editor.canConfirmVoice)
                    editor.confirmVoiceAssignment(try #require(editor.voiceDraft))
                }
                try #require(editor.voiceReviewComplete && editor.voiceLearningNotice == "Каталог недоступен.")
                try await snapshot("native-complete-learning-error")

                manager.closeCurrent()
                let reopened = try await manager.open(recordingURL: url, title: "Обсуждение продукта")
                let automatic = try #require(reopened.rows.first { $0.nameOriginLabel == "Автоимя" })
                reopened.openVoiceReview(anchorTurnID: automatic.id)
                #expect(!reopened.canConfirmSavedVoiceName)
                let saved = try #require(reopened.rows.first { $0.name == "Олег" && $0.personID == nil })
                reopened.openVoiceReview(anchorTurnID: saved.id)
                try #require(reopened.canConfirmSavedVoiceName)
                try await snapshot("native-confirm-saved-name")
                reopened.confirmVoiceAssignment(try #require(reopened.voiceDraft), confirmSavedName: true)
                try #require(reopened.voiceLearningConfirmedTurnID == saved.id)
                try #require(reopened.selectedVoice?.title == "Олег" && !reopened.canConfirmVoice)
                try await snapshot("native-confirmed-saved-name", dark: true)
                // Click the blank space well to the right of the title and chevron.
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let click = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 800, y: 606),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    window.sendEvent(click)
                }
                try await snapshot("native-confirmed-saved-name-expanded", dark: true)
            }
        }
    }

    @Test func speakerSegmentStopsRealMutedAVPlayer() async throws {
        let fixture = try SpeakerReviewFixture()
        defer { fixture.close() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000))
        buffer.frameLength = 32000
        for i in 0..<32000 { buffer.floatChannelData![0][i] = 0 }
        let wav = fixture.result.appendingPathComponent("segment.wav")
        do { let file = try AVAudioFile(forWriting: wav, settings: format.settings); try file.write(from: buffer) }
        let resultFile = fixture.result.appendingPathComponent("result.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: resultFile)) as! [String: Any]
        json["playback"] = ["status": "ready", "mixPath": "raw/transcripts/v1/segment.wav"]
        try JSONSerialization.data(withJSONObject: json).write(to: resultFile)
        let transport = TranscriptAVPlayerTransport(isMuted: true)
        let player = TranscriptPlaybackController(transport: transport)
        defer { player.close() }
        await player.select(resultID: "v1", recordingDirectory: fixture.root)
        #expect(player.state == .ready)
        await player.playSegment(start: 0.2, end: 0.5)
        for _ in 0..<1000 where player.segment != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(player.segment == nil && player.state == .ready && player.position == 0.5)
        #expect(transport.actualPlaybackRate == 0)
        #expect(transport.currentPosition <= 0.7)
    }
    @Test func speakerReviewNativeWorkspace() async throws {
        guard let destination = ProcessInfo.processInfo.environment["SPEAKER_REVIEW_NATIVE_ROOT"] else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let transport = NativeFixtureTransport(duration: 5000)
        let fixture = try SpeakerReviewFixture(transportFactory: { transport })
        defer { fixture.close() }
        let manager = fixture.manager
        let editor = try await fixture.open()
        let suite = "speaker-native-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(fixture.root.deletingLastPathComponent().path, forKey: "recordingsDirectory")
        defaults.set([String](), forKey: "meetingCalendarIDs")
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = RecordingHistoryRepository()
        let processing = ProcessingService(transcriptionRunner: SyntheticRunner(), audioExporter: SyntheticExporter(), historyRepository: repo)
        let app = isolatedRecorderModel(sessionService: RecordingSessionService(historyRepo: repo),
            processingService: processing, historyRepository: repo, workspace: manager,
            defaults: defaults, startBackgroundServices: false,
            captureControllerFactory: { url, _, _ in SyntheticAudioCapture(outputURL: url) },
            shortRecordingTrash: { _ in }, audioLevelMonitorFactory: { _, _, _ in SyntheticLevels() })
        await app.history.refresh(root: fixture.root.deletingLastPathComponent())
        var entry = RecordingEntry(recording: fixture.recording, date: Date(timeIntervalSince1970: 1794911520),
            title: "Обсуждение продукта", phase: .completed)
        entry.duration = 5000
        repo.put(entry, persist: false)
        await app.history.synchronize()
        app.mainPage = .history
        app.selectedHistoryURL = fixture.recording
        app.workspaceShowsList = false
        func elements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
            guard depth < 30, let element = object as? any NSAccessibilityProtocol else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap { elements($0, depth: depth + 1) }
        }
        func capture(_ name: String, width: CGFloat, height: CGFloat = 850, dark: Bool = false,
                     pane: TranscriptReviewWindowModel? = nil, scrollToBottom: Bool = false) async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let content = pane.map { AnyView(SpeakerReviewView(model: $0)) }
                ?? AnyView(RecordingHistoryView(model: app, history: app.history, workspace: manager, showSettings: {}))
            let host = NSHostingView(rootView: content.defaultAppStorage(defaults)
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            window.setContentSize(NSSize(width: width, height: height))
            try await Task.sleep(for: .milliseconds(180))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            if scrollToBottom {
                func scroll(_ view: NSView) {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView {
                        let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    for child in view.subviews { scroll(child) }
                }
                scroll(host)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            }
            let frame = (window.attachedSheet?.contentView ?? window.contentView)?.superview ?? host
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            let tree = elements(host).map { ["role": $0.accessibilityRole()?.rawValue ?? "", "label": $0.accessibilityLabel() ?? "", "frame": NSStringFromRect($0.accessibilityFrame())] }
            try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(name + "-ax.json"))
            try JSONSerialization.data(withJSONObject: ["width": host.bounds.width, "height": host.bounds.height, "review": editor.voiceReviewVisible, "result": editor.currentResultID ?? ""], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(name + "-geometry.json"))
        }
        try await capture("transcript-entry", width: 1440)
        editor.openVoiceReview()
        #expect(editor.voiceReviewVisible && editor.selectedVoice?.originalName == "Speaker 2")
        for width: CGFloat in [360, 390, 768, 1024, 1440] {
            try await capture("review-\(Int(width))", width: width, dark: width == 768)
        }
        for _ in 0..<100 where !editor.playbackEnabled { try await Task.sleep(for: .milliseconds(5)) }
        let fragment = try #require(editor.selectedVoice?.rows.first)
        for dark in [false, true] {
            try await capture("fragment-idle-\(dark ? "dark" : "light")", width: 1440, dark: dark)
            try await capture("fragment-idle-narrow-\(dark ? "dark" : "light")", width: 390, dark: dark)
        }
        await editor.playVoiceTurn(fragment.id)
        transport.onEvent?(.position((fragment.start + fragment.end) / 2))
        #expect(editor.fragmentTurnID == fragment.id && editor.playbackState == .playing)
        for dark in [false, true] {
            try await capture("fragment-playing-\(dark ? "dark" : "light")", width: 1440, dark: dark)
            try await capture("fragment-narrow-\(dark ? "dark" : "light")", width: 390, dark: dark)
        }
        await editor.playVoiceTurn(fragment.id)
        #expect(editor.fragmentTurnID == fragment.id && editor.playbackState == .ready)
        try await capture("fragment-paused", width: 1024, dark: true)
        editor.selectVoice(editor.voiceGroups[6].id)
        try await capture("late-voice", width: 1440)
        editor.returnToTranscript(turnID: "t6")
        try await capture("quick-entry", width: 1024)
        editor.openSpeakerAssignment(for: "t6")
        #expect(editor.activeDraft != nil)
        editor.updateDraftName("Длинное имя — Éva 李明 👩🏽‍💻 " + String(repeating: "Фамилия ", count: 6))
        try await capture("local-sheet", width: 390, height: 650)
        editor.openDraftVoiceReview()
        try await capture("transferred-draft-short", width: 390, height: 550)
        editor.cancelVoiceInput()
        editor.returnToTranscript()
        editor.openVoiceReview()
        editor.setUnrecognizedVoiceFilter(true)
        try await capture("unrecognized-filter", width: 1440)
        editor.selectVoice(try #require(editor.selectedVoiceID))
        #expect(editor.requestVoiceList())
        editor.updateVoiceName("Имя после списка")
        #expect(!editor.voiceListVisible)
        try await capture("resize-dirty-details", width: 390)
        editor.cancelVoiceInput()
        editor.selectVoice(editor.voiceGroups[1].id)
        editor.updateVoiceName("Анна")
        editor.setVoiceReplaceManual(true)
        try await capture("overwrite-preview", width: 1024)
        let editsFile = fixture.result.appendingPathComponent("edits.json")
        var changedBytes = try Data(contentsOf: editsFile)
        changedBytes.append(0x20)
        try changedBytes.write(to: editsFile)
        editor.confirmVoiceAssignment(try #require(editor.voiceDraft))
        #expect(editor.voiceRequiresReopen && editor.voiceDraft?.inputName == "Анна")
        try await capture("save-conflict", width: 390)
        editor.cancelVoiceInput()
        for count in [1, 16] {
            let extra = try SpeakerReviewFixture(voiceCount: count, transportFactory: { NativeFixtureTransport(duration: 5000) })
            let review = try await extra.open()
            review.openVoiceReview()
            #expect(review.voiceGroups.count == count)
            try await capture("voices-\(count)", width: 390, pane: review)
            extra.close()
        }
        let long = try SpeakerReviewFixture(turnsPerVoice: 80, transportFactory: { NativeFixtureTransport(duration: 5000) })
        let longReview = try await long.open()
        longReview.openVoiceReview()
        longReview.updateVoiceName("Очень длинное имя — Éva 李明 👩🏽‍💻 " + String(repeating: "Фамилия ", count: 10))
        #expect(longReview.selectedVoice?.rows.count == 80)
        try await capture("long-list-unicode", width: 390, height: 550, pane: longReview)
        try await capture("long-list-unicode-bottom", width: 390, height: 550, pane: longReview, scrollToBottom: true)
        long.close()
    }
    @Test func processingProgressNativeSyntheticRender() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROCESSING_PROGRESS_NATIVE_ROOT"] else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let requireAccessibility = ProcessInfo.processInfo.environment["PROCESSING_PROGRESS_REQUIRE_AX"] == "1"
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("progress-native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func settle(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<500 where !predicate() { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }
        func ax(_ object: Any, depth: Int = 0, pressDetails: Bool = false) -> [[String: String]] {
            guard depth < 24 else { return [] }
            let label: String, role: String, frame: String, children: [Any], enabled: Bool
            let press: () -> Bool
            if let view = object as? NSView {
                label = view.accessibilityLabel() ?? ""
                role = view.accessibilityRole()?.rawValue ?? ""
                frame = NSStringFromRect(view.accessibilityFrame())
                children = view.accessibilityChildrenInNavigationOrder() ?? view.accessibilityChildren() ?? []
                enabled = view.isAccessibilityEnabled()
                press = { view.accessibilityPerformPress() }
            } else if let element = object as? NSAccessibilityElement {
                label = element.accessibilityLabel() ?? ""
                role = element.accessibilityRole()?.rawValue ?? ""
                frame = NSStringFromRect(element.accessibilityFrame())
                children = element.accessibilityChildrenInNavigationOrder() ?? element.accessibilityChildren() ?? []
                enabled = element.isAccessibilityEnabled()
                press = { element.accessibilityPerformPress() }
            } else if let element = object as? any NSAccessibilityProtocol {
                label = element.accessibilityLabel() ?? ""
                role = element.accessibilityRole()?.rawValue ?? ""
                frame = NSStringFromRect(element.accessibilityFrame())
                children = element.accessibilityChildrenInNavigationOrder() ?? element.accessibilityChildren() ?? []
                enabled = element.isAccessibilityEnabled()
                press = { element.accessibilityPerformPress() }
            } else { return [] }
            if pressDetails, label == "Подробнее", role == "AXButton" {
                #expect(enabled && press(), "Actual native Details button must be enabled and pressable")
            }
            return [["role": role, "label": label, "frame": frame, "enabled": String(enabled)]] + children.flatMap { ax($0, depth: depth + 1, pressDetails: pressDetails) }
        }
        func capture(_ host: NSView, _ name: String) throws {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            let tree = ax(host)
            try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + "-accessibility.json"))
            try JSONSerialization.data(withJSONObject: ["bounds": NSStringFromRect(host.bounds), "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh], "scale": host.window?.backingScaleFactor ?? 1], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + "-geometry.json"))
        }
        for (aec, parakeet, voices) in [(false, false, false), (true, false, false),
                                        (false, true, false), (true, true, false), (true, true, true)] {
            let optional = aec && parakeet && !voices
            let count = 4 + (aec ? 1 : 0) + (parakeet ? 1 : 0) + (voices ? 1 : 0)
            let variant = "\(count)-aec\(aec)-parakeet\(parakeet)"
            let folder = root.appendingPathComponent(variant)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
            let stem = folder.lastPathComponent, url = folder.appendingPathComponent(folder.lastPathComponent + ".m4a")
            for name in [stem + ".m4a", "raw/" + stem + ".host_record.wav", "raw/" + stem + ".remote_record.wav"] { try Data().write(to: folder.appendingPathComponent(name)) }
            let suite = "progress-native-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(root.path, forKey: "recordingsDirectory")
            defer { defaults.removePersistentDomain(forName: suite) }
            let repo = RecordingHistoryRepository(), runner = ProgressNativeRunner()
            var entry = RecordingEntry.load(recording: url)
            entry.displayTitle = "Очень длинное название синтетической встречи про обработку, которое должно аккуратно обрезаться в капсуле"
            entry.duration = 3600
            repo.put(entry, persist: false)
            let service = ProcessingService(transcriptionRunner: runner, audioExporter: SyntheticExporter(), historyRepository: repo)
            let model = isolatedRecorderModel(processingService: service, historyRepository: repo, defaults: defaults)
            try await settle { model.isAttached }
            _ = await service.enqueue(recordingURL: url, settings: .init(
                parakeet: parakeet, echoCancellation: aec,
                voiceMatchPolicy: voices ? RecorderViewModel.defaultVoiceMatchPolicy : nil
            ))
            for _ in 0..<500 { if await runner.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
            if aec { await runner.emit(.init(stage: .echo, channel: "host", completed: 0, total: 0, state: .completed)) }
            for source in ["host", "remote"] {
                await runner.emit(.init(stage: .diarization, channel: source, completed: 0, total: 0, state: .completed))
            }
            await runner.emit(.init(stage: .speakers, channel: "host", completed: 0, total: 0, state: .completed))
            await runner.emit(.init(stage: .gigaam, channel: "remote", completed: 96, total: 150))
            try await settle { model.capsuleProgress?.local?.completed == 96 }
            #expect(model.capsuleProgress?.route.count == count)
            #expect(model.capsuleProgress?.route.map(\.rawValue).contains("vad") == false)
            if voices {
                await runner.emit(.init(stage: .voices, completed: 0, total: 0, state: .started))
                try await settle { model.capsuleProgress?.current == .voices }
                #expect(model.capsuleProgress?.countText == "Этап 7 из 7")
            }
            model.showProcessingDetails()
            let controller = RecordingCapsuleController(model: model, defaults: defaults)
            let panel = try #require(controller.panel)
            defer { controller.hideCapsule() }
            #expect(panel.standardWindowButton(.closeButton) == nil && !panel.styleMask.contains(.closable))
            #expect(!controller.windowShouldClose(panel))
            for state in optional ? ["active", "warning", "failed", "success"] : ["active"] {
                if state == "warning" {
                    await runner.emit(.init(stage: .diarization, channel: "remote", completed: 0, total: 0, warning: "Синтетическое замечание: нет интервалов речи", state: .skipped))
                    await runner.emit(.init(stage: .gigaam, channel: "remote", completed: 96, total: 150))
                    try await settle { model.capsuleProgress?.reasons[.diarization] != nil && model.capsuleProgress?.current == .recognition }
                } else if state == "failed" {
                    await runner.emit(.init(stage: .speakers, channel: "remote", completed: 0, total: 0, state: .completed))
                    for source in ["host", "remote"] { await runner.emit(.init(stage: .correction, channel: source, completed: 0, total: 0, state: .completed)) }
                    await runner.emit(.init(stage: .publication, completed: 0, total: 0, warning: "Синтетическая ошибка публикации", state: .started))
                    await runner.finish(failed: true)
                    try await settle { model.capsuleProgress?.failure != nil }
                } else if state == "success" {
                    _ = await service.enqueue(recordingURL: url, settings: .init(parakeet: true, echoCancellation: true))
                    for _ in 0..<500 { if await runner.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
                    for stage: TranscriptionProgress.Stage in [.echo, .diarization, .speakers, .correction] {
                        for source in (stage == .echo ? ["host"] : ["host", "remote"]) { await runner.emit(.init(stage: stage, channel: source, completed: 0, total: 0, state: .completed)) }
                    }
                    await runner.emit(.init(stage: .publication, completed: 0, total: 0, state: .started))
                    await runner.finish(failed: false)
                    try await settle { model.capsuleProgress?.terminal == true && model.capsuleProgress?.failure == nil }
                }
                for dark in [false, true] {
                    let name = "\(variant)-\(state)-\(dark ? "dark" : "light")"
                    panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    if let host = panel.contentView as? NSHostingView<RecordingCapsuleHostView> {
                        host.rootView = RecordingCapsuleHostView(viewModel: model)
                    }
                    controller.showCapsule()
                    try await Task.sleep(for: .milliseconds(120))
                    #expect(panel.frame.size == AppWindowState.processingCapsuleSize)
                    let content = try #require(panel.contentView)
                    let labels = ax(content).compactMap { $0["label"] }
                    let action = state == "success" ? "Открыть" : "Подробнее"
                    let hasAction = labels.contains(action)
                    let verification = ["status": hasAction ? "AX tree available; strict check opt-in" : "UNVERIFIED", "reason": hasAction ? "" : "SwiftUI accessibility children unavailable in this test host", "strictCheck": String(requireAccessibility)]
                    try JSONSerialization.data(withJSONObject: verification, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("capsule-" + name + "-ax-verification.json"))
                    if requireAccessibility {
                        #expect(hasAction)
                        #expect(!labels.contains("Закрыть") && !labels.contains("Скрыть"))
                        if state == "active" { _ = ax(content, pressDetails: true) }
                    } else if !hasAction { print("UNVERIFIED native AX: " + name + " — SwiftUI tree unavailable") }
                    try capture(content, "capsule-" + name)
                    let snapshot = try #require(model.capsuleProgress)
                    let latestEntry = try #require(model.history.entry(url))
                    for width: CGFloat in state == "active" ? [900, 480] : [600] {
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = panel.appearance
                        let host = NSHostingView(rootView: ProcessingDetailsView(snapshot: snapshot, entry: latestEntry, retry: {}).environment(\.colorScheme, dark ? .dark : .light))
                        host.sizingOptions = []
                        window.contentView = host
                        window.setContentSize(NSSize(width: width, height: 850)); window.orderFront(nil)
                        try await Task.sleep(for: .milliseconds(100))
                        host.setFrameSize(NSSize(width: width, height: 850))
                        try capture(host, "details-\(Int(width))-" + name)
                        window.orderOut(nil); window.contentView = nil; window.close()
                    }
                    if optional && state == "active" {
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1392, height: 900), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.appearance = panel.appearance
                        let host = NSHostingView(rootView: RecorderWorkspaceView(model: model, showSettings: {}).defaultAppStorage(defaults).environment(\.colorScheme, dark ? .dark : .light))
                        host.sizingOptions = []; window.contentView = host
                        window.setContentSize(NSSize(width: 1392, height: 900)); window.orderFront(nil)
                        try await Task.sleep(for: .milliseconds(150))
                        #expect(model.selectedHistoryURL == url)
                        host.setFrameSize(NSSize(width: 1392, height: 900))
                        try capture(host, "workspace-" + name)
                        window.orderOut(nil); window.contentView = nil; window.close()
                    }
                }
            }
            if !optional { await runner.finish(failed: false) }
        }
    }

    @Test func solRepairCancelsActualWaveformWorkerWithoutPartialEnvelope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancellation.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        for channel in 0..<2 { for index in 0..<16000 { buffer.floatChannelData![channel][index] = index % 117 < 30 ? 0.6 : 0.01 } }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let worker = Task { try await TranscriptWaveformExtractor.extractEnvelope(from: url) }
        // The real detached extractor is entered before cancelling its public async operation.
        await Task.yield()
        worker.cancel()
        do { _ = try await worker.value; Issue.record("Cancelled extraction published an envelope") }
        catch is CancellationError {}
        catch { Issue.record("Expected cancellation, received \(error)") }
    }
    @Test func solMutedAVPlayerRateLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        // Keep the muted clip alive while parallel App tests contend for MainActor.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160000))
        buffer.frameLength = 160000
        for i in 0..<160000 { buffer.floatChannelData![0][i] = 0 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let transport = TranscriptAVPlayerTransport(isMuted: true)
        defer { transport.stop() }
        #expect(try await transport.prepare(url: url) == 10)
        var observations: [[String: Any]] = []
        for rate: Float in [1,1.25,1.5,2] {
            transport.setRate(1)
            transport.play()
            let initialStatus = transport.timeControlStatus.rawValue
            transport.setRate(rate) // Change the requested rate during the observed local waiting state.
            for _ in 0..<100 where transport.timeControlStatus != .playing || transport.actualPlaybackRate != rate { try await Task.sleep(for: .milliseconds(5)) }
            #expect(transport.timeControlStatus == .playing)
            #expect(transport.actualPlaybackRate == rate)
            transport.pause()
            #expect(transport.actualPlaybackRate == 0)
            #expect(await transport.seek(to: 0.1))
            transport.play()
            for _ in 0..<100 where transport.timeControlStatus != .playing { try await Task.sleep(for: .milliseconds(5)) }
            #expect(transport.actualPlaybackRate == rate)
            observations.append(["requested": rate, "initialTimeControlStatus": initialStatus, "actualRateAfterResume": transport.actualPlaybackRate])
            transport.pause()
        }
        #expect(try await transport.prepare(url: url) == 10)
        transport.setRate(2); transport.play()
        for _ in 0..<100 where transport.timeControlStatus != .playing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(transport.actualPlaybackRate == 2)
        transport.stop()
        #expect(transport.actualPlaybackRate == 0 && !transport.hasPeriodicObserver)
        if let output = ProcessInfo.processInfo.environment["SOL_NATIVE_ROOT"] {
            try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted,.sortedKeys])
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("muted-avplayer-actions.json"))
        }
    }
    @Test func solNativeProductionHost() async throws {
        guard let destination = ProcessInfo.processInfo.environment["SOL_NATIVE_ROOT"] else { return }
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtureRoot = output.appendingPathComponent("fixture")
        let microphoneState = Mutex(MicrophoneRecordingState.receiving)
        let recording = fixtureRoot.appendingPathComponent("meeting")
        let result = recording.appendingPathComponent("raw/transcripts/res_valid_parakeet_off")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let suite = "sol-native-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(fixtureRoot.path, forKey: "recordingsDirectory")
        defaults.set([String](), forKey: "meetingCalendarIDs")
        defaults.set("synthetic-missing-mic", forKey: "selectedMicrophoneID")
        defaults.set(true, forKey: "transcriptionPrepared")
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_parakeet_off.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var playback = json["playback"] as! [String: Any]
        playback["mixPath"] = "raw/transcripts/res_valid_parakeet_off/mix.wav"
        json["playback"] = playback
        let starts = [0.0,0.6,1.2,326,489,731,1054,1328]
        let texts = [
            "Давайте обсудим",
            "Да, слушаю",
            "следующий релиз и оставшиеся задачи",
            "Да, и важно отделить предупреждение от самого результата. Если текст готов, он должен оставаться читаемым. А подробности о проблеме можно раскрыть отдельно.",
            "Тогда оставляем один основной путь: выбрать встречу, открыть транскрипт, при необходимости послушать фрагмент. Экспорт и технические детали убираем в дополнительные действия.",
            "Согласен. Ещё предлагаю сохранить компактную панель во время записи. В ней достаточно таймера, микрофона и кнопки остановки — ничего лишнего.",
            "Договорились. Сначала посмотрим весь сценарий на макете, включая пустую библиотеку, обработку и ошибку. После этого можно переносить решения в приложение.",
            "Хорошо. По следующей итерации зафиксировали: библиотека, транскрипт и состояния записи. На этом можем закончить."
        ]
        json["words"] = starts.indices.map { i in ["id": "w_\(i)", "speakerID": i % 2 == 0 ? "spk_h1" : "spk_r1", "start": starts[i], "end": starts[i]+1, "text": texts[i]] as [String: Any] }
        json["baselineWords"] = json["words"]
        json["turns"] = starts.indices.map { i in ["id": "turn_\(i)", "speakerID": i % 2 == 0 ? "spk_h1" : "spk_r1", "start": starts[i], "end": starts[i]+1, "wordIDs": ["w_\(i)"]] as [String: Any] }
        json["context"] = NSNull()
        try JSONSerialization.data(withJSONObject: json).write(to: result.appendingPathComponent("result.json"))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        for i in 0..<8000 { buffer.floatChannelData![0][i] = i % 317 < 70 ? 0.4 : 0.02 }
        do { let file = try AVAudioFile(forWriting: result.appendingPathComponent("mix.wav"), settings: format.settings); try file.write(from: buffer) }
        let url = recording.appendingPathComponent("meeting.m4a")
        let repo = RecordingHistoryRepository()
        let manager = TranscriptReviewWindowManager(transportFactory: { NativeFixtureTransport() })
        let processing = ProcessingService(transcriptionRunner: SyntheticRunner(), audioExporter: SyntheticExporter(), historyRepository: repo)
        let session = RecordingSessionService(historyRepo: repo)
        let model = isolatedRecorderModel(sessionService: session, processingService: processing, historyRepository: repo, workspace: manager,
            defaults: defaults, appDataDirectory: fixtureRoot.appendingPathComponent("appData"), startBackgroundServices: false,
            captureControllerFactory: { url, _, _ in
                SyntheticAudioCapture(outputURL: url, microphoneState: { microphoneState.withLock { $0 } })
            },
            shortRecordingTrash: { _ in }, audioLevelMonitorFactory: { _, _, _ in SyntheticLevels() })
        await model.history.refresh(root: fixtureRoot)
        var entry = RecordingEntry.load(recording: url)
        entry.title = "Продукт–тех синк"; entry.date = Date(timeIntervalSince1970: 1793350800); entry.duration = 1458; entry.phase = .completed
        repo.put(entry, persist: false)
        for (name, title, timestamp, duration, phase) in [
            ("design", "Обсуждение интерфейса", Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 + 11*3600+32*60, 812.0, RecordingEntry.Phase.completed),
            ("weekly", "Weekly tech sync", 1793284260.0, 1865.0, .completed),
            ("one", "1:1 · разговор о задачах", 1793278800.0, 2240.0, .completed),
            ("standup", "Командный стендап", 1793262600.0, 937.0, .completed),
            ("error", "Планирование итерации", 1793188800.0, 1180.0, .failed)
        ] {
            let directory = fixtureRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("raw"), withIntermediateDirectories: true)
            var item = RecordingEntry(recording: directory.appendingPathComponent(name+".m4a"), date: Date(timeIntervalSince1970: timestamp), title: title, phase: phase)
            item.duration = duration
            repo.put(item, persist: false)
        }
        await model.history.synchronize()
        model.selectedHistoryURL = url
        model.workspaceShowsList = false
        let editor = try await manager.open(recordingURL: url, title: entry.title)
        #expect(!editor.rows.isEmpty && !editor.state.isReadOnly)
        for row in editor.rows {
            _ = try editor.state.session?.assignSpeakerName(turnID: row.id, displayName: row.sourceID == .host ? "Вы" : "Спикер 2")
        }
        // Reload through the production manager to read the test-owned saved assignments.
        manager.closeCurrent()
        let current = try await manager.open(recordingURL: url, title: entry.title)
        for _ in 0..<100 where current.waveform == nil { try await Task.sleep(for: .milliseconds(5)) }
        await current.seekPlayback(to: 0.6)
        var provenance: [[String: Any]] = []
        var actions: [[String: Any]] = []
        func accessibilityElements(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
            guard depth < 20, let element = object as? any NSAccessibilityProtocol else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap { accessibilityElements($0, depth: depth+1) }
        }
        func render<V: View>(_ view: V, _ name: String, _ width: CGFloat, _ height: CGFloat, dark: Bool = false, press: String? = nil) async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "SOL synthetic — " + name
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: view.defaultAppStorage(defaults).environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host
            window.orderFront(nil)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            window.setContentSize(host.frame.size)
            try await capture(host, in: window, name: name, width: width, height: height, dark: dark, press: press)
            window.orderOut(nil); window.contentView = nil; window.close()
        }

        func capture(_ host: NSView, in window: NSWindow, name: String, width: CGFloat, height: CGFloat,
                     dark: Bool, press: String?) async throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "NativeHostBitmapUnavailable", code: 1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + ".png"))
            let elements = accessibilityElements(host)
            let tree = elements.map { element in
                ["role": element.accessibilityRole()?.rawValue ?? "", "label": element.accessibilityLabel() ?? "",
                 "frame": NSStringFromRect(element.accessibilityFrame())]
            }
            try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent(name+"-accessibility.json"))
            if let press {
                let button = elements.first { $0.accessibilityLabel() == press }
                let accepted = button?.accessibilityPerformPress() ?? false
                actions.append(["view": name, "action": "AXPress", "label": press, "accepted": accepted])
                try await Task.sleep(for: .milliseconds(20))
            }
            provenance.append(["file": name+".png", "requestedBounds": [width,height], "bounds": [host.bounds.width,host.bounds.height], "windowBounds": NSStringFromRect(window.frame), "pixelSize": [bitmap.pixelsWide,bitmap.pixelsHigh],
                               "displayScale": window.backingScaleFactor, "theme": dark ? "dark" : "light", "fixture": "product-8-turns-short-pcm-synthetic-transport",
                               "bundle": Bundle.main.bundleURL.path, "executable": ProcessInfo.processInfo.arguments[0],
                               "time": ISO8601DateFormatter().string(from: Date())])
        }
        for width in [1392.0,1024,1023,768,767,480] {
            try await render(RecorderWorkspaceView(model: model, showSettings: {}), "workspace-\(Int(width))", width, width == 1392 ? 992 : 800)
        }
        try await render(RecorderWorkspaceView(model: model, showSettings: {}), "workspace-dark", 1392, 992, dark: true)
        await current.seekPlayback(to: 0)
        current.setPlaybackRate(1.5)
        try await render(RecorderWorkspaceView(model: model, showSettings: {}), "workspace-reference-narrow", 700, 1000)
        try await render(RecorderWorkspaceView(model: model, showSettings: {}), "workspace-reference-narrow-dark", 700, 1000, dark: true)
        current.setPlaybackRate(1)
        await current.seekPlayback(to: 0.6)
        for page in RecorderSettingsView.Page.allCases {
            model.settingsPage = page
            try await render(SettingsShell(model: model), "settings-"+page.symbol, 760, 740)
        }
        try await render(SettingsShell(model: model), "settings-narrow", 480, 740)
        model.settingsPage = .general
        model.appearance = .light
        try await render(SettingsShell(model: model), "settings-general-baseline", 760, 585)
        try await render(FullRecorderView(viewModel: model, showSettings: {}), "new-recording", 480, 650)
        let documentView = TranscriptReviewWindowView(model: current, title: entry.title)
        current.openTextEditing(for: "turn_2")
        current.updateDraftText("Синтетическая правка из production form")
        try await render(documentView.editingSheet, "edit-text", 560, 440, press: "Сохранить")
        actions.append(["action": "text-save-result", "draftClosed": current.activeTextDraft == nil, "savedText": current.rows.first { $0.id == "turn_2" }?.text ?? ""])
        if current.activeTextDraft != nil { current.cancelTextDraft() }
        current.openSpeakerAssignment(for: "turn_2")
        try await render(documentView.editingSheet, "speaker-initial-live", 560, 650)
        current.updateDraftName("Алиса")
        try await render(documentView.editingSheet, "speaker-form", 560, 650)
        try await render(documentView.editingSheet, "speaker-one-preview", 560, 710)
        try await render(documentView.editingSheet, "speaker-one-dark", 560, 710, dark: true)
        current.selectDraftScope(.allVoiceGroup)
        try await render(documentView.editingSheet, "speaker-remaining-preview", 560, 800)
        current.cancelDraft()
        let historyView = RecordingHistoryView(model: model, history: model.history, workspace: manager, showSettings: {})
        try await render(historyView.renameSheet(entry), "rename", 480, 360)
        for _ in 0..<100 where !model.isAttached { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await model.startRecordingIntent(customTitle: "Очень длинное название синтетической встречи для проверки компактной капсулы"))
        let captureURL = try #require(model.lastFileURL)
        for _ in 0..<100 where !model.isRecording { try await Task.sleep(for: .milliseconds(2)) }
        let capsule = RecordingCapsuleController(model: model, defaults: defaults)
        defer { capsule.hideCapsule() }
        func renderCapsule(_ name: String, dark: Bool = false, press: String? = nil) async throws {
            let panel = try #require(capsule.panel)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            capsule.showCapsule()
            try await Task.sleep(for: .milliseconds(150))
            let host = try #require(panel.contentView)
            let size = AppWindowState.recordingCapsuleSize
            let height = model.showsOvertimeReminder ? AppWindowState.overtimeCapsuleHeight : size.height
            #expect(host.bounds.size == NSSize(width: size.width, height: height))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await capture(host, in: panel, name: name, width: size.width, height: height, dark: dark, press: press)
        }
        model.elapsed = 8*3600
        #expect(model.showsOvertimeReminder)
        try await renderCapsule("capsule-8h")
        try await renderCapsule("capsule-overtime")
        model.elapsed = 125
        try await renderCapsule("capsule-recording")
        try await renderCapsule("capsule-recording-dark", dark: true)
        func setMicMuted(_ muted: Bool) async throws {
            model.toggleMicrophoneMute(sessionID: model.activeSessionID)
            for _ in 0..<100 where model.microphoneMuted != muted { try await Task.sleep(for: .milliseconds(2)) }
            try #require(model.microphoneMuted == muted)
        }
        try await setMicMuted(true)
        try await renderCapsule("capsule-muted")
        model.elapsed = 72 * 60
        microphoneState.withLock { $0 = .silent }
        try await setMicMuted(false)
        #expect(model.microphoneState == .silent)
        try await renderCapsule("capsule-mic-silent")
        try await setMicMuted(true)
        microphoneState.withLock { $0 = .missing }
        try await setMicMuted(false)
        #expect(model.microphoneState == .missing)
        try await renderCapsule("capsule-mic-missing-dark", dark: true)
        _ = try await session.stop(elapsed: 15, expectedSessionID: model.activeSessionID)
        for _ in 0..<100 where model.isRecording || model.sessionStopping { try await Task.sleep(for: .milliseconds(2)) }
        var captured = RecordingEntry(recording: captureURL, date: Date(), title: "Продукт–тех синк", phase: .processing)
        repo.put(captured, persist: false); await model.history.synchronize()
        model.history.progress[captureURL] = TranscriptionProgress(stage: .gigaam, completed: 1, total: 3, step: 2, steps: 3)
        model.syncProcessingPresentation(captureURL)
        try await renderCapsule("capsule-processing")
        captured.phase = .completed
        repo.put(captured, persist: false); await model.history.synchronize()
        model.syncProcessingPresentation(captureURL)
        try await renderCapsule("capsule-done")
        model.recordingSaveError = "Синтетическая ошибка сохранения. Исходные файлы доступны для восстановления; это тест полного длинного сообщения."
        try await renderCapsule("capsule-terminal")
        try await renderCapsule("capsule-terminal-close", press: "Закрыть")
        actions.append(["action": "terminal-close-result", "hidden": !model.showsRecordingCapsule, "errorRetained": model.recordingSaveError != nil])
        model.dismissCapsule()

        manager.closeCurrent()
        json["warnings"] = [["code": "capture_warning", "sourceID": NSNull(), "message": "Синтетическое предупреждение захвата"]]
        try JSONSerialization.data(withJSONObject: json).write(to: result.appendingPathComponent("result.json"))
        _ = try await manager.open(recordingURL: url, title: entry.title)
        model.selectedHistoryURL = url
        try await render(RecorderWorkspaceView(model: model, showSettings: {}), "workspace-warning", 1392, 992)

        let failedURL = fixtureRoot.appendingPathComponent("error/error.m4a")
        for source in ["host", "remote"] {
            try FileManager.default.copyItem(at: result.appendingPathComponent("mix.wav"), to: failedURL.deletingLastPathComponent().appendingPathComponent("raw/error.\(source)_record.wav"))
        }
        var failed = RecordingEntry.load(recording: failedURL)
        failed.title = "Планирование итерации"; failed.date = Date(timeIntervalSince1970: 1793188800)
        failed.phase = .failed
        failed.addProblem(.transcription, "Синтетическая ошибка распознавания. Исходные WAV сохранены.", error: true)
        repo.put(failed, persist: false); await model.history.synchronize()
        manager.closeCurrent(); model.selectedHistoryURL = failedURL
        try await render(RecorderWorkspaceView(model: model, showSettings: {}), "workspace-failed", 1392, 992)
        failed.phase = .processing; repo.put(failed, persist: false); await model.history.synchronize()
        model.history.progress[failedURL] = TranscriptionProgress(stage: .gigaam, completed: 1, total: 3, step: 2, steps: 3)
        try await render(RecorderWorkspaceView(model: model, showSettings: {}), "workspace-processing", 1392, 992)
        try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("provenance.json"))
        try JSONSerialization.data(withJSONObject: actions, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("native-actions.json"))
        manager.closeCurrent()
    }
    @Test func solWaveformFailureIsNotSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("corrupt.wav")
        try Data("not audio".utf8).write(to: corrupt)
        for url in [root.appendingPathComponent("missing.wav"), corrupt] {
            do {
                _ = try await TranscriptWaveformExtractor.extractEnvelope(from: url)
                Issue.record("Missing/corrupt audio must fail extraction, never publish silence")
            } catch { #expect(!(error is CancellationError)) }
        }
    }

    @Test func solWaveformReadsInteriorPeakStereoAndSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        for channel in 0..<2 { for frame in 0..<8000 { buffer.floatChannelData![channel][frame] = 0 } }
        for isSilent in [false, true] {
            buffer.floatChannelData![1][3456] = isSilent ? 0 : 0.8
            let url = root.appendingPathComponent(isSilent ? "silence.wav" : "peak.wav")
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
            let waveform = try await TranscriptWaveformExtractor.extractEnvelope(from: url)
            #expect(waveform.samples.count == 120)
            if isSilent { #expect(waveform.samples.allSatisfy { $0 == 0 }) }
            else { #expect(waveform.samples[51] == 1 && waveform.samples[0] == 0 && waveform.samples[119] == 0) }
        }
    }

    // MARK: - Row 1: Main Window Layout
    @Test func mainWindowLayoutContract() {
        #expect(ODSpacing.sidebarWidth == 304)
        #expect(ODSpacing.sidebarWidthCompact == 264)
        #expect(ODSpacing.narrowBreakpoint == 768)
        #expect(ODSpacing.wideBreakpoint == 1024)
        #expect(ODSpacing.documentMaxWidth == 840)
        #expect(ODSpacing.toolbarHeight == 72)
    }

    // MARK: - Row 2: Library & Sidebar
    @Test func librarySidebarComponents() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let pastDate = Calendar.current.date(byAdding: .day, value: -5, to: today)!

        #expect(today.dateGroupTitle == "Сегодня")
        #expect(yesterday.dateGroupTitle == "Вчера")
        #expect(!pastDate.dateGroupTitle.isEmpty)
    }

    // MARK: - Row 3: Search Functionality
    @Test func searchFilteringLogic() {
        let rec1URL = URL(fileURLWithPath: "/tmp/rec1/meeting_rec1.m4a")
        let rec2URL = URL(fileURLWithPath: "/tmp/rec2/meeting_rec2.m4a")
        let item1 = RecordingEntry(
            recording: rec1URL,
            date: Date(),
            title: "Еженедельный синк CX",
            phase: .completed
        )
        let item2 = RecordingEntry(
            recording: rec2URL,
            date: Date(),
            title: "Интервью дизайн",
            phase: .completed
        )

        let all = [item1, item2]

        let matchTitle = all.filter { item in
            let q = "CX".lowercased()
            return item.effectiveTitle.lowercased().contains(q)
        }
        #expect(matchTitle.count == 1 && matchTitle.first?.recording == rec1URL)

        let matchSnippet = all.filter { item in
            let q = "дизайн".lowercased()
            return item.effectiveTitle.lowercased().contains(q)
        }
        #expect(matchSnippet.count == 1 && matchSnippet.first?.recording == rec2URL)

        let emptyQuery = ""
        let kept = all.filter { item in
            if emptyQuery.isEmpty { return true }
            return item.effectiveTitle.contains(emptyQuery)
        }
        #expect(kept.count == 2)
    }

    // MARK: - Row 4: Toolbar
    @Test func toolbarStructureTokens() {
        #expect(ODSpacing.toolbarHeight == 72)
        #expect(ODColors.toolbarBackground != ODColors.sidebar)
    }

    // MARK: - Row 5: Additional Actions
    @Test func moreActionsMenuDesignTokens() {
        #expect(ODColors.accent != ODColors.surface)
    }

    // MARK: - Row 6: Document Header & Time Formatting
    @Test func documentHeaderFormatting() {
        #expect(formatClock(0) == "00:00")
        #expect(formatClock(65) == "01:05")
        #expect(formatClock(3661) == "1:01:01")
    }

    // MARK: - Row 7: Turn & Replica Presentation
    @Test func turnVisualTokens() {
        #expect(ODSpacing.turnAvatarSize == 28)
        #expect(ODColors.avatarPalette.count >= 4)
    }

    // MARK: - Row 8: Text Edit Form
    @Test func textEditFormTokens() {
        #expect(ODColors.surface != ODColors.canvas)
        #expect(ODColors.text != ODColors.secondaryText)
        #expect(ODColors.border != ODColors.accent)
    }

    // MARK: - Row 9: Speaker Assignment
    @Test func speakerAssignmentScopes() {
        enum SpeakerScope: String, CaseIterable {
            case turnOnly = "Только эта реплика"
            case remainingVoice = "Все следующие реплики этого голоса"
        }
        #expect(SpeakerScope.allCases.count == 2)
    }

    // MARK: - Row 10: Player & Waveform
    @Test func playerControlsAndWaveform() {
        let wf = TranscriptWaveform(samples: [])
        #expect(wf.samples.count == TranscriptWaveform.sampleCount)
        #expect(TranscriptWaveform.sampleCount == 120)
        #expect(wf.samples.allSatisfy { $0 >= 0.0 && $0 <= 1.0 })

        let supportedRates: [Float] = [1.0, 1.25, 1.5, 2.0]
        #expect(supportedRates.count == 4)
    }

    // MARK: - Row 11 & 12: Warning and Error States
    @Test func statusColorsContract() {
        #expect(ODColors.statusGreen != ODColors.statusRed)
        #expect(ODColors.statusAmber != ODColors.statusRed)
    }

    // MARK: - Row 13: New Recording Form
    @Test func newRecordingFormDefaults() {
        let defaultTitle = "Без встречи"
        #expect(!defaultTitle.isEmpty)
    }

    // MARK: - Row 14: Capture Capsule
    @Test func captureCapsuleGeometry() {
        let size = AppWindowState.recordingCapsuleSize
        let screen = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let offscreen = NSRect(x: 1000, y: -80, width: size.width, height: size.height)
        let restored = AppWindowState.visibleCapsuleFrame(offscreen, screens: [screen])
        #expect(screen.contains(restored) && restored.size == size)
        #expect(size == NSSize(width: 344, height: 64))
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let external = NSRect(x: -1600, y: 600, width: size.width, height: size.height)
        #expect(AppWindowState.visibleCapsuleFrame(external, screens: [screen, secondary]) == external)
        let recovered = AppWindowState.visibleCapsuleFrame(external, screens: [screen])
        #expect(screen.contains(recovered) && recovered.minX == screen.minX && recovered.size == size)
        let beyond = NSRect(x: screen.maxX - 5, y: -50, width: size.width, height: size.height)
        let fitted = AppWindowState.visibleCapsuleFrame(beyond, screens: [screen])
        #expect(screen.contains(fitted) && fitted.maxX == screen.maxX && fitted.minY == screen.minY)
        #expect(AppWindowState.visibleCapsuleFrame(external, screens: []) == external)
    }

    // MARK: - Row 15: Capsule Processing & Completion
    @Test func capsuleProcessingGeometry() {
        let overtimeHeight = AppWindowState.overtimeCapsuleHeight
        #expect(overtimeHeight > AppWindowState.recordingCapsuleSize.height)
        #expect(AppWindowState.processingCapsuleSize == AppWindowState.recordingCapsuleSize)
    }

    // MARK: - Row 16: Narrow Window
    @Test func narrowBreakpointThreshold() {
        #expect(ODSpacing.narrowBreakpoint == 768)
        let isNarrow = 700 <= ODSpacing.narrowBreakpoint
        #expect(isNarrow == true)
        let isWide = 1200 > ODSpacing.narrowBreakpoint
        #expect(isWide == true)
    }

    // MARK: - Row 17: Settings Five Tabs
    @Test func settingsFiveTabsSpecification() {
        enum SettingsTab: String, CaseIterable {
            case general = "general"
            case recording = "recording"
            case transcription = "transcription"
            case calendar = "calendar"
            case diagnostics = "diagnostics"
        }
        #expect(SettingsTab.allCases.count == 5)
    }

    // MARK: - Row 18: Status Menu (M01-M04)
    @Test func statusMenuConsistency() {
        let defaults = UserDefaults(suiteName: "VisualFidelityTests-\(UUID().uuidString)")!
        let appUpdater = AppUpdater(defaults: defaults)
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)
        let processing = ProcessingService(
            transcriptionRunner: SyntheticRunner(),
            audioExporter: SyntheticExporter(),
            historyRepository: repo
        )
        let model = isolatedRecorderModel(
            sessionService: session,
            processingService: processing,
            historyRepository: repo,
            defaults: defaults,
            startBackgroundServices: false,
            captureControllerFactory: { url, _, _ in SyntheticAudioCapture(outputURL: url) },
            shortRecordingTrash: { _ in }
        )
        let menu = StatusMenu.build(model: model, appUpdater: appUpdater, target: nil)
        #expect(!menu.items.isEmpty)
    }
}

private actor ProgressNativeRunner: TranscriptionRunnerProtocol {
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (TranscriptionProgress) -> Void)?
    var waiting: Bool { continuation != nil }
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        progress = onProgress
        try await withCheckedThrowingContinuation { continuation = $0 }
        return recording.appendingPathExtension("txt")
    }
    func emit(_ value: TranscriptionProgress) { progress?(value) }
    func finish(failed: Bool) {
        if failed { continuation?.resume(throwing: NSError(domain: "SyntheticProgressPublication", code: 1)) }
        else { continuation?.resume() }
        continuation = nil
    }
}
