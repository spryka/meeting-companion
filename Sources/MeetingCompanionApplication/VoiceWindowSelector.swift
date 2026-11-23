import Foundation
import MeetingCompanionCore

public enum VoiceWindowSelector {
    public enum Purpose: Sendable {
        case learning, matching
    }

    public enum Refusal: Error, Equatable, Sendable {
        case sourceMismatch, missingEvidence, insufficientSpeech, overlap
    }

    public enum Selection: Equatable, Sendable {
        case windows([VoiceAudioInterval])
        case refused(Refusal)
    }

    private static let matchingPauseGap = 0.6
    private static let learningWordPauseGap = 0.4

    public static func select(
        turn: TranscriptDocument.Turn, source: TranscriptDocument.Source, document: TranscriptDocument,
        evidence: VoiceAudioQuality.Source?, actualFingerprint: String, purpose: Purpose
    ) -> Selection {
        switch purpose {
        case .matching:
            switch matchingCandidateFrames(
                turn: turn, source: source, document: document,
                evidence: evidence, actualFingerprint: actualFingerprint
            ) {
            case .failure(let refusal):
                return .refused(refusal)
            case .success(let candidateFrames):
                let rate = Double(VoiceEmbeddingProtocol.sampleRate)
                let windows = extractMatchingSubwindows(from: candidateFrames, maxWindows: 1).map {
                    VoiceAudioInterval(start: Double($0.start) / rate, end: Double($0.end) / rate)
                }
                return windows.isEmpty ? .refused(.insufficientSpeech) : .windows(windows)
            }

        case .learning:
            let prepared: (trimmed: VoiceAudioInterval, speech: [VoiceAudioInterval], exclusions: [VoiceAudioInterval])
            switch preparedIntervals(
                turn: turn, source: source, document: document,
                evidence: evidence, actualFingerprint: actualFingerprint,
                speechGap: 0, wordGap: learningWordPauseGap, requireDiarizationConfirmation: false
            ) {
            case .failure(let refusal):
                return .refused(refusal)
            case .success(let value):
                prepared = value
            }
            let eligible = cleanIntervals(within: prepared.trimmed, speech: prepared.speech, exclusions: prepared.exclusions)
            let candidates = eligible.flatMap { interval -> [VoiceAudioInterval] in
                let length = interval.end - interval.start
                guard length >= 3 else { return [] }
                guard length > 6 else { return [interval] }
                let count = Int(min(4, (length / 6).rounded(.down)))
                return (0..<count).map { index in
                    let position = count == 1 ? 0.5 : Double(index) / Double(count - 1)
                    let start = interval.start + (length - 6) * position
                    return VoiceAudioInterval(start: start, end: min(interval.end, start + 6))
                }
            }
            guard !candidates.isEmpty else { return .refused(prepared.exclusions.isEmpty ? .insufficientSpeech : .overlap) }
            guard candidates.count > 4 else { return .windows(candidates) }
            return .windows((0..<4).map { candidates[$0 * (candidates.count - 1) / 3] })
        }
    }

