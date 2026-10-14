import Foundation

final class OutputProbe: @unchecked Sendable {
    var updates: [String] = []
    var arrivedBeforeExit = false
}

@main struct Check {
    static func main() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
import sys, time
print('Шаг 1', flush=True)
time.sleep(0.2)
word = 'Загрузка'.encode()
sys.stdout.buffer.write(word[:1]); sys.stdout.flush()
time.sleep(0.1)
sys.stdout.buffer.write(word[1:] + b'\\n'); sys.stdout.flush()
print('Готово', flush=True)
"""]
        let pipe = Pipe()
        process.standardOutput = pipe
        let probe = OutputProbe()
        try process.run()
        let output = Transcription.readOutput(from: pipe.fileHandleForReading) { value in
            probe.updates.append(value)
            probe.arrivedBeforeExit = probe.arrivedBeforeExit || process.isRunning
        }
        process.waitUntilExit()
        precondition(output == "Шаг 1\nЗагрузка\nГотово\n")
        precondition(probe.arrivedBeforeExit && probe.updates.count >= 2)

        let large = Pipe()
        DispatchQueue.global().async {
            large.fileHandleForWriting.write(Data((String(repeating: "Строка\n", count: 20000) + "Конец\n").utf8))
            try? large.fileHandleForWriting.close()
        }
        let tail = Transcription.readOutput(from: large.fileHandleForReading, onOutput: nil)
        precondition(tail.count <= 12000 && tail.hasSuffix("Конец\n") && !tail.contains("�"))
        print("Live output, split UTF-8 and bounded log checks passed")
    }
}
