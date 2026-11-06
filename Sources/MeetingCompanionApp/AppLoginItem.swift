import Foundation
import ServiceManagement

@MainActor
struct AppLoginItem {
    private let bundleURL: URL
    private let bundleIdentifier: String?
    private let serviceIsEnabled: () -> Bool
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isEnabled: @escaping () -> Bool = { SMAppService.mainApp.status == .enabled },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.serviceIsEnabled = isEnabled
        self.register = register
        self.unregister = unregister
    }

    var isSupported: Bool {
        bundleURL.pathExtension == "app" && bundleIdentifier == "local.meeting-companion"
    }
    var isEnabled: Bool { isSupported && serviceIsEnabled() }

    func configureIfNeeded(defaults: UserDefaults) throws {
        guard isSupported, !defaults.bool(forKey: "loginItemConfigured") else { return }
        if !isEnabled { try setEnabled(true) }
        defaults.set(true, forKey: "loginItemConfigured")
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isSupported else { return }
        if enabled { try register() }
        else { try unregister() }
    }
}
