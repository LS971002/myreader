import Foundation

// MARK: - IBS 书源（爱阅书香 BookFixConfig 原生格式）

/// 规则值：字符串单条，或字符串数组（组合规则，前序结果通过 contents[i] 传递）。
enum RuleValue {
    case text(String)
    case combo([String])

    /// 全部规则串（单条也包装成数组）。
    var rules: [String] {
        switch self {
        case .text(let s): return [s]
        case .combo(let list): return list
        }
    }

    var first: String? { rules.first }

    static func from(_ any: Any?) -> RuleValue? {
        switch any {
        case let s as String: return .text(s)
        case let a as [Any]:
            let list = a.compactMap { $0 as? String }
            return list.isEmpty ? nil : .combo(list)
        default: return nil
        }
    }
}

/// parser 字段值：规则（字符串 / 数组）或子字典（_BookFields / _SourceFields）。
enum ParserField {
    case rules([String])
    case sub([String: ParserField])

    static func from(_ any: Any?) -> ParserField? {
        if let s = any as? String { return .rules([s]) }
        if let a = any as? [Any] {
            let list = a.compactMap { $0 as? String }
            return list.isEmpty ? nil : .rules(list)
        }
        if let d = any as? [String: Any] {
            var result: [String: ParserField] = [:]
            for (k, v) in d where !k.hasPrefix("^-^") {
                if let f = ParserField.from(v) { result[k] = f }
            }
            return result.isEmpty ? nil : .sub(result)
        }
        return nil
    }

    var ruleStrings: [String] {
        if case .rules(let list) = self { return list }
        return []
    }
}

/// 每个规则节点（searchBook / sourceDetail / chapterDetail / middleHandle…）。
/// 字段类型在真实 IBS 文件里非常混乱（数字可能是字符串、url 可能是数组），
/// 因此不做标准 Codable，统一用字典工厂构造。
struct RuleNode {
    var url: RuleValue?
    var forGetMethod: Bool = true
    var params: [String: String] = [:]
    var parser: [String: ParserField] = [:]
    var middleHandle: RuleNode?
    var nextPageUrl: RuleValue?
    var nextPageParams: [String: String] = [:]
    var nextPageForGetMethod: Bool = true
    var maxPageCount: Int = 1
    var requestByWebView: Bool = false
    var tryCount: Int = 0
    var trySpaceSecond: Double = 0
    var responseType: Int = 0
    var httpConfigs: HTTPConfig?
    /// 原始 JSON 里携带的其它键（如 ^-^XDKEYWORD20210623）。
    var extraKeys: [String: String] = [:]

    init(dict: [String: Any]?) {
        guard let dict, !dict.isEmpty else { return }
        url = RuleValue.from(dict["url"])
        forGetMethod = (dict["forGetMethod"] as? Bool) ?? true
        params = Self.stringDict(dict["params"]) ?? [:]
        if let parser = dict["parser"] as? [String: Any] {
            var result: [String: ParserField] = [:]
            for (key, value) in parser {
                if key.hasPrefix("^-^"), let s = value as? String {
                    extraKeys[key] = s
                } else if let field = ParserField.from(value) {
                    result[key] = field
                }
            }
            parser = result
        }
        if let middle = dict["middleHandle"] as? [String: Any], !middle.isEmpty {
            middleHandle = RuleNode(dict: middle)
        }
        nextPageUrl = RuleValue.from(dict["nextPageUrl"])
        nextPageParams = Self.stringDict(dict["nextPageParams"]) ?? [:]
        nextPageForGetMethod = (dict["nextPageForGetMedthod"] as? Bool) ?? true
        maxPageCount = Self.flexInt(dict["maxPageCount"]) ?? 1
        requestByWebView = (dict["requestByWebView"] as? Bool) ?? false
        tryCount = Self.flexInt(dict["tryCount"]) ?? 0
        trySpaceSecond = Self.flexDouble(dict["trySpaceSecond"]) ?? 0
        responseType = Self.flexInt(dict["responseType"]) ?? 0
        if let http = dict["httpConfigs"] as? [String: Any] {
            httpConfigs = HTTPConfig(dict: http)
        }
        // XDKEYWORD 之类的特殊键：记录下来供搜索词注入
        for (key, value) in dict {
            if key.hasPrefix("^-^"), let s = value as? String {
                extraKeys[key] = s
            }
        }
    }

