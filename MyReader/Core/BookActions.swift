import Foundation
import UIKit

enum BookActions {
    /// 把搜索结果变成书架里的一本书（目录 + 封面 + 简介）。
    static func add(result: SearchResult, store: Store) async throws -> Book {
        guard let source = store.source(id: result.sourceID) else {
            throw BookSourceEngineError.missingSource
        }
        var book = Book(name: result.title, origin: .online)
        book.author = result.author
        book.intro = result.intro
        book.coverURL = result.cover
        book.sourceID = source.id
        book.sourceName = source.name
        book.detailURL = result.link

        // 同一本书（书名 + 作者一致）在书架里只保留一条记录：
        // 换源加入 / 重复加入都走「更新已有记录」，复用 id（章节缓存目录、书签、
        // 阅读进度都挂在 id 上），避免书架出现两本同名书。
        if let existing = store.books.first(where: {
            $0.name == result.title && Self.sameAuthor($0.author, result.author)
        }) {
            book.id = existing.id
            book.currentChapter = existing.currentChapter
            book.currentPage = existing.currentPage
            book.groupID = existing.groupID
            book.stick = existing.stick
            book.createdAt = existing.createdAt
            book.lastReadAt = existing.lastReadAt
            if existing.sourceID != source.id {
                // 换源：旧源正文缓存按「章节索引」存储，索引含义已变 → 必须清空，
                // 否则新目录配上旧源正文就是「章节错配」。
                Paths.removeChapters(bookID: book.id)
                AppLog.info("ADD", "《\(book.name.prefix(16))》换源加入（\(existing.sourceName) → \(source.name)），旧正文缓存已清空")
            }
        }
        // helpId 提取失败时从详情地址的 id= 参数兜底（否则正文组合规则拼出 `id=` 空）
        book.helpId = result.helpId.isEmpty
            ? IBSEngine.helpIdFromURL(result.link) : result.helpId

        let engine = IBSEngine(source: source)
        engine.helpId = book.helpId
        // 目录
        if let chapters = try? await engine.directory(link: result.link) {
            book.chapters = chapters
        }
        if book.chapters.isEmpty {
            AppLog.warn("ADD", "《\(book.name.prefix(16))》目录0章（link=\(result.link.prefix(60))）——阅读将为空白")
        }
        // 详情（bookDetail 为空时保持搜索结果字段）
        if let (intro, cover) = try? await engine.detail(link: result.link) {
            if book.intro.isEmpty { book.intro = intro }
            if book.coverURL.isEmpty { book.coverURL = cover }
        }

        store.addBook(book)
        if !book.coverURL.isEmpty {
            downloadCover(book: book, store: store)
        }
        return book
    }

    /// 异步下载封面并缓存到本地。
    static func downloadCover(book: Book, store: Store) {
        guard !book.coverURL.isEmpty else { return }
        let bookID = book.id
        let urlString = book.coverURL
        Task.detached(priority: .utility) {
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            request.setValue(Fetcher.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = UIImage(data: data) else { return }
            let file = Paths.covers.appendingPathComponent("\(bookID.uuidString).jpg")
            if let jpeg = image.jpegData(compressionQuality: 0.85) {
                try? jpeg.write(to: file)
            }
            await MainActor.run {
                guard var latest = store.book(id: bookID) else { return }
                latest.coverFile = Paths.relative(file)
                store.updateBook(latest)
            }
        }
    }

    /// 更新目录（书源详情页解析）。
    static func refreshDirectory(book: Book, store: Store) async throws -> Book {
        guard let sourceID = book.sourceID,
              let source = store.source(id: sourceID) else {
            throw BookSourceEngineError.missingSource
        }
        var updated = book
        let engine = IBSEngine(source: source)
        // 目录/正文组合规则（七猫 `bid=source.helpId`）依赖书籍级 helpId，必须带上。
        let helpId = book.helpId.isEmpty
            ? IBSEngine.helpIdFromURL(book.detailURL) : book.helpId
        engine.helpId = helpId
        if book.helpId.isEmpty && !helpId.isEmpty {
            updated.helpId = helpId
            AppLog.warn("ADD", "《\(book.name.prefix(16))》helpId为空，已从详情URL补全：\(helpId)")
        }
        let chapters = try await engine.directory(link: book.detailURL)
        if !chapters.isEmpty {
            // 按磁盘缓存标记
            updated.chapters = chapters.map { chapter in
                var copy = chapter
                copy.cached = Paths.readChapter(bookID: book.id, index: chapter.index) != nil
                return copy
            }
        }
        if let (intro, cover) = try? await engine.detail(link: book.detailURL) {
            if !intro.isEmpty { updated.intro = intro }
            if !cover.isEmpty { updated.coverURL = cover }
        }
        store.updateBook(updated)
        return updated
    }

    /// 换源：切换书源重新解析目录（正文缓存按旧源磁盘文件保留，索引对得上的章节直接复用）。
    static func changeSource(book: Book, to newSource: IBSBookSource, store: Store) async throws -> Book {
        AppLog.info("SOURCE", "换源：\(book.name) \(book.sourceName.isEmpty ? "?" : book.sourceName) → \(newSource.name)")
        var updated = book
        updated.sourceID = newSource.id
        updated.sourceName = newSource.name
        // detailURL 需按新源重新解析——搜索接口用书名定位该书
        let engine = IBSEngine(source: newSource)
        let results = try await engine.search(keyword: book.name)
        guard let match = results.first(where: { $0.title == book.name })
            ?? results.first(where: { $0.title.localizedCaseInsensitiveContains(book.name) })
            ?? results.first else {
            AppLog.warn("SOURCE", "换源失败：新源搜索「\(book.name)」无结果")
            throw BookSourceEngineError.missingSource
        }
        updated.detailURL = match.link
        updated.helpId = match.helpId.isEmpty
            ? IBSEngine.helpIdFromURL(match.link) : match.helpId
        engine.helpId = updated.helpId
        let chapters = try await engine.directory(link: match.link)
        guard !chapters.isEmpty else {
            AppLog.error("SOURCE", "换源失败：新源目录解析0章（detailURL=\(match.link.prefix(60))）")
            throw BookSourceEngineError.directoryFailed
        }
        // 旧源正文缓存按章节索引存储，换源后索引含义已变 → 必须清空，
        // 否则「新源目录 + 旧源正文」= 章节错配（用户实拍现象）。
        Paths.removeChapters(bookID: book.id)
        updated.chapters = chapters   // cached 全部 false
        // 进度对齐：按章节标题匹配，而不是直接沿用索引（各源章节数/顺序不同）
        let oldTitle = book.chapters.indices.contains(book.currentChapter)
            ? book.chapters[book.currentChapter].title : ""
        updated.currentChapter = Self.alignChapter(oldTitle: oldTitle,
                                                  oldIndex: book.currentChapter,
                                                  oldCount: book.chapters.count,
                                                  newChapters: chapters)
        updated.currentPage = 0
        store.updateBook(updated)
        AppLog.info("SOURCE", "换源完成：\(chapters.count)章，进度对齐 「\(oldTitle.prefix(18))」→ 第\(updated.currentChapter + 1)章「\(chapters[updated.currentChapter].title.prefix(18))」")
        return updated
    }

    // MARK: - 章节对齐 / 作者判定

    /// 作者一致性：双方都有作者时严格相等；任一侧为空时按「都为空」放过。
    static func sameAuthor(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty }
        return a == b
    }

    /// 换源后定位到「同一章」：标题精确 → 标题前缀 → 章节号 → 按比例估算。
    static func alignChapter(oldTitle: String, oldIndex: Int, oldCount: Int,
                             newChapters: [Chapter]) -> Int {
        guard !newChapters.isEmpty else { return 0 }
        let key = normalizeTitle(oldTitle)
        if key.count >= 2 {
            if let index = newChapters.firstIndex(where: { normalizeTitle($0.title) == key }) {
                return index
            }
            let head = String(key.prefix(12))
            if head.count >= 4,
               let index = newChapters.firstIndex(where: { normalizeTitle($0.title).hasPrefix(head) }) {
                return index
            }
            if let number = IBSEngine.chapterNumber(in: oldTitle),
               let index = newChapters.firstIndex(where: { IBSEngine.chapterNumber(in: $0.title) == number }) {
                return index
            }
        }
        let ratio = oldCount > 1 ? Double(oldIndex) / Double(oldCount) : 0
        let estimated = Int((ratio * Double(newChapters.count)).rounded())
        return min(newChapters.count - 1, max(0, estimated))
    }

    /// 标题归一化：去掉所有空白与常见分隔标点，便于跨源比对。
    static func normalizeTitle(_ title: String) -> String {
        let dropped: Set<Character> = [" ", "\u{3000}", "\t", "\n", "　", "·", "：", ":", "，", ","]
        return String(title.filter { !dropped.contains($0) })
    }

    /// 导出书籍为 TXT。
    static func exportTXT(book: Book) -> URL? {
        var text = book.name + "\n" + book.author + "\n\n"
        for chapter in book.chapters {
            text += chapter.title + "\n\n"
            if let content = Paths.readChapter(bookID: book.id, index: chapter.index) {
                text += content + "\n\n"
            }
        }
        let file = Paths.root.appendingPathComponent("\(book.name).txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

enum BookSourceEngineError: LocalizedError {
    case missingSource
    case directoryFailed

    var errorDescription: String? {
        switch self {
        case .missingSource: return "书源已被删除"
        case .directoryFailed: return "新源目录解析失败（0章），已保留原书源"
        }
    }
}
