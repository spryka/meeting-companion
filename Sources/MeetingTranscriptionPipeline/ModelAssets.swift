import Foundation
import CryptoKit
import Darwin

public struct ModelFileSpec: Sendable, Equatable {
    public let filename: String
    public let sha256: String

    public init(filename: String, sha256: String) {
        self.filename = filename
        self.sha256 = sha256
    }
}

public struct ModelSpec: Sendable, Equatable {
    public let name: String
    public let repo: String
    public let revision: String
    public let files: [ModelFileSpec]

    public init(name: String, repo: String, revision: String, files: [ModelFileSpec]) {
        self.name = name
        self.repo = repo
        self.revision = revision
        self.files = files
    }
}

private final class DownloadResultBox: @unchecked Sendable {
    var result: Result<URL, Error>?
}

public enum ModelAssets {
    /// Pinned specification for GigaAM v3 MLX (exact SHA-256 for all required assets)
    public static let gigaamSpec = ModelSpec(
        name: "gigaam",
        repo: "kruatech/gigaam-v3-mlx",
        revision: "2478743c1c449a468ee163bc3030170d1a2e81fb",
        files: [
            ModelFileSpec(filename: "manifest.json", sha256: "993c538b6dceffb7b018c633a7cc8e4034e7ca975b5c27ecc8ecd679fa574d16"),
            ModelFileSpec(filename: "weights.fp16.safetensors", sha256: "2ff6d955a61003e0d3cb2155be36c14aa3df69c879713f30880ddd07d71fde21"),
            ModelFileSpec(filename: "tokenizer.model", sha256: "828c12c991019eef952a960661f25a92d6ad279591e2ea466b4aeddf1d20a18a"),
            ModelFileSpec(filename: "tokenizer_vocab.json", sha256: "84e15355333a8eb460b2f899947e9976b8c036f4dd086002e43b987ddf4cc606"),
            ModelFileSpec(filename: "hann_window.f32.bin", sha256: "834a6744851a775dbb1831e9e17f0f702599b4d52c1d97d7638b3f170824419f"),
            ModelFileSpec(filename: "mel_filterbank_mel_freq.f32.bin", sha256: "e9425a25940359fb85efeaf6651f81679971a1c46bec1af3aba943ec8a5fd793")
        ]
    )

    /// Pinned specification for Silero VAD v6 MLX
    public static let vadSpec = ModelSpec(
        name: "vad",
        repo: "mlx-community/silero-vad-v6",
        revision: "2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06",
        files: [
            ModelFileSpec(filename: "config.json", sha256: "9fe1befb9692a0d4135adadc33f8075ef6d350bd2391b88d750f2c233f97fa0b"),
            ModelFileSpec(filename: "model.safetensors", sha256: "65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff")
        ]
    )

    /// Pinned specification for Nemotron-3 Diarization MLX
    public static let nemotronSpec = ModelSpec(
        name: "nemotron",
        repo: "mlx-community/Nemotron-3-Diarization",
        revision: "59ed2dbfc1346dcea9d423c71306a3a2499c568f",
        files: [
            ModelFileSpec(filename: "config.json", sha256: "f215091252bc54f8dcc7d682962a659e03a6bcb26d1c86e4728b8c6730130eb4"),
            ModelFileSpec(filename: "model.safetensors", sha256: "21e8427d1795c9c46c5800f56b16061734ffd0dcadd71d9bcf0b4d6ef7261da5")
        ]
    )

