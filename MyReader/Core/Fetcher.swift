import Foundation

/// 一次抓取的结果：保留原始文本 + 解析好的 DOM。
final class Page {
    let url: String
    let body: String
    private(set) lazy var dom: HTMLNode = HTMLParser.parse(body)
    private(set) lazy var engine: RuleEngine = RuleEngine(baseURL: url, raw: body)

    init(url: String, body: String) {
        self.url = url
        self.body = body
    }
}

enum FetchError: LocalizedError {
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

enum Fetcher {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    static func fetch(
        _ urlString: String,
        method: String = "GET",
        body: String? = nil,
        referer: String? = nil,
        charset: String = "utf-8"
    ) async throws -> Page {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FetchError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let referer, let ref = URL(string: referer) {
            request.setValue(ref.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let body {
            if method.uppercased() == "POST" {
                request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                                 forHTTPHeaderField: "Content-Type")
                request.httpBody = body.data(using: .utf8)
            } else {
                if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.percentEncodedQuery = body
                    request.url = comps.url
                }
            }
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw FetchError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw FetchError.empty }

        let headerCharset = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        let text = decode(data: data, hint: charset, header: headerCharset) ?? ""
        guard !text.isEmpty else { throw FetchError.decode }
        return Page(url: url.absoluteString, body: text)
    }

    static func decode(data: Data, hint: String, header: String) -> String? {
        // 1. 优先按 UTF-8 直接解
        if let s = String(data: data, encoding: .utf8), !s.contains("\u{FFFD}") {
            return s
        }
        // 2. 页面 meta 里声明的编码
        var candidates: [String] = []
        if let ascii = String(data: data.prefix(2048), encoding: .isoLatin1) {
            if let range = ascii.range(of: "charset=[\"']?([a-zA-Z0-9_\\-]+)",
                                       options: [.regularExpression, .caseInsensitive]) {
                let matched = String(ascii[range])
                candidates.append(matched.replacingOccurrences(of: "charset=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
            }
        }
        candidates.append(hint)
        if let h = header.range(of: "charset=([a-zA-Z0-9_\\-]+)", options: .regularExpression) {
            candidates.append(String(header[h]).replacingOccurrences(of: "charset=", with: ""))
        }

        for name in candidates {
            if let encoding = encoding(for: name),
               let s = String(data: data, encoding: encoding) {
                return s
            }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func encoding(for name: String) -> String.Encoding? {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch key {
        case "utf8", "utf": return .utf8
        case "gbk", "gb2312", "gb18030", "cp936":
            let cf = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: cf)
        case "big5":
            let cf = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String.Encoding(rawValue: cf)
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf == kCFStringEncodingInvalidId { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }
}
