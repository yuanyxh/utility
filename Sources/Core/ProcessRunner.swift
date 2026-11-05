import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let truncated: Bool
    let timedOut: Bool
}

enum ProcessError: Error {
    case launchFailed(String)
}

/// Runs a process without a shell, with a timeout and a hard cap on captured
/// output. Output beyond the cap is drained and discarded so the child never
/// blocks on a full pipe.
enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        maxBytes: Int = 2 * 1024 * 1024,
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try execute(
                        executable: executable,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        timeout: timeout,
                        maxBytes: maxBytes,
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func execute(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        maxBytes: Int,
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        let stdoutBuffer = OutputBuffer(limit: maxBytes)
        let stderrBuffer = OutputBuffer(limit: maxBytes)
        let group = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdoutBuffer, group: group)
        drain(stderrPipe.fileHandleForReading, into: stderrBuffer, group: group)

        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning, Date() < grace {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        group.wait()

        let (stdout, stdoutTruncated) = stdoutBuffer.snapshot()
        let (stderr, stderrTruncated) = stderrBuffer.snapshot()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            truncated: stdoutTruncated || stderrTruncated,
            timedOut: timedOut,
        )
    }

    private static func drain(
        _ handle: FileHandle, into buffer: OutputBuffer, group: DispatchGroup,
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            group.leave()
        }
    }

    private final class OutputBuffer {
        private let limit: Int
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = limit - data.count
            guard remaining > 0 else {
                truncated = true
                return
            }
            if chunk.count > remaining {
                data.append(chunk.prefix(remaining))
                truncated = true
            } else {
                data.append(chunk)
            }
        }

        func snapshot() -> (Data, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, truncated)
        }
    }
}
