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

// MARK: - Brace-depth body tracking

/// Tracks brace depth and pending symbol bodies for regex extractors.
///
/// `advance` updates the depth for one line and closes every body whose
/// opening depth has been passed. `attachSymbol` records where a just-added
/// symbol's body starts.
struct SymbolBodyTracker {
    private var braceDepth = 0
    private var bodyStack: [(symIdx: Int, bodyDepth: Int?)] = []

    /// Update depth without resolving pending bodies (used while a signature spans lines).
    mutating func advanceDepthOnly(_ line: String) -> (prevDepth: Int, newDepth: Int, openBraces: Int) {
        let openBraces = line.count(where: { $0 == "{" })
        let closeBraces = line.count(where: { $0 == "}" })
        let prevDepth = braceDepth
        braceDepth += openBraces - closeBraces
        return (prevDepth, braceDepth, openBraces)
    }

    mutating func advance(
        _ line: String, lineIdx: Int, symbols: inout [SymbolRecord],
    ) -> (prevDepth: Int, newDepth: Int, openBraces: Int) {
        let depth = advanceDepthOnly(line)

        while let top = bodyStack.last {
            if top.bodyDepth == nil {
                // Waiting for the body to open on a later line: settles if this line opens a brace
                if depth.openBraces > 0 {
                    if depth.newDepth == depth.prevDepth {
                        symbols[top.symIdx].endLine = lineIdx + 1
                        bodyStack.removeLast()
                    } else {
                        bodyStack[bodyStack.count - 1].bodyDepth = depth.newDepth
                    }
                }
                break
            }
            if let bodyDepth = top.bodyDepth, depth.newDepth < bodyDepth {
                symbols[top.symIdx].endLine = lineIdx + 1
                bodyStack.removeLast()
            } else {
                break
            }
        }

        return depth
    }

    mutating func attachSymbol(
        at index: Int, lineIdx: Int, depth: (prevDepth: Int, newDepth: Int, openBraces: Int),
        expectsBodyLater: Bool, symbols: inout [SymbolRecord],
    ) {
        if depth.openBraces > 0 {
            if depth.newDepth == depth.prevDepth {
                // Opens and closes on the same line (e.g. `func f() {}`)
                symbols[index].endLine = lineIdx + 1
            } else {
                bodyStack.append((symIdx: index, bodyDepth: depth.newDepth))
            }
        } else if expectsBodyLater {
            bodyStack.append((symIdx: index, bodyDepth: nil))
        } else {
            symbols[index].endLine = lineIdx + 1
        }
    }
}

// MARK: - Comment / string stripping

enum CommentStringStripper {
    /// Strip `//` and `/* */` comments and string literals, preserving newlines
    /// so the cleaned text keeps the original line count (line-number alignment).
    static func strip(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        let end = text.endIndex
        var inBlockComment = false
        var inLineComment = false
        var inString = false

        while i < end {
            let c = text[i]
            let next = text.index(after: i)

            if inBlockComment {
                if c == "*", next < end, text[next] == "/" {
                    inBlockComment = false
                    i = text.index(after: next)
                } else {
                    if c == "\n" || c == "\r" { result.append(c) }
                    i = next
                }
                continue
            }

            if inLineComment {
                if c == "\n" || c == "\r" { result.append(c) }
                if c == "\n" { inLineComment = false }
                i = next
                continue
            }

            if inString {
                if c == "\\", next < end {
                    i = text.index(after: next)
                    continue
                }
                if c == "\"" {
                    inString = false
                } else if c == "\n" || c == "\r" {
                    result.append(c)
                }
                i = next
                continue
            }

            if c == "/", next < end, text[next] == "/" {
                inLineComment = true
                i = text.index(after: next)
                continue
            }

            if c == "/", next < end, text[next] == "*" {
                inBlockComment = true
                i = text.index(after: next)
                continue
            }

            if c == "\"" {
                inString = true
                i = next
                continue
            }

            result.append(c)
            i = next
        }

        return result
    }
}