    /// 字段规则组：parser 顶层 → _SourceFields → _BookFields 依次查找。
    func field(_ name: String) -> [String]? {
        if let f = parser[name] {
            let rules = f.ruleStrings
            if !rules.isEmpty { return rules }
        }
        for container in ["_SourceFields", "_BookFields"] {
            if let sub = parser[container], case .sub(let dict) = sub,
               let f = dict[name], !f.ruleStrings.isEmpty {
                return f.ruleStrings
            }
        }
        return nil
    }

    /// 列表选择规则。
    var listRules: [String]? { field("_list") }

    private static func stringDict(_ any: Any?) -> [String: String]? {
        guard let dict = any as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String { result[k] = s }
            else if let n = v as? NSNumber { result[k] = n.stringValue }
        }
        return result.isEmpty ? nil : result
    }

    private static func flexInt(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func flexDouble(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// HTTP 配置（每节点可独立携带，覆盖全局）。
struct HTTPConfig {
    var headers: [String: String] = [:]
    var useCookies: Bool = false
    var httpCreateCode: String = ""

    init(dict: [String: Any]?) {
        guard let dict else { return }
        if let h = dict["headers"] as? [String: Any] {
            for (k, v) in h {
                if let s = v as? String { headers[k] = s }
                else if let n = v as? NSNumber { headers[k] = n.stringValue }
            }
        }
        useCookies = (dict["useCookies"] as? Bool) ?? false
        httpCreateCode = (dict["httpCreateCode"] as? String) ?? ""
    }
}

/// IBS 书源：解密后的 BookFixConfig 树。
struct IBSBookSource: Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var homeURL: String = ""
    var group: String = "默认"
    var enabled: Bool = true
    var weight: Int = 0
    var tryCount: Int = 0
    var trySpaceSecond: Double = 0
    var priorityEncoding: Int = 0
    var responseType: Int = 0
    var authorInfo: String = ""
    var httpConfigs: HTTPConfig?
    var searchBook: RuleNode?
    var bookDetail: RuleNode?
    var sourceDetail: RuleNode?
    var chapterDetail: RuleNode?
    /// 解密后的书源 JSON 原文（导出 / 再编辑 / 重建用）。
    var rawJSON: String = ""

    var hashBase: String { rawJSON }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: IBSBookSource, r: IBSBookSource) -> Bool { l.id == r.id }

    /// 从解密后的 JSON 字典构造。
    static func parse(rawJSON: String, id: UUID = UUID(), group: String = "默认",
                      enabled: Bool? = nil) -> IBSBookSource? {
        guard let data = rawJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var source = IBSBookSource()
        source.id = id
        source.rawJSON = rawJSON
        source.group = group
        source.name = (object["name"] as? String) ?? "未命名书源"
        source.homeURL = (object["homeUrl"] as? String) ?? ""
        source.weight = (object["weight"] as? Int) ?? 0
        source.tryCount = (object["tryCount"] as? Int) ?? 0
        source.trySpaceSecond = (object["trySpaceSecond"] as? Double) ?? 0
        source.priorityEncoding = (object["priorityEncoding"] as? Int) ?? 0
        source.responseType = (object["responseType"] as? Int) ?? 0
        source.authorInfo = (object["authorInfo"] as? String) ?? ""
        source.enabled = enabled ?? ((object["enable"] as? Bool) ?? true)
        if let http = object["httpConfigs"] as? [String: Any] {
            source.httpConfigs = HTTPConfig(dict: http)
        }
        if let node = object["searchBook"] as? [String: Any], !node.isEmpty {
            source.searchBook = RuleNode(dict: node)
        }
        if let node = object["bookDetail"] as? [String: Any], !node.isEmpty {
            source.bookDetail = RuleNode(dict: node)
        }
        if let node = object["sourceDetail"] as? [String: Any], !node.isEmpty {
            source.sourceDetail = RuleNode(dict: node)
        }
        if let node = object["chapterDetail"] as? [String: Any], !node.isEmpty {
            source.chapterDetail = RuleNode(dict: node)
        }
        return source.name.isEmpty || source.homeURL.isEmpty ? nil : source
    }
}

/// 书源持久化记录：以解密后 JSON 原文为准，元数据为辅。
struct SourceRecord: Codable {
    var id: UUID = UUID()
    var group: String = "默认"
    var enabled: Bool = true
    var rawJSON: String = ""
    var importedAt: Date = Date()

    func resolve() -> IBSBookSource? {
        IBSBookSource.parse(rawJSON: rawJSON, id: id, group: group, enabled: enabled)
    }

    static func record(from source: IBSBookSource) -> SourceRecord {
        SourceRecord(id: source.id, group: source.group, enabled: source.enabled,
                     rawJSON: source.rawJSON)
    }
}

// MARK: - 搜索结果

