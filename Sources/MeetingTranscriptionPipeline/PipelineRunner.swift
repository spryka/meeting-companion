import Foundation
import AVFoundation
import CryptoKit
import Darwin
import MLX
import MLXNN
import GigaAMKit
import Nemotron
import PipelineSilero
import MLXAudioSTT
import MeetingCompanionCore

public struct PipelineResult: Sendable {
    public let document: TranscriptDocument
    public let suggestions: [Suggestion]
    public let hostAudioURL: URL
    public let remoteAudioURL: URL?
    public let audioMixURL: URL?
    public let aecAudioURL: URL?
    public let correctionJournalData: Data?

    public init(
        document: TranscriptDocument,
        suggestions: [Suggestion],
        hostAudioURL: URL,
        remoteAudioURL: URL?,
        audioMixURL: URL? = nil,
        aecAudioURL: URL? = nil,
        correctionJournalData: Data? = nil
    ) {
        self.document = document
        self.suggestions = suggestions
        self.hostAudioURL = hostAudioURL
        self.remoteAudioURL = remoteAudioURL
        self.audioMixURL = audioMixURL
        self.aecAudioURL = aecAudioURL
        self.correctionJournalData = correctionJournalData
    }
}

public final class PipelineRunner: @unchecked Sendable {
    public let modelRoot: URL
    public let parakeetEnabled: Bool
    public let echoCancelEnabled: Bool

    public init(
        modelRoot: URL,
        parakeetEnabled: Bool = false,
        echoCancelEnabled: Bool = false
    ) {
        self.modelRoot = modelRoot.resolvingSymlinksInPath()
        self.parakeetEnabled = parakeetEnabled
        self.echoCancelEnabled = echoCancelEnabled
    }

    struct ChannelAudio {
        let id: TranscriptDocument.SourceID
        let originalURL: URL
        var recognitionURL: URL
        let originalRelPath: String
        var recognitionRelPath: String
        let sha256: String
        let frameCount: Int
        let duration: Double
        var windowMask: [Bool] = []
        var diarizationStatus: TranscriptDocument.ProcessingStatus = .disabled
        var detectedVoiceCount: Int? = nil
        var intervals: [DiarizationInterval] = []
        var gigaamWords: [PipelineWord] = []
        var finalWords: [PipelineWord] = []
        var correctionStatus: TranscriptDocument.ProcessingStatus = .disabled
        var suggestions: [Suggestion] = []
        var warnings: [TranscriptDocument.Warning] = []
    }

    private func modelPath(_ sub: String) -> URL {
        modelRoot.appendingPathComponent(sub).resolvingSymlinksInPath()
    }

    private func checkCancellation(_ checkCancel: () throws -> Void) throws {
        try checkCancel()
    }

    private func loadAudioChunk(
        url: URL,
        range: Range<Int>
    ) throws -> [Float] {
        let reader = try PCMReader(url, block: max(1, range.count), limit: range.count)
        reader.file.framePosition = AVAudioFramePosition(range.lowerBound)
        return try reader.next() ?? []
    }

