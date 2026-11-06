import Foundation

/// Shared word-boundary rules for new turns and display-only continuations.
public enum TranscriptParagraphs {
    public static func endsSentence(_ text: String) -> Bool {
        let closing = CharacterSet(charactersIn: "\"'»”’“)]} ").union(.whitespacesAndNewlines)
        let stripped = text.trimmingCharacters(in: closing)
        return [".", "!", "?", "…"].contains { stripped.hasSuffix($0) }
    }

    public static func shouldBreak(start: Double, previousEnd: Double, previousText: String,
                                   nextStart: Double, nextEnd: Double) -> Bool {
        let duration = nextEnd - start
        return nextStart - previousEnd >= 1.5 || duration > 30
            || (duration >= 15 && endsSentence(previousText))
    }

    /// Input is already in reading order; speaker IDs retain source ownership.
    public static func groupWordIndices(_ words: [TranscriptDocument.Word]) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        for (index, word) in words.enumerated() {
            if let previousIndex = current.last, let firstIndex = current.first {
                let previous = words[previousIndex]
                if word.speakerID != previous.speakerID || shouldBreak(
                    start: words[firstIndex].start, previousEnd: previous.end, previousText: previous.text,
                    nextStart: word.start, nextEnd: word.end
                ) {
                    groups.append(current)
                    current = []
                }
            }
            current.append(index)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
