import Foundation

@main struct Check {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/Meeting Companion.app")
        let other = root.appendingPathComponent("Other/Meeting Companion.app")
        let cask = root.appendingPathComponent("Caskroom/meeting-companion")
        let version = cask.appendingPathComponent("1.4.1")
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        try manager.createDirectory(at: version, withIntermediateDirectories: true)
        precondition(!AppUpdatePolicy.isHomebrewManaged(app, caskrooms: [cask]))
        let link = version.appendingPathComponent("Meeting Companion.app")
        try manager.createSymbolicLink(at: link, withDestinationURL: app)
        precondition(AppUpdatePolicy.isHomebrewManaged(app, caskrooms: [cask]))
        precondition(!AppUpdatePolicy.isHomebrewManaged(other, caskrooms: [cask]))
        precondition(AppUpdatePolicy.isHomebrewManaged(link, caskrooms: [cask]))
        try manager.removeItem(at: link)
        try manager.createDirectory(at: link, withIntermediateDirectories: true)
        precondition(!AppUpdatePolicy.isHomebrewManaged(app, caskrooms: [cask]))
        print("Homebrew: exact target, separate app copy, absent receipt and non-symlink passed")
    }
}
