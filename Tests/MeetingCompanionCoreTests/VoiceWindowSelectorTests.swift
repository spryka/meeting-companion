import MeetingCompanionApplication
import MeetingCompanionCore
import Testing

@Suite struct VoiceWindowSelectorTests {
    private let fingerprint = String(repeating: "a", count: 64)

    private func document(
        secondary: TranscriptDocument.SourceID,
        wordIntervals: [(id: String, speakerID: String, start: Double, end: Double)]? = nil,
        turnsOverride: [TranscriptDocument.Turn]? = nil
    ) throws -> TranscriptDocument {
        let sources: [TranscriptDocument.Source] = [.host, .remote].map {
            .init(id: $0, originalAudioPath: "raw/\($0.rawValue).wav",
                  recognitionAudioPath: $0 == .host ? "raw/transcripts/result/host_aec.wav" : "raw/remote.wav",
                  diarizationStatus: .completed, detectedVoiceCount: 2, correctionStatus: .disabled)
        }
        let speakers: [TranscriptDocument.Speaker] = [
            .init(id: "speaker_1", sourceID: .host, localID: 1, displayNumber: 1),
            .init(id: "speaker_2", sourceID: secondary, localID: secondary == .host ? 2 : 1, displayNumber: 2)
        ]
        let words: [TranscriptDocument.Word]
        let turns: [TranscriptDocument.Turn]
        if let wordIntervals {
            words = wordIntervals.map {
                .init(id: $0.id, speakerID: $0.speakerID, start: $0.start, end: $0.end, text: "Слово")
            }
            turns = try #require(turnsOverride)
        } else {
            words = [
                .init(id: "word_1", speakerID: "speaker_1", start: 10, end: 22, text: "Первая"),
                .init(id: "word_2", speakerID: "speaker_2", start: 15, end: 16, text: "Вторая")
            ]
            turns = words.map { word in
                TranscriptDocument.Turn(id: "turn_" + word.id, speakerID: word.speakerID,
                                        start: word.start, end: word.end, wordIDs: [word.id])
            }
        }
        return try TranscriptDocument(schemaVersion: 1, resultID: "result", createdAt: "2026-11-21T12:00:00Z",
            sources: sources, speakers: speakers, words: words, turns: turns, baselineWords: words,
            aec: .init(requested: true, outcome: .applied),
            playback: .init(status: .ready, mixPath: "raw/transcripts/result/mix.m4a"), warnings: [])
    }

    @Test func matchingSelectsCenteredSubwindowAndChecksSourceAndEvidence() throws {
        let document = try document(secondary: .remote)
        let source = try #require(document.sources.first)
        let turn = try #require(document.turns.first)
        let evidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80, speech: [.init(start: 9, end: 23)], overlap: [])

        let rate = 16_000.0
        let startFrame = Int((10.15 * rate).rounded(.up))
        let endFrame = Int((21.85 * rate).rounded(.down))
        let centeredStart = startFrame + (endFrame - startFrame - 96_000) / 2
        let expected = VoiceAudioInterval(start: Double(centeredStart) / rate, end: Double(centeredStart + 96_000) / rate)

