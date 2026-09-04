import Foundation

/// Python 脚本统一执行入口。
///
/// 所有 py 脚本（server.py / summarize.py / token_proxy.py / ast_extractor.py /
/// prepare_article_source.py / gen_article_generic.py）的 venv 定位、脚本路径解析、
/// 环境变量构造、一次性执行与常驻守护都收敛到这里，各调用方不再各自实现。
/// 业务决策（状态语义、事件广播、复用探测、通知）仍由组合方（MCPProcessManager /
/// TokenProxyManager）负责，本类只提供通用骨架。
enum PythonScriptRunner {
    // MARK: - venv 路径（唯一来源）

    /// Path to the Python venv where MCP dependencies are installed.
    /// 自动探测系统 Python 版本，构造对应的 venv 路径。
    /// Created by: `python3.X -m venv ~/.config/utility/mcp-venv && pip install -r requirements.txt`
    static var pythonVenvPath: String {
        let venvDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/utility/mcp-venv")
            .path

        // 探测系统 Python 版本（如 python3.12）
        let pythonVersion = detectPythonVersion()

        if let version = pythonVersion {
            // 尝试精确版本路径：~/.config/utility/mcp-venv/bin/python3.12
            let versionedPath = "\(venvDir)/bin/python\(version)"
            if FileManager.default.fileExists(atPath: versionedPath) {
                return versionedPath
            }
        }

        // 回退到通用路径：~/.config/utility/mcp-venv/bin/python3
        return "\(venvDir)/bin/python3"
    }

