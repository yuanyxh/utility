import AppKit
import ArgumentParser
import Foundation
import WebKit

/// Google search through an offscreen WKWebView, emitted as one JSON line.
struct WebSearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "websearch",
        abstract: L10n.CLI.websearchAbstract,
    )

    @Option(name: .long, help: ArgumentHelp(L10n.CLI.websearchQueryHelp))
    var query: String

    @Option(name: .long, help: ArgumentHelp(L10n.CLI.websearchLimitHelp))
    var limit = 10

    @Option(name: .long, help: ArgumentHelp(L10n.CLI.websearchTimeoutHelp))
    var timeout = 20.0

    mutating func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let probe = GoogleSearchProbe(
            query: query,
            limit: limit,
            timeout: timeout,
        ) { payload, ok in
            print(payload)
            Darwin.exit(ok ? 0 : 1)
        }
        probe.start()
        app.run()
    }
}

private final class GoogleSearchProbe: NSObject, WKNavigationDelegate {
    private let query: String
    private let limit: Int
    private let timeout: TimeInterval
    private let completion: (String, Bool) -> Void
    private let webView: WKWebView
    private let window: NSWindow
    private let startedAt = Date()
    private var generation = 0
    private var finished = false

    init(
        query: String,
        limit: Int,
        timeout: TimeInterval,
        completion: @escaping (String, Bool) -> Void,
    ) {
        self.query = query
        self.limit = max(1, limit)
        self.timeout = max(1, timeout)
        self.completion = completion

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: configuration,
        )
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isMovable = false
        window = panel

        super.init()
        webView.navigationDelegate = self
        panel.contentView?.addSubview(webView)
    }

    func start() {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: "zh-CN"),
            URLQueryItem(name: "num", value: String(limit)),
        ]
        guard let url = components.url else {
            finish(status: "invalid_url", results: [], error: "bad query encoding")
            return
        }
        webView.load(URLRequest(url: url))
        generation += 1
        schedulePoll(generation, delay: 0.8)
    }

    private func schedulePoll(_ generation: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !self.finished, self.generation == generation else { return }
            self.poll(generation)
        }
    }

    private func poll(_ generation: Int) {
        webView.evaluateJavaScript(Self.extractJS(limit: limit)) { value, error in
            guard !self.finished, self.generation == generation else { return }
            let elapsed = Date().timeIntervalSince(self.startedAt)
            if let error {
                if elapsed >= self.timeout {
                    self.finish(
                        status: "render_timeout",
                        results: [],
                        error: error.localizedDescription,
                    )
                } else {
                    self.schedulePoll(generation, delay: 0.5)
                }
                return
            }
            let payload = Self.decode(value)
            let results = payload["results"] as? [[String: String]] ?? []
            if !results.isEmpty {
                self.finish(status: "ok", results: results, error: nil)
            } else if payload["captcha"] as? Bool == true {
                self.finish(status: "captcha", results: [], error: nil)
            } else if elapsed >= self.timeout {
                let status = payload["enablejs"] as? Bool == true ? "enablejs" : "empty"
                self.finish(status: status, results: [], error: nil)
            } else {
                self.schedulePoll(generation, delay: 0.5)
            }
        }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Error,
    ) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        finish(status: "network_error", results: [], error: nsError.localizedDescription)
    }

    private func finish(status: String, results: [[String: String]], error: String?) {
        guard !finished else { return }
        finished = true
        var payload: [String: Any] = [
            "ok": status == "ok",
            "engine": "google",
            "status": status,
            "query": query,
            "results": results,
            "elapsed_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "final_url": webView.url?.absoluteString ?? "",
        ]
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        completion(text, status == "ok")
    }

    private static func decode(_ value: Any?) -> [String: Any] {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func extractJS(limit: Int) -> String {
        """
        (function () {
          var body = document.body ? document.body.innerText : "";
          var hits = [];
          document.querySelectorAll("#search a h3, #rso a h3, a h3").forEach(function (h) {
            var a = h.closest("a");
            if (!a || !/^https?:/.test(a.href)) return;
            hits.push({ title: h.innerText, url: a.href });
          });
          var captcha = /unusual traffic|not a robot|recaptcha|verify you are human/i.test(body)
            || /\\/sorry\\//.test(location.href);
          var enablejs = /enablejs/.test(location.href);
          return JSON.stringify({
            results: hits.slice(0, \(limit)),
            captcha: captcha,
            enablejs: enablejs
          });
        })();
        """
    }
}
