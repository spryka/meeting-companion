import Foundation

public enum PipelineLogic {
    public static func assemble(
        _ tokens: [ASRToken],
        start: Double,
        end: Double,
        last: Bool
    ) throws -> [PipelineWord] {
        var result: [PipelineWord] = []
        var previous = -Double.infinity
        for token in tokens {
            guard token.start.isFinite, token.end.isFinite, token.start >= 0,
                  token.start >= previous, token.start <= end - start,
                  token.end >= token.start, token.end <= end - start + 0.15 else {
                throw PipelineError("invalid token timestamp")
            }
            previous = token.start
            let at = start + token.start
            // Preserve Python's absolute-time arithmetic for GigaAM, including floating-point rounding.
            let until = token.frame == 0 ? min(end, start + token.end) : min(end, at + 0.1)
            if result.isEmpty || token.piece.hasPrefix("\u{2581}") || token.piece.hasPrefix(" ") {
                result.append(PipelineWord(start: at, end: until, text: ""))
            }
            result[result.count - 1].text += token.piece.replacingOccurrences(of: "\u{2581}", with: " ")
            result[result.count - 1].end = max(result.last!.end, until)
        }
        let lower = start == 0 ? 0 : start + 0.5
        let upper = last ? end + 0.1 : start + 24.5
        return result.map { var w = $0; w.text = w.text.trimmingCharacters(in: .whitespaces); return w }
            .filter { !$0.text.isEmpty && lower <= $0.start && $0.start < upper }
    }

    public static func windows(_ samples: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for start in stride(from: 0, to: samples, by: 384_000) {
            let end = min(start + 400_000, samples)
            result.append(start..<end)
            if end == samples { break }
        }
        return result
    }

    public static func mask(_ samples: Int, _ speech: [Range<Int>]) -> [Bool] {
        windows(samples).map { window in
            speech.contains { range in
                max(window.lowerBound, range.lowerBound) < min(window.upperBound, range.upperBound)
            }
        }
    }

    private static func round3(_ value: Double) -> Double {
        (value * 1000.0).rounded() / 1000.0
    }

    private static func norm(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let mapped = folded.map { char -> Character in
            if char == "ё" { return "е" }
            if char.isLetter || char.isNumber { return char }
            return " "
        }
        return String(mapped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func phoneticDistance(_ a: String, _ b: String) -> Double {
        let left = Array(norm(a))
        let right = Array(norm(b))
        if left.isEmpty || right.isEmpty {
            return left == right ? 0.0 : 1.0
        }
        let m = left.count
        let n = right.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
            }
        }
        let dist = dp[m][n]
        return Double(dist) / Double(max(m, n))
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        max(0.0, 1.0 - phoneticDistance(a, b))
    }

    private static let stopWords: Set<String> = [
        "и", "в", "не", "на", "я", "быть", "он", "с", "что", "а", "по", "это", "она", "этот", "к", "но", "они", "мы", "как", "из",
        "у", "который", "то", "за", "свой", "что", "еще", "для", "мочь", "человек", "такой", "его", "о", "же", "себя", "сказать",
        "этот", "от", "бы", "вы", "все", "до", "время", "если", "год", "так", "его", "один", "кто", "еще", "да", "она", "о",
        "из-за", "про", "тот", "когда", "очень", "даже", "тут", "там", "ну", "вот", "же", "ли"
    ]

