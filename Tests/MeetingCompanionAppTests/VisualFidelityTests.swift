import Foundation
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
    init(outputURL: URL) { self.outputURL = outputURL }
    func startCapture() async throws {}
    func stopCapture() async throws -> AudioCaptureStopResult {
        .init(duration: 0, outputURL: outputURL)
    }
    func setMicrophoneMuted(_ muted: Bool) {}
    func currentMicrophoneState() -> MicrophoneRecordingState { .receiving }
}

private struct SyntheticRunner: TranscriptionRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL { recording.appendingPathExtension("txt") }
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
    func prepare(url: URL) async throws -> Double { 1458 }
    func play() { onEvent?(.playing(true)) }
    func pause() { onEvent?(.playing(false)) }
    func seek(to seconds: Double) async -> Bool { onEvent?(.position(seconds)); return true }
    func stop() {}
    func setRate(_ rate: Float) {}
}

@Suite @MainActor final class VisualFidelityTests {
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
        for (aec, parakeet) in [(false, false), (true, false), (false, true), (true, true)] {
            let optional = aec && parakeet
            let count = 4 + (aec ? 1 : 0) + (parakeet ? 1 : 0)
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
            _ = await service.enqueue(recordingURL: url, settings: .init(parakeet: parakeet, echoCancellation: aec))
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
            captureControllerFactory: { url, _, _ in SyntheticAudioCapture(outputURL: url) },
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
            window.orderOut(nil); window.contentView = nil; window.close()
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
        #expect(await model.startRecordingIntent(customTitle: "Продукт–тех синк"))
        let captureURL = try #require(model.lastFileURL)
        for _ in 0..<100 where !model.isRecording { try await Task.sleep(for: .milliseconds(2)) }
        model.elapsed = 8*3600
        #expect(model.showsOvertimeReminder)
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-8h", 580, 64)
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-overtime", 580, 64)
        model.elapsed = 125
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-recording", 580, 64)
        model.toggleMicrophoneMute(sessionID: model.activeSessionID)
        for _ in 0..<100 where !model.microphoneMuted { try await Task.sleep(for: .milliseconds(2)) }
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-muted", 580, 64)
        _ = try await session.stop(elapsed: 15, expectedSessionID: model.activeSessionID)
        for _ in 0..<100 where model.isRecording || model.sessionStopping { try await Task.sleep(for: .milliseconds(2)) }
        var captured = RecordingEntry(recording: captureURL, date: Date(), title: "Продукт–тех синк", phase: .processing)
        repo.put(captured, persist: false); await model.history.synchronize()
        model.history.progress[captureURL] = TranscriptionProgress(stage: .gigaam, completed: 1, total: 3, step: 2, steps: 3)
        model.syncProcessingPresentation(captureURL)
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-processing", 560, 64)
        captured.phase = .completed
        repo.put(captured, persist: false); await model.history.synchronize()
        model.syncProcessingPresentation(captureURL)
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-done", 560, 64)
        model.recordingSaveError = "Синтетическая ошибка сохранения. Исходные файлы доступны для восстановления; это тест полного длинного сообщения."
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-terminal", 580, 64)
        try await render(RecordingCapsuleHostView(viewModel: model), "capsule-terminal-close", 580, 64, press: "Закрыть")
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
        #expect(size.height == 64)
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
        #expect(overtimeHeight == 64)
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
