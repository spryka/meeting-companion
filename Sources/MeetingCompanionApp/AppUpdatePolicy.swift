import Foundation

enum AppUpdatePolicy {
    static func isHomebrewManaged(_ app: URL, caskrooms: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom/meeting-companion"),
        URL(fileURLWithPath: "/usr/local/Caskroom/meeting-companion")
    ]) -> Bool {
        let manager = FileManager.default
        let installed = app.resolvingSymlinksInPath().standardizedFileURL
        // shortcut: custom Homebrew prefixes require updating through brew manually.
        return caskrooms.contains { caskroom in
            let versions = (try? manager.contentsOfDirectory(at: caskroom,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return versions.contains { version in
                let link = version.appendingPathComponent("Meeting Companion.app")
                return (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil
                    && link.resolvingSymlinksInPath().standardizedFileURL == installed
            }
        }
    }
}
