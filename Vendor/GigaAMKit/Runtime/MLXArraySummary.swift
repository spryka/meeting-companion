import Foundation
@preconcurrency import MLX

public struct MLXArraySummary: Sendable {
    public let shape: [Int]
    public let firstValues: [Float]
    public let lastValues: [Float]
    public let min: Float
    public let max: Float
    public let mean: Float

    public static func make(_ array: MLXArray, edgeCount: Int = 12) -> MLXArraySummary {
        eval(array)

        let floatArray = array.asType(Float.self).asArray(Float.self)

        let first = Array(floatArray.prefix(edgeCount))
        let last = Array(floatArray.suffix(edgeCount))

        let minValue = floatArray.min() ?? .nan
        let maxValue = floatArray.max() ?? .nan

        let meanValue: Float
        if floatArray.isEmpty {
            meanValue = .nan
        } else {
            meanValue = floatArray.reduce(0, +) / Float(floatArray.count)
        }

        return MLXArraySummary(
            shape: array.shape,
            firstValues: first,
            lastValues: last,
            min: minValue,
            max: maxValue,
            mean: meanValue
        )
    }
}