        #expect(VoiceWindowSelector.select(turn: turn, source: source, document: document,
            evidence: evidence, actualFingerprint: fingerprint, purpose: .matching) == .windows([expected]))
        #expect(VoiceWindowSelector.select(turn: turn, source: source, document: document,
            evidence: evidence, actualFingerprint: "changed", purpose: .matching) == .refused(.sourceMismatch))

        let missingSpeechEvidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80, speech: nil, overlap: [])
        #expect(VoiceWindowSelector.select(turn: turn, source: source, document: document,
            evidence: missingSpeechEvidence, actualFingerprint: fingerprint, purpose: .matching) == .refused(.missingEvidence))
    }

    @Test func matchingSelectsLongestCleanSubintervalDespitePauseOrMidTurnOverlap() throws {
        let document = try document(secondary: .host)
        let source = try #require(document.sources.first)
        let turn = try #require(document.turns.first)
        let evidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80, speech: [.init(start: 9, end: 23)], overlap: [])

        // Mid-turn overlap [15, 16] on host splits [10.15, 21.85] into [10.15, 14.9] and [16.1, 21.85].
        // Matching picks the longest clean sub-interval [16.1, 21.85] quantized inward.
        let rate = 16_000.0
        let rightStart = Int((16.1 * rate).rounded(.up))
        let rightEnd = Int((21.85 * rate).rounded(.down))
        #expect(VoiceWindowSelector.select(turn: turn, source: source, document: document,
            evidence: evidence, actualFingerprint: fingerprint, purpose: .matching) ==
            .windows([.init(start: Double(rightStart) / rate, end: Double(rightEnd) / rate)]))

        // Full-turn overlap leaving < 3s still refuses with .overlap.
        let heavyOverlap = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80, speech: [.init(start: 9, end: 23)],
            overlap: [.init(start: 10, end: 13), .init(start: 18, end: 22)])
        #expect(VoiceWindowSelector.select(turn: turn, source: source, document: document,
            evidence: heavyOverlap, actualFingerprint: fingerprint, purpose: .matching) == .refused(.overlap))

        // Internal speech pause inside turn without overlap selects the longest clean speech interval.
        let remoteDoc = try self.document(secondary: .remote)
        let pausedEvidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80,
            speech: [.init(start: 10, end: 11.5), .init(start: 13.0, end: 21.0)], overlap: [])
        let pauseStart = Int((13.0 * rate).rounded(.up))
        let pauseEnd = Int((21.0 * rate).rounded(.down))
        let pausedCentered = pauseStart + (pauseEnd - pauseStart - 96_000) / 2
        #expect(VoiceWindowSelector.select(turn: turn, source: source, document: remoteDoc,
            evidence: pausedEvidence, actualFingerprint: fingerprint, purpose: .matching) ==
            .windows([.init(start: Double(pausedCentered) / rate, end: Double(pausedCentered + 96_000) / rate)]))
    }

    @Test func matchingTieBreaksEqualSubintervalsToEarlierAndUsesWordsFallbackWhenQualityIsNil() throws {
        // Equal clean intervals [10.15, 14.9] and [17.1, 21.85] -> picks earlier one.
        let rate = 16_000.0
        let words: [(String, String, Double, Double)] = [
            ("w1", "speaker_1", 10.0, 22.0),
            ("w2", "speaker_2", 15.0, 17.0)
        ]
        let turns: [TranscriptDocument.Turn] = [
            .init(id: "turn_1", speakerID: "speaker_1", start: 10.0, end: 22.0, wordIDs: ["w1"]),
            .init(id: "turn_2", speakerID: "speaker_2", start: 15.0, end: 17.0, wordIDs: ["w2"])
        ]
        let doc = try document(secondary: .host, wordIntervals: words, turnsOverride: turns)
        let source = try #require(doc.sources.first)
        let turn = try #require(doc.turns.first)
        let evidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80, speech: [.init(start: 9, end: 23)], overlap: [])
        let leftStart = Int((10.15 * rate).rounded(.up))
        let leftEnd = Int((14.9 * rate).rounded(.down))
        #expect(VoiceWindowSelector.select(turn: turn, source: source, document: doc,
            evidence: evidence, actualFingerprint: fingerprint, purpose: .matching) ==
            .windows([.init(start: Double(leftStart) / rate, end: Double(leftEnd) / rate)]))

        // Without voice-quality.v1.json (evidence == nil), words with gap <= 0.40s merge (including decimal 0.40s boundary).
        let boundaryWords: [(String, String, Double, Double)] = [
            ("bw1", "speaker_1", 2.0, 2.3),
            ("bw2", "speaker_1", 2.7, 4.5), // gap = 0.4s in IEEE-754 (2.3 + 0.4 < 2.7)
            ("bw3", "speaker_1", 4.8, 6.5)  // gap = 0.3s
        ]
        let boundaryTurn = TranscriptDocument.Turn(id: "turn_bw", speakerID: "speaker_1", start: 2.0, end: 6.5,
                                                   wordIDs: ["bw1", "bw2", "bw3"])
        let boundaryDoc = try document(secondary: .remote, wordIntervals: boundaryWords, turnsOverride: [boundaryTurn])
        let expectedStart = Int((2.15 * rate).rounded(.up))
        let expectedEnd = Int((6.35 * rate).rounded(.down))
        #expect(VoiceWindowSelector.select(turn: boundaryTurn, source: source, document: boundaryDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .matching) ==
            .windows([.init(start: Double(expectedStart) / rate, end: Double(expectedEnd) / rate)]))

        // With maxGap = 0.60s for .matching, 0.50s and IEEE-754 decimal 0.60s pauses merge for both words fallback and evidence.speech.
        for gapWords in [
            [("sw1", "speaker_1", 2.0, 4.0), ("sw2", "speaker_1", 4.5, 6.5)],
            [("gw1", "speaker_1", 2.0, 2.3), ("gw2", "speaker_1", 2.9, 4.7), ("gw3", "speaker_1", 5.0, 6.5)] // 2.3 + 0.6 < 2.9
        ] {
            let turn = TranscriptDocument.Turn(id: "turn_merge", speakerID: "speaker_1", start: 2.0, end: 6.5,
                                               wordIDs: gapWords.map(\.0))
            let mergeDoc = try document(secondary: .remote, wordIntervals: gapWords, turnsOverride: [turn])
            #expect(VoiceWindowSelector.select(turn: turn, source: source, document: mergeDoc,
                evidence: nil, actualFingerprint: fingerprint, purpose: .matching) ==
                .windows([.init(start: Double(expectedStart) / rate, end: Double(expectedEnd) / rate)]))

            let speechEvidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
                fingerprint: fingerprint, duration: 80,
                speech: gapWords.map { .init(start: $0.2, end: $0.3) }, overlap: [])
            #expect(VoiceWindowSelector.select(turn: turn, source: source, document: mergeDoc,
                evidence: speechEvidence, actualFingerprint: fingerprint, purpose: .matching) ==
                .windows([.init(start: Double(expectedStart) / rate, end: Double(expectedEnd) / rate)]))
        }

        // Gaps > 0.60s (0.70s) do not merge -> insufficientSpeech when no segment >= 3s.
        let splitWords: [(String, String, Double, Double)] = [
            ("sw1", "speaker_1", 2.0, 4.0),
            ("sw2", "speaker_1", 4.7, 6.5) // gap = 0.70s
        ]
        let splitTurn = TranscriptDocument.Turn(id: "turn_sw", speakerID: "speaker_1", start: 2.0, end: 6.5,
                                               wordIDs: ["sw1", "sw2"])
        let splitDoc = try document(secondary: .remote, wordIntervals: splitWords, turnsOverride: [splitTurn])
        #expect(VoiceWindowSelector.select(turn: splitTurn, source: source, document: splitDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .matching) == .refused(.insufficientSpeech))
        let splitSpeechEvidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80,
            speech: [.init(start: 2.0, end: 4.0), .init(start: 4.7, end: 6.5)], overlap: [])
        #expect(VoiceWindowSelector.select(turn: splitTurn, source: source, document: splitDoc,
            evidence: splitSpeechEvidence, actualFingerprint: fingerprint, purpose: .matching) == .refused(.insufficientSpeech))

        // Turn with empty words when evidence == nil -> missingEvidence.
        let emptyWordTurn = TranscriptDocument.Turn(id: "turn_empty", speakerID: "speaker_1", start: 10.0, end: 15.0, wordIDs: [])
        let emptyDoc = try document(secondary: .remote, wordIntervals: [], turnsOverride: [emptyWordTurn])
        #expect(VoiceWindowSelector.select(turn: emptyWordTurn, source: source, document: emptyDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .matching) == .refused(.missingEvidence))
    }

    @Test func learningTrimsKnownOverlapsAndKeepsDisjointAbsoluteWindows() throws {
        let document = try document(secondary: .host)
        let source = try #require(document.sources.first)
        let turn = try #require(document.turns.first)
        let evidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80, speech: [.init(start: 9, end: 23)], overlap: [])
        let windows: [VoiceAudioInterval] = [.init(start: 10.15, end: 14.9), .init(start: 16.1, end: 21.85)]
        for quality in [nil, evidence] {
            #expect(VoiceWindowSelector.select(turn: turn, source: source, document: document,
                evidence: quality, actualFingerprint: fingerprint, purpose: .learning) == .windows(windows))
        }
    }

    @Test(arguments: [
        (TranscriptDocument.ProcessingStatus.failed, Int?.none),
        (.disabled, nil),
        (.completed, 0)
    ])
    func matchingWordsFallbackRequiresConfirmedDiarization(status: TranscriptDocument.ProcessingStatus, voices: Int?) throws {
        let sources: [TranscriptDocument.Source] = [
            .init(id: .host, originalAudioPath: "raw/host.wav", recognitionAudioPath: "raw/host.wav",
                  diarizationStatus: status, detectedVoiceCount: voices, correctionStatus: .disabled)
        ]
        let speakers: [TranscriptDocument.Speaker] = [
            .init(id: "speaker_1", sourceID: .host, localID: 1, displayNumber: 1)
        ]
        let words: [TranscriptDocument.Word] = [
            .init(id: "w1", speakerID: "speaker_1", start: 0, end: 6, text: "Слово")
        ]
        let turns: [TranscriptDocument.Turn] = [
            .init(id: "t1", speakerID: "speaker_1", start: 0, end: 6, wordIDs: ["w1"])
        ]
        let doc = try TranscriptDocument(schemaVersion: 1, resultID: "result", createdAt: "2026-11-21T12:00:00Z",
            sources: sources, speakers: speakers, words: words, turns: turns, baselineWords: words,
            aec: .init(requested: false, outcome: .disabled),
            playback: .init(status: .unavailable, mixPath: nil),
            warnings: [.init(code: "test", message: "synthetic")])
        #expect(VoiceWindowSelector.select(turn: turns[0], source: sources[0], document: doc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .matching) == .refused(.missingEvidence))
    }

    @Test func matchingSafelyRefusesUnrepresentableFrameTimestampsWithoutTrapping() throws {
        let huge = 1e16
        let sources: [TranscriptDocument.Source] = [
            .init(id: .host, originalAudioPath: "raw/host.wav", recognitionAudioPath: "raw/host.wav",
                  diarizationStatus: .completed, detectedVoiceCount: 1, correctionStatus: .disabled)
        ]
        let speakers: [TranscriptDocument.Speaker] = [
            .init(id: "speaker_1", sourceID: .host, localID: 1, displayNumber: 1)
        ]
        let words: [TranscriptDocument.Word] = [
            .init(id: "w1", speakerID: "speaker_1", start: 0, end: huge, text: "Слово")
        ]
        let turns: [TranscriptDocument.Turn] = [
            .init(id: "t1", speakerID: "speaker_1", start: 0, end: huge, wordIDs: ["w1"])
        ]
        let doc = try TranscriptDocument(schemaVersion: 1, resultID: "result", createdAt: "2026-11-21T12:00:00Z",
            sources: sources, speakers: speakers, words: words, turns: turns, baselineWords: words,
            aec: .init(requested: false, outcome: .disabled),
            playback: .init(status: .unavailable, mixPath: nil),
            warnings: [.init(code: "test", message: "synthetic")])
        let evidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: "raw/host.wav",
            fingerprint: fingerprint, duration: huge, speech: [.init(start: 0, end: huge)], overlap: [])
        #expect(VoiceWindowSelector.select(turn: turns[0], source: sources[0], document: doc,
            evidence: evidence, actualFingerprint: fingerprint, purpose: .matching) == .refused(.insufficientSpeech))
        #expect(VoiceWindowSelector.select(turn: turns[0], source: sources[0], document: doc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .matching) == .refused(.insufficientSpeech))
    }

    @Test func learningUsesWordsFallbackAndClampsStretchedTrailingWordSilence() throws {
        // Part A: Without voice-quality.v1.json, .learning builds intervals from document.words and does not span a 2.0s pause.
        let cluster1: [(String, String, Double, Double)] = (0..<3).map { i in
            ("pw1_\(i)", "speaker_1", 0.5 + Double(i) * 0.5, 1.0 + Double(i) * 0.5)
        }
        let cluster2: [(String, String, Double, Double)] = (0..<10).map { i in
            ("pw2_\(i)", "speaker_1", 4.0 + Double(i) * 0.5, 4.5 + Double(i) * 0.5)
        }
        let pausedWords = cluster1 + cluster2
        let pausedTurn = TranscriptDocument.Turn(id: "turn_paused", speakerID: "speaker_1", start: 0.0, end: 12.0,
                                                 wordIDs: pausedWords.map(\.0))
        let pausedDoc = try document(secondary: .remote, wordIntervals: pausedWords, turnsOverride: [pausedTurn])
        let source = try #require(pausedDoc.sources.first)
        #expect(VoiceWindowSelector.select(turn: pausedTurn, source: source, document: pausedDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .learning) == .windows([.init(start: 4.0, end: 9.0)]))

        // Part B: Empty words with evidence == nil -> .refused(.missingEvidence).
        let emptyTurn = TranscriptDocument.Turn(id: "turn_empty_l", speakerID: "speaker_1", start: 0.0, end: 12.0, wordIDs: [])
        let emptyDoc = try document(secondary: .remote, wordIntervals: [], turnsOverride: [emptyTurn])
        #expect(VoiceWindowSelector.select(turn: emptyTurn, source: source, document: emptyDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .learning) == .refused(.missingEvidence))

        // Part C: Multi-word turn with stretched trailing CTC word "быстренько. Ты" [0.40, 28.80] clamps trailing silence -> <3s.
        let stretchedWords: [(String, String, Double, Double)] = [
            ("sw1", "speaker_1", 0.0, 0.38),
            ("sw2", "speaker_1", 0.40, 28.80)
        ]
        let stretchedTurn = TranscriptDocument.Turn(id: "turn_stretched", speakerID: "speaker_1", start: 0.0, end: 28.80,
                                                    wordIDs: ["sw1", "sw2"])
        let stretchedDoc = try document(secondary: .remote, wordIntervals: stretchedWords, turnsOverride: [stretchedTurn])
        for purpose in [VoiceWindowSelector.Purpose.matching, .learning] {
            #expect(VoiceWindowSelector.select(turn: stretchedTurn, source: source, document: stretchedDoc,
                evidence: nil, actualFingerprint: fingerprint, purpose: purpose) == .refused(.insufficientSpeech))
        }

        // Part D: 6 dense words across [0.0, 4.0] + stretched trailing word "колобой." [4.0, 16.0]
        // -> .matching stays within [0.15, 5.5] (NOT centered in silent tail [7, 13]).
        var mixedWords: [(String, String, Double, Double)] = (0..<6).map { i in
            ("mw\(i)", "speaker_1", Double(i) * 0.65, Double(i + 1) * 0.65)
        }
        mixedWords.append(("mw_tail", "speaker_1", 4.0, 16.0))
        let mixedTurn = TranscriptDocument.Turn(id: "turn_mixed", speakerID: "speaker_1", start: 0.0, end: 16.0,
                                                wordIDs: mixedWords.map(\.0))
        let mixedDoc = try document(secondary: .remote, wordIntervals: mixedWords, turnsOverride: [mixedTurn])
        let selection = VoiceWindowSelector.select(turn: mixedTurn, source: source, document: mixedDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .matching)
        guard case .windows(let selected) = selection, let win = selected.first else {
            Issue.record("Expected clean speech window before clamped tail, got \(selection)")
            return
        }
        #expect(win.start >= 0.15 && win.end <= 5.5 + 1e-6)
    }

    @Test func learningRetainsStrictPauseGapsWhileMatchingBridgesShortPauses() throws {
        // 0.30s speech pause merges in .matching (maxGap = 0.60) but stays split in .learning (maxGap = 0.0).
        let speechWords: [(String, String, Double, Double)] = [
            ("w1", "speaker_1", 2.0, 4.0),
            ("w2", "speaker_1", 4.3, 6.5)
        ]
        let speechTurn = TranscriptDocument.Turn(id: "turn_sp", speakerID: "speaker_1", start: 2.0, end: 6.5, wordIDs: ["w1", "w2"])
        let speechDoc = try document(secondary: .remote, wordIntervals: speechWords, turnsOverride: [speechTurn])
        let source = try #require(speechDoc.sources.first)
        let speechEvidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80,
            speech: [.init(start: 2.0, end: 4.0), .init(start: 4.3, end: 6.5)], overlap: [])
        #expect(VoiceWindowSelector.select(turn: speechTurn, source: source, document: speechDoc,
            evidence: speechEvidence, actualFingerprint: fingerprint, purpose: .learning) == .refused(.insufficientSpeech))
        guard case .windows(let matchedSpeech) = VoiceWindowSelector.select(turn: speechTurn, source: source, document: speechDoc,
            evidence: speechEvidence, actualFingerprint: fingerprint, purpose: .matching), matchedSpeech.count == 1 else {
            Issue.record("Expected merged window for .matching on 0.30s speech gap")
            return
        }

        // 0.50s word pause merges in .matching (maxGap = 0.60) but stays split in .learning (maxGap = 0.40).
        let fallbackWords: [(String, String, Double, Double)] = [
            ("fw1", "speaker_1", 2.0, 4.0),
            ("fw2", "speaker_1", 4.5, 6.5)
        ]
        let fallbackTurn = TranscriptDocument.Turn(id: "turn_fb", speakerID: "speaker_1", start: 2.0, end: 6.5, wordIDs: ["fw1", "fw2"])
        let fallbackDoc = try document(secondary: .remote, wordIntervals: fallbackWords, turnsOverride: [fallbackTurn])
        #expect(VoiceWindowSelector.select(turn: fallbackTurn, source: source, document: fallbackDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .learning) == .refused(.insufficientSpeech))
        guard case .windows(let matchedFallback) = VoiceWindowSelector.select(turn: fallbackTurn, source: source, document: fallbackDoc,
            evidence: nil, actualFingerprint: fingerprint, purpose: .matching), matchedFallback.count == 1 else {
            Issue.record("Expected merged window for .matching on 0.50s words gap")
            return
        }
    }

    @Test func extractMatchingSubwindowsSplitsLongAndDisjointSegments() throws {
        let short = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 16_000, end: 96_000)], maxWindows: 3)
        #expect(short.map(\.start) == [16_000] && short.map(\.end) == [96_000])

        let tenSeconds = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 160_000)], maxWindows: 3)
        #expect(tenSeconds.map(\.start) == [0, 80_000] && tenSeconds.map(\.end) == [80_000, 160_000])

        let fourteenSeconds = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 224_000)], maxWindows: 3)
        #expect(fourteenSeconds.map(\.start) == [16_000, 112_000] && fourteenSeconds.map(\.end) == [112_000, 208_000])

        let twentyFiveSeconds = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 400_000)], maxWindows: 3)
        #expect(twentyFiveSeconds.map(\.start) == [8_000, 104_000, 296_000] &&
                twentyFiveSeconds.map(\.end) == [104_000, 200_000, 392_000])

        // Two disjoint clean segments separated by a 0.8s speech pause return both segments.
        let words: [(String, String, Double, Double)] = [
            ("a1", "speaker_1", 10.0, 21.0)
        ]
        let turn = TranscriptDocument.Turn(id: "t_disjoint", speakerID: "speaker_1", start: 10.0, end: 21.0, wordIDs: ["a1"])
        let doc = try document(secondary: .remote, wordIntervals: words, turnsOverride: [turn])
        let source = try #require(doc.sources.first)
        let evidence = VoiceAudioQuality.Source(id: .host, recognitionAudioPath: source.recognitionAudioPath,
            fingerprint: fingerprint, duration: 80,
            speech: [.init(start: 10.0, end: 15.0), .init(start: 15.8, end: 21.0)], overlap: [])
        let candidates = try VoiceWindowSelector.matchingCandidateFrames(
            turn: turn, source: source, document: doc, evidence: evidence, actualFingerprint: fingerprint
        ).get()
        #expect(candidates.count == 2)
        let subwindows = VoiceWindowSelector.extractMatchingSubwindows(from: candidates, maxWindows: 3)
        #expect(subwindows.count == 2)

        // Direct boundary checks: intervals < 48_000 frames must be filtered out for both maxWindows: 1 and maxWindows: 3.
        #expect(VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 47_999)], maxWindows: 1).isEmpty)
        #expect(VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 47_999)], maxWindows: 3).isEmpty)
        let exactMin1 = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 48_000)], maxWindows: 1)
        #expect(exactMin1.map(\.start) == [0] && exactMin1.map(\.end) == [48_000])
        let exactMin3 = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 48_000)], maxWindows: 3)
        #expect(exactMin3.map(\.start) == [0] && exactMin3.map(\.end) == [48_000])
        let exactMax1 = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 96_000)], maxWindows: 1)
        #expect(exactMax1.map(\.start) == [0] && exactMax1.map(\.end) == [96_000])
        let exactMax3 = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 96_000)], maxWindows: 3)
        #expect(exactMax3.map(\.start) == [0] && exactMax3.map(\.end) == [96_000])
        let mixed = VoiceWindowSelector.extractMatchingSubwindows(from: [(start: 0, end: 47_999), (start: 100_000, end: 148_000)], maxWindows: 1)
        #expect(mixed.map(\.start) == [100_000] && mixed.map(\.end) == [148_000])
    }
}