struct SearchResult: Identifiable, Hashable {
    var id = UUID()
    var sourceID: UUID
    var sourceName: String
    var title: String
    var author: String
    var link: String
    var cover: String
    var intro: String
    var latest: String
    /// 匹配类型：书名精确 / 书名模糊 / 作者匹配（搜索排序用）。
    var matchKind: MatchKind = .fuzzy

    enum MatchKind: Int {
        case exactTitle = 0
        case fuzzyTitle = 1
        case authorMatch = 2
    }
}

/// 跨源聚合的搜索结果（同名同作者合并）。
struct GroupedResult: Identifiable {
    var id = UUID()
    var title: String
    var author: String
    var intro: String
    var cover: String
    var latest: String
    var items: [SearchResult] = []

    init?(items: [SearchResult]) {
        guard let first = items.first else { return nil }
        title = first.title
        author = first.author
        intro = items.map(\.intro).first { !$0.isEmpty } ?? ""
        cover = items.map(\.cover).first { !$0.isEmpty } ?? ""
        latest = items.map(\.latest).first { !$0.isEmpty } ?? ""
        self.items = items.sorted { $0.sourceName < $1.sourceName }
    }
}

// MARK: - 章节 / 书籍

struct Chapter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var index: Int = 0
    var title: String = ""
    var url: String = ""
    var cached: Bool = false
    var wordCount: Int = 0
}

enum BookOrigin: String, Codable {
    case online
    case local
}

struct Book: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var author: String = ""
    var intro: String = ""
    var coverURL: String = ""
    var coverFile: String? = nil
    var origin: BookOrigin = .online
    var localFile: String? = nil
    var localEncoding: String = "utf-8"

    var sourceID: UUID? = nil
    var sourceName: String = ""
    var detailURL: String = ""
    /// 换源用：同书在其它源的详情地址。
    var altLinks: [String] = []

    var chapters: [Chapter] = []
    var currentChapter: Int = 0
    var currentPage: Int = 0
    var progress: Double = 0

    var groupID: UUID? = nil
    var stick: Bool = false
    var finished: Bool = false
    var createdAt: Date = Date()
    var lastReadAt: Date = Date()

    var readChapterTitle: String {
        guard chapters.indices.contains(currentChapter) else { return "" }
        return chapters[currentChapter].title
    }

    var displayCover: String? { coverFile }
}

// MARK: - 分组 / 书签 / 缓存

struct BookGroup: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "未分组"
    var sort: Int = 0
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var bookID: UUID = UUID()
    var chapterIndex: Int = 0
    var chapterTitle: String = ""
    var page: Int = 0
    var text: String = ""
    var createdAt: Date = Date()
}

struct CacheStat: Codable, Hashable {
    var bookID: UUID
    var chapterCount: Int
    var bytes: Int
}

// MARK: - 阅读设置

enum PageTurnStyle: String, Codable, CaseIterable, Identifiable {
    case slide, cover, scroll, none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .slide: return "平移"
        case .cover: return "覆盖"
        case .scroll: return "滚动"
        case .none: return "无动画"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var fontSize: Double = 19
    var lineSpacing: Double = 8
    var paragraphSpacing: Double = 12
    var fontName: String = ""
    var bold: Bool = false
    var indentFirstLine: Bool = true

    var pageTurn: PageTurnStyle = .slide
    var tapToTurn: Bool = true
    var volumeKeyTurn: Bool = false

    var themeID: String = "paper"
    var followSystemDark: Bool = true

    var keepScreenOn: Bool = true
    var fullScreen: Bool = true
    var showStatusBar: Bool = false
    var brightness: Double = -1

    var preloadCount: Int = 5
    var autoCacheNext: Bool = true
    var showBatteryAndTime: Bool = true

    // 本地朗读（还原爱阅：语速恒等映射，音调 0.5~1.5）
    var ttsRatePercent: Double = 50        // 0~100
    var ttsPitchPercent: Double = 75       // 0~100（默认 1.0）
    var ttsVoice: String = ""

    var ttsRate: Float { Float(max(0, min(1, ttsRatePercent / 100))) }
    var ttsPitch: Float {
        let p = ttsPitchPercent / 100
        return (p > 0 && p <= 1) ? Float(2 * p - 0.5) : 1.0
    }

    // 搜索
    var searchConcurrency: Int = 6
    var searchMinCount: Int = 20
}

// MARK: - 批量缓存进度

struct CacheProgress {
    var bookID: UUID
    var total: Int = 0
    var finished: Int = 0
    var failed: Int = 0
    var running = false
    var cancelled = false

    var fraction: Double { total <= 0 ? 0 : Double(finished) / Double(total) }
}
