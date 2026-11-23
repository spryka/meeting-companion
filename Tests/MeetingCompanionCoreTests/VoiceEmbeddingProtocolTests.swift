import Foundation
import MeetingCompanionCore
import Testing

@Suite struct VoiceEmbeddingProtocolTests {
    private let hash = String(repeating: "a", count: 64)

    @Test func requestRejectsBoundsTraversalAndUnknownVersion() throws {
        let valid = VoiceEmbeddingProtocol.Window(sourceID: .host, sourceFingerprint: hash, startFrame: 0, endFrame: 48_000)
        let request = VoiceEmbeddingProtocol.Request(resultID: "res_test", windows: [valid])
        let bytes = try JSONEncoder().encode(request)
        #expect(try VoiceEmbeddingProtocol.decodeRequest(bytes).id == request.id)
        let future = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
        #expect(throws: VoiceEmbeddingProtocol.Invalid.request) { try VoiceEmbeddingProtocol.decodeRequest(Data(future.utf8)) }
        let long = VoiceEmbeddingProtocol.Window(sourceID: .host, sourceFingerprint: hash, startFrame: 0, endFrame: 96_001)
        let invalidRequests: [VoiceEmbeddingProtocol.Request] = [
            .init(resultID: "../result", windows: [valid]),
            .init(resultID: "res_test", windows: [long]),
            .init(resultID: "res_test", windows: Array(repeating: valid, count: 65))
        ]
        for request in invalidRequests {
            #expect(throws: VoiceEmbeddingProtocol.Invalid.request) {
                try VoiceEmbeddingProtocol.decodeRequest(JSONEncoder().encode(request))
            }
        }
        var padded = bytes
        padded.append(Data(repeating: 32, count: VoiceEmbeddingProtocol.requestByteLimit))
        #expect(throws: VoiceEmbeddingProtocol.Invalid.request) { try VoiceEmbeddingProtocol.decodeRequest(padded) }
    }

    @Test func responseBindsRequestAndWindowsAndRejectsInvalidEmbeddings() throws {
        let window = VoiceEmbeddingProtocol.Window(sourceID: .host, sourceFingerprint: hash, startFrame: 0, endFrame: 48_000)
        let request = VoiceEmbeddingProtocol.Request(resultID: "res_test", windows: [window])
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        let valid = VoiceEmbeddingProtocol.Feature(windowID: window.id, pcmFingerprint: hash, embedding: vector)
        let response = VoiceEmbeddingProtocol.Response(requestID: request.id, features: [valid])
        #expect(try VoiceEmbeddingProtocol.decodeResponse(JSONEncoder().encode(response), for: request).features.first?.embedding == vector)
        let invalidResponses: [VoiceEmbeddingProtocol.Response] = [
            .init(requestID: UUID(), features: [valid]),
            .init(requestID: request.id, features: [.init(windowID: UUID(), pcmFingerprint: hash, embedding: vector)]),
            .init(requestID: request.id, features: [.init(windowID: window.id, pcmFingerprint: hash, embedding: [1])]),
            .init(requestID: request.id, features: [.init(windowID: window.id, pcmFingerprint: hash, embedding: Array(repeating: 0, count: 256))])
        ]
        for response in invalidResponses {
            #expect(throws: VoiceEmbeddingProtocol.Invalid.response) {
                try VoiceEmbeddingProtocol.decodeResponse(JSONEncoder().encode(response), for: request)
            }
        }
    }
}
