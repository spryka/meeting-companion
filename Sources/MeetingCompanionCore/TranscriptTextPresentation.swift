import Foundation

/// Automatic continuation marks belong to reading/export, never to edit drafts.
public struct TranscriptTextPresentation: Sendable {
    public let editableText: [String: String]
    public let readingText: [String: String]

    public init(document: TranscriptDocument, overrides: [String: TranscriptTurnOverride] = [:]) {
        let words = Dictionary(uniqueKeysWithValues: document.words.map { ($0.id, $0) })
        let original = Dictionary(uniqueKeysWithValues: document.turns.map { turn in
            (turn.id, turn.wordIDs.compactMap { words[$0]?.text }.joined(separator: " "))
        })
        var editable = original
        for turn in document.turns {
            if let text = overrides[turn.id]?.text { editable[turn.id] = text }
        }
        editableText = editable
        var reading = editable
        var owner: [String: Int] = [:]
        for (index, turn) in document.turns.enumerated() {
            for id in turn.wordIDs { owner[id] = index }
        }
        let bySpeaker = Dictionary(grouping: document.words.enumerated(), by: { $0.element.speakerID })
        for speakerWords in bySpeaker.values {
            let ordered = speakerWords.sorted {
                $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
            }.map(\.element)
            for group in TranscriptParagraphs.groupWordIndices(ordered) {
                let ids = group.map { ordered[$0].id }
                let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
                var fragments: [Int] = []
                for id in ids {
                    if let index = owner[id], fragments.last != index { fragments.append(index) }
                }
                func containedRange(_ turn: TranscriptDocument.Turn) -> Range<Int>? {
                    guard let firstID = turn.wordIDs.first, let first = positions[firstID] else { return nil }
                    let end = first + turn.wordIDs.count
                    guard end <= ids.count, Array(ids[first..<end]) == turn.wordIDs else { return nil }
                    return first..<end
                }
                for (left, right) in zip(fragments, fragments.dropFirst()) {
                    let before = document.turns[left]
                    let after = document.turns[right]
                    // A later legacy/duration boundary must not invalidate an earlier exact pair.
                    guard right > left + 1,
                          let beforeRange = containedRange(before), let afterRange = containedRange(after),
                          beforeRange.upperBound == afterRange.lowerBound,
                          document.turns[(left + 1)..<right].allSatisfy({ $0.speakerID != before.speakerID }),
                          let lastID = before.wordIDs.last, let last = words[lastID] else { continue }
                    let stripped = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let existingEllipsis = stripped.hasSuffix("…") || stripped.hasSuffix("...")
                    guard existingEllipsis || !TranscriptParagraphs.endsSentence(last.text) else { continue }
                    if overrides[before.id]?.text == nil, !existingEllipsis {
                        reading[before.id, default: ""] += "…"
                    }
                    if overrides[after.id]?.text == nil, let text = reading[after.id],
                       !text.hasPrefix("…"), !text.hasPrefix("...") {
                        reading[after.id] = "…" + text
                    }
                }
            }
        }
        readingText = reading
    }
}