    /// Pinned specification for Parakeet TDT 0.6b v3 MLX 8-bit (optional)
    public static let parakeetSpec = ModelSpec(
        name: "parakeet",
        repo: "craquehouse/parakeet-tdt-0.6b-v3-mlx-8bit",
        revision: "29d291a62b4013d74a24d79fca00883b717d988a",
        files: [
            ModelFileSpec(filename: "config.json", sha256: "6fb1da46eda7c57f3b71294363f396e64c18abbc01a921477bd716a392ec0ebf"),
            ModelFileSpec(filename: "model.safetensors", sha256: "3e9a25e0f1c4cd866868e271601407b5a5c187ac1d4f7324a4867120775204eb"),
            ModelFileSpec(filename: "tokenizer.model", sha256: "eacec2b0a77f336d4a2ca4a25a7047575d3c2b74de47e997f4c205126ed3135e"),
            ModelFileSpec(filename: "tokenizer.vocab", sha256: "41130ff456706304a1adec782ccc9e003c4d417e8e324353d281be958cac4e17"),
            ModelFileSpec(filename: "vocab.txt", sha256: "3cde1409fd78783a79b29ed4d32da57c746993856f7c8263bcb905d2e5839db7")
        ]
    )

    public static func defaultModelRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["MEETING_COMPANION_MODELS"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MeetingCompanion/native-models", isDirectory: true)
    }

