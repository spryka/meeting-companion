import Foundation
@preconcurrency import MLX

public final class GigaAMTensorStore: @unchecked Sendable {
    public let weightsURL: URL
    public let index: SafetensorsIndex

    private var cache: [String: MLXArray] = [:]
    private let computeDType: DType?

    public init(weightsURL: URL, computeDType: DType? = nil) throws {
        self.weightsURL = weightsURL
        self.computeDType = computeDType
        self.index = try SafetensorsIndex.loadHeader(url: weightsURL)
    }

    public var tensorCount: Int {
        index.tensorCount
    }

    public var totalParameterCount: Int {
        index.totalParameterCount
    }

    public func contains(_ name: String) -> Bool {
        index.tensors.contains { $0.name == name }
    }

    public func info(for name: String) -> SafetensorsTensorInfo? {
        index.tensors.first { $0.name == name }
    }

    public func names(prefix: String? = nil, limit: Int? = nil) -> [String] {
        let filtered: [String]

        if let prefix {
            filtered = index.tensors.map(\.name).filter { $0.hasPrefix(prefix) }
        } else {
            filtered = index.tensors.map(\.name)
        }

        if let limit {
            return Array(filtered.prefix(limit))
        }

        return filtered
    }

    public func load(_ name: String, cache: Bool = true) throws -> MLXArray {
        if cache, let cached = self.cache[name] {
            return cached
        }

        let loaded = try SafetensorsMLXLoader.loadTensor(
            url: weightsURL,
            tensorName: name
        )

        let array = computeDType.map { loaded.array.asType($0) } ?? loaded.array
        if cache {
            self.cache[name] = array
        }

        return array
    }

    public func clearCache() {
        cache.removeAll()
    }
}
