import Foundation

/// Fast interval index for transcript playback, seeking, and autoscroll targeting.
///
/// Intervals are half-open `[start, end)`:
/// - A turn or word is active at timestamp `t` iff `start <= t && t < end`.
/// - Start is inclusive; end is exclusive.
/// - Zero-duration intervals (`start == end`) are never active at any timestamp.
/// - Active items are always returned in original display order (matching document order).
public struct TranscriptIntervalIndex: Sendable {
    public let turns: [TranscriptDocument.Turn]
    public let words: [TranscriptDocument.Word]

    private let turnTree: [IntervalNode]
    private let wordTree: [IntervalNode]

    public init(document: TranscriptDocument) {
        self.init(turns: document.turns, words: document.words)
    }

    public init(turns: [TranscriptDocument.Turn], words: [TranscriptDocument.Word] = []) {
        self.turns = turns
        self.words = words

        let turnItems = turns.enumerated().map { (displayIndex: $0.offset, start: $0.element.start, end: $0.element.end) }
        self.turnTree = Self.buildTree(items: turnItems)

        let wordItems = words.enumerated().map { (displayIndex: $0.offset, start: $0.element.start, end: $0.element.end) }
        self.wordTree = Self.buildTree(items: wordItems)
    }

    // MARK: - Query Turns

    /// Returns all turns active at `timestamp`, preserving their original display order.
    public func activeTurns(at timestamp: Double) -> [TranscriptDocument.Turn] {
        let indices = activeTurnIndices(at: timestamp)
        return indices.map { turns[$0] }
    }

    /// Returns the first active turn in display order at `timestamp`, suitable for autoscroll targeting.
    public func firstActiveTurn(at timestamp: Double) -> TranscriptDocument.Turn? {
        guard let firstIndex = activeTurnIndices(at: timestamp).first else { return nil }
        return turns[firstIndex]
    }

    /// Returns IDs of all active turns at `timestamp` in display order.
    public func activeTurnIDs(at timestamp: Double) -> [String] {
        activeTurns(at: timestamp).map(\.id)
    }

    /// Returns ID of the first active turn in display order at `timestamp`.
    public func firstActiveTurnID(at timestamp: Double) -> String? {
        firstActiveTurn(at: timestamp)?.id
    }

    /// Returns original display indices of all active turns at `timestamp`.
    public func activeTurnIndices(at timestamp: Double) -> [Int] {
        Self.searchTree(nodes: turnTree, at: timestamp)
    }

    // MARK: - Query Words

    /// Returns all words active at `timestamp`, preserving their original display order.
    public func activeWords(at timestamp: Double) -> [TranscriptDocument.Word] {
        let indices = Self.searchTree(nodes: wordTree, at: timestamp)
        return indices.map { words[$0] }
    }

    /// Returns the first active word in display order at `timestamp`.
    public func firstActiveWord(at timestamp: Double) -> TranscriptDocument.Word? {
        guard let firstIndex = Self.searchTree(nodes: wordTree, at: timestamp).first else { return nil }
        return words[firstIndex]
    }

    // MARK: - Internal Interval Tree

    private struct IntervalNode: Sendable {
        let displayIndex: Int
        let start: Double
        let end: Double
        var maxEnd: Double
        var leftIndex: Int?
        var rightIndex: Int?
    }

    private static func buildTree(
        items: [(displayIndex: Int, start: Double, end: Double)]
    ) -> [IntervalNode] {
        let validItems = items.filter { $0.start.isFinite && $0.end.isFinite && $0.start < $0.end }
        guard !validItems.isEmpty else { return [] }

        let sorted = validItems.sorted {
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            return $0.displayIndex < $1.displayIndex
        }

        var nodes: [IntervalNode] = []
        nodes.reserveCapacity(sorted.count)

        func buildSubtree(low: Int, high: Int) -> Int? {
            guard low <= high else { return nil }
            let mid = low + (high - low) / 2
            let item = sorted[mid]

            let nodeIndex = nodes.count
            nodes.append(IntervalNode(
                displayIndex: item.displayIndex,
                start: item.start,
                end: item.end,
                maxEnd: item.end,
                leftIndex: nil,
                rightIndex: nil
            ))

            let left = buildSubtree(low: low, high: mid - 1)
            let right = buildSubtree(low: mid + 1, high: high)

            var maxEnd = item.end
            if let left = left {
                maxEnd = max(maxEnd, nodes[left].maxEnd)
            }
            if let right = right {
                maxEnd = max(maxEnd, nodes[right].maxEnd)
            }

            nodes[nodeIndex].leftIndex = left
            nodes[nodeIndex].rightIndex = right
            nodes[nodeIndex].maxEnd = maxEnd

            return nodeIndex
        }

        _ = buildSubtree(low: 0, high: sorted.count - 1)
        return nodes
    }

    private static func searchTree(
        nodes: [IntervalNode],
        at timestamp: Double
    ) -> [Int] {
        guard timestamp.isFinite, timestamp >= 0, !nodes.isEmpty else { return [] }
        var matchedDisplayIndices: [Int] = []

        func search(nodeIndex: Int) {
            let node = nodes[nodeIndex]
            if timestamp >= node.maxEnd {
                return
            }

            if let left = node.leftIndex, nodes[left].maxEnd > timestamp {
                search(nodeIndex: left)
            }

            if node.start <= timestamp && timestamp < node.end {
                matchedDisplayIndices.append(node.displayIndex)
            }

            if timestamp >= node.start, let right = node.rightIndex, nodes[right].maxEnd > timestamp {
                search(nodeIndex: right)
            }
        }

        search(nodeIndex: 0)
        matchedDisplayIndices.sort()
        return matchedDisplayIndices
    }
}

// MARK: - Equatable & Convenience extensions for TranscriptDocument types

extension TranscriptDocument.Turn: Equatable {
    public init(
        id: String,
        speakerID: String,
        start: Double,
        end: Double
    ) {
        self.init(id: id, speakerID: speakerID, start: start, end: end, wordIDs: [])
    }

    public static func == (lhs: TranscriptDocument.Turn, rhs: TranscriptDocument.Turn) -> Bool {
        lhs.id == rhs.id &&
        lhs.speakerID == rhs.speakerID &&
        lhs.start == rhs.start &&
        lhs.end == rhs.end &&
        lhs.wordIDs == rhs.wordIDs
    }
}

extension TranscriptDocument.Word: Equatable {
    public static func == (lhs: TranscriptDocument.Word, rhs: TranscriptDocument.Word) -> Bool {
        lhs.id == rhs.id &&
        lhs.speakerID == rhs.speakerID &&
        lhs.start == rhs.start &&
        lhs.end == rhs.end &&
        lhs.text == rhs.text
    }
}
