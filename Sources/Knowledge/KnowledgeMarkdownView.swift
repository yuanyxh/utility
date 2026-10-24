import Cocoa
import WebKit

/// Markdown renderer backed by WKWebView + bundled marked.js (GFM).
/// WebKit provides text selection, copying and link handling; there is no
/// per-intent font mapping to maintain.
final class KnowledgeMarkdownView: NSView, WKNavigationDelegate {
    private var webView: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder _: NSCoder) { nil }

    func render(_ markdown: String) {
        let web = webView ?? makeWebView()
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        web.loadHTMLString(Self.page(markdown: text), baseURL: nil)
    }

    private func makeWebView() -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        web.underPageBackgroundColor = .clear
        // Private but stable: without it WKWebView paints an opaque white card that
        // clashes with the blurred panel. `responds(to: "setDrawsBackground:")` is false
        // here even though the KVC key works, so the guard cannot be used.
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: topAnchor),
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        webView = web
        return web
    }

    // MARK: - Links

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
    ) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    // MARK: - Page

    private static let markedScript: String = {
        let candidates = [
            Bundle.module.url(
                forResource: "marked.umd", withExtension: "js", subdirectory: "markdown",
            ),
            Bundle.module.url(forResource: "marked.umd", withExtension: "js"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        debugLog("[Knowledge] marked.umd.js 缺失，Markdown 降级为纯文本")
        return ""
    }()

    /// CommonMark emphasis is punctuation-flanking; a closing `**` right after a
    /// full-width bracket never closes for CJK text. These inline extensions accept
    /// any non-blank closing delimiter, while fenced/inline code stays untouched.
    private static let markdownExtensions = """
    if (window.marked) {
      marked.use({
        extensions: [
          {
            name: 'cjkStrong',
            level: 'inline',
            start(src) { return src.indexOf('**'); },
            tokenizer(src) {
              const m = /^\\*\\*(?=\\S)([^\\n]*?\\S)\\*\\*/.exec(src);
              if (!m) return;
              return {
                type: 'cjkStrong', raw: m[0], text: m[1],
                tokens: this.lexer.inlineTokens(m[1]),
              };
            },
            renderer(token) {
              return '<strong>' + this.parser.parseInline(token.tokens) + '</strong>';
            },
          },
          {
            name: 'cjkDel',
            level: 'inline',
            start(src) { return src.indexOf('~~'); },
            tokenizer(src) {
              const m = /^~~(?=\\S)([^\\n]*?\\S)~~/.exec(src);
              if (!m) return;
              return {
                type: 'cjkDel', raw: m[0], text: m[1],
                tokens: this.lexer.inlineTokens(m[1]),
              };
            },
            renderer(token) {
              return '<del>' + this.parser.parseInline(token.tokens) + '</del>';
            },
          },
        ],
      });
    }
    """

    private static func jsonLiteral(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func page(markdown: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)</style>
        </head>
        <body>
        <div id="content"></div>
        <script>\(markedScript)</script>
        <script>\(markdownExtensions)</script>
        <script>
        const source = \(jsonLiteral(markdown));
        const el = document.getElementById('content');
        if (window.marked) {
          el.innerHTML = window.marked.parse(source, { gfm: true, breaks: false });
        } else {
          el.textContent = source;
        }
        </script>
        </body>
        </html>
        """
    }

    private static let css = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: transparent; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
      font-size: 13px;
      line-height: 1.6;
      color: #1d1d1f;
      padding: 10px 12px 16px;
      -webkit-font-smoothing: antialiased;
      overflow-x: hidden;
      overflow-wrap: anywhere;
      word-break: break-word;
      -webkit-user-select: text;
      user-select: text;
    }
    ::selection { background: rgba(0, 122, 255, .24); }
    @media (prefers-color-scheme: dark) {
      body { color: #f5f5f7; }
      a { color: #6cb4ff; }
      blockquote { color: rgba(235, 235, 245, .62); }
      ::selection { background: rgba(10, 132, 255, .42); }
      code {
        background: rgba(235, 235, 245, .14);
        border-color: rgba(235, 235, 245, .24);
      }
      pre {
        background: rgba(235, 235, 245, .08);
        border-color: rgba(235, 235, 245, .26);
      }
      th, td { border-color: rgba(235, 235, 245, .3); }
      th { background: rgba(235, 235, 245, .1); }
      hr { border-top-color: rgba(235, 235, 245, .26); }
    }
    h1, h2, h3, h4, h5, h6 {
      font-weight: 600; line-height: 1.35; margin: 16px 0 8px;
      overflow-wrap: anywhere;
    }
    h1 { font-size: 17px; margin-top: 4px; }
    h2 { font-size: 15px; }
    h3 { font-size: 13.5px; }
    h4, h5, h6 { font-size: 13px; }
    p { margin: 0 0 10px; }
    p:last-child { margin-bottom: 0; }
    ul, ol { margin: 0 0 10px; padding-left: 22px; }
    li { margin: 2px 0; overflow-wrap: anywhere; }
    li > p { margin: 0; }
    strong { font-weight: 600; }
    em { font-style: italic; }
    del { opacity: .75; }
    a {
      color: #0066cc; text-decoration: none;
      overflow-wrap: anywhere; word-break: break-word;
    }
    a:hover { text-decoration: underline; }
    code {
      font-family: SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      padding: 0 4px;
      border-radius: 4px;
      background: rgba(60, 60, 67, .12);
      border: 1px solid rgba(60, 60, 67, .22);
      overflow-wrap: anywhere;
    }
    pre {
      margin: 0 0 10px;
      padding: 10px;
      border-radius: 6px;
      background: rgba(60, 60, 67, .08);
      border: 1px solid rgba(60, 60, 67, .28);
      white-space: pre-wrap;
      word-break: break-word;
    }
    pre code {
      padding: 0; background: none; border: 0;
      font-size: 12px; white-space: inherit;
    }
    blockquote {
      margin: 0 0 10px;
      padding-left: 10px;
      border-left: 3px solid rgba(127, 127, 127, .35);
      color: rgba(60, 60, 67, .62);
    }
    table {
      width: 100%;
      margin: 0 0 12px;
      border-collapse: collapse;
      font-size: 12px;
      table-layout: auto;
    }
    th, td {
      border: 1px solid rgba(60, 60, 67, .38);
      padding: 5px 8px;
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    th { font-weight: 600; background: rgba(60, 60, 67, .1); }
    hr { border: none; border-top: 1px solid rgba(60, 60, 67, .3); margin: 14px 0; }
    img { max-width: 100%; height: auto; }
    input[type="checkbox"] { margin: 0 6px 0 0; vertical-align: middle; }
    ::-webkit-scrollbar { width: 0; height: 0; }
    """
}
