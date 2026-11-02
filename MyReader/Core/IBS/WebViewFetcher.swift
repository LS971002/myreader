import Foundation
import WebKit
import UIKit

/// requestByWebView 抓取：隐藏 WKWebView 加载页面 → 执行 webHtmlEvaluateJS 取 HTML。
final class WebViewFetcher: NSObject, WKNavigationDelegate {
    static let shared = WebViewFetcher()

    private var loadContinuation: CheckedContinuation<String, Error>?
    private var evaluateJS: String?
    private var timedOut = false
    private let timeout: TimeInterval = 20

    enum WebViewError: LocalizedError {
        case timeout
        case failed(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .timeout: return "WebView 加载超时"
            case .failed(let reason): return "WebView 加载失败：\(reason)"
            case .noContent: return "WebView 未取得内容"
            }
        }
    }

    /// 加载页面并取回 HTML。
    /// - Parameters:
    ///   - url: 完整 URL
    ///   - headers: 请求头（含动态 Cookie / Referer）
    ///   - js: 书源 webHtmlEvaluateJS（为空时用默认取整页 HTML）
    func fetch(url: String, headers: [String: String], js: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.loadContinuation = continuation
                self.evaluateJS = (js?.isEmpty == false) ? js : nil
                self.timedOut = false

                guard let urlObject = URL(string: url) else {
                    self.finish(.failure(WebViewError.failed("无效 URL")))
                    return
                }

                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                        configuration: config)
                webView.navigationDelegate = self
                webView.isHidden = true

                // 挂到窗口层级（离屏 WKWebView 才能可靠执行 JS）
                if let window = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                    window.addSubview(webView)
                }
                self.currentWebView = webView

                var request = URLRequest(url: urlObject)
                for (name, value) in headers {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                webView.load(request)

                // 超时守卫
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    if self.loadContinuation != nil {
                        self.timedOut = true
                        self.finish(.failure(WebViewError.timeout))
                    }
                }
            }
        }
    }

    private weak var currentWebView: WKWebView?

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // 延迟让 JS 跑一会（动态渲染站点）
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard self.loadContinuation != nil, !self.timedOut else { return }
            await self.extractContent(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            // 部分站点导航失败但页面已可用，仍尝试取内容
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard self.loadContinuation != nil else { return }
            if let html = try? await self.rawHTML(from: webView), !html.isEmpty {
                self.finish(.success(html))
            } else {
                self.finish(.failure(WebViewError.failed(error.localizedDescription)))
            }
        }
    }

    @MainActor
    private func extractContent(from webView: WKWebView) async {
        if let js = evaluateJS {
            let result = try? await webView.evaluateJavaScript(js)
            if let html = result as? String, !html.isEmpty {
                finish(.success(html))
                return
            }
            // JS 结果非字符串：退回整页 HTML
        }
        if let html = try? await rawHTML(from: webView) {
            finish(.success(html))
        } else {
            finish(.failure(WebViewError.noContent))
        }
    }

    @MainActor
    private func rawHTML(from webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript(
            "document.documentElement.outerHTML")
        return (result as? String) ?? ""
    }

    private func finish(_ result: Result<String, Error>) {
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(with: result)
        }
        Task { @MainActor in
            self.currentWebView?.stopLoading()
            self.currentWebView?.removeFromSuperview()
            self.currentWebView = nil
        }
    }
}
