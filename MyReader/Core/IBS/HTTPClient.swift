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
        let urlObject: URL
        if let direct = URL(string: requestURL) {
            urlObject = direct
        } else if let comps = URLComponents(string: requestURL), let encoded = comps.url {
            // 含未编码中文等字符：URLComponents 自动编码 path/query
            urlObject = encoded
        } else {
            throw HTTPError.badURL
        }

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

        AppLog.debug("HTTP", "→ \(request.httpMethod ?? "GET") \(requestURL)")
        if !headers.isEmpty {
            let keys = headers.keys.sorted().joined(separator: ",")
            AppLog.debug("HTTP", "  头: [\(keys)]")
        }
        let started = Date()
        let (rawData, response) = try await session.data(for: request)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            AppLog.error("HTTP", "✗ \(requestURL) → \(http.statusCode) (\(elapsed)ms, \(rawData.count)B)")
            throw HTTPError.http(http.statusCode)
        }
        // gzip 兜底解压（服务器无视协商仍压缩时；URLSession 手动设置过
        // Accept-Encoding 的场景系统不解压，书源头已剥离，此处为二道防线）
        let contentEncoding = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? ""
        let data: Data
        // 只在数据真的是 gzip 流（魔数 1f 8b）时才解压：
        // URLSession 默认已自动解压，此时响应头仍留着 Content-Encoding: gzip，
        // 原来无条件解压会对已解压的数据反复失败（日志(13) 里成百条
        // 「输入14008B → 输出14008B」的噪音 WARN）。
        let looksGzipped = rawData.count > 2 && rawData[rawData.startIndex] == 0x1f
            && rawData[rawData.startIndex + 1] == 0x8b
        if contentEncoding.contains("gzip"), looksGzipped {
            if let unzipped = Self.gunzip(rawData) {
                data = unzipped
                AppLog.debug("HTTP", "  gzip手动解压: \(rawData.count)B → \(data.count)B")
            } else {
                data = rawData
                AppLog.warn("HTTP", "  gzip解压失败，按原数据解析（\(rawData.count)B）")
            }
        } else {
            data = rawData
        }
        guard !data.isEmpty else {
            AppLog.error("HTTP", "✗ \(requestURL) → 空响应 (\(elapsed)ms)")
            throw HTTPError.empty
        }

        let headerCharset = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let text = Fetcher.decode(data: data, hint: "utf-8", header: headerCharset) ?? ""
        AppLog.info("HTTP", "✓ \(requestURL) → \(data.count)B \(elapsed)ms 编码=\(headerCharset.isEmpty ? "utf8" : headerCharset) 文本长度=\(text.count)")
        guard !text.isEmpty else {
            AppLog.error("HTTP", "✗ \(requestURL) → 解码失败 (首字节=\(data.prefix(4).map { String(format: "%02x", $0) }.joined()))")
            throw HTTPError.decode
        }

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
    ///
    /// 两个必须避开的坑（均为日志实锤）：
    /// 1. 双重编码：`URLComponents.path` setter 期望未编码值，对已含 % 序列的路径
    ///    会把 % 再编码成 %25（错层 `/book/so/%E6...` → `%25E6...` → 401）。
    /// 2. **query 被当成 path 编码**：`@dyn:` 规则常产出
    ///    `/modules/article/search.php?searchkey=xxx&searchtype=all`
    ///    这类「相对路径 + 自带 query」；整串塞进 path 会把 `?` 编码成 `%3F`
    ///    （101Minc 实测：`search.php%3Fsearchkey=...` → 404）。
    ///    因此必须先把 path 与 query 拆开分别赋值。
    static func absolute(_ link: String, base: String) -> String {
        let v = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "" }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return v }
        if v.hasPrefix("//") { return "https:" + v }
        guard let baseURL = URL(string: base) else { return v }

        // 拆分 path / query / fragment
        var pathPart = v
        var queryPart: String? = nil
        var fragmentPart: String? = nil
        if let hashIndex = pathPart.firstIndex(of: "#") {
            fragmentPart = String(pathPart[pathPart.index(after: hashIndex)...])
            pathPart = String(pathPart[pathPart.startIndex..<hashIndex])
        }
        if let qIndex = pathPart.firstIndex(of: "?") {
            queryPart = String(pathPart[pathPart.index(after: qIndex)...])
            pathPart = String(pathPart[pathPart.startIndex..<qIndex])
        }
        // 纯 query 相对链接（`?page=2`）：path 取 base 的 path
        if pathPart.isEmpty { pathPart = baseURL.path }

        // 契约式防御：URLComponents 的 path / percentEncodedPath setter 遇到
        // 非法字符（孤立 %、控制字符、引号）会抛 NSInvalidArgumentException，
        // Swift 无法 catch → 直接进程崩溃。这里先净化。
        func sanitizePath(_ raw: String) -> String {
            var out = ""
            let scalars = Array(raw.unicodeScalars)
            var i = 0
            while i < scalars.count {
                let s = scalars[i]
                if s == "%" {
                    // 只有 %XX(X 为 hex) 才原样保留，否则编码成 %25
                    if i + 2 < scalars.count,
                       CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalars[i + 1]),
                       CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalars[i + 2]) {
                        out.append("%")
                        out.append(Character(scalars[i + 1]))
                        out.append(Character(scalars[i + 2]))
                        i += 3
                        continue
                    }
                    out += "%25"
                    i += 1
                    continue
                }
                if s.isASCII, !CharacterSet.controlCharacters.contains(s),
                   "\"'<>\\^`{|} ".unicodeScalars.contains(s) == false {
                    out.append(Character(s))
                } else {
                    out += s.utf8.map { String(format: "%%%02X", $0) }.joined()
                }
                i += 1
            }
            return out
        }

        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let pathIsEncoded = pathPart.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil
        if pathPart.hasPrefix("/") {
            if pathIsEncoded {
                comps?.percentEncodedPath = sanitizePath(pathPart)
            } else {
                comps?.path = pathPart
            }
        } else {
            // 相对路径（`book/1.html`）：拼到 base 目录后
            let basePath = baseURL.path
            let dir = basePath.hasSuffix("/")
                ? basePath
                : (basePath as NSString).deletingLastPathComponent + "/"
            let joined = dir + pathPart
            if pathIsEncoded {
                comps?.percentEncodedPath = sanitizePath(joined)
            } else {
                comps?.path = joined
            }
        }

        if let queryPart, !queryPart.isEmpty {
            let queryIsEncoded = queryPart.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil
            if queryIsEncoded {
                comps?.percentEncodedQuery = sanitizePath(queryPart)
            } else {
                // query setter 会保留 & 与 = 当作分隔符，只编码中文/空格等非法字符
                comps?.query = queryPart
            }
        } else {
            comps?.query = nil
        }
        comps?.fragment = fragmentPart
        return comps?.url?.absoluteString ?? v
    }

    /// 把 `?a=1&b=2` 里未编码的值补编码（`@dyn:` format 产出的 query 常带中文）。
    static func encodeQueryValues(_ query: String) -> String {
        query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(pair) }
            let key = String(parts[0])
            let raw = String(parts[1])
            if raw.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil { return String(pair) }
            let allowed = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }
}
