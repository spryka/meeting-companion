import Foundation
import MeetingCompanionCore
import MeetingCompanionPlatform
import MeetingCompanionApplication

extension RecorderViewModel {
    func retentionPolicy(key: String?) -> RecordingRetention {
        guard let key, let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(RecordingRetention.self, from: data) else { return RecordingRetention() }
        return policy
    }

    func invalidateRetention() {
        retentionGeneration.withLock { $0 = UUID() }
        pendingRetentionRecording = nil
        retentionError = nil
    }

    func saveRetention(_ policy: RecordingRetention, key: String) throws {
        guard key == RecordingRetention.preferenceKey(for: outputDirectory) else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(policy)
        invalidateRetention()
        defaults.set(data, forKey: key)
        objectWillChange.send()
    }

    private func protectedFromRetention(_ url: URL) -> Bool {
        trashAdmitting || workspace.loading || workspace.current?.state.id == url || workspaceRequested && selectedHistoryURL == url
            || recordingTrash?.target.recording == url || activeRecordingURL == url
            || (isRecording || sessionStarting || sessionStopping) && lastFileURL == url
            || audioPreviewURL?.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(url.deletingLastPathComponent().path + "/") == true
    }

    func retentionPreview(_ policy: RecordingRetention, root: URL) async throws -> [RetentionCandidate] {
        let repo = historyRepository
        let scan = Task.detached(priority: .utility) {
            try repo.retentionCandidates(root: root, policy: policy, now: Date(), verifyMix: verifyRetentionMix)
        }
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }

    func scheduleRetention(afterSaving recording: URL) {
        let root = outputDirectory
        guard Self.isInLibrary(recording, root: root), let key = RecordingRetention.preferenceKey(for: root),
              retentionPolicy(key: key) != RecordingRetention() else { return }
        pendingRetentionRecording = recording
        guard !retentionRunning else { return }
        retentionRunning = true
        Task {
            defer { retentionRunning = false }
            while let saved = pendingRetentionRecording {
                pendingRetentionRecording = nil
                await cleanExpiredRecordings(afterSaving: saved)
            }
        }
    }

    private func cleanExpiredRecordings(afterSaving recording: URL) async {
        let root = outputDirectory, repo = historyRepository, generation = retentionGeneration
        guard Self.isInLibrary(recording, root: root), let key = RecordingRetention.preferenceKey(for: root) else { return }
        let token = generation.withLock { $0 }, policy = retentionPolicy(key: key)
        let authorized: @Sendable () -> Bool = {
            generation.withLock { $0 == token } && RecordingRetention.preferenceKey(for: root) == key
        }
        retentionError = nil
        do {
            let candidates = try await retentionPreview(policy, root: root)
            for candidate in candidates {
                guard authorized() else { break }
                let url = candidate.target.recording
                guard url != recording, !protectedFromRetention(url) else { continue }
                retentionTarget = url
                defer { retentionTarget = nil }
                do {
                    try await Task.detached(priority: .utility) {
                        try repo.applyRetention(candidate, policy: policy, now: Date(), verifyMix: verifyRetentionMix, authorized: authorized)
                    }.value
                } catch let error as RecordingTrashFailure where error.busy { continue }
                catch let error as POSIXError where error.code == .EWOULDBLOCK { continue }
                catch TranscriptEditsError.lockDenied { continue }
                catch {
                    if authorized() { retentionError = "Ошибка автоочистки «" + url.deletingPathExtension().lastPathComponent + "»: " + error.localizedDescription }
                }
            }
            if root == outputDirectory, !candidates.isEmpty {
                await history.refresh(root: root)
                if root == outputDirectory { clearMissingRetentionSelection() }
            }
        } catch {
            if authorized() { retentionError = "Ошибка автоочистки: " + error.localizedDescription }
        }
    }
}
