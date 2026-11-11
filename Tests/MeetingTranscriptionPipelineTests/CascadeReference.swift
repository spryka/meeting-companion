// Frozen native cascade from 35d00b8: independent differential oracle.
import Foundation
@testable import MeetingTranscriptionPipeline

enum CascadeReference {
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

}
