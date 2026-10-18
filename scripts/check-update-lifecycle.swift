import AppKit
import Sparkle

@main struct Check {
    @MainActor static func main() throws {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let owner = AppUpdater()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: owner)
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
        print("Busy guard and deferred installation without forced termination passed")
    }
}
