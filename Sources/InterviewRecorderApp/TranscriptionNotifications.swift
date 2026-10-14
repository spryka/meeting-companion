import Foundation
import UserNotifications

@MainActor
final class TranscriptionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TranscriptionNotifications()

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            do { _ = try await center.requestAuthorization(options: [.alert]) }
            catch { NSLog("Notification authorization failed: %@", error.localizedDescription) }
        }
    }

    static func content(recording: URL) -> UNMutableNotificationContent {
        struct Context: Decodable { let summary: String }
        let context = recording.deletingPathExtension().appendingPathExtension("context.json")
        let summary = (try? Data(contentsOf: context))
            .flatMap { try? JSONDecoder().decode(Context.self, from: $0) }?
            .summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = "Транскрибация завершена"
        content.body = summary.flatMap { $0.isEmpty ? nil : $0 } ?? recording.deletingPathExtension().lastPathComponent
        return content
    }

    func completed(recording: URL) async {
        let request = UNNotificationRequest(identifier: "transcription-" + UUID().uuidString,
                                            content: Self.content(recording: recording), trigger: nil)
        do { try await UNUserNotificationCenter.current().add(request) }
        catch { NSLog("Transcription notification failed: %@", error.localizedDescription) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
