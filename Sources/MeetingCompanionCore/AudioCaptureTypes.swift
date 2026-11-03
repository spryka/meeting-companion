import Foundation

public enum AudioCaptureBackend: String, CaseIterable, Sendable {
    case screenCaptureKit
    case coreAudioTap
}
