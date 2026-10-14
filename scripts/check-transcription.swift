import Foundation
@main struct Check {
 static func main() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let recording = folder.appendingPathComponent("missing.m4a")
  do {
   _ = try await Transcription.run(recording: recording)
   preconditionFailure("Missing source accepted")
  } catch {
   precondition(error.localizedDescription.contains("Запись сохранена, но транскрибация не завершилась"))
   let log = try String(contentsOf: folder.appendingPathComponent("missing.transcription.log"), encoding: .utf8)
   precondition(log.contains("Missing source recording"))
  }
  do {
   _ = try await Transcription.run(recording: recording)
   preconditionFailure("Missing source accepted on retry")
  } catch {
   precondition(error.localizedDescription.contains("Запись сохранена, но транскрибация не завершилась"))
   let logs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
   precondition(logs.count == 2 && logs.allSatisfy { $0.pathExtension == "log" })
  }
  print("Transcription failure check passed")
 }
}
