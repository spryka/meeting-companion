import AppKit
import Sparkle

@main struct Check {
    @MainActor static func main() throws {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let suite = "check-update-lifecycle-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = AppUpdater(defaults: defaults)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: owner)
        precondition(owner.responds(to: NSSelectorFromString("allowedChannelsForUpdater:")))
        precondition(owner.allowedChannels(for: updater).isEmpty)
        defaults.set(true, forKey: "receiveBetaUpdates")
        precondition(owner.allowedChannels(for: updater) == ["beta"])
        defaults.set(false, forKey: "receiveBetaUpdates")
        precondition(owner.allowedChannels(for: updater).isEmpty)
        owner.isBusy = { true }
        do {
            try owner.updater(updater, mayPerform: .updatesInBackground)
            preconditionFailure("Busy app must refuse update checks")
        } catch {
            precondition((error as NSError).domain == "MeetingCompanion.Updates")
        }
        owner.isBusy = { false }
        try owner.updater(updater, mayPerform: .updatesInBackground)
        // Background network errors leave the recorder independent and allow another check.
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost] {
            owner.updater(updater, didFinishUpdateCycleFor: .updatesInBackground,
                error: NSError(domain: NSURLErrorDomain, code: code))
            precondition(owner.pendingVersion == nil)
            try owner.updater(updater, mayPerform: .updatesInBackground)
        }
        let item = SUAppcastItem(dictionary: ["enclosure": [
            "url": "https://example.invalid/update.zip", "sparkle:version": "19",
            "sparkle:shortVersionString": "1.5.1"
        ]])!
        var immediateInstallation = false
        precondition(owner.updater(updater, willInstallUpdateOnQuit: item,
            immediateInstallationBlock: { immediateInstallation = true }))
        precondition(!immediateInstallation, "Preparing an update must never terminate the app")
        precondition(owner.pendingVersion == "1.5.1")
        owner.isBusy = { true }
        precondition(!owner.canInstall)
        precondition(!owner.installPreparedUpdate())
        precondition(!immediateInstallation)
        owner.isBusy = { false }
        precondition(owner.canInstall)
        precondition(owner.installPreparedUpdate())
        precondition(immediateInstallation)
        var resumedInstallation = false
        precondition(!owner.updater(updater, shouldPostponeRelaunchForUpdate: item,
            untilInvokingBlock: { resumedInstallation = true }))
        owner.isBusy = { true }
        precondition(owner.updater(updater, shouldPostponeRelaunchForUpdate: item,
            untilInvokingBlock: { resumedInstallation = true }))
        precondition(!owner.installPreparedUpdate())
        owner.isBusy = { false }
        precondition(owner.installPreparedUpdate())
        precondition(resumedInstallation)
        owner.updater(updater, didFinishUpdateCycleFor: .updatesInBackground,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        precondition(!owner.canInstall && owner.pendingVersion == nil)
        print("Beta opt-in, busy guard and deferred installation without forced termination passed")
    }
}
