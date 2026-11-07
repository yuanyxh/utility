import Foundation

struct CommandResult: Sendable {
    var exitCode: Int32
    var timedOut: Bool
    var output: String

    var ok: Bool { !timedOut && exitCode == 0 }
}

/// Runs a tool to completion with a timeout, streaming output chunks as they arrive.
enum CommandRunner {
    static func run(
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        onOutput: ((String) -> Void)? = nil,
    ) -> CommandResult {
        guard let executable = arguments.first else {
            return CommandResult(exitCode: -1, timedOut: false, output: "empty command")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        if let environment {
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var output = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            output.append(chunk)
            lock.unlock()
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                onOutput?(text)
            }
        }

        guard (try? process.run()) != nil else {
            return CommandResult(
                exitCode: -1,
                timedOut: false,
                output: "failed to launch \(executable)",
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let timedOut = process.isRunning
        if timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        lock.unlock()

        return CommandResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            timedOut: timedOut,
            output: String(data: output, encoding: .utf8) ?? "",
        )
    }
}