    public func run(
        sources: RecordingSources,
        resultID: String = "res_" + UUID().uuidString.prefix(8).lowercased(),
        checkCancel: @escaping () throws -> Void = {},
        onProgress: (@Sendable (PipelineProgressEvent) -> Void)? = nil
    ) throws -> PipelineResult {
        try checkCancellation(checkCancel)

        let recordingDirectory = sources.recordingDirectory
        let hostURL = sources.hostWAV
        let remoteURL = sources.remoteWAV

        var additionalWarnings: [TranscriptDocument.Warning] = []
        for w in sources.contextWarnings {
            additionalWarnings.append(TranscriptDocument.Warning(code: "context_warning", sourceID: nil, message: w))
            onProgress?(PipelineProgressEvent(stage: .warning, completed: 0, total: 1, warning: w))
        }

        // ----------------------------------------------------
        // Stage 0: Echo Cancellation (if requested)
        // ----------------------------------------------------
        let transcriptsDir = try TranscriptPublisher.validateContainment(of: recordingDirectory)
        let aecTempDir = transcriptsDir.appendingPathComponent(".staging-\(resultID)")
        try FileManager.default.createDirectory(at: aecTempDir, withIntermediateDirectories: true)
        let aecTargetURL = aecTempDir.appendingPathComponent("host_aec.wav")

        var aecAudioURL: URL? = nil
        let aecOutcome: TranscriptDocument.AECOutcome
        var recognitionHostURL = hostURL
        var recognitionHostRelPath = sources.hostRelPath

        if echoCancelEnabled {
            onProgress?(PipelineProgressEvent(stage: .echo, channel: "host", completed: 0, total: 1))
            let aecResult = EchoCanceller.process(
                host: hostURL,
                remote: remoteURL,
                destination: aecTargetURL,
                requested: true,
                onProgress: { done, total in
                    onProgress?(PipelineProgressEvent(stage: .echo, channel: "host", completed: done, total: total))
                }
            )
            aecOutcome = aecResult.outcome
            additionalWarnings.append(contentsOf: aecResult.warnings)
            for w in aecResult.warnings {
                onProgress?(PipelineProgressEvent(stage: .warning, channel: "host", completed: 0, total: 1, warning: w.message))
            }
            if aecResult.outcome == .applied {
                recognitionHostURL = aecResult.audioURL
                recognitionHostRelPath = "raw/transcripts/\(resultID)/host_aec.wav"
                aecAudioURL = aecResult.audioURL
            }
            onProgress?(PipelineProgressEvent(stage: .echo, channel: "host", completed: 1, total: 1))
        } else {
            aecOutcome = .disabled
        }

        var channels: [ChannelAudio] = []

        // Prepare Host
        let hostReader = try PCMReader(recognitionHostURL, block: 160_000)
        let hostCount = hostReader.count
        channels.append(ChannelAudio(
            id: .host,
            originalURL: hostURL,
            recognitionURL: recognitionHostURL,
            originalRelPath: sources.hostRelPath,
            recognitionRelPath: recognitionHostRelPath,
            sha256: try streamingSHA(hostURL),
            frameCount: hostCount,
            duration: Double(hostCount) / 16000.0,
            windowMask: PipelineLogic.windows(hostCount).map { _ in true }
        ))

        // Prepare Remote
        let remoteReader = try PCMReader(remoteURL, block: 160_000)
        let remoteCount = remoteReader.count
        channels.append(ChannelAudio(
            id: .remote,
            originalURL: remoteURL,
            recognitionURL: remoteURL,
            originalRelPath: sources.remoteRelPath,
            recognitionRelPath: sources.remoteRelPath,
            sha256: try streamingSHA(remoteURL),
            frameCount: remoteCount,
            duration: Double(remoteCount) / 16000.0,
            windowMask: PipelineLogic.windows(remoteCount).map { _ in true }
        ))

        // ----------------------------------------------------
        // Stage 1: Nemotron Diarization
        // ----------------------------------------------------
        try checkCancellation(checkCancel)
        let nemotronDir = modelPath("nemotron")
        if FileManager.default.fileExists(atPath: nemotronDir.path) {
            do {
                let diarizer = try Nemotron3Diarizer.fromMLXDirectory(nemotronDir)
                for i in channels.indices {
                    try checkCancellation(checkCancel)
                    onProgress?(PipelineProgressEvent(stage: .diarization, channel: channels[i].id.rawValue, completed: 0, total: 1))
                    do {
                        diarizer.resetState()
                        let samples = try loadAudioChunk(url: channels[i].recognitionURL, range: 0..<channels[i].frameCount)
                        let diarResult = try diarizer.diarize(
                            audio: samples,
                            sampleRate: 16000,
                            config: DiarizationConfig(onset: 0.5, offset: 0.5, minSpeechDuration: 0, minSilenceDuration: 0),
                            coreEncoderFrames: 340,
                            rightContextEncoderFrames: 40
                        )
                        try checkCancellation(checkCancel)
                        let intervals = diarResult.segments.map {
                            DiarizationInterval(start: Double($0.startTime), end: Double($0.endTime), speaker: $0.speakerId)
                        }
                        if intervals.isEmpty {
                            channels[i].diarizationStatus = .failed
                            channels[i].warnings.append(TranscriptDocument.Warning(
                                code: "diarization_no_speech",
                                sourceID: channels[i].id,
                                message: "Nemotron не обнаружил речи в дорожке \(channels[i].id.rawValue)"
                            ))
                        } else {
                            channels[i].intervals = intervals
                            channels[i].detectedVoiceCount = diarResult.numSpeakers
                            channels[i].diarizationStatus = .completed
                            if diarResult.numSpeakers >= 8 {
                                channels[i].warnings.append(TranscriptDocument.Warning(
                                    code: "diarization_voice_limit",
                                    sourceID: channels[i].id,
                                    message: "Достигнут предел 8 голосов для дорожки \(channels[i].id.rawValue)"
                                ))
                            }
                        }
                    } catch {
                        try checkCancellation(checkCancel)
                        channels[i].diarizationStatus = .failed
                        channels[i].warnings.append(TranscriptDocument.Warning(
                            code: "diarization_failed",
                            sourceID: channels[i].id,
                            message: "Сбой диаризации: \(error.localizedDescription)"
                        ))
                    }
                    onProgress?(PipelineProgressEvent(stage: .diarization, channel: channels[i].id.rawValue, completed: 1, total: 1))
                }
            } catch {
                try checkCancellation(checkCancel)
                for i in channels.indices {
                    channels[i].diarizationStatus = .failed
                    channels[i].warnings.append(TranscriptDocument.Warning(
                        code: "diarization_load_failed",
                        sourceID: channels[i].id,
                        message: "Не удалось загрузить модель диаризации: \(error.localizedDescription)"
                    ))
                }
            }
            MLX.Stream.gpu.synchronize()
            Memory.clearCache()
        }

        // ----------------------------------------------------
        // Stage 2: Silero VAD
        // ----------------------------------------------------
        try checkCancellation(checkCancel)
        let vadDir = modelPath("vad")
        if FileManager.default.fileExists(atPath: vadDir.path) {
            do {
                let vadModel = try PipelineSilero.SileroVAD.fromModelDirectory(vadDir)
                eval(vadModel.parameters())
                MLX.Stream.gpu.synchronize()

                for i in channels.indices {
                    try checkCancellation(checkCancel)
                    onProgress?(PipelineProgressEvent(stage: .vad, channel: channels[i].id.rawValue, completed: 0, total: 1))
                    do {
                        let reader = try PCMReader(channels[i].recognitionURL, block: 160_000)
                        let (p, _) = try boundedVAD(vadModel, checkCancel: checkCancel) {
                            try reader.next()
                        }
                        let probs = MLXArray(p)
                        eval(probs)
                        let speech = PipelineSilero.SileroVAD.probsToTimestamps(
                            probs,
                            audioLen: channels[i].frameCount,
                            sampleRate: 16000,
                            threshold: 0.5,
                            minSpeechDurationMs: 250,
                            minSilenceDurationMs: 250,
                            speechPadMs: 150
                        )
                        let accepted = PipelineLogic.mask(channels[i].frameCount, speech.map { $0.start..<$0.end })
                        channels[i].windowMask = accepted
                    } catch {
                        try checkCancellation(checkCancel)
                        channels[i].warnings.append(TranscriptDocument.Warning(
                            code: "vad_failed",
                            sourceID: channels[i].id,
                            message: "Сбой VAD: \(error.localizedDescription)"
                        ))
                    }
                    onProgress?(PipelineProgressEvent(stage: .vad, channel: channels[i].id.rawValue, completed: 1, total: 1))
                }
            } catch {
                try checkCancellation(checkCancel)
                for i in channels.indices {
                    channels[i].warnings.append(TranscriptDocument.Warning(
                        code: "vad_load_failed",
                        sourceID: channels[i].id,
                        message: "Не удалось загрузить VAD: \(error.localizedDescription)"
                    ))
                }
            }
            MLX.Stream.gpu.synchronize()
            Memory.clearCache()
        }

        // ----------------------------------------------------
        // Stage 3: GigaAM (Mandatory ASR)
        // ----------------------------------------------------
        try checkCancellation(checkCancel)
        let gigaamDir = modelPath("gigaam")
        let bundle = try ModelBundle.load(configuration: .init(modelDirectory: gigaamDir))
        guard bundle.manifest.sampleRate == 16000, let weights = bundle.weightsURL else {
            throw PipelineError("Некорректная модель GigaAM в \(gigaamDir.path)")
        }
        let frontend = try MelSpectrogramProcessor(assetsDirectory: gigaamDir)
        let tokenizer = try SentencePieceTokenizer(modelURL: bundle.tokenizerURL)
        let store = try GigaAMTensorStore(weightsURL: weights, computeDType: nil)
        let encoder = try GigaAMEncoder(store: store)
        let head = try GigaAMRNNTHead(store: store)
        let decoder = RNNTGreedyDecoder()
        for name in store.names() { eval(try store.load(name)) }
        MLX.Stream.gpu.synchronize()

        for i in channels.indices {
            let grid = PipelineLogic.windows(channels[i].frameCount)
            onProgress?(PipelineProgressEvent(stage: .gigaam, channel: channels[i].id.rawValue, completed: 0, total: grid.count))

            for (j, range) in grid.enumerated() {
                try checkCancellation(checkCancel)
                if channels[i].windowMask[j] {
                    let start = Double(range.lowerBound) / 16000.0
                    let end = Double(range.upperBound) / 16000.0
                    let tokens: [ASRToken] = try autoreleasepool {
                        var chunk = try self.loadAudioChunk(url: channels[i].recognitionURL, range: range)
                        if chunk.count < 320 {
                            chunk += [Float](repeating: 0, count: 320 - chunk.count)
                        }
                        let f = try frontend.computeFlat(samples: chunk)
                        let e = encoder.forward(features: MLXArray(f.features, f.shape), length: f.length)
                        MLX.Stream.gpu.synchronize()
                        let decoded = try decoder.decodeTimed(head: head, encoded: e.encoded, encodedLength: e.length)
                        MLX.Stream.gpu.synchronize()
                        return try decoded.result.steps.filter { !$0.isBlank }.map { s -> ASRToken in
                            guard let p = tokenizer.piece(forTokenId: s.token) else {
                                throw PipelineError("Неизвестный токен ASR: \(s.token)")
                            }
                            let t = Double(s.timeIndex) * 0.04
                            return ASRToken(id: s.token, piece: p, start: t, end: min(end - start, t + 0.1), frame: s.timeIndex)
                        }
                    }
                    MLX.Stream.gpu.synchronize()
                    channels[i].gigaamWords += try PipelineLogic.assemble(
                        tokens,
                        start: start,
                        end: end,
                        last: range.upperBound == channels[i].frameCount
                    )
                }
                onProgress?(PipelineProgressEvent(stage: .gigaam, channel: channels[i].id.rawValue, completed: j + 1, total: grid.count))
            }

            channels[i].gigaamWords = PipelineLogic.assign(channels[i].gigaamWords, channels[i].intervals)
            channels[i].finalWords = channels[i].gigaamWords
        }
        MLX.Stream.gpu.synchronize()
        Memory.clearCache()

        // ----------------------------------------------------
        // Stage 4: Parakeet Cascade (Optional)
        // ----------------------------------------------------
        var allSuggestions: [Suggestion] = []
        if parakeetEnabled {
            try checkCancellation(checkCancel)
            let parakeetDir = modelPath("parakeet")
            if FileManager.default.fileExists(atPath: parakeetDir.path) {
                do {
                    let parakeetModel = try ParakeetModel.fromDirectory(parakeetDir, computeDType: .float16)
                    eval(parakeetModel.parameters())
                    MLX.Stream.gpu.synchronize()

                    for i in channels.indices {
                        let grid = PipelineLogic.windows(channels[i].frameCount)
                        onProgress?(PipelineProgressEvent(stage: .parakeet, channel: channels[i].id.rawValue, completed: 0, total: grid.count))
                        do {
                            var donorWords: [PipelineWord] = []
                            for (j, range) in grid.enumerated() {
                                try checkCancellation(checkCancel)
                                if channels[i].windowMask[j] {
                                    let start = Double(range.lowerBound) / 16000.0
                                    let end = Double(range.upperBound) / 16000.0
                                    let tokens: [ASRToken] = try autoreleasepool {
                                        var chunk = try self.loadAudioChunk(url: channels[i].recognitionURL, range: range)
                                        if chunk.count < 320 {
                                            chunk += [Float](repeating: 0, count: 320 - chunk.count)
                                        }
                                        let aligned = parakeetModel.decodeAlignedTokens(chunk)
                                        return aligned.map { tok in
                                            ASRToken(id: tok.id, piece: tok.text, start: tok.start, end: tok.end)
                                        }
                                    }
                                    MLX.Stream.gpu.synchronize()
                                    donorWords += try PipelineLogic.assemble(
                                        tokens,
                                        start: start,
                                        end: end,
                                        last: range.upperBound == channels[i].frameCount
                                    )
                                }
                                onProgress?(PipelineProgressEvent(stage: .parakeet, channel: channels[i].id.rawValue, completed: j + 1, total: grid.count))
                            }
                            let (corrected, journal) = PipelineLogic.cascade(channels[i].gigaamWords, donorWords)
                            channels[i].finalWords = corrected
                            channels[i].suggestions = journal
                            channels[i].correctionStatus = .completed
                            allSuggestions += journal
                        } catch {
                            try checkCancellation(checkCancel)
                            channels[i].correctionStatus = .failed
                            channels[i].warnings.append(TranscriptDocument.Warning(
                                code: "parakeet_failed",
                                sourceID: channels[i].id,
                                message: "Сбой коррекции Parakeet: \(error.localizedDescription)"
                            ))
                        }
                    }
                } catch {
                    try checkCancellation(checkCancel)
                    for i in channels.indices {
                        channels[i].correctionStatus = .failed
                        channels[i].warnings.append(TranscriptDocument.Warning(
                            code: "parakeet_load_failed",
                            sourceID: channels[i].id,
                            message: "Не удалось загрузить Parakeet: \(error.localizedDescription)"
                        ))
                    }
                }
                MLX.Stream.gpu.synchronize()
                Memory.clearCache()
            }
        }

        // ----------------------------------------------------
        // Stage 5: Audio Mixing
        // ----------------------------------------------------
        let stagingMixURL = aecTempDir.appendingPathComponent("mix.m4a")
        var finalMixURL: URL? = nil
        var playback: TranscriptDocument.Playback

        do {
            try AudioMixer.prepareMix(host: hostURL, remote: remoteURL, destination: stagingMixURL)
            finalMixURL = stagingMixURL
            playback = TranscriptDocument.Playback(
                status: .ready,
                mixPath: "raw/transcripts/\(resultID)/mix.m4a"
            )
        } catch {
            playback = TranscriptDocument.Playback(
                status: .unavailable,
                mixPath: nil
            )
            let mixWarning = TranscriptDocument.Warning(
                code: "playback_mix_failed",
                sourceID: nil,
                message: "Не удалось создать микс для воспроизведения: \(error.localizedDescription)"
            )
            additionalWarnings.append(mixWarning)
            onProgress?(PipelineProgressEvent(stage: .warning, completed: 0, total: 1, warning: mixWarning.message))
        }

        // ----------------------------------------------------
        // Stage 6: Turns & Document Serialization
        // ----------------------------------------------------
        try checkCancellation(checkCancel)
        onProgress?(PipelineProgressEvent(stage: .merge, completed: 0, total: 1))

        let document = try Self.assembleDocument(
            channels: channels,
            resultID: resultID,
            aec: TranscriptDocument.AEC(requested: echoCancelEnabled, outcome: aecOutcome),
            playback: playback,
            additionalWarnings: additionalWarnings
        )

        var journalData: Data? = nil
        if !allSuggestions.isEmpty {
            journalData = try? JSONEncoder().encode(allSuggestions)
        }

        onProgress?(PipelineProgressEvent(stage: .merge, completed: 1, total: 1))

        return PipelineResult(
            document: document,
            suggestions: allSuggestions,
            hostAudioURL: hostURL,
            remoteAudioURL: remoteURL,
            audioMixURL: finalMixURL,
            aecAudioURL: aecAudioURL,
            correctionJournalData: journalData
        )
    }

