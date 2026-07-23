import Foundation

/// Esecuzione di processi esterni con timeout e streaming delle righe,
/// sicura sotto strict concurrency (i readabilityHandler sono @Sendable).
struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Colleziona i byte di un pipe e spezza in righe per il callback.
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var lineBuffer = ""
        private let onLine: (@Sendable (String) -> Void)?

        init(onLine: (@Sendable (String) -> Void)?) {
            self.onLine = onLine
        }

        func ingest(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            var pendingLines: [String] = []
            if onLine != nil, let text = String(data: chunk, encoding: .utf8) {
                lineBuffer += text
                while let range = lineBuffer.range(of: "\n") {
                    pendingLines.append(String(lineBuffer[..<range.lowerBound]))
                    lineBuffer = String(lineBuffer[range.upperBound...])
                }
            }
            lock.unlock()
            for line in pendingLines { onLine?(line) }
        }

        func finish() -> String {
            lock.lock()
            let remainder = lineBuffer
            lineBuffer = ""
            let text = String(data: data, encoding: .utf8) ?? ""
            lock.unlock()
            if !remainder.isEmpty { onLine?(remainder) }
            return text
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 120,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outCollector = PipeCollector(onLine: onStdoutLine)
        let errCollector = PipeCollector(onLine: onStderrLine)
        outPipe.fileHandleForReading.readabilityHandler = { outCollector.ingest($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errCollector.ingest($0.availableData) }

        let box = ProcessBox(process)
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, box.process.isRunning else { return }
            box.process.terminate()
            // Escalation: se ignora SIGTERM, dopo 5s arriva SIGKILL
            // (altrimenti la coda resterebbe bloccata per sempre).
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled, box.process.isRunning {
                kill(box.process.processIdentifier, SIGKILL)
            }
        }
        defer { watchdog.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outCollector.ingest((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
        errCollector.ingest((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())

        return ProcessResult(
            status: process.terminationStatus,
            stdout: outCollector.finish(),
            stderr: errCollector.finish())
    }
}