    /// Computes the SHA-256 hex string of a file with streaming and cooperative cancellation support.
    public static func computeSHA256(
        at url: URL,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NSError(domain: "ModelAssets", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось открыть файл \(url.path)"])
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB buffer
        while true {
            if isCancelled?() == true {
                throw PipelineError("cancelled")
            }
            let data = try handle.read(upToCount: bufferSize) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Checks availability and integrity of local models against pinned specifications.
    public static func checkAvailability(
        modelRoot: URL,
        parakeet: Bool,
        verifyChecksums: Bool = true
    ) -> (ready: Bool, missingFiles: [String]) {
        let fm = FileManager.default
        var missing: [String] = []

        var specs = [gigaamSpec, vadSpec, nemotronSpec]
        if parakeet {
            specs.append(parakeetSpec)
        }

        for spec in specs {
            let dir = modelRoot.appendingPathComponent(spec.name)
            for file in spec.files {
                let fileURL = dir.appendingPathComponent(file.filename)
                guard fm.fileExists(atPath: fileURL.path) else {
                    missing.append("\(spec.name)/\(file.filename)")
                    continue
                }
                guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                      let size = attrs[.size] as? Int64, size > 0 else {
                    missing.append("\(spec.name)/\(file.filename) (empty)")
                    continue
                }
                if verifyChecksums {
                    do {
                        let actual = try computeSHA256(at: fileURL)
                        if actual != file.sha256 {
                            missing.append("\(spec.name)/\(file.filename) (corrupt checksum)")
                        }
                    } catch {
                        missing.append("\(spec.name)/\(file.filename) (unreadable)")
                    }
                }
            }
        }

        return (missing.isEmpty, missing)
    }

    /// Prepares the app-owned native model root.
    /// Checks pinned specifications and verifies integrity.
    /// If assets are missing or corrupted, copies from sourceRoot or downloads via HTTPS with pinned SHA-256.
    /// Uses atomic staging to prevent partial states.
    public static func prepare(
        modelRoot: URL,
        sourceRoot: URL? = nil,
        parakeet: Bool = true,
        allowDownload: Bool = true,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws {
        if isCancelled?() == true {
            throw PipelineError("cancelled")
        }

        let fm = FileManager.default

        // Path containment check: ensure no directory traversal outside target
        guard !modelRoot.path.contains("/..") else {
            throw NSError(
                domain: "ModelAssets",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Путь к моделям содержит недопустимые переходы: \(modelRoot.path)"]
            )
        }

        let standardizedRoot = modelRoot.standardizedFileURL
        let (initialReady, _) = checkAvailability(modelRoot: standardizedRoot, parakeet: parakeet, verifyChecksums: true)
        if initialReady {
            onProgress?("Все модели уже проверены и готовы.")
            return
        }

        try fm.createDirectory(at: standardizedRoot, withIntermediateDirectories: true)

        var specs = [gigaamSpec, vadSpec, nemotronSpec]
        if parakeet {
            specs.append(parakeetSpec)
        }

        for spec in specs {
            if isCancelled?() == true {
                throw PipelineError("cancelled")
            }

            let finalDir = standardizedRoot.appendingPathComponent(spec.name)

            // Reject symlink directories that escape root or point outside
            if fm.fileExists(atPath: finalDir.path) {
                let attrs = try? fm.attributesOfItem(atPath: finalDir.path)
                if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                    throw NSError(
                        domain: "ModelAssets",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Директория модели не может быть символической ссылкой: \(finalDir.path)"]
                    )
                }
                guard finalDir.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(standardizedRoot.path) else {
                    throw NSError(
                        domain: "ModelAssets",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Директория модели выходит за пределы корня: \(finalDir.path)"]
                    )
                }
            }

            // Check if this model is already 100% complete and valid
            let isComplete: Bool = {
                for file in spec.files {
                    let path = finalDir.appendingPathComponent(file.filename)
                    guard fm.fileExists(atPath: path.path),
                          let actual = try? computeSHA256(at: path, isCancelled: isCancelled),
                          actual == file.sha256 else {
                        return false
                    }
                }
                return true
            }()

            if isComplete {
                onProgress?("Модель \(spec.name) проверена.")
                continue
            }

            onProgress?("Подготовка модели \(spec.name)...")

            // Create temporary staging directory within standardizedRoot
            let stagingDir = standardizedRoot.appendingPathComponent(".staging-\(spec.name)-\(UUID().uuidString.prefix(8))")
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            var stagingSucceeded = false
            defer {
                if !stagingSucceeded {
                    try? fm.removeItem(at: stagingDir)
                }
            }

            for file in spec.files {
                if isCancelled?() == true {
                    throw PipelineError("cancelled")
                }

                let destFile = stagingDir.appendingPathComponent(file.filename)
                var fileAcquired = false

                // 1. Try from sourceRoot if provided
                if let source = sourceRoot {
                    let srcCandidates = [
                        source.appendingPathComponent(spec.name).appendingPathComponent(file.filename),
                        source.appendingPathComponent(file.filename)
                    ]
                    for candidate in srcCandidates {
                        if fm.fileExists(atPath: candidate.path),
                           let actual = try? computeSHA256(at: candidate, isCancelled: isCancelled),
                           actual == file.sha256 {
                            try fm.copyItem(at: candidate, to: destFile)
                            fileAcquired = true
                            break
                        }
                    }
                }

                // 2. Try from existing destination if present and valid
                if !fileAcquired {
                    let existingFile = finalDir.appendingPathComponent(file.filename)
                    if fm.fileExists(atPath: existingFile.path),
                       let actual = try? computeSHA256(at: existingFile, isCancelled: isCancelled),
                       actual == file.sha256 {
                        try fm.copyItem(at: existingFile, to: destFile)
                        fileAcquired = true
                    }
                }

                // 3. Download from Hugging Face if allowed
                if !fileAcquired {
                    guard allowDownload else {
                        throw NSError(
                            domain: "ModelAssets",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Файл \(spec.name)/\(file.filename) отсутствует и скачивание запрещено."]
                        )
                    }
                    guard let downloadURL = URL(string: "https://huggingface.co/\(spec.repo)/resolve/\(spec.revision)/\(file.filename)") else {
                        throw NSError(domain: "ModelAssets", code: 4, userInfo: [NSLocalizedDescriptionKey: "Некорректный URL для \(spec.repo)/\(file.filename)"])
                    }
                    onProgress?("Скачивание \(spec.name)/\(file.filename)...")
                    try download(
                        from: downloadURL,
                        to: destFile,
                        expectedSHA256: file.sha256,
                        isCancelled: isCancelled,
                        onProgress: onProgress
                    )
                    fileAcquired = true
                }
            }

            // Verify all files in stagingDir before atomic replace
            for file in spec.files {
                if isCancelled?() == true {
                    throw PipelineError("cancelled")
                }
                let stagedPath = stagingDir.appendingPathComponent(file.filename)
                let actual = try computeSHA256(at: stagedPath, isCancelled: isCancelled)
                guard actual == file.sha256 else {
                    throw NSError(
                        domain: "ModelAssets",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Ошибка верификации контрольной суммы \(spec.name)/\(file.filename) в staging."]
                    )
                }
            }

            // Atomic publication of stagingDir to finalDir
            if fm.fileExists(atPath: finalDir.path) {
                // Use renamex_np with RENAME_SWAP for atomic exchange without crash window
                let swapResult = renamex_np(stagingDir.path, finalDir.path, UInt32(RENAME_SWAP))
                if swapResult == 0 {
                    stagingSucceeded = true
                    try? fm.removeItem(at: stagingDir)
                } else {
                    let backupDir = standardizedRoot.appendingPathComponent(".old-\(spec.name)-\(UUID().uuidString.prefix(8))")
                    try fm.moveItem(at: finalDir, to: backupDir)
                    do {
                        try fm.moveItem(at: stagingDir, to: finalDir)
                        stagingSucceeded = true
                        try? fm.removeItem(at: backupDir)
                    } catch {
                        try? fm.moveItem(at: backupDir, to: finalDir)
                        throw error
                    }
                }
            } else {
                try fm.moveItem(at: stagingDir, to: finalDir)
                stagingSucceeded = true
            }
        }

        let (finalReady, missing) = checkAvailability(modelRoot: standardizedRoot, parakeet: parakeet, verifyChecksums: true)
        guard finalReady else {
            throw NSError(
                domain: "ModelAssets",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "После подготовки в \(modelRoot.path) отсутствуют или повреждены файлы: \(missing.joined(separator: ", "))"]
            )
        }
    }

    private static func download(
        from url: URL,
        to destination: URL,
        expectedSHA256: String,
        maxRetries: Int = 2,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws {
        var lastError: Error?
        for attempt in 1...maxRetries {
            if isCancelled?() == true {
                throw PipelineError("cancelled")
            }

            let semaphore = DispatchSemaphore(value: 0)
            let box = DownloadResultBox()

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 180.0
            config.timeoutIntervalForResource = 3600.0
            config.connectionProxyDictionary = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any]
            let session = URLSession(configuration: config)

            let task = session.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    box.result = .failure(error)
                } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    box.result = .failure(NSError(
                        domain: "ModelAssets",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) при загрузке \(url.absoluteString)"]
                    ))
                } else if let tempURL = tempURL {
                    let tempDest = destination.deletingLastPathComponent().appendingPathComponent(".dl-\(UUID().uuidString.prefix(8))")
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: tempDest)
                        box.result = .success(tempDest)
                    } catch {
                        box.result = .failure(error)
                    }
                } else {
                    box.result = .failure(NSError(domain: "ModelAssets", code: -1, userInfo: nil))
                }
                semaphore.signal()
            }
            task.resume()

            var timedOut = true
            while timedOut {
                if isCancelled?() == true {
                    task.cancel()
                    semaphore.signal()
                    throw PipelineError("cancelled")
                }
                let waitResult = semaphore.wait(timeout: .now() + .milliseconds(100))
                if waitResult == .success {
                    timedOut = false
                }
            }

            switch box.result {
            case .success(let downloadedTemp):
                defer { try? FileManager.default.removeItem(at: downloadedTemp) }
                do {
                    let actualSHA = try computeSHA256(at: downloadedTemp, isCancelled: isCancelled)
                    guard actualSHA == expectedSHA256 else {
                        throw NSError(
                            domain: "ModelAssets",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Несовпадение контрольной суммы для \(url.lastPathComponent): ожидалось \(expectedSHA256), получено \(actualSHA)"]
                        )
                    }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: downloadedTemp, to: destination)
                    return
                } catch {
                    lastError = error
                }
            case .failure(let error):
                lastError = error
            case .none:
                lastError = NSError(domain: "ModelAssets", code: -1, userInfo: nil)
            }

            if attempt < maxRetries {
                onProgress?("Сбой загрузки (\(lastError?.localizedDescription ?? "ошибка")), повтор (попытка \(attempt + 1)/\(maxRetries))...")
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        throw lastError ?? NSError(domain: "ModelAssets", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить \(url.absoluteString)"])
    }
}
