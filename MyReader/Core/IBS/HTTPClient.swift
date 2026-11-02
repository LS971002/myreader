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
            // 剥离书源声明的 Accept-Encoding：URLSession 手动设置该头后不再自动解压，
            // 服务器返回 gzip/br 会拿到乱码（00小说/错层/猫眼实测中招）；
            // 让系统自动协商，响应永远走自动解压通道。
            if name.caseInsensitiveCompare("Accept-Encoding") == .orderedSame { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }

        if !useCookies {
            request.httpShouldHandleCookies = false
        }

        let (rawData, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw HTTPError.http(http.statusCode)
        }
        // gzip 兜底解压（服务器无视协商仍压缩时；URLSession 手动设置过
        // Accept-Encoding 的场景系统不解压，书源头已剥离，此处为二道防线）
        let contentEncoding = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? ""
        let data: Data
        if contentEncoding.contains("gzip") {
            data = Self.gunzip(rawData) ?? rawData
        } else {
            data = rawData
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

    /// gzip 解压：解析 gzip 头（magic/标志位/可选字段）→ raw deflate 解压（复用 EPUB.inflate）。
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {   // FNAME（零结尾）
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {   // FCOMMENT（零结尾）
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 {   // FHCRC
            offset += 2
        }
        guard offset < bytes.count - 8 else { return nil }
        let deflate = Data(bytes[offset..<(bytes.count - 8)])
        // ZipReader.inflate = raw deflate 解压（Apple 的 COMPRESSION_ZLIB 实为无zlib头的raw deflate，
        // 与 gzip payload 格式吻合）
        return ZipReader.inflate(deflate, expected: bytes.count * 4)
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
