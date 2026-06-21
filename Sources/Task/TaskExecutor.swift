import Foundation

public enum TaskExecutor {
    public struct Result {
        let success: Bool
        let output: String
        let error: String
    }

    /// 同步执行（调用方负责放到后台线程）
    public static func execute(_ config: TaskExecConfig) -> Result {
        switch config {
        case let .sh(cmd): return runShell(cmd)
        case let .js(cmd): return runJS(cmd)
        case let .shortcuts(cmd): return runShortcuts(cmd)
        case let .py(cmd): return runPython(cmd)
        }
    }

    // MARK: - Shell

    private static func runShell(_ cmd: String) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", cmd]
        return runProcess(task)
    }

    // MARK: - JavaScript (JXA)

    private static func runJS(_ code: String) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-l", "JavaScript", "-e", code]
        return runProcess(task)
    }

    // MARK: - Shortcuts

    private static func runShortcuts(_ name: String) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", name]
        return runProcess(task)
    }

    // MARK: - Python

    private static func runPython(_ code: String) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", "-c", code]
        return runProcess(task)
    }

    // MARK: - Process runner

    private static func runProcess(_ task: Process) -> Result {
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let error = String(data: errData, encoding: .utf8) ?? ""

            return Result(success: task.terminationStatus == 0, output: output, error: error)
        } catch {
            return Result(success: false, output: "", error: error.localizedDescription)
        }
    }
}
