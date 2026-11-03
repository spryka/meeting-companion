import Foundation
@preconcurrency import MLX

public struct MLXTensorLoadResult {
    public let name: String
    public let dtype: String
    public let shape: [Int]
    public let byteCount: Int
    public let array: MLXArray
}

public enum SafetensorsMLXLoader {
    public static func loadTensor(
        url: URL,
        tensorName: String
    ) throws -> MLXTensorLoadResult {
        let index = try SafetensorsIndex.loadHeader(url: url)

        guard let tensor = index.tensors.first(where: { $0.name == tensorName }) else {
            let prefix = index.tensors.prefix(20).map(\.name).joined(separator: "\n  ")
            throw GigaAMError.invalidArguments(
                "Tensor not found: \(tensorName)\nFirst tensors:\n  \(prefix)"
            )
        }

        guard tensor.dataOffsets.count == 2 else {
            throw GigaAMError.invalidManifest("Tensor has invalid data_offsets: \(tensorName)")
        }

        let start = index.dataStartOffset + UInt64(tensor.dataOffsets[0])
        let end = index.dataStartOffset + UInt64(tensor.dataOffsets[1])

        guard end >= start else {
            throw GigaAMError.invalidManifest("Tensor has invalid byte range: \(tensorName)")
        }

        let byteCount = Int(end - start)

        let dtype = try mlxDType(fromSafetensorsDType: tensor.dtype)

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: byteCount) ?? Data()

        guard data.count == byteCount else {
            throw GigaAMError.invalidManifest(
                "Could not read full tensor data for \(tensorName): expected \(byteCount), got \(data.count)"
            )
        }

        let array = MLXArray(data, tensor.shape, dtype: dtype)

        return MLXTensorLoadResult(
            name: tensor.name,
            dtype: tensor.dtype,
            shape: tensor.shape,
            byteCount: byteCount,
            array: array
        )
    }

    private static func mlxDType(fromSafetensorsDType dtype: String) throws -> DType {
        switch dtype {
        case "F16":
            return .float16
        case "F32":
            return .float32
        default:
            throw GigaAMError.invalidManifest("Unsupported safetensors dtype for MLX load: \(dtype)")
        }
    }
}
