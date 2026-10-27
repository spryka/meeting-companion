import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init() }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        defaults.bool(forKey: "receiveBetaUpdates") ? ["beta"] : []
    }

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var manualCheck = false
    private var messageWindows: [NSWindow] = []
    private var readyWindow: NSWindow?
    private var restartButton: NSButton?
    private var restartStatus: NSTextField?
    private var installHandler: (() -> Void)?
    private(set) var pendingVersion: String?
    var isBusy: () -> Bool = { false }
    var canInstall: Bool { installHandler != nil && !isBusy() }
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
            message("Обновление через Homebrew", "После завершения записи выйди из приложения и выполни:\nbrew update\nbrew upgrade --cask meeting-companion")
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
        installHandler = immediateInstallHandler
        if manualCheck {
            manualCheck = false
            showReadyMessage()
        }
        // Keep the cycle pending: no impatient reminders or forced relaunch while recording.
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if error != nil {
            installHandler = nil
            pendingVersion = nil
            readyWindow?.close()
        }
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
        guard isBusy() else { return false }
        pendingVersion = item.displayVersionString
        self.installHandler = installHandler
        refreshReadyMessage()
        return true
    }

    private func showReadyMessage() {
        if let readyWindow {
            refreshReadyMessage()
            readyWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Обновления Meeting Companion"
        window.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: "Обновление готово\n\nМожно установить его сейчас и перезапустить приложение или продолжить работу. При обычном выходе обновление установится автоматически.")
        label.frame = NSRect(x: 20, y: 100, width: 480, height: 120)
        let status = NSTextField(wrappingLabelWithString: "")
        status.frame = NSRect(x: 20, y: 55, width: 480, height: 40)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        let later = NSButton(title: "Позже", target: self, action: #selector(dismissReadyMessage))
        later.frame = NSRect(x: 20, y: 15, width: 90, height: 32)
        later.bezelStyle = .rounded
        later.keyEquivalent = "\u{1b}"
        let restart = NSButton(title: "Установить и перезапустить", target: self, action: #selector(restartForUpdate))
        restart.frame = NSRect(x: 250, y: 15, width: 250, height: 32)
        restart.bezelStyle = .rounded
        for view in [label, status, later, restart] { window.contentView?.addSubview(view) }
        readyWindow = window
        restartButton = restart
        restartStatus = status
        refreshReadyMessage()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func refreshReadyMessage() {
        restartButton?.isEnabled = canInstall
        restartStatus?.stringValue = isBusy()
            ? "Перезапуск доступен после завершения записи, обработки и подготовки приложения."
            : ""
    }

    @discardableResult
    func installPreparedUpdate() -> Bool {
        guard canInstall, let installHandler else { refreshReadyMessage(); return false }
        readyWindow?.close()
        installHandler()
        return true
    }

    @objc private func restartForUpdate() { installPreparedUpdate() }
    @objc private func dismissReadyMessage() { readyWindow?.close() }

    private func message(_ title: String, _ text: String) {
        // A failed update must never enter a modal loop or block recording controls.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Обновления Meeting Companion"
        window.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: title + "\n\n" + text)
        label.frame = NSRect(x: 20, y: 20, width: 420, height: 180)
        window.contentView?.addSubview(label)
        messageWindows.removeAll { !$0.isVisible }
        messageWindows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
