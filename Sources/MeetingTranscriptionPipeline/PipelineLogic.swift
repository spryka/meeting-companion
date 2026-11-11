import Foundation
import MeetingCompanionCore

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

    static func speechMask(_ samples: Int, _ intervals: [DiarizationInterval], status: TranscriptDocument.ProcessingStatus) -> [Bool] {
        windows(samples).map { window in
            status != .completed || intervals.isEmpty || intervals.contains { interval in
                max(Double(window.lowerBound) / 16000, interval.start)
                    < min(Double(window.upperBound) / 16000, interval.end)
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
        return phoneticDistance(left, right)
    }

    private static func phoneticDistance(_ left: [Character], _ right: [Character]) -> Double {
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
        guard !g.isEmpty && !p.isEmpty else { return (g, []) }
        struct Fragment {
            let text: String
            let tokens: [String]
            let tokenCharacters: [[Character]]
            let normalized: [Character]
            let latinTokens: [Bool]
            let latinPhrase: Bool

            init(_ words: ArraySlice<PipelineWord>) {
                text = words.map(\.text).joined(separator: " ")
                tokens = text.split(whereSeparator: \.isWhitespace).map { PipelineLogic.norm(String($0)) }
                // Token similarity normalizes the already-normalized tokens again.
                tokenCharacters = tokens.map { Array(PipelineLogic.norm($0)) }
                normalized = Array(PipelineLogic.norm(text))
                latinTokens = tokens.map { $0.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil }
                latinPhrase = text.range(of: "^[a-zA-Z0-9_ -]+$", options: .regularExpression) != nil
            }
        }
        let donors = p.indices.map { j in
            (1...min(4, p.count - j)).map { Fragment(p[j..<(j + $0)]) }
        }
        // Ends need not be monotonic; a donor may end up to three words after its start.
        var prefixEnds: [Double] = []
        for word in p { prefixEnds.append(max(prefixEnds.last ?? -.infinity, word.end)) }
        let stop = stopWords
        var rows: [Suggestion] = []
        var similarities: [Double] = []

        for i in 0..<g.count {
            for n in 1...min(4, g.count - i) {
                let source = g[i..<(i + n)]
                guard source.allSatisfy({ $0.speaker == g[i].speaker }) else { continue }
                let fragment = Fragment(source)
                let original = fragment.text
                if original.range(of: "\\d", options: .regularExpression) != nil { continue }
                let protected = fragment.tokens.contains { stop.contains($0) }
                var low = 0, high = p.count
                while low < high {
                    let mid = (low + high) / 2
                    if prefixEnds[mid] <= g[i].start { low = mid + 1 } else { high = mid }
                }
                let first = max(0, low - 3)
                low = 0; high = p.count
                while low < high {
                    let mid = (low + high) / 2
                    if p[mid].start < source.last!.end { low = mid + 1 } else { high = mid }
                }
                guard first < low else { continue }
                for j in first..<low {
                    for m in 1...min(4, p.count - j) {
                        let donorEnd = p[j + m - 1].end
                        let overlap = min(source.last!.end, donorEnd) - max(g[i].start, p[j].start)
                        if overlap > 0.05 {
                            let donor = donors[j][m - 1]
                            let proposed = donor.text
                            var allowed = true
                            if fragment.tokens.count == donor.tokens.count {
                                for k in fragment.tokens.indices {
                                    let o = fragment.tokens[k], pr = donor.tokens[k]
                                    if !stop.contains(o) && (donor.latinTokens[k] || max(0.0, 1.0 - phoneticDistance(fragment.tokenCharacters[k], donor.tokenCharacters[k])) >= 0.5) {
                                        continue
                                    }
                                    if o == pr { continue }
                                    allowed = false
                                    break
                                }
                            } else {
                                allowed = donor.latinPhrase
                            }
                            if !allowed { continue }
                            let similarity = max(0.0, 1.0 - phoneticDistance(fragment.normalized, donor.normalized))
                            if similarity < 0.4 { continue }
                            let union = max(source.last!.end, donorEnd) - min(g[i].start, p[j].start)
                            rows.append(Suggestion(
                                start: g[i].start,
                                end: source.last!.end,
                                original: original,
                                proposed: proposed,
                                score: round3(similarity),
                                donor_start: p[j].start,
                                donor_end: donorEnd,
                                source_indices: [i, i + n],
                                donor_indices: [j, j + m],
                                time_overlap: round3(overlap / union),
                                applied: false,
                                reason: protected ? "protected_word" : "candidate"
                            ))
                            similarities.append(similarity)
                        }
                    }
                }
            }
        }
        func key(_ index: Int) -> [Double] {
            let r = rows[index]
            return [similarities[index], r.time_overlap, Double(r.source_indices[0]), Double(r.source_indices[1] - r.source_indices[0]), Double(r.donor_indices[0]), Double(r.donor_indices[1] - r.donor_indices[0])]
        }
        let keys = rows.indices.map(key)
        let candidates = rows.indices.filter { rows[$0].reason == "candidate" }.sorted { keys[$1].lexicographicallyPrecedes(keys[$0]) }
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
            let end = current.map(\.end).max()!
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
            let boundaryCut = TranscriptParagraphs.shouldBreak(
                start: current[0].start, previousEnd: prev.end, previousText: prev.text,
                nextStart: word.start, nextEnd: word.end
            )
            let externalCut = externalBreaks.contains { $0 > current[0].start && $0 <= word.start }

            if speakerChanged || boundaryCut || externalCut {
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
            let boundaryCut = TranscriptParagraphs.shouldBreak(
                start: words[current[0]].start, previousEnd: prev.end, previousText: prev.text,
                nextStart: word.start, nextEnd: word.end
            )

            if speakerChanged || boundaryCut {
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

        return groupTurns(hostSorted + remoteOffset)
    }
}
