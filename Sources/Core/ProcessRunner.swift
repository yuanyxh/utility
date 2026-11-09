import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let truncated: Bool
    let timedOut: Bool
    /// Drain threads had not reached EOF; output may miss its tail.
    let outputIncomplete: Bool

    var ok: Bool { !timedOut && exitCode == 0 }

    /// stdout followed by stderr; interleaving is not preserved.
    var output: String { stdout + stderr }
}

enum ProcessError: Error {
    case launchFailed(String)
}

/// Runs a process without a shell, with a timeout and a hard cap on captured
/// output. Output beyond the cap is drained and discarded so the child never
/// blocks on a full pipe.
enum ProcessRunner {
    private static let defaultMaxBytes = 2 * 1024 * 1024

    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        maxBytes: Int = defaultMaxBytes,
        environment: [String: String]? = nil,
        onOutput: ((String) -> Void)? = nil,
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
                        environment: environment,
                        onOutput: onOutput,
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking entry point for synchronous callers (probes, installers, CLI checks).
    /// `arguments[0]` is the executable, matching the shape those call sites already use.
    static func runSync(
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        onOutput: ((String) -> Void)? = nil,
    ) -> ProcessResult {
        guard let executable = arguments.first else {
            return ProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: "empty command",
                truncated: false,
                timedOut: false,
                outputIncomplete: false,
            )
        }
        do {
            return try execute(
                executable: executable,
                arguments: Array(arguments.dropFirst()),
                workingDirectory: nil,
                timeout: timeout,
                maxBytes: defaultMaxBytes,
                environment: environment,
                onOutput: onOutput,
            )
        } catch {
            return ProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: "failed to launch \(executable): \(error.localizedDescription)",
                truncated: false,
                timedOut: false,
                outputIncomplete: false,
            )
        }
    }

    private static func execute(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        maxBytes: Int,
        environment: [String: String]?,
        onOutput: ((String) -> Void)?,
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

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
        let callbackQueue = DispatchQueue(label: "utility.process.output")
        drain(
            stdoutPipe.fileHandleForReading,
            into: stdoutBuffer,
            group: group,
            callbackQueue: callbackQueue,
            onOutput: onOutput,
        )
        drain(
            stderrPipe.fileHandleForReading,
            into: stderrBuffer,
            group: group,
            callbackQueue: callbackQueue,
            onOutput: onOutput,
        )

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
        // A grandchild can inherit the pipe and outlive the direct child, so EOF
        // may never arrive. Bound the wait instead of blocking the caller forever.
        let drainFinished = group.wait(timeout: .now() + 2) == .success

        let (stdout, stdoutTruncated) = stdoutBuffer.snapshot()
        let (stderr, stderrTruncated) = stderrBuffer.snapshot()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            truncated: stdoutTruncated || stderrTruncated,
            timedOut: timedOut,
            outputIncomplete: !drainFinished,
        )
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: OutputBuffer,
        group: DispatchGroup,
        callbackQueue: DispatchQueue,
        onOutput: ((String) -> Void)?,
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if let onOutput {
                    let text = String(decoding: chunk, as: UTF8.self)
                    callbackQueue.async { onOutput(text) }
                }
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
