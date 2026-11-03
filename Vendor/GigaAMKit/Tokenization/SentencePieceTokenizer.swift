import Foundation

public final class SentencePieceTokenizer: @unchecked Sendable {
    private struct VocabularyFile: Decodable {
        let pieces: [String]
        let unkId: Int?
        let bosId: Int?
        let eosId: Int?
        let padId: Int?

        enum CodingKeys: String, CodingKey {
            case pieces
            case unkId = "unk_id"
            case bosId = "bos_id"
            case eosId = "eos_id"
            case padId = "pad_id"
        }
    }

    private let pieces: [String]
    private let unkId: Int?
    private let bosId: Int?
    private let eosId: Int?
    private let padId: Int?

    public var count: Int {
        pieces.count
    }

    public init(modelURL: URL?) throws {
        guard let modelURL else {
            throw GigaAMError.invalidArguments("SentencePieceTokenizer requires tokenizer.model URL")
        }

        let vocabURL = modelURL
            .deletingLastPathComponent()
            .appendingPathComponent("tokenizer_vocab.json")

        guard FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw GigaAMError.fileNotFound(
                "\(vocabURL.path)."
            )
        }

        let data = try Data(contentsOf: vocabURL)
        let vocab = try JSONDecoder().decode(VocabularyFile.self, from: data)

        self.pieces = vocab.pieces
        self.unkId = vocab.unkId
        self.bosId = vocab.bosId
        self.eosId = vocab.eosId
        self.padId = vocab.padId
    }

    /// Raw sentencepiece piece for a token id. Nil for control tokens (bos/eos/pad)
    /// and out-of-range ids. `<unk>` is returned as-is.
    public func piece(forTokenId tokenId: Int) -> String? {
        guard tokenId >= 0 && tokenId < pieces.count else { return nil }
        if tokenId == bosId || tokenId == eosId || tokenId == padId { return nil }
        return pieces[tokenId]
    }

    public func decode(tokenIds: [Int]) throws -> String {
        var text = ""

        for tokenId in tokenIds {
            guard tokenId >= 0 && tokenId < pieces.count else {
                throw GigaAMError.invalidArguments(
                    "Token id out of vocabulary range: \(tokenId), vocab size: \(pieces.count)"
                )
            }

            if tokenId == bosId || tokenId == eosId || tokenId == padId {
                continue
            }

            let piece = pieces[tokenId]

            if tokenId == unkId || piece == "<unk>" {
                text += " ⁇ "
            } else {
                text += piece
            }
        }

        // SentencePiece uses U+2581 LOWER ONE EIGHTH BLOCK as whitespace marker.
        text = text.replacingOccurrences(of: "▁", with: " ")

        // SentencePiece decode removes the artificial leading whitespace.
        if text.hasPrefix(" ") {
            text.removeFirst()
        }

        return text
    }
}
