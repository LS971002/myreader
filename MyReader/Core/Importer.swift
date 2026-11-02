import Foundation
import UniformTypeIdentifiers

/// 本地文件导入：.ibs 书源 / 明文书源 JSON / TXT / EPUB。
///
/// 流程（两条入口统一：onOpenURL 与 fileImporter）：
///   1. readIncoming(url:)   —— 同步读 Data（安全域时序安全）
///   2. processIncoming(file) —— 后台解析（IBS 解密 / TXT 切分 / EPUB）
///   3. Store.present(outcome) —— 主线程：书源→全局提示；书籍→导入确认 Sheet
///   4. 用户确认 → commitBook（按切分规则落盘章节 + 入库）
enum Importer {
    enum ImportError: LocalizedError {
        case unsupported
        case empty
        case read
        case ibsParse(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "不支持的文件类型（支持 .ibs / .txt / .epub / 书源 JSON）"
            case .empty: return "文件内容为空"
            case .read: return "读取文件失败"
            case .ibsParse(let reason): return "ibs 解析失败：\(reason)"
            }
        }
    }

    // MARK: - 章节切分规则

    enum SplitMode: Equatable {
        case smart                          // 内置智能正则（第X章/卷/节…）
        case regex(String)                  // 用户自定义正则
        case count(Int)                     // 按字数强制切分

        var settingsKey: String {
            switch self {
            case .smart: return "smart"
            case .regex: return "regex"
            case .count: return "count"
            }
        }
    }

    static let defaultSmartPattern =
        "^\\s*(?:正文\\s*)?(?:第[0-9零一二三四五六七八九十百千万两〇]{1,10}[章节回卷集部篇]|序章|楔子|前言|后记|尾声|番外)[^\\n]{0,40}$"

    // MARK: - 入口一：onOpenURL / fileImporter 共用

    struct IncomingFile {
        var data: Data
        var ext: String        // "ibs" / "json" / "txt" / "epub"
        var fileName: String   // 不含扩展名
    }

    /// 同步读取（安全域权限与打开动作的生命周期绑定，必须立即读）。
    static func readIncoming(url: URL) -> IncomingFile? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty { ext = sniff(data) }
        var name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = "未命名" }
        return IncomingFile(data: data, ext: ext, fileName: name)
    }

    /// 无扩展名时按内容嗅探。
    private static func sniff(_ data: Data) -> String {
        let head = [UInt8](data.prefix(4))
        if head == [0x50, 0x4b, 0x03, 0x04] { return "ibs" }   // zip 家族按 ibs 试
        if let text = String(data: data.prefix(1024), encoding: .utf8)
            ?? String(data: data.prefix(1024), encoding: .utf16LittleEndian) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") || t.hasPrefix("[") { return "json" }
            return "txt"
        }
        return "txt"
    }

    // MARK: - 处理结果

    enum IncomingOutcome {
        case sources(count: Int, firstName: String)
        /// 书籍草稿：元信息 + 章节列表已解析（原文件已存 Imported/，正文待确认后落盘）。
        case bookDraft(Book)
        case failed(String)
    }

    /// 后台处理（不碰 UI）。
    static func processIncoming(_ file: IncomingFile) -> IncomingOutcome {
        switch file.ext {
        case "ibs":
            do {
                let count = try importIBSData(file.data, fileName: file.fileName)
                return .sources(count: count, firstName: firstSourceName())
            } catch {
                return .failed("ibs 导入失败：\(error.localizedDescription)")
            }
        case "json":
            do {
                guard let text = decodeText(file.data) else { throw ImportError.read }
                let count = try importSourceJSON(text)
                return .sources(count: count, firstName: firstSourceName())
            } catch {
                return .failed("书源导入失败：\(error.localizedDescription)")
            }
        case "epub":
            do {
                return .bookDraft(try parseEPUBDraft(data: file.data, name: file.fileName))
            } catch {
                return .failed("EPUB 导入失败：\(error.localizedDescription)")
            }
        default:
            do {
                return .bookDraft(try parseTXTDraft(data: file.data, name: file.fileName))
            } catch {
                return .failed("TXT 导入失败：\(error.localizedDescription)")
            }
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    // MARK: - TXT 草稿（解析 + 存原文件，不落章节）

    /// 解析 TXT：识别书名/作者 + 智能切分出章节元信息；原文件存 Imported/ 供重切分。
    static func parseTXTDraft(data: Data, name: String) throws -> Book {
        guard let text = Fetcher.decode(data: data, hint: "utf-8", header: "") else {
            throw ImportError.read
        }
        var book = Book(name: detectTitle(text, fallback: name), origin: .local)
        book.author = detectAuthor(text)
        book.sourceName = "本地"
        book.localEncoding = encodingHint(text)

        let copy = Paths.imported.appendingPathComponent("\(book.id.uuidString).txt")
        try? data.write(to: copy)
        book.localFile = Paths.relative(copy)

        let chapters = splitChapters(text, fallbackTitle: name, mode: .smart)
        guard !chapters.isEmpty else { throw ImportError.empty }
        book.chapters = chapters.enumerated().map { index, item in
            Chapter(index: index, title: item.title, url: "", cached: false,
                    wordCount: item.content.count)
        }
        return book
    }

    /// EPUB 草稿：解析出元信息 + 章节列表；原文件存 Imported/。
    static func parseEPUBDraft(data: Data, name: String) throws -> Book {
        let epub = try EPUBArchive(data: data)
        let result = try epub.chapters()
        guard !result.isEmpty else { throw ImportError.empty }

        var book = Book(name: result.first?.bookTitle.isEmpty == false
                        ? (result.first?.bookTitle ?? name) : name, origin: .local)
        book.author = result.first?.author ?? ""
        book.sourceName = "本地"

        let copy = Paths.imported.appendingPathComponent("\(book.id.uuidString).epub")
        try? data.write(to: copy)
        book.localFile = Paths.relative(copy)

        book.chapters = result.enumerated().map { index, item in
            Chapter(index: index, title: item.title, url: "", cached: false,
                    wordCount: item.content.count)
        }
        return book
    }

    // MARK: - 确认入库

    /// 用户确认后：按切分规则从原文件重新解析 → 落盘章节 → 入库。
    /// EPUB 忽略 mode（重新走 EPUB 解析）。
    static func commitBook(_ draft: Book, mode: SplitMode) -> Book {
        var book = draft
        let fileURL = draft.localFile.map { Paths.absolute($0) }
        let ext = fileURL?.pathExtension.lowercased() ?? "txt"

        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if ext == "epub" {
                if let epub = try? EPUBArchive(data: data),
                   let result = try? epub.chapters(), !result.isEmpty {
                    book.chapters = result.enumerated().map { index, item in
                        Chapter(index: index, title: item.title, url: "", cached: true,
                                wordCount: item.content.count)
                    }
                    for (index, item) in result.enumerated() {
                        Paths.writeChapter(item.content, bookID: book.id, index: index)
                    }
                }
            } else {
                if let text = Fetcher.decode(data: data, hint: draft.localEncoding, header: "") {
                    let chapters = splitChapters(text, fallbackTitle: draft.name, mode: mode)
                    book.chapters = chapters.enumerated().map { index, item in
                        Chapter(index: index, title: item.title, url: "", cached: true,
                                wordCount: item.content.count)
                    }
                    for (index, item) in chapters.enumerated() {
                        Paths.writeChapter(item.content, bookID: book.id, index: index)
                    }
                }
            }
        }
        if book.chapters.isEmpty {
            // 兜底：原文件不可读时仍把草稿章节入册（cached 状态不变）
        } else if !book.chapters.allSatisfy(\.cached) {
            for index in book.chapters.indices { book.chapters[index].cached = true }
        }
        Store.shared.addBook(book)
        return book
    }

    /// 切分规则变化时重新解析草稿（不落盘，只更新章节元信息）。
    static func reparse(draft: Book, mode: SplitMode) -> Book {
        guard let rel = draft.localFile else { return draft }
        let fileURL = Paths.absolute(rel)
        guard let data = try? Data(contentsOf: fileURL) else { return draft }

        var copy = draft
        if fileURL.pathExtension.lowercased() == "epub" { return draft }
        guard let text = Fetcher.decode(data: data, hint: draft.localEncoding, header: "") else {
            return draft
        }
        let chapters = splitChapters(text, fallbackTitle: draft.name, mode: mode)
        copy.chapters = chapters.enumerated().map { index, item in
            Chapter(index: index, title: item.title, url: "", cached: false,
                    wordCount: item.content.count)
        }
        return copy
    }

    // MARK: - 书名 / 作者识别

    static func detectTitle(_ text: String, fallback: String) -> String {
        let head = String(text.prefix(2000))
        if let m = firstMatch("书名[：:\\s]\\s*([^\\n\\r]{1,40})", in: head) { return m }
        if let m = firstMatch("《([^\\n《》]{1,40})》", in: head) { return m }
        return fallback
    }

    static func detectAuthor(_ text: String) -> String {
        let head = String(text.prefix(3000))
        if let m = firstMatch("作者[：:\\s]\\s*([^\\n\\r，。；]{1,24})", in: head) { return m }
        if let m = firstMatch("著[：:\\s]\\s*([^\\n\\r，。；]{1,24})", in: head) { return m }
        return ""
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text,
                                           range: NSRange(location: 0, length: ns.length)),
            match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range).trimmingCharacters(in: .whitespaces)
    }

    private static func encodingHint(_ text: String) -> String {
        text.contains("\u{FFFD}") ? "gbk" : "utf-8"
    }

    // MARK: - 切分实现

    struct RawChapter {
        var title: String
        var content: String
    }

    static func splitChapters(_ text: String, fallbackTitle: String,
                              mode: SplitMode = .smart) -> [RawChapter] {
        switch mode {
        case .smart:
            return regexSplit(text, pattern: defaultSmartPattern, fallback: fallbackTitle)
        case .regex(let pattern):
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return regexSplit(text, pattern: defaultSmartPattern, fallback: fallbackTitle)
            }
            let result = regexSplit(text, pattern: trimmed, fallback: fallbackTitle)
            // 自定义正则切不出章（<2）时回退智能
            if result.count < 2 {
                return regexSplit(text, pattern: defaultSmartPattern, fallback: fallbackTitle)
            }
            return result
        case .count(let per):
            return countSplit(text, per: max(per, 500), fallback: fallbackTitle)
        }
    }

    private static func regexSplit(_ text: String, pattern: String,
                                   fallback: String) -> [RawChapter] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let regex = try? NSRegularExpression(pattern: pattern)

        var chapters: [RawChapter] = []
        var currentTitle: String? = nil
        var buffer: [String] = []

        func flush() {
            let content = trimBlank(buffer.joined(separator: "\n"))
            if let title = currentTitle {
                chapters.append(RawChapter(title: title, content: content))
            } else if !content.isEmpty {
                chapters.append(RawChapter(title: fallback, content: content))
            }
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            let isTitle = trimmed.count >= 2 && trimmed.count <= 60 &&
                (regex?.firstMatch(in: trimmed,
                                   range: NSRange(location: 0, length: ns.length)) != nil)
            if isTitle {
                flush()
                currentTitle = trimmed
            } else {
                buffer.append(line)
            }
        }
        flush()

        // 合并过短章节（误判标题）
        var merged: [RawChapter] = []
        for chapter in chapters where !chapter.content.isEmpty {
            if let last = merged.last, last.content.count < 200 {
                merged[merged.count - 1].content += "\n" + chapter.title + "\n" + chapter.content
            } else {
                merged.append(chapter)
            }
        }
        return merged.isEmpty ? [RawChapter(title: fallback, content: trimBlank(normalized))] : merged
    }

    private static func countSplit(_ text: String, per: Int,
                                   fallback: String) -> [RawChapter] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let chars = Array(normalized)
        guard chars.count > per else { return [RawChapter(title: fallback, content: normalized)] }

        var chapters: [RawChapter] = []
        var start = 0
        var part = 1
        while start < chars.count {
            var end = min(start + per, chars.count)
            // 尽量在段落边界断开（向前找 \n，最多回退 500 字）
            if end < chars.count {
                let searchBack = max(start, end - 500)
                var cut = -1
                var i = end - 1
                while i >= searchBack {
                    if chars[i] == "\n" { cut = i + 1; break }
                    i -= 1
                }
                if cut > start { end = cut }
            }
            let content = String(chars[start..<end])
            chapters.append(RawChapter(title: "第\(part)部分（\(content.count)字）",
                                       content: content))
            part += 1
            start = end
        }
        return chapters
    }

    private static func trimBlank(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - IBS 书源导入

    /// .ibs 文件 Data → 解密 → 书源入库，返回导入数量。
    @discardableResult
    static func importIBS(from url: URL) throws -> Int {
        guard let file = readIncoming(url: url) else { throw ImportError.read }
        return try importIBSData(file.data, fileName: file.fileName)
    }

    @discardableResult
    static func importIBSData(_ data: Data, fileName: String = "书源.ibs") throws -> Int {
        guard !data.isEmpty else { throw ImportError.empty }
        let rawJSON: String
        do {
            rawJSON = try IBSCrypto.decryptFile(data)
        } catch {
            throw ImportError.ibsParse(error.localizedDescription)
        }
        return try importSourceJSON(rawJSON)
    }

    /// 解密后的书源 JSON（单对象或数组）入库。
    @discardableResult
    static func importSourceJSON(_ json: String) throws -> Int {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) else {
            throw ImportError.ibsParse("书源 JSON 无效")
        }
        var list: [[String: Any]] = []
        if let array = object as? [[String: Any]] {
            list = array
        } else if let dict = object as? [String: Any] {
            list = [dict]
        }
        var sources: [IBSBookSource] = []
        for item in list {
            guard let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let raw = String(data: itemData, encoding: .utf8),
                  let source = IBSBookSource.parse(rawJSON: raw) else { continue }
            sources.append(source)
        }
        guard !sources.isEmpty else { throw ImportError.ibsParse("没有可用的书源") }
        Store.shared.upsertSources(sources)
        return sources.count
    }

    /// 最近导入的第一个书源名（提示用）。
    static func firstSourceName() -> String {
        Store.shared.sources.last?.name ?? ""
    }

    // MARK: - 明文 JSON 书源

    @discardableResult
    static func importBookSources(from url: URL) throws -> Int {
        guard let file = readIncoming(url: url) else { throw ImportError.read }
        guard let text = decodeText(file.data) else { throw ImportError.read }
        guard text.contains("searchBook") || text.contains("sourceDetail")
            || text.contains("chapterDetail") else {
            throw ImportError.unsupported
        }
        return try importSourceJSON(text)
    }
}
