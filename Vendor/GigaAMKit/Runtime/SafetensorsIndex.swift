import Foundation

public struct SafetensorsTensorInfo: Sendable {
    public let name: String
    public let dtype: String
    public let shape: [Int]
    public let dataOffsets: [Int]

    public var parameterCount: Int {
        shape.reduce(1, *)
    }
}

public struct SafetensorsIndex: Sendable {
    public let path: String
    public let dataStartOffset: UInt64
    public let tensors: [SafetensorsTensorInfo]

    public var tensorCount: Int {
        tensors.count
    }

    public var totalParameterCount: Int {
        tensors.reduce(0) { $0 + $1.parameterCount }
    }

    public static func loadHeader(url: URL) throws -> SafetensorsIndex {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let lengthData = try handle.read(upToCount: 8) ?? Data()

        guard lengthData.count == 8 else {
            throw GigaAMError.invalidManifest("Invalid safetensors file: cannot read header length")
        }

        let headerLength = lengthData.withUnsafeBytes { rawBuffer -> UInt64 in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var value: UInt64 = 0

            for i in 0..<8 {
                value |= UInt64(bytes[i]) << UInt64(8 * i)
            }

            return value
        }

        guard headerLength > 0 else {
            throw GigaAMError.invalidManifest("Invalid safetensors file: empty header")
        }

        guard headerLength < 1024 * 1024 * 128 else {
            throw GigaAMError.invalidManifest("Invalid safetensors file: header too large")
        }

        let headerData = try handle.read(upToCount: Int(headerLength)) ?? Data()

        guard headerData.count == Int(headerLength) else {
            throw GigaAMError.invalidManifest("Invalid safetensors file: cannot read full header")
        }

        let object = try JSONSerialization.jsonObject(with: headerData, options: [])

        guard let root = object as? [String: Any] else {
            throw GigaAMError.invalidManifest("Invalid safetensors header JSON")
        }

        var tensors: [SafetensorsTensorInfo] = []

        for (name, value) in root {
            if name == "__metadata__" {
                continue
            }

            guard let item = value as? [String: Any] else {
                continue
            }

            guard let dtype = item["dtype"] as? String else {
                continue
            }

            guard let shapeAny = item["shape"] as? [Any] else {
                continue
            }

            guard let offsetsAny = item["data_offsets"] as? [Any] else {
                continue
            }

            let shape = shapeAny.compactMap { value -> Int? in
                if let intValue = value as? Int {
                    return intValue
                }
                if let numberValue = value as? NSNumber {
                    return numberValue.intValue
                }
                return nil
            }

            let offsets = offsetsAny.compactMap { value -> Int? in
                if let intValue = value as? Int {
                    return intValue
                }
                if let numberValue = value as? NSNumber {
                    return numberValue.intValue
                }
                return nil
            }

            tensors.append(
                SafetensorsTensorInfo(
                    name: name,
                    dtype: dtype,
                    shape: shape,
                    dataOffsets: offsets
                )
            )
        }

        tensors.sort { $0.name < $1.name }

        return SafetensorsIndex(
            path: url.path,
            dataStartOffset: 8 + headerLength,
            tensors: tensors
        )
    }
}
