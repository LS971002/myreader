import Foundation
import UniformTypeIdentifiers

/// 本地文件导入：.ibs 书源 / 明文书源 JSON / TXT / EPUB。
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

    static func handleIncoming(url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ibs":
            _ = try? importIBS(url: url)
        case "json":
            _ = try? importBookSources(from: url)
        default:
            _ = try? importBook(from: url)
        }
    }

    // MARK: - IBS 书源导入（核心）

    /// .ibs 文件 → 解密 → 书源入库，返回导入数量。
    @discardableResult
    static func importIBS(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try importIBSData(data, fileName: url.lastPathComponent)
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

    // MARK: - 明文 JSON 书源（兼容含 searchBook 节点的爱阅格式导出）

    @discardableResult
    static func importBookSources(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw ImportError.read
        }
        // 必须是含 IBS 规则节点的 JSON
        guard text.contains("searchBook") || text.contains("sourceDetail") || text.contains("chapterDetail") else {
            throw ImportError.unsupported
        }
        return try importSourceJSON(text)
    }

    // MARK: - 导入书籍

    @discardableResult
    static func importBook(from url: URL) throws -> Book {
        let ext = url.pathExtension.lowercased()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw ImportError.empty }

        switch ext {
        case "txt":
            return try importTXT(data: data, name: url.deletingPathExtension().lastPathComponent)
        case "epub":
            return try importEPUB(data: data, name: url.deletingPathExtension().lastPathComponent)
        default:
            return try importTXT(data: data, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private static func importTXT(data: Data, name: String) throws -> Book {
        guard let text = Fetcher.decode(data: data, hint: "utf-8", header: "") else {
            throw ImportError.read
        }
        let chapters = splitChapters(text, fallbackTitle: name)
        guard !chapters.isEmpty else { throw ImportError.empty }

        var book = Book(name: name, origin: .local)
        book.sourceName = "本地"
        book.chapters = chapters.enumerated().map { index, item in
            Chapter(index: index, title: item.title, url: "", cached: true, wordCount: item.content.count)
        }

        for (index, item) in chapters.enumerated() {
            Paths.writeChapter(item.content, bookID: book.id, index: index)
        }

        let copy = Paths.imported.appendingPathComponent("\(book.id.uuidString).txt")
        try? data.write(to: copy)
        book.localFile = Paths.relative(copy)
        return book
    }

    private static func importEPUB(data: Data, name: String) throws -> Book {
        let epub = try EPUBArchive(data: data)
        let result = try epub.chapters()
        guard !result.isEmpty else { throw ImportError.empty }

        var book = Book(name: result.first?.bookTitle ?? name, origin: .local)
        book.author = result.first?.author ?? ""
        book.sourceName = "本地"
        book.chapters = result.enumerated().map { index, item in
            Chapter(index: index, title: item.title, url: "", cached: true, wordCount: item.content.count)
        }
        for (index, item) in result.enumerated() {
            Paths.writeChapter(item.content, bookID: book.id, index: index)
        }
        let copy = Paths.imported.appendingPathComponent("\(book.id.uuidString).epub")
        try? data.write(to: copy)
        book.localFile = Paths.relative(copy)
        return book
    }

    // MARK: - TXT 切章

    struct RawChapter {
        var title: String
        var content: String
    }

    static func splitChapters(_ text: String, fallbackTitle: String) -> [RawChapter] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        let pattern = "^\\s*(?:正文\\s*)?(?:第[0-9零一二三四五六七八九十百千万两〇]{1,10}[章节回卷集部篇]|序章|楔子|前言|后记|尾声|番外)[^\\n]{0,40}$"
        let regex = try? NSRegularExpression(pattern: pattern)

        var chapters: [RawChapter] = []
        var currentTitle: String? = nil
        var buffer: [String] = []

        func flush() {
            let content = trimBlank(buffer.joined(separator: "\n"))
            if let title = currentTitle {
                chapters.append(RawChapter(title: title, content: content))
            } else if !content.isEmpty {
                chapters.append(RawChapter(title: fallbackTitle, content: content))
            }
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            let isTitle = trimmed.count <= 40 && trimmed.count >= 2 &&
                (regex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil)

            if isTitle {
                flush()
                currentTitle = trimmed
            } else {
                buffer.append(line)
            }
        }
        flush()

        var merged: [RawChapter] = []
        for chapter in chapters where !chapter.content.isEmpty {
            if let last = merged.last, last.content.count < 200 {
                merged[merged.count - 1].content += "\n" + chapter.title + "\n" + chapter.content
            } else {
                merged.append(chapter)
            }
        }
        return merged.isEmpty ? [RawChapter(title: fallbackTitle, content: trimBlank(normalized))] : merged
    }

    private static func trimBlank(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
