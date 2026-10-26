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

    /// Extract symbols and imports from multiple files in a single subprocess call (--batch mode).
    static func extractBatchWithImports(_ files: [BatchInput]) -> [String: ASTFileResult] {
        guard !files.isEmpty else { return [:] }
        guard PythonScriptRunner.isGatewayAvailable else {
            debugLog("[AST] gateway unavailable, batch skipped")
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
                module: GatewayEntry.astExtractor,
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

    /// Symbol-only wrapper kept for existing callers.
    static func extractBatch(_ files: [BatchInput]) -> [String: [SymbolRecord]] {
        extractBatchWithImports(files).mapValues(\.symbols)
    }

    /// Run AST extraction for one file, returning symbols and imports.
    static func extractFileWithImports(
        from content: String, filePath: String, ext: String
    ) -> ASTFileResult? {
        guard isSupported(ext) else { return nil }
        guard PythonScriptRunner.isGatewayAvailable else {
            debugLog("[AST] gateway unavailable, single-file extraction skipped")
            return nil
        }

        do {
            let outputData = try PythonScriptRunner.runCaptureOutput(
                module: GatewayEntry.astExtractor,
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

    /// Symbol-only wrapper kept for existing callers.
    static func extract(from content: String, filePath: String, ext: String) -> [SymbolRecord]? {
        extractFileWithImports(from: content, filePath: filePath, ext: ext)?.symbols
    }

    // MARK: - JSON parsing

    /// Parse batch output: JSON dictionary { filePath → { symbols, imports } }.
    private static func parseBatch(_ data: Data, fallbackFilePath _: String?) -> [String: ASTFileResult] {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var results: [String: ASTFileResult] = [:]
        for (filePath, value) in json {
            guard let entry = value as? [String: Any] else { continue }
            let hasSymbols = entry["symbols"] != nil
            let hasImports = entry["imports"] != nil
            guard hasSymbols || hasImports else { continue } // errors are silently skipped
            results[filePath] = ASTFileResult(
                symbols: parseSymbols(entry["symbols"], filePath: filePath),
                imports: parseImports(entry["imports"], fromPath: filePath),
            )
        }
        return results
    }

    /// Parse single-file output: JSON { error? / symbols / imports }.
    private static func parseSingle(_ data: Data, fallbackFilePath: String) -> ASTFileResult? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if json["error"] != nil { return nil }
        guard json["symbols"] != nil || json["imports"] != nil else { return nil }
        return ASTFileResult(
            symbols: parseSymbols(json["symbols"], filePath: fallbackFilePath),
            imports: parseImports(json["imports"], fromPath: fallbackFilePath),
        )
    }

    private static func parseSymbols(_ value: Any?, filePath: String) -> [SymbolRecord] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { parseSymbol($0, defaultFilePath: filePath) }
    }

    private static func parseImports(_ value: Any?, fromPath: String) -> [ImportRecord] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { dict -> ImportRecord? in
            guard let raw = dict["raw_target"] as? String, !raw.isEmpty else { return nil }
            let kind = ImportKind(rawValue: dict["kind"] as? String ?? "") ?? .staticImport
            return ImportRecord(
                fromPath: fromPath,
                rawTarget: raw,
                kind: kind,
                line: dict["line"] as? Int,
                confidence: 1.0,
            )
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
