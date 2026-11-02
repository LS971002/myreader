import Foundation

/// IBS 引擎专用 HTTP 客户端：动态头（@dyn: 脚本设置的 Cookie / Referer）+
/// 节点级 headers 合并 + GET/POST params + 编码探测。
final class HTTPClient {
    static let shared = HTTPClient()

    struct Response {
        var finalURL: String
        var text: String
        var headers: [String: String]
    }

    enum HTTPError: LocalizedError {
        case badURL
        case http(Int)
        case empty
        case decode

        var errorDescription: String? {
            switch self {
            case .badURL: return "网址无效"
            case .http(let code): return "服务器返回 \(code)"
            case .empty: return "没有抓到内容"
            case .decode: return "网页编码无法识别"
            }
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpAdditionalHeaders = [
            "User-Agent": Fetcher.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh-Hans;q=0.9"
        ]
        return URLSession(configuration: config)
    }()

    /// 执行一次请求。
    /// - Parameters:
    ///   - url: 完整 URL（相对路径已解析）
    ///   - method: GET / POST（params：GET 拼查询串，POST 表单体）
    ///   - params: 参数值（`%@` 已由上层替换为搜索词）
    ///   - staticHeaders: 全局 + 节点 headers 合并后的静态头
    ///   - dynamicHeaders: @dyn: 脚本设置的动态头（优先级最高）
    ///   - useCookies: 使用共享 Cookie 存储
    func request(url: String,
                 method: String,
                 params: [String: String],
                 staticHeaders: [String: String],
                 dynamicHeaders: HeaderStore?,
                 useCookies: Bool) async throws -> Response {
        guard var components = URLComponents(string: url) else { throw HTTPError.badURL }

        var requestURL = url
        var body: String? = nil
        let isPost = method.uppercased() == "POST"

        if !params.isEmpty {
            let query = Self.formEncode(params)
            if isPost {
                body = query
            } else {
                if let existing = components.percentEncodedQuery, !existing.isEmpty {
                    components.percentEncodedQuery = existing + "&" + query
                } else {
                    components.percentEncodedQuery = query
                }
                requestURL = components.url?.absoluteString ?? url
            }
        }
        guard let urlObject = URL(string: requestURL) else { throw HTTPError.badURL }

        var request = URLRequest(url: urlObject)
        request.httpMethod = isPost ? "POST" : "GET"
        if let body {
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        // 头合并：静态 → 动态（脚本 Cookie / Referer 优先，墓碑删除生效）
        var headers = staticHeaders
        if let dynamic = dynamicHeaders {
            headers = dynamic.merged(over: staticHeaders)
        }
        // 默认 UA 先设，书源 / 脚本 UA 可覆盖
        request.setValue(Fetcher.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if !useCookies {
            request.httpShouldHandleCookies = false
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw HTTPError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw HTTPError.empty }

        let headerCharset = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let text = Fetcher.decode(data: data, hint: "utf-8", header: headerCharset) ?? ""
        guard !text.isEmpty else { throw HTTPError.decode }

        var responseHeaders: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    responseHeaders[k] = v
                }
            }
        }
        return Response(finalURL: response.url?.absoluteString ?? requestURL,
                        text: text, headers: responseHeaders)
    }

    /// 表单编码（保留字母数字与 -._~，其余 percent-encode）。
    static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// 相对 URL → 绝对（基于书源 homeURL 或当前页）。
    static func absolute(_ link: String, base: String) -> String {
        let v = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "" }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return v }
        if v.hasPrefix("//") { return "https:" + v }
        guard let baseURL = URL(string: base) else { return v }
        if v.hasPrefix("/") {
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            comps?.path = v
            comps?.query = nil
            return comps?.url?.absoluteString ?? v
        }
        return URL(string: v, relativeTo: baseURL)?.absoluteString ?? v
    }
}
