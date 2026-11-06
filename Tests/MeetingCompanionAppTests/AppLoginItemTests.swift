import Foundation
import Testing
@testable import MeetingCompanionApp

@MainActor
struct AppLoginItemTests {
    @Test(arguments: [
        ("swiftpm-testing-helper", nil),
        ("Helper.app", "swiftpm-testing-helper"),
        ("MeetingCompanionAppTests.xctest", "local.meeting-companion"),
        ("Other.app", nil),
        ("Other.app", "other.app")
    ] as [(String, String?)])
    func unsupportedHostsNeverTouchServiceOrMarker(path: String, identifier: String?) throws {
        let fixture = LoginItemFixture()
        defer { fixture.close() }
        let login = fixture.login(path: path, identifier: identifier)
        #expect(!login.isSupported)
        #expect(!login.isEnabled)
        for marker in [nil, false, true] as [Bool?] {
            if let marker { fixture.defaults.set(marker, forKey: "loginItemConfigured") }
            else { fixture.defaults.removeObject(forKey: "loginItemConfigured") }
            try login.configureIfNeeded(defaults: fixture.defaults)
            try login.setEnabled(true)
            try login.setEnabled(false)
            #expect((fixture.defaults.object(forKey: "loginItemConfigured") as? Bool) == marker)
        }
        #expect(fixture.service.statusReads == 0)
        #expect(fixture.service.registrations == 0 && fixture.service.unregistrations == 0)
    }

    @Test func actualTestHostCannotRegister() throws {
        let fixture = LoginItemFixture()
        defer { fixture.close() }
        print("Login probe host: \(Bundle.main.bundleURL.path), id=\(Bundle.main.bundleIdentifier ?? "nil")")
        let login = fixture.login(bundleURL: Bundle.main.bundleURL, identifier: Bundle.main.bundleIdentifier)
        try login.configureIfNeeded(defaults: fixture.defaults)
        #expect(!login.isSupported && !login.isEnabled)
        #expect(fixture.defaults.object(forKey: "loginItemConfigured") == nil)
        #expect(fixture.service.statusReads == 0 && fixture.service.registrations == 0)
    }

    @Test(arguments: ["Meeting Companion.app", "renamed-local.app"])
    func applicationKeepsOneTimeSetupAndManualToggle(path: String) throws {
        let fixture = LoginItemFixture()
        defer { fixture.close() }
        let login = fixture.login(path: path)
        #expect(login.isSupported)
        try login.configureIfNeeded(defaults: fixture.defaults)
        #expect(login.isEnabled && fixture.service.registrations == 1)
        #expect(fixture.defaults.bool(forKey: "loginItemConfigured"))
        try login.setEnabled(false)
        try login.configureIfNeeded(defaults: fixture.defaults)
        #expect(!login.isEnabled && fixture.service.registrations == 1)
        #expect(fixture.service.unregistrations == 1)
        try login.setEnabled(true)
        #expect(login.isEnabled && fixture.service.registrations == 2)
    }

    @Test func alreadyEnabledApplicationOnlyMarksSetup() throws {
        let fixture = LoginItemFixture()
        defer { fixture.close() }
        fixture.service.enabled = true
        try fixture.login().configureIfNeeded(defaults: fixture.defaults)
        #expect(fixture.defaults.bool(forKey: "loginItemConfigured"))
        #expect(fixture.service.registrations == 0)
    }

    @Test func failedSetupPreservesErrorAndCanRetry() throws {
        let fixture = LoginItemFixture()
        defer { fixture.close() }
        fixture.service.failure = .denied
        #expect(throws: LoginItemError.denied) { try fixture.login().configureIfNeeded(defaults: fixture.defaults) }
        #expect(fixture.defaults.object(forKey: "loginItemConfigured") == nil)
        fixture.service.failure = nil
        try fixture.login().configureIfNeeded(defaults: fixture.defaults)
        #expect(fixture.defaults.bool(forKey: "loginItemConfigured"))
        #expect(fixture.service.registrations == 2)
    }

    @Test(arguments: [false, true])
    func manualFailurePreservesServiceStateAndError(enabled: Bool) throws {
        let fixture = LoginItemFixture()
        defer { fixture.close() }
        fixture.service.enabled = !enabled
        fixture.service.failure = .denied
        #expect(throws: LoginItemError.denied) { try fixture.login().setEnabled(enabled) }
        #expect(fixture.service.enabled == !enabled)
        #expect(fixture.defaults.object(forKey: "loginItemConfigured") == nil)
    }
}

private enum LoginItemError: Error { case denied }

@MainActor private final class LoginItemService {
    var enabled = false
    var statusReads = 0, registrations = 0, unregistrations = 0
    var failure: LoginItemError?
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        enabled = true
    }
    func unregister() throws {
        unregistrations += 1
        if let failure { throw failure }
        enabled = false
    }
}

@MainActor private struct LoginItemFixture {
    let suite = "AppLoginItemTests-" + UUID().uuidString
    let defaults: UserDefaults
    let service = LoginItemService()
    init() { defaults = UserDefaults(suiteName: suite)! }
    func login(path: String = "Meeting Companion.app", identifier: String? = "local.meeting-companion") -> AppLoginItem {
        login(bundleURL: URL(fileURLWithPath: "/synthetic/" + path), identifier: identifier)
    }
    func login(bundleURL: URL, identifier: String?) -> AppLoginItem {
        AppLoginItem(bundleURL: bundleURL, bundleIdentifier: identifier,
            isEnabled: { service.statusReads += 1; return service.enabled },
            register: service.register, unregister: service.unregister)
    }
    func close() { defaults.removePersistentDomain(forName: suite) }
}
