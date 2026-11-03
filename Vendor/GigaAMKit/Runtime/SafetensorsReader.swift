import Foundation

public struct SafetensorsTensorPreview: Sendable {
    public let name: String
    public let dtype: String
    public let shape: [Int]
    public let byteCount: Int
    public let firstFloatValues: [Float]
}

public enum SafetensorsReader {
    public static func previewTensor(
        url: URL,
        tensorName: String,
        sampleCount: Int = 8
    ) throws -> SafetensorsTensorPreview {
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
        let bytesToRead: Int

        switch tensor.dtype {
        case "F16":
            bytesToRead = min(byteCount, sampleCount * 2)
        case "F32":
            bytesToRead = min(byteCount, sampleCount * 4)
        default:
            bytesToRead = min(byteCount, sampleCount * 2)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: bytesToRead) ?? Data()
        let values = decodePreviewValues(data: data, dtype: tensor.dtype)

        return SafetensorsTensorPreview(
            name: tensor.name,
            dtype: tensor.dtype,
            shape: tensor.shape,
            byteCount: byteCount,
            firstFloatValues: values
        )
    }

    private static func decodePreviewValues(data: Data, dtype: String) -> [Float] {
        let bytes = [UInt8](data)

        switch dtype {
        case "F16":
            var result: [Float] = []
            result.reserveCapacity(bytes.count / 2)

            var i = 0
            while i + 1 < bytes.count {
                let bits = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
                result.append(Float(Float16(bitPattern: bits)))
                i += 2
            }

            return result

        case "F32":
            var result: [Float] = []
            result.reserveCapacity(bytes.count / 4)

            var i = 0
            while i + 3 < bytes.count {
                let bits =
                    UInt32(bytes[i]) |
                    (UInt32(bytes[i + 1]) << 8) |
                    (UInt32(bytes[i + 2]) << 16) |
                    (UInt32(bytes[i + 3]) << 24)

                result.append(Float(bitPattern: bits))
                i += 4
            }

            return result

        default:
            return []
        }
    }
}
