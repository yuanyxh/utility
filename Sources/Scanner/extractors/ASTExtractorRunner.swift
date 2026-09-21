import Foundation

/// Runs AST-based extraction via Python subprocess.
///
/// For each supported file extension, tries the AST pipeline first
/// (ast_extractor.py → dispatches to Python ast module or Node + @babel/parser).
///
/// Falls back to returning nil (caller should use regex extractors as fallback).
enum ASTExtractorRunner {
    static let supportedExtensions: Set<String> = ["py", "js", "ts", "jsx", "tsx", "mjs", "cjs", "vue"]

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
        guard let scriptPath = PythonScriptRunner.findScript(named: PythonScripts.astExtractor) else {
            debugLog("[AST] \(PythonScripts.astExtractor) not found in bundle")
            return [:]
        }

        let jsonData: Data
        do {
            jsonData = try JSONEncoder().encode(files)
        } catch {
            debugLog("[AST] Batch encode error: \(error.localizedDescription)")
            return [:]
        }

        do {
            let outputData = try PythonScriptRunner.runCaptureOutput(
                scriptPath: scriptPath,
                arguments: ["--batch"],
                stdin: jsonData,
                timeout: 30.0,
            )
            return parseBatch(outputData, fallbackFilePath: nil)
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
        guard let scriptPath = PythonScriptRunner.findScript(named: PythonScripts.astExtractor) else {
            debugLog("[AST] \(PythonScripts.astExtractor) not found in bundle")
            return nil
        }

        do {
            let outputData = try PythonScriptRunner.runCaptureOutput(
                scriptPath: scriptPath,
                arguments: ["--ext", ext, "--file-path", filePath],
                stdin: content.data(using: .utf8),
                timeout: 15.0,
            )
            return parseSingle(outputData, fallbackFilePath: filePath)
        } catch {
            debugLog("[AST] Subprocess error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - JSON 解析

    /// 解析 batch 输出：JSON 字典 { filePath → { symbols } }。
    private static func parseBatch(_ data: Data, fallbackFilePath _: String?) -> [String: [SymbolRecord]] {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        // Parse per-file results
        var results: [String: [SymbolRecord]] = [:]
        for (filePath, value) in json {
            guard let entry = value as? [String: Any] else { continue }
            if let symbolsJSON = entry["symbols"] as? [[String: Any]] {
                let symbols = symbolsJSON.compactMap { dict -> SymbolRecord? in
                    parseSymbol(dict, defaultFilePath: filePath)
                }
                results[filePath] = symbols
            }
            // Error results are silently skipped (caller falls back to regex)
        }
        return results
    }

    /// 解析单文件输出：JSON { error? / symbols }。
    private static func parseSingle(_ data: Data, fallbackFilePath: String) -> [SymbolRecord]? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        // Check for error response
        if json["error"] != nil {
            return nil
        }

        guard let symbolsJSON = json["symbols"] as? [[String: Any]] else { return nil }

        return symbolsJSON.compactMap { dict -> SymbolRecord? in
            parseSymbol(dict, defaultFilePath: fallbackFilePath)
        }
    }

    private static func parseSymbol(_ dict: [String: Any], defaultFilePath: String) -> SymbolRecord? {
        guard let name = dict["name"] as? String,
              let kind = dict["kind"] as? String else { return nil }
        return SymbolRecord(
            filePath: defaultFilePath,
            name: name,
            kind: kind,
            signature: dict["signature"] as? String,
            docComment: dict["doc_comment"] as? String,
            visibility: dict["visibility"] as? String,
            startLine: dict["start_line"] as? Int,
            endLine: dict["end_line"] as? Int,
        )
    }
}
