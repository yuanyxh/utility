import Foundation

/// A language-specific symbol extractor.
protocol SymbolExtractor {
    var language: String { get }
    var supportedExtensions: Set<String> { get }

    /// Extract symbols from file content at the given path.
    func extract(from content: String, filePath: String) -> [SymbolRecord]
}

// MARK: - Regex match helper

struct RegexMatch {
    let result: NSTextCheckingResult
    let string: String

    subscript(_ idx: Int) -> String {
        let range = result.range(at: idx)
        if range.location == NSNotFound { return "" }
        return (string as NSString).substring(with: range)
    }
}

extension NSRegularExpression {
    /// Returns a RegexMatch wrapping both the result and the original string.
    func match(_ string: String) -> RegexMatch? {
        let range = NSRange(string.startIndex ..< string.endIndex, in: string)
        guard let result = firstMatch(in: string, range: range) else { return nil }
        return RegexMatch(result: result, string: string)
    }
}