    public static func matchingCandidateFrames(
        turn: TranscriptDocument.Turn, source: TranscriptDocument.Source, document: TranscriptDocument,
        evidence: VoiceAudioQuality.Source?, actualFingerprint: String
    ) -> Result<[(start: Int, end: Int)], Refusal> {
        let prepared: (trimmed: VoiceAudioInterval, speech: [VoiceAudioInterval], exclusions: [VoiceAudioInterval])
        switch preparedIntervals(
            turn: turn, source: source, document: document,
            evidence: evidence, actualFingerprint: actualFingerprint,
            speechGap: matchingPauseGap, wordGap: matchingPauseGap, requireDiarizationConfirmation: true
        ) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let value):
            prepared = value
        }
        let eligible = cleanIntervals(within: prepared.trimmed, speech: prepared.speech, exclusions: prepared.exclusions)
        let rate = Double(VoiceEmbeddingProtocol.sampleRate)
        let minimumFrames = 3 * VoiceEmbeddingProtocol.sampleRate
        let candidateFrames: [(start: Int, end: Int)] = eligible.compactMap { interval in
            guard let start = Int(exactly: (interval.start * rate).rounded(.up)),
                  let end = Int(exactly: (interval.end * rate).rounded(.down)),
                  start >= 0, end >= start, end - start >= minimumFrames else { return nil }
            return (start, end)
        }
        guard !candidateFrames.isEmpty else {
            return .failure(prepared.exclusions.isEmpty ? .insufficientSpeech : .overlap)
        }
        return .success(candidateFrames)
    }

    public static func extractMatchingSubwindows(
        from candidateFrames: [(start: Int, end: Int)],
        maxWindows: Int
    ) -> [(start: Int, end: Int)] {
        let minimumFrames = 3 * VoiceEmbeddingProtocol.sampleRate
        let maximumFrames = 6 * VoiceEmbeddingProtocol.sampleRate
        let valid = candidateFrames.filter { $0.start >= 0 && $0.end - $0.start >= minimumFrames }
        guard !valid.isEmpty else { return [] }
        guard let best = valid.max(by: { lhs, rhs in
            let lhsLen = lhs.end - lhs.start
            let rhsLen = rhs.end - rhs.start
            if lhsLen != rhsLen { return lhsLen < rhsLen }
            return lhs.start > rhs.start
        }) else { return [] }

        if maxWindows <= 1 {
            let length = best.end - best.start
            let count = min(length, maximumFrames)
            let startFrame = best.start + (length - count) / 2
            return [(startFrame, startFrame + count)]
        }

        var chunks: [(start: Int, end: Int)] = []
        let ordered = valid.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        for (sf, ef) in ordered {
            let length = ef - sf
            if length <= maximumFrames {
                chunks.append((sf, ef))
            } else {
                let nFull = length / maximumFrames
                let rem = length - nFull * maximumFrames
                if rem >= minimumFrames {
                    let n = nFull + 1
                    let size = length / n
                    for k in 0..<n {
                        let sk = sf + k * size
                        let ek = sk + min(maximumFrames, k == n - 1 ? ef - sk : size)
                        if ek - sk >= minimumFrames {
                            chunks.append((sk, ek))
                        }
                    }
                } else {
                    let offset = (length - nFull * maximumFrames) / 2
                    for k in 0..<nFull {
                        let sk = sf + offset + k * maximumFrames
                        chunks.append((sk, sk + maximumFrames))
                    }
                }
            }
        }
        guard chunks.count > maxWindows else { return chunks }
        return (0..<maxWindows).map { idx in
            chunks[idx * (chunks.count - 1) / (maxWindows - 1)]
        }
    }

    private static func preparedIntervals(
        turn: TranscriptDocument.Turn, source: TranscriptDocument.Source, document: TranscriptDocument,
        evidence: VoiceAudioQuality.Source?, actualFingerprint: String,
        speechGap: Double, wordGap: Double, requireDiarizationConfirmation: Bool
    ) -> Result<(trimmed: VoiceAudioInterval, speech: [VoiceAudioInterval], exclusions: [VoiceAudioInterval]), Refusal> {
        guard document.speakers.first(where: { $0.id == turn.speakerID })?.sourceID == source.id,
              document.sources.contains(where: { $0.id == source.id && $0.recognitionAudioPath == source.recognitionAudioPath }),
              !actualFingerprint.isEmpty else { return .failure(.sourceMismatch) }
        if let evidence {
            guard evidence.id == source.id, evidence.recognitionAudioPath == source.recognitionAudioPath,
                  evidence.fingerprint == actualFingerprint, evidence.duration >= turn.end else {
                return .failure(.sourceMismatch)
            }
        }
        let range = VoiceAudioInterval(start: turn.start, end: turn.end)
        guard range.isValid, range.end - range.start >= 3 else { return .failure(.insufficientSpeech) }
        let trimmed = VoiceAudioInterval(start: range.start + 0.15, end: range.end - 0.15)
        guard trimmed.isValid else { return .failure(.insufficientSpeech) }

        let otherSpeakers = Set(document.speakers.filter { $0.sourceID == source.id && $0.id != turn.speakerID }.map(\.id))
        let otherTurns = document.turns.filter { otherSpeakers.contains($0.speakerID) }
            .map { VoiceAudioInterval(start: $0.start, end: $0.end) }
        let exclusions = (otherTurns + (evidence?.overlap ?? [])).filter(\.isValid)
            .map { VoiceAudioInterval(start: max(0, $0.start - 0.1), end: $0.end + 0.1) }
            .filter { intersects($0, trimmed) }

        let speech: [VoiceAudioInterval]
        if let evidence {
            if let rawSpeech = evidence.speech {
                speech = merged(rawSpeech, maxGap: speechGap)
            } else if !requireDiarizationConfirmation, let wordSpeech = wordSpeechIntervals(for: turn, in: document, maxGap: wordGap) {
                speech = wordSpeech
            } else {
                return .failure(.missingEvidence)
            }
        } else {
            guard !requireDiarizationConfirmation || (source.diarizationStatus == .completed && (source.detectedVoiceCount ?? 0) > 0),
                  let wordSpeech = wordSpeechIntervals(for: turn, in: document, maxGap: wordGap) else {
                return .failure(.missingEvidence)
            }
            speech = wordSpeech
        }
        return .success((trimmed, speech, exclusions))
    }

    public static func spokenTokenCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { token in
            token.contains { $0.isLetter || $0.isNumber }
        }.count
    }

    public static func isDenseSpeechWindow(
        start: Double, end: Double, speakerID: String, document: TranscriptDocument
    ) -> Bool {
        guard start.isFinite, end.isFinite, end > start else { return false }
        let duration = end - start
        var effectiveTokens = 0.0
        for word in document.words where word.speakerID == speakerID && word.end > start && word.start < end {
            let wordDuration = word.end - word.start
            guard wordDuration > 0 else { continue }
            let overlap = min(word.end, end) - max(word.start, start)
            guard overlap > 0 else { continue }
            let tokens = spokenTokenCount(in: word.text)
            guard tokens > 0 else { continue }
            effectiveTokens += Double(tokens) * (overlap / wordDuration)
        }
        return effectiveTokens >= duration
    }

    private static func wordSpeechIntervals(
        for turn: TranscriptDocument.Turn,
        in document: TranscriptDocument,
        maxGap: Double
    ) -> [VoiceAudioInterval]? {
        let wordIDs = Set(turn.wordIDs)
        let turnWords = document.words.filter {
            $0.speakerID == turn.speakerID && (wordIDs.contains($0.id) || ($0.end > turn.start && $0.start < turn.end))
        }
        guard !turnWords.isEmpty else { return nil }
        let intervals: [VoiceAudioInterval]
        if turnWords.count > 1 {
            intervals = turnWords.compactMap { word -> VoiceAudioInterval? in
                let duration = word.end - word.start
                guard word.start.isFinite, word.end.isFinite, duration > 0 else { return nil }
                let tokens = max(1, spokenTokenCount(in: word.text))
                let stretchLimit = max(2.5, Double(tokens) * 1.2)
                if duration > stretchLimit {
                    let clampedEnd = min(word.end, word.start + max(1.5, Double(tokens) * 0.8))
                    return VoiceAudioInterval(start: word.start, end: clampedEnd)
                }
                return VoiceAudioInterval(start: word.start, end: word.end)
            }
        } else {
            intervals = turnWords.map { VoiceAudioInterval(start: $0.start, end: $0.end) }
        }
        let result = merged(intervals, maxGap: maxGap)
        return result.isEmpty ? nil : result
    }

    private static func cleanIntervals(
        within trimmed: VoiceAudioInterval,
        speech: [VoiceAudioInterval],
        exclusions: [VoiceAudioInterval]
    ) -> [VoiceAudioInterval] {
        var eligible = speech.map { VoiceAudioInterval(start: max($0.start, trimmed.start), end: min($0.end, trimmed.end)) }
            .filter(\.isValid)
        for exclusion in exclusions {
            eligible = eligible.flatMap { interval in
                guard intersects(interval, exclusion) else { return [interval] }
                return [
                    VoiceAudioInterval(start: interval.start, end: min(interval.end, exclusion.start)),
                    VoiceAudioInterval(start: max(interval.start, exclusion.end), end: interval.end)
                ].filter(\.isValid)
            }
        }
        return eligible
    }

    private static func intersects(_ lhs: VoiceAudioInterval, _ rhs: VoiceAudioInterval) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private static func merged(_ intervals: [VoiceAudioInterval], maxGap: Double = 0) -> [VoiceAudioInterval] {
        var merged: [VoiceAudioInterval] = []
        let tolerance = maxGap > 0 ? 1e-9 : 0
        for interval in intervals.filter(\.isValid).sorted(by: { $0.start < $1.start || ($0.start == $1.start && $0.end < $1.end) }) {
            if let last = merged.last, interval.start <= last.end + maxGap + tolerance {
                merged[merged.count - 1] = .init(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
