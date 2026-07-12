import Foundation

/// Vue SFC symbol extractor.
///
/// Delegates to the AST pipeline (ast_extractor.py) which:
/// 1. Extracts the <script> block (with lang="ts" detection)
/// 2. Parses via @babel/parser (Node.js)
/// 3. Returns extracted symbols
///
/// Falls back to empty array if AST pipeline is unavailable.
struct VueExtractor: SymbolExtractor {
    let language = "vue"
    let supportedExtensions: Set<String> = ["vue"]

    func extract(from content: String, filePath: String) -> [SymbolRecord] {
        ASTExtractorRunner.extract(from: content, filePath: filePath, ext: "vue") ?? []
    }
}