    /// 探测系统 Python 版本号（如 "12"），失败返回 nil
    private static func detectPythonVersion() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", "--version"]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 解析 "Python 3.12.1" → "12"
        let components = output.components(separatedBy: " ").last?.components(separatedBy: ".")
        return components?.first
    }

    /// 解析可用的 python 可执行文件：优先 mcp venv，缺失时回退系统 python3。
    static func resolvePython() -> String? {
        if FileManager.default.fileExists(atPath: pythonVenvPath) {
            return pythonVenvPath
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-c", "command -v python3 || command -v python"]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 脚本路径解析（唯一来源）

    /// Resolve path to a script in MCPScripts bundle directory.
    /// Checks bundle first (packaged app), then dev source directory.
    static func findScript(named name: String) -> String? {
        // In SPM, resources are at Bundle.module.resourceURL
        guard let resourceURL = Bundle.module.resourceURL else {
            debugLog("[ScriptRunner] No bundle resource URL")
            return nil
        }

        let scriptsDir = resourceURL.appendingPathComponent("MCPScripts")
        let scriptPath = scriptsDir.appendingPathComponent(name).path

        if FileManager.default.fileExists(atPath: scriptPath) {
            return scriptPath
        }

        // Fallback: development path (source directory)
        let devBase = resourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = devBase.appendingPathComponent("MCPScripts/\(name)").path

        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return nil
    }

    // MARK: - 环境变量（唯一来源）

    /// 公共基础环境变量：AI 配置 + 数据目录 + 笔记目录 + 非缓冲输出 + 用户名 + 超时配置。
    /// 各脚本专属变量（MCP_PORT / MODEL_PROXY_* / QDRANT_PATH 等）由调用方经
    /// `environment(overrides:)` 追加，保持「Swift 侧 env 收敛」。
    static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["UTILITY_DATA_DIR"] = AppPaths.configDir.path

        // 当前系统用户名（传给 Python 层 DEFAULT_USER_ID）
        let username = NSUserName()
        if !username.isEmpty { env["UTILITY_USER_ID"] = username }

        // 超时配置（从 GeneralConfig 读取）
        let general = ConfigManager.shared.config.general
        if general.httpTimeout > 0 {
            env["SERVER_TIMEOUT"] = String(general.httpTimeout)
        }
        if general.aiTimeout > 0 {
            env["AGENT_TIMEOUT"] = String(Int(general.aiTimeout))
        }

        // ai 配置
        let ai = ConfigManager.shared.config.ai
        if !ai.apiKey.isEmpty { env["DEEPSEEK_API_KEY"] = ai.apiKey }
        if !ai.baseURL.isEmpty { env["SUMMARY_API_URL"] = ai.baseURL }
        if !ai.model.isEmpty { env["SUMMARY_MODEL"] = ai.model }

        // mcp 路径配置（token_proxy 也需要 NOTES_DIR，故放在公共层）
        if let mcp = ConfigManager.shared.config.mcp {
            // 空字符串 = 使用默认路径 ~/.utility/notes/
            let notesDir: String = if mcp.knowledgeBasePath.isEmpty {
                AppPaths.configDir
                    .appendingPathComponent("notes").path
            } else {
                (mcp.knowledgeBasePath as NSString).expandingTildeInPath
            }
            env["NOTES_DIR"] = notesDir
        }
        return env
    }

    /// baseEnvironment + 脚本专属 overrides。
    static func environment(overrides: [String: String]) -> [String: String] {
        var env = baseEnvironment()
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }

    // MARK: - Shell 命令构造（TaskScheduler .sh 任务用）

    /// 生成 shell 命令字符串：`KEY=VALUE ... pythonVenv script args`。
    /// TaskScheduler 的 .sh 走 `/bin/bash -c`，子进程继承 app 受限 PATH 且
    /// TaskExecConfig.toProcess() 不设环境变量，故环境必须以 `KEY=VALUE` 前缀内联。
    ///
    /// 注意：只内联调用方显式给出的变量（environmentOverrides），不要塞入
    /// baseEnvironment()——它从 ProcessInfo.processInfo.environment 起步会引入
    /// 全部继承环境变量，内联进命令会污染且值含空格/特殊字符。bash 本身会继承
    /// 父进程环境，这里只需注入脚本需要的覆盖项（与既有调用行为一致）。
    static func shellCommand(
        script: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:]
    ) -> String {
        var parts: [String] = []
        // 排序保证输出稳定（KEY 顺序不影响 bash 语义）
        for key in environmentOverrides.keys.sorted() {
            parts.append("\(key)=\(environmentOverrides[key] ?? "")")
        }
        parts.append(pythonVenvPath)
        parts.append(script)
        parts.append(contentsOf: arguments)
        return parts.joined(separator: " ")
    }

    // MARK: - 一次性执行（AST batch / 单文件）

    /// 以 venv python 执行脚本，写入可选 stdin，边读边存 stdout（避免 pipe buffer
    /// 写满阻塞子进程），超时 kill 并抛错。
    /// - Returns: stdout 完整字节。
    static func runCaptureOutput(
        scriptPath: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) throws -> Data {
        guard let pythonPath = resolvePython() else {
            throw PythonProcessError.pythonUnavailable
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath] + arguments

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        // 边读边存 stdout：批量 AST 输出可能超过 pipe buffer(64KB)，
        // 等待期间不读会导致子进程写满阻塞、无法退出，被超时误杀。
        var outputData = Data()
        let outputLock = NSLock()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputLock.lock()
            outputData.append(chunk)
            outputLock.unlock()
        }

        do {
            try proc.run()

            if let stdin {
                inputPipe.fileHandleForWriting.write(stdin)
            }
            inputPipe.fileHandleForWriting.closeFile()

            // Wait with timeout
            let deadline = DispatchTime.now() + timeout
            while proc.isRunning, .now() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // 停止异步读取，同步 drain 剩余（handler 可能没读完退出瞬间的尾部数据）
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                throw PythonProcessError.timeout(script: scriptPath)
            }
            while let chunk = outputPipe.fileHandleForReading.availableData as Data?, !chunk.isEmpty {
                outputLock.lock()
                outputData.append(chunk)
                outputLock.unlock()
            }

            return outputData
        } catch let error as PythonProcessError {
            throw error
        } catch {
            throw PythonProcessError.launchFailed(error.localizedDescription)
        }
    }
}

enum PythonProcessError: Error, LocalizedError {
    case pythonUnavailable
    case timeout(script: String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            "没有可用的 Python（mcp-venv 与系统 python3 均不可用）"
        case let .timeout(script):
            "脚本 \(script) 执行超时"
        case let .launchFailed(msg):
            "Python 进程启动失败: \(msg)"
        }
    }
}