    static func assembleDocument(
        channels: [ChannelAudio],
        resultID: String,
        aec: TranscriptDocument.AEC,
        playback: TranscriptDocument.Playback,
        additionalWarnings: [TranscriptDocument.Warning]
    ) throws -> TranscriptDocument {
        var docSources: [TranscriptDocument.Source] = []
        var docSpeakers: [TranscriptDocument.Speaker] = []
        var docWords: [TranscriptDocument.Word] = []
        var docBaselineWords: [TranscriptDocument.Word] = []
        var docTurns: [TranscriptDocument.Turn] = []

        func registeredSpeakers(_ channel: ChannelAudio) -> [Int] {
            let baseline = channel.correctionStatus == .completed ? channel.gigaamWords : []
            return Array(Set((channel.finalWords + baseline).map { $0.speaker ?? 1 } + [1])).sorted()
        }
        let hostMaxSpeaker = channels.first(where: { $0.id == .host })
            .map { registeredSpeakers($0).max() ?? 1 } ?? 1

        for channel in channels {
            docSources.append(TranscriptDocument.Source(
                id: channel.id,
                originalAudioPath: channel.originalRelPath,
                recognitionAudioPath: channel.recognitionRelPath,
                diarizationStatus: channel.diarizationStatus,
                detectedVoiceCount: channel.detectedVoiceCount,
                correctionStatus: channel.correctionStatus
            ))

            let distinctSpeakers = registeredSpeakers(channel)
            for spkLocal in distinctSpeakers {
                let spkID = "spk_\(channel.id == .host ? "h" : "r")\(spkLocal)"
                let displayNumber = spkLocal + (channel.id == .host ? 0 : hostMaxSpeaker)
                docSpeakers.append(TranscriptDocument.Speaker(
                    id: spkID,
                    sourceID: channel.id,
                    localID: spkLocal,
                    displayNumber: displayNumber
                ))
            }
        }

        // Build docWords and docBaselineWords
        for channel in channels {
            let channelPrefix = channel.id == .host ? "h" : "r"

            for (idx, w) in channel.finalWords.enumerated() {
                let spkLocal = w.speaker ?? 1
                let spkID = "spk_\(channelPrefix)\(spkLocal)"
                let wordID = "w_\(channelPrefix)_\(idx + 1)"
                docWords.append(TranscriptDocument.Word(
                    id: wordID,
                    speakerID: spkID,
                    start: w.start,
                    end: w.end,
                    text: w.text
                ))
            }

            for (idx, bw) in channel.gigaamWords.enumerated() {
                let spkLocal = bw.speaker ?? 1
                let spkID = "spk_\(channelPrefix)\(spkLocal)"
                let baselineWordID = "bw_\(channelPrefix)_\(idx + 1)"
                docBaselineWords.append(TranscriptDocument.Word(
                    id: baselineWordID,
                    speakerID: spkID,
                    start: bw.start,
                    end: bw.end,
                    text: bw.text
                ))
            }
        }

        // If correctionStatus is NOT completed, ensure baselineWords match words
        for channel in channels where channel.correctionStatus != .completed {
            let channelPrefix = channel.id == .host ? "h" : "r"
            let finalWordsForChannel = docWords.filter { $0.id.hasPrefix("w_\(channelPrefix)_") }
            docBaselineWords.removeAll { $0.id.hasPrefix("bw_\(channelPrefix)_") }
            for (idx, fw) in finalWordsForChannel.enumerated() {
                docBaselineWords.append(TranscriptDocument.Word(
                    id: "bw_\(channelPrefix)_\(idx + 1)",
                    speakerID: fw.speakerID,
                    start: fw.start,
                    end: fw.end,
                    text: fw.text
                ))
            }
        }

        // Keep stored words untouched; order references before grouping across sources.
        let sourceBySpeaker = Dictionary(uniqueKeysWithValues: docSpeakers.map { ($0.id, $0.sourceID) })
        let orderedWords = docWords.enumerated().sorted {
            if $0.element.start != $1.element.start { return $0.element.start < $1.element.start }
            let lhsSource = sourceBySpeaker[$0.element.speakerID]
            let rhsSource = sourceBySpeaker[$1.element.speakerID]
            if lhsSource != rhsSource { return lhsSource == .host }
            return $0.offset < $1.offset
        }.map(\.element)
        docTurns = TranscriptParagraphs.groupWordIndices(orderedWords).enumerated().map { index, group in
            let words = group.map { orderedWords[$0] }
            return TranscriptDocument.Turn(
                id: "turn_\(index + 1)", speakerID: words[0].speakerID,
                start: words.map(\.start).min()!, end: words.map(\.end).max()!,
                wordIDs: words.map(\.id)
            )
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let createdAtStr = isoFormatter.string(from: Date())

        let allWarnings = channels.flatMap(\.warnings) + additionalWarnings

        return try TranscriptDocument(
            schemaVersion: 1,
            resultID: resultID,
            createdAt: createdAtStr,
            sources: docSources,
            speakers: docSpeakers,
            words: docWords,
            turns: docTurns,
            baselineWords: docBaselineWords,
            aec: aec,
            playback: playback,
            warnings: allWarnings
        )

    }
}