    public static func cascade(
        _ gigaam: [PipelineWord],
        _ parakeet: [PipelineWord]
    ) -> ([PipelineWord], [Suggestion]) {
        let g = gigaam.sorted { $0.start < $1.start }
        let p = parakeet.sorted { $0.start < $1.start }
        let stop = stopWords
        var rows: [Suggestion] = []

        for i in 0..<g.count {
            for n in 1...min(4, g.count - i) {
                let source = Array(g[i..<(i + n)])
                guard source.allSatisfy({ $0.speaker == source[0].speaker }) else { continue }
                let original = source.map(\.text).joined(separator: " ")
                for j in 0..<p.count {
                    for m in 1...min(4, p.count - j) {
                        let donor = Array(p[j..<(j + m)])
                        let overlap = min(source.last!.end, donor.last!.end) - max(source[0].start, donor[0].start)
                        if overlap > 0.05 {
                            let proposed = donor.map(\.text).joined(separator: " ")
                            let originalTokens = original.split(whereSeparator: \.isWhitespace).map { norm(String($0)) }
                            let proposedTokens = proposed.split(whereSeparator: \.isWhitespace).map { norm(String($0)) }
                            var allowed = true
                            if originalTokens.count == proposedTokens.count {
                                for (o, pr) in zip(originalTokens, proposedTokens) {
                                    if !stop.contains(o) && (pr.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil || similarity(o, pr) >= 0.5) {
                                        continue
                                    }
                                    if o == pr { continue }
                                    allowed = false
                                    break
                                }
                            } else {
                                allowed = proposed.range(of: "^[a-zA-Z0-9_ -]+$", options: .regularExpression) != nil
                            }
                            if !allowed || original.range(of: "\\d", options: .regularExpression) != nil || similarity(original, proposed) < 0.4 {
                                continue
                            }
                            let union = max(source.last!.end, donor.last!.end) - min(source[0].start, donor[0].start)
                            let protected = original.split(whereSeparator: \.isWhitespace).contains { stop.contains(norm(String($0))) }
                            rows.append(Suggestion(
                                start: source[0].start,
                                end: source.last!.end,
                                original: original,
                                proposed: proposed,
                                score: round3(similarity(original, proposed)),
                                donor_start: donor[0].start,
                                donor_end: donor.last!.end,
                                source_indices: [i, i + n],
                                donor_indices: [j, j + m],
                                time_overlap: round3(overlap / union),
                                applied: false,
                                reason: protected ? "protected_word" : "candidate"
                            ))
                        }
                    }
                }
            }
        }
        func key(_ r: Suggestion) -> [Double] {
            [similarity(r.original, r.proposed), r.time_overlap, Double(r.source_indices[0]), Double(r.source_indices[1] - r.source_indices[0]), Double(r.donor_indices[0]), Double(r.donor_indices[1] - r.donor_indices[0])]
        }
        let candidates = rows.indices.filter { rows[$0].reason == "candidate" }.sorted { key(rows[$1]).lexicographicallyPrecedes(key(rows[$0])) }
        var selected: [Int] = []
        for index in candidates {
            let row = rows[index]
            let conflict = selected.contains(where: { other in
                let other = rows[other]
                return max(row.source_indices[0], other.source_indices[0]) < min(row.source_indices[1], other.source_indices[1]) ||
                    max(row.donor_indices[0], other.donor_indices[0]) < min(row.donor_indices[1], other.donor_indices[1])
            })
            if conflict { rows[index].reason = "conflict"; continue }
            if selected.contains(where: { (row.source_indices[0] - rows[$0].source_indices[0]) * (row.donor_indices[0] - rows[$0].donor_indices[0]) < 0 }) {
                rows[index].reason = "crossing_alignment"; continue
            }
            rows[index].applied = true
            rows[index].reason = "phonetic"
            selected.append(index)
        }
        let byStart = Dictionary(uniqueKeysWithValues: selected.map { (rows[$0].source_indices[0], rows[$0]) })
        var corrected: [PipelineWord] = []
        var i = 0
        while i < g.count {
            if let row = byStart[i] {
                var word = g[i]
                word.text = row.proposed
                word.end = row.end
                corrected.append(word)
                i = row.source_indices[1]
            } else {
                corrected.append(g[i])
                i += 1
            }
        }
        let sortedSuggestions = rows.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        return (corrected, sortedSuggestions)
    }

