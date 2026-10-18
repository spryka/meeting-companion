import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var manualCheck = false
    private(set) var pendingVersion: String?
    var isBusy: () -> Bool = { false }
    var menuTitle: String {
        if let pendingVersion { return "Версия \(pendingVersion) установится после выхода" }
        return manualCheck ? "Проверка и загрузка обновления…" : "Проверить обновления…"
    }

    func start() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "MCEnableUpdates") as? Bool == true,
              !AppUpdatePolicy.isHomebrewManaged(Bundle.main.bundleURL) else { return }
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        userDriver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        try updater.start()
    }

    func check() {
        if AppUpdatePolicy.isHomebrewManaged(Bundle.main.bundleURL) {
            message("Обновление через Homebrew", "После завершения записи выйди из приложения и выполни:\nbrew update\nbrew upgrade --cask bulat/apps/meeting-companion")
        } else if pendingVersion != nil {
            showReadyMessage()
        } else if let updater {
            guard updater.canCheckForUpdates else {
                message("Обновление уже проверяется", "Дождись завершения проверки или загрузки.")
                return
            }
            manualCheck = true
            updater.automaticallyDownloadsUpdates = true
            updater.checkForUpdatesInBackground()
        } else {
            message("Обновления отключены для этой сборки", "Установи готовую сборку из DMG или обнови приложение из исходников.")
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isBusy() || AppUpdatePolicy.isHomebrewManaged(Bundle.main.bundleURL) {
            throw NSError(domain: "MeetingCompanion.Updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Проверка обновлений доступна после завершения записи и обработки."])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingVersion = item.displayVersionString
        if manualCheck {
            manualCheck = false
            showReadyMessage()
        }
        // Keep the cycle pending: no impatient reminders or forced relaunch while recording.
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error { NSLog("Meeting Companion update: %@", error.localizedDescription) }
        guard manualCheck else { return }
        manualCheck = false
        if let error {
            let nsError = error as NSError
            message(nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
                ? "Установлена последняя версия" : "Не удалось подготовить обновление", error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle's prepared installer still waits for the host process to exit.
        pendingVersion = item.displayVersionString
        showReadyMessage()
        return true
    }

    private func showReadyMessage() {
        message("Обновление готово", "Новая версия установится после выхода из Meeting Companion. Можно продолжать работу. При следующем запуске откроется новая версия.")
    }

    private func message(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
