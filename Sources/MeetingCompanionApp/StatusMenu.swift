import AppKit
import MeetingCompanionCore

@MainActor
enum StatusMenu {
    static func build(
        model: RecorderViewModel,
        appUpdater: AppUpdater,
        target: AnyObject?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 1. Incomplete initial attachment: protect against false idle
        if !model.isAttached {
            let item = NSMenuItem(title: "Подключение к службам…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }
        // 2. Starting recording capture
        else if model.sessionStarting {
            let item = NSMenuItem(title: "Запуск записи…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }
        // 3. Active recording (capture priority over processing)
        else if model.isRecording {
            let durationItem = NSMenuItem(title: "Запись: \(model.elapsedText)", action: nil, keyEquivalent: "")
            durationItem.isEnabled = false
            menu.addItem(durationItem)

            if model.showsCancelRecording {
                let cancelItem = NSMenuItem(title: "Отменить короткую запись", action: #selector(RecorderAppDelegate.cancelRecordingAction), keyEquivalent: "")
                cancelItem.target = target
                cancelItem.representedObject = model.activeSessionID
                cancelItem.isEnabled = !model.sessionStopping && !model.isBusy
                menu.addItem(cancelItem)
            } else {
                let stopItem = NSMenuItem(title: "Остановить запись", action: #selector(RecorderAppDelegate.stopRecordingAction), keyEquivalent: "")
                stopItem.target = target
                stopItem.representedObject = model.activeSessionID
                stopItem.isEnabled = !model.sessionStopping && !model.isBusy
                menu.addItem(stopItem)
            }

            let muteTitle = model.microphoneMuted ? "Включить микрофон" : "Выключить микрофон"
            let muteItem = NSMenuItem(title: muteTitle, action: #selector(RecorderAppDelegate.toggleMicrophoneMuteAction), keyEquivalent: "")
            muteItem.target = target
            muteItem.representedObject = model.activeSessionID
            muteItem.isEnabled = !model.sessionStopping && !model.isBusy
            menu.addItem(muteItem)

            let capsuleItem = NSMenuItem(title: "Показать капсулу", action: #selector(RecorderAppDelegate.showCapsuleAction), keyEquivalent: "")
            capsuleItem.target = target
            capsuleItem.isEnabled = true
            menu.addItem(capsuleItem)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }
        // 4. Saving / stopping capture
        else if model.sessionStopping {
            let statusItem = NSMenuItem(title: "Сохранение записи…", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }
        // 5. Preparing / checking models (diagnostic running)
        else if model.diagnosticRunning {
            let diagItem = NSMenuItem(title: model.diagnosticStatusText, action: nil, keyEquivalent: "")
            diagItem.isEnabled = false
            menu.addItem(diagItem)

            let newItem = NSMenuItem(title: "Новая запись", action: #selector(RecorderAppDelegate.startRecordingAction), keyEquivalent: "")
            newItem.target = target
            newItem.isEnabled = false
            menu.addItem(newItem)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }
        // 6. Admitting processing job
        else if model.isAdmittingProcessing {
            let statusItem = NSMenuItem(title: "Проверка допуска транскрибации…", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            let newItem = NSMenuItem(title: "Новая запись", action: #selector(RecorderAppDelegate.startRecordingAction), keyEquivalent: "")
            newItem.target = target
            newItem.isEnabled = model.canStartRecording
            menu.addItem(newItem)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }
        // 7. Processing / queued without capture
        else if model.transcriptionJobs > 0 {
            let statusItem = NSMenuItem(title: model.transcriptionStatus, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            let newItem = NSMenuItem(title: "Новая запись", action: #selector(RecorderAppDelegate.startRecordingAction), keyEquivalent: "")
            newItem.target = target
            newItem.isEnabled = model.canStartRecording
            menu.addItem(newItem)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }
        // 8. Idle
        else {
            let newItem = NSMenuItem(title: "Новая запись", action: #selector(RecorderAppDelegate.startRecordingAction), keyEquivalent: "")
            newItem.target = target
            newItem.isEnabled = model.canStartRecording
            menu.addItem(newItem)

            let libItem = NSMenuItem(title: "Библиотека", action: #selector(RecorderAppDelegate.openRecordings), keyEquivalent: "")
            libItem.target = target
            libItem.isEnabled = true
            menu.addItem(libItem)
        }

        // Utility section (M04)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(RecorderAppDelegate.showSettings), keyEquivalent: ",")
        settingsItem.target = target
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: appUpdater.menuTitle, action: #selector(RecorderAppDelegate.checkForUpdates), keyEquivalent: "")
        updateItem.target = target
        updateItem.isEnabled = true
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(RecorderAppDelegate.quit), keyEquivalent: "q")
        quitItem.target = target
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        return menu
    }
}
