import Foundation

public struct ModelBundle: Sendable {
    public let directory: URL?
    public let manifest: GigaAMManifest
    public let weightsURL: URL?
    public let tokenizerURL: URL?

    public static func load(configuration: GigaAMConfiguration) throws -> ModelBundle {
        if let directory = configuration.modelDirectory {
            return try loadExternal(directory: directory)
        }

        return try loadBundled()
    }

    private static func loadExternal(directory: URL) throws -> ModelBundle {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw GigaAMError.modelDirectoryNotFound(directory.path)
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw GigaAMError.manifestNotFound(manifestURL.path)
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(GigaAMManifest.self, from: data)

        let weightsURL = directory.appendingPathComponent(manifest.weightsFile)
        let tokenizerURL = manifest.tokenizerFile.map { directory.appendingPathComponent($0) }

        return ModelBundle(
            directory: directory,
            manifest: manifest,
            weightsURL: FileManager.default.fileExists(atPath: weightsURL.path) ? weightsURL : nil,
            tokenizerURL: tokenizerURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        )
    }

    private static func loadBundled() throws -> ModelBundle {
        throw GigaAMError.manifestNotFound(
            "No bundled model found. Use GigaAMConfiguration(modelDirectory:) " +
            "to provide the model path explicitly."
        )
    }
}