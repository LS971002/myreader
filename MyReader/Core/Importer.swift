import Foundation

/// 本地文件导入：TXT / EPUB / 书源 JSON。全部落地到沙盒，可离线阅读。
enum Importer {
    enum ImportError: LocalizedError {
        case unsupported
        case empty
        case read

        var errorDescription: String? {
            switch self {
            case .unsupported: return "不支持的文件类型"
            case .empty: return "文件内容为空"
            case .read: return "读取文件失败"
            }
        }
    }

    static func handleIncoming(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            _ = try? importBookSources(from: url)
        } else {
            _ = try? importBook(from: url)
        }
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
            // 没有扩展名时按文本处理
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

        // 正文落盘
        for (index, item) in chapters.enumerated() {
            Paths.writeChapter(item.content, bookID: book.id, index: index)
        }

        // 备份原文件
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

    // MARK: - 切章

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

        // 合并过短的章节（通常是误判的标题）
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

    // MARK: - 导入书源

    @discardableResult
    static func importBookSources(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let sources = try decodeSources(data)
        Store.shared.upsertSources(sources)
        return sources.count
    }

    static func decodeSources(_ data: Data) throws -> [BookSource] {
        if let list = LenientJSON.decodeArray(BookSource.self, from: data, elementDefault: BookSource()) {
            return list.map { fillID($0) }
        }
        // 兼容 {"sources": [...]} 或单个对象
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let array = object["sources"] as? [[String: Any]],
               let arrayData = try? JSONSerialization.data(withJSONObject: array),
               let list = LenientJSON.decodeArray(BookSource.self, from: arrayData,
                                                  elementDefault: BookSource()) {
                return list.map { fillID($0) }
            }
            if let single = LenientJSON.decode(BookSource.self, from: data, default: BookSource()) {
                return [fillID(single)]
            }
        }
        throw ImportError.unsupported
    }

    private static func fillID(_ source: BookSource) -> BookSource {
        var copy = source
        if copy.name.isEmpty { copy.name = "未命名书源" }
        return copy
    }
}
