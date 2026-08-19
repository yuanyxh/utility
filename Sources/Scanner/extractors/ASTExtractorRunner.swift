import Foundation

/// Runs AST-based extraction via Python subprocess.
///
/// For each supported file extension, tries the AST pipeline first
/// (ast_extractor.py → dispatches to Python ast module or Node + @babel/parser).
///
/// Falls back to returning nil (caller should use regex extractors as fallback).
enum ASTExtractorRunner {
    static let supportedExtensions: Set<String> = ["py", "js", "ts", "jsx", "tsx", "mjs", "cjs", "vue"]

    /// The Python venv created by MCPProcessManager (preferred).
    private static let venvPython = MCPProcessManager.pythonVenvPath

    /// Check whether the given file extension is supported by the AST pipeline.
    static func isSupported(_ ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    /// Input descriptor for batch AST extraction.
    struct BatchInput: Codable {
        let content: String
        let filePath: String
        let ext: String

        enum CodingKeys: String, CodingKey {
            case content, ext
            case filePath = "file_path"
        }
    }

    /// Extract symbols from multiple files in a single subprocess call (--batch mode).
    ///
    /// - Returns: Dictionary mapping filePath → symbols array if successful, or nil on overall failure.
    ///            Individual file errors are silently dropped (caller falls back to regex).
    static func extractBatch(_ files: [BatchInput]) -> [String: [SymbolRecord]] {
        guard !files.isEmpty else { return [:] }
        guard let scriptPath = findScript() else {
            debugLog("[AST] ast_extractor.py not found in bundle")
            return [:]
        }
        guard let pythonPath = findPython() else {
            debugLog("[AST] No Python available for AST extraction")
            return [:]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath, "--batch"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        // 边读边存 stdout:批量 AST 输出可能超过 pipe buffer(64KB),
        // 等待期间不读会导致子进程写满阻塞、无法退出,被 30s 超时误杀
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

            // Write JSON array to stdin, then close
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(files)
            inputPipe.fileHandleForWriting.write(jsonData)
            inputPipe.fileHandleForWriting.closeFile()

            // Wait with timeout (30s for batch)
            let deadline = DispatchTime.now() + 30.0
            while proc.isRunning, .now() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // 停止异步读取,同步 drain 剩余(handler 可能没读完退出瞬间的尾部数据)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                debugLog("[AST] Batch subprocess timed out")
                return [:]
            }
            while let chunk = outputPipe.fileHandleForReading.availableData as Data?, !chunk.isEmpty {
                outputLock.lock()
                outputData.append(chunk)
                outputLock.unlock()
            }
            guard !outputData.isEmpty,
                  let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any]
            else {
                return [:]
            }

            // Parse per-file results
            var results: [String: [SymbolRecord]] = [:]
            for (filePath, value) in json {
                guard let entry = value as? [String: Any] else { continue }
                if let symbolsJSON = entry["symbols"] as? [[String: Any]] {
                    let symbols = symbolsJSON.compactMap { dict -> SymbolRecord? in
                        guard let name = dict["name"] as? String,
                              let kind = dict["kind"] as? String else { return nil }
                        return SymbolRecord(
                            filePath: filePath,
                            name: name,
                            kind: kind,
                            signature: dict["signature"] as? String,
                            docComment: dict["doc_comment"] as? String,
                            visibility: dict["visibility"] as? String,
                            startLine: dict["start_line"] as? Int,
                            endLine: dict["end_line"] as? Int,
                        )
                    }
                    results[filePath] = symbols
                }
                // Error results are silently skipped (caller falls back to regex)
            }

            return results
        } catch {
            debugLog("[AST] Batch subprocess error: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Run AST extraction for a file.
    ///
    /// - Returns: `[SymbolRecord]` on success, `nil` on any failure
    ///   (script not found, parse error, timeout — caller should fall back to regex).
    static func extract(from content: String, filePath: String, ext: String) -> [SymbolRecord]? {
        guard isSupported(ext) else { return nil }
        guard let scriptPath = findScript() else {
            debugLog("[AST] ast_extractor.py not found in bundle")
            return nil
        }
        guard let pythonPath = findPython() else {
            debugLog("[AST] No Python available for AST extraction")
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath, "--ext", ext, "--file-path", filePath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        // 边读边存 stdout,避免子进程输出超 pipe buffer 时阻塞(与 extractBatch 同模式)
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

            // Write content to stdin, then close
            if let data = content.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()

            // Wait with timeout
            let deadline = DispatchTime.now() + 15.0
            while proc.isRunning, .now() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // 停止异步读取,同步 drain 剩余(handler 可能没读完退出瞬间的尾部数据)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                debugLog("[AST] Subprocess timed out, killed")
                return nil
            }
            while let chunk = outputPipe.fileHandleForReading.availableData as Data?, !chunk.isEmpty {
                outputLock.lock()
                outputData.append(chunk)
                outputLock.unlock()
            }
            guard !outputData.isEmpty,
                  let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any]
            else {
                return nil
            }

            // Check for error response
            if json["error"] != nil {
                return nil
            }

            guard let symbolsJSON = json["symbols"] as? [[String: Any]] else { return nil }

            return symbolsJSON.compactMap { dict -> SymbolRecord? in
                guard let name = dict["name"] as? String,
                      let kind = dict["kind"] as? String else { return nil }
                return SymbolRecord(
                    filePath: filePath,
                    name: name,
                    kind: kind,
                    signature: dict["signature"] as? String,
                    docComment: dict["doc_comment"] as? String,
                    visibility: dict["visibility"] as? String,
                    startLine: dict["start_line"] as? Int,
                    endLine: dict["end_line"] as? Int,
                )
            }
        } catch {
            debugLog("[AST] Subprocess error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    /// Find ast_extractor.py in the bundle or development source directory.
    private static func findScript() -> String? {
        // In SPM, resources are at Bundle.module.resourceURL
        guard let resourceURL = Bundle.module.resourceURL else {
            debugLog("[AST] No bundle resource URL")
            return nil
        }

        let scriptsDir = resourceURL.appendingPathComponent("MCPScripts")
        let bundlePath = scriptsDir.appendingPathComponent("ast_extractor.py").path
        if FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }

        // Fallback: development path (next to compiled bundle)
        let devBase = resourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = devBase.appendingPathComponent("MCPScripts/ast_extractor.py").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return nil
    }

    /// Find the Python binary: prefer MCP venv, fall back to system PATH.
    private static func findPython() -> String? {
        let venv = venvPython
        if FileManager.default.fileExists(atPath: venv) {
            return venv
        }

        // Fall back to system python3
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
}