    public static func assign(_ words: [PipelineWord], _ intervals: [DiarizationInterval]) -> [PipelineWord] {
        let sorted = intervals.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var labels: [Int: Int] = [:]
        return words.map { word in
            var totals: [Int: Double] = [:]
            var order: [Int] = []
            for seg in sorted {
                let overlap = min(word.end, seg.end) - max(word.start, seg.start)
                if overlap > 0 {
                    if totals[seg.speaker] == nil { order.append(seg.speaker) }
                    totals[seg.speaker, default: 0] += overlap
                }
            }
            var best = order.first ?? 0
            for speaker in order where totals[speaker]! > (totals[best] ?? 0) {
                best = speaker
            }
            if order.isEmpty && !sorted.isEmpty {
                let candidates = sorted.enumerated().flatMap { i, s in
                    [(abs(s.start - word.start), i), (abs(s.end - word.end), i)]
                }
                if let nearest = candidates.min(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
                    best = sorted[nearest.1].speaker
                }
            }
            if labels[best] == nil { labels[best] = labels.count + 1 }
            var result = word
            result.speaker = labels[best]
            return result
        }
    }

    public static func groupTurns(_ words: [PipelineWord], _ externalBreaks: [Double] = []) -> [PipelineWord] {
        guard !words.isEmpty else { return [] }
        let sorted = words.sorted { $0.start < $1.start }
        var result: [PipelineWord] = []
        var current: [PipelineWord] = []

        func flush() {
            guard !current.isEmpty else { return }
            let text = current.map(\.text).joined(separator: " ")
            let start = current[0].start
            let end = current.last!.end
            let speaker = current[0].speaker
            result.append(PipelineWord(start: start, end: end, text: text, speaker: speaker))
            current.removeAll()
        }

        for word in sorted {
            if current.isEmpty {
                current.append(word)
                continue
            }
            let prev = current.last!
            let speakerChanged = (word.speaker != prev.speaker)
            let pause = word.start - prev.end
            let pauseCut = pause >= 2.0
            let duration = word.end - current[0].start
            let durationExceeded = duration > 30.0
            let punctuationCut = duration >= 15.0 && [".", "!", "?", "…"].contains { prev.text.hasSuffix($0) }
            let externalCut = externalBreaks.contains { $0 > current[0].start && $0 <= word.start }

            if speakerChanged || pauseCut || durationExceeded || punctuationCut || externalCut {
                flush()
            }
            current.append(word)
        }
        flush()
        return result
    }

    public static func groupTurnIndices(_ words: [PipelineWord]) -> [[Int]] {
        guard !words.isEmpty else { return [] }
        var groups: [[Int]] = []
        var current: [Int] = []

        for (idx, word) in words.enumerated() {
            if current.isEmpty {
                current.append(idx)
                continue
            }
            let prevIdx = current.last!
            let prev = words[prevIdx]
            let speakerChanged = (word.speaker != prev.speaker)
            let pause = word.start - prev.end
            let pauseCut = pause >= 2.0
            let duration = word.end - words[current[0]].start
            let durationExceeded = duration > 30.0
            let punctuationCut = duration >= 15.0 && [".", "!", "?", "…"].contains { prev.text.hasSuffix($0) }

            if speakerChanged || pauseCut || durationExceeded || punctuationCut {
                groups.append(current)
                current = [idx]
            } else {
                current.append(idx)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    public static func mergeTwoChannels(
        host: [PipelineWord],
        remote: [PipelineWord]
    ) -> [PipelineWord] {
        let hostSpeakers = Set(host.compactMap(\.speaker) + [1])
        let offset = hostSpeakers.max() ?? 1

        let hostSorted = host.sorted { $0.start < $1.start }
        let remoteOffset = remote.map { w -> PipelineWord in
            var w = w
            w.speaker = (w.speaker ?? 1) + offset
            return w
        }.sorted { $0.start < $1.start }

        let breaks = (groupTurns(hostSorted) + groupTurns(remoteOffset)).map(\.start)
        let hostTurns = groupTurns(hostSorted, breaks)
        let remoteTurns = groupTurns(remoteOffset, breaks)
        var combined = hostTurns + remoteTurns
        combined.sort { a, b in
            if a.start != b.start {
                return a.start < b.start
            }
            return (a.speaker ?? 1) < (b.speaker ?? 1)
        }
        return combined
    }
}
