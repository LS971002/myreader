import Foundation

// MARK: - 书源

/// 一个书源 = 一套抓取规则。字段命名尽量贴近常见的 iOS 阅读器规则写法，
/// 便于直接导入已有的 JSON 书源文件。
struct BookSource: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var group: String = "默认"
    var baseURL: String = ""
    var charset: String = "utf-8"

    // 搜索
    var searchURL: String = ""
    var searchList: String = ""
    var searchTitle: String = ""
    var searchLink: String = ""
    var searchAuthor: String = ""
    var searchCover: String = ""
    var searchIntro: String = ""
    var searchLatest: String = ""

    // 详情
    var introRule: String = ""
    var coverRule: String = ""

    // 目录
    var dirURL: String = ""
    var dirList: String = ""
    var dirTitle: String = ""
    var dirLink: String = ""
    var dirNext: String = ""

    // 正文
    var contentRule: String = ""
    var contentNext: String = ""

    var weight: Int = 100
    var enabled: Bool = true
    var lastFailAt: Date? = nil

    static func empty() -> BookSource { BookSource() }
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
}

// MARK: - 章节

/// 章节正文不入库（单独存文件），避免书架 JSON 膨胀。
struct Chapter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var index: Int
    var title: String
    var url: String = ""
    var cached: Bool = false
    var wordCount: Int = 0
}

// MARK: - 书籍

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
    var coverFile: String? = nil          // 本地缓存封面（相对路径）
    var origin: BookOrigin = .online
    var localFile: String? = nil          // 导入文件（相对路径）
    var localEncoding: String = "utf-8"

    var sourceID: UUID? = nil
    var sourceName: String = ""
    var detailURL: String = ""

    var chapters: [Chapter] = []
    var currentChapter: Int = 0
    var currentPage: Int = 0
    var progress: Double = 0              // 0...1

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

// MARK: - 分组

struct BookGroup: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "未分组"
    var sort: Int = 0
}

// MARK: - 书签

struct Bookmark: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var bookID: UUID
    var chapterIndex: Int
    var chapterTitle: String
    var page: Int = 0
    var text: String = ""
    var createdAt: Date = Date()
}

// MARK: - 缓存统计

struct CacheStat: Codable, Hashable {
    var bookID: UUID
    var chapterCount: Int
    var bytes: Int
}

// MARK: - 阅读设置

enum PageTurnStyle: String, Codable, CaseIterable, Identifiable {
    case slide      // 平移
    case cover      // 覆盖
    case scroll     // 上下滚动
    case none       // 无动画

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

/// 全应用设置。注意：这里**没有**任何「会员 / 激励 / 试用」字段，
/// 所有高级功能一律常驻开启。
struct AppSettings: Codable, Hashable {
    // 排版
    var fontSize: Double = 19
    var lineSpacing: Double = 8
    var paragraphSpacing: Double = 12
    var fontName: String = ""             // 空 = 系统字体
    var bold: Bool = false
    var indentFirstLine: Bool = true

    // 翻页
    var pageTurn: PageTurnStyle = .slide
    var tapToTurn: Bool = true
    var volumeKeyTurn: Bool = false

    // 主题
    var themeID: String = "paper"
    var followSystemDark: Bool = true

    // 屏幕
    var keepScreenOn: Bool = true
    var fullScreen: Bool = true
    var showStatusBar: Bool = false
    var brightness: Double = -1           // -1 = 跟随系统

    // 阅读行为
    var preloadCount: Int = 5
    var autoCacheNext: Bool = true
    var showBatteryAndTime: Bool = true

    // 朗读
    var ttsRate: Double = 0.5
    var ttsPitch: Double = 1.0
    var ttsVoice: String = ""

    // 高级功能（全部无条件开启）
    var enableTTS: Bool = true
    var enableThemes: Bool = true
    var enableExport: Bool = true
    var enableWebSourceImport: Bool = true
    var enableCloudBackup: Bool = true
    var enableNoAds: Bool = true
}
