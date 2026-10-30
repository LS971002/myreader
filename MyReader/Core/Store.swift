import Foundation
import Combine

/// 全局数据仓库。使用 JSON + 文件系统持久化，简单、可读、方便备份。
final class Store: ObservableObject {
    static let shared = Store()

    @Published var books: [Book] = []
    @Published var sources: [BookSource] = []
    @Published var groups: [BookGroup] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var settings: AppSettings = AppSettings()

    private let io = DispatchQueue(label: "com.example.myreader.io")
    private var pendingSave: DispatchWorkItem?

    private init() {
        load()
    }

    // MARK: - 载入 / 保存

    private func load() {
        books = loadArray(Book.self, elementDefault: Book(), at: Paths.booksJSON)
        sources = loadArray(BookSource.self, elementDefault: BookSource(), at: Paths.sourcesJSON)
        groups = loadArray(BookGroup.self, elementDefault: BookGroup(), at: Paths.groupsJSON)
        bookmarks = loadArray(Bookmark.self, elementDefault: Bookmark(), at: Paths.bookmarksJSON)

        if let data = try? Data(contentsOf: Paths.settingsJSON),
           let settings = LenientJSON.decode(AppSettings.self, from: data, default: AppSettings()) {
            self.settings = settings
        }

        if groups.isEmpty {
            groups = [BookGroup(name: "未分组", sort: 0)]
        }
    }

    private func loadArray<T: Codable>(_ type: T.Type, elementDefault: T, at url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return LenientJSON.decodeArray(type, from: data, elementDefault: elementDefault) ?? []
    }

    /// 合并短时间内的多次写入，避免频繁落盘。
    func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flush()
        }
        pendingSave = work
        io.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        let snapshot = (
            json(books), json(sources), json(groups), json(bookmarks), json(settings)
        )
        io.async {
            try? snapshot.0?.write(to: Paths.booksJSON, options: .atomic)
            try? snapshot.1?.write(to: Paths.sourcesJSON, options: .atomic)
            try? snapshot.2?.write(to: Paths.groupsJSON, options: .atomic)
            try? snapshot.3?.write(to: Paths.bookmarksJSON, options: .atomic)
            try? snapshot.4?.write(to: Paths.settingsJSON, options: .atomic)
        }
    }

    private func json<T: Encodable>(_ value: T) -> Data? {
        let encoder = LenientJSON.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    // MARK: - 书籍

    func book(id: UUID) -> Book? { books.first { $0.id == id } }

    func updateBook(_ book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        save()
    }

    func addBook(_ book: Book) {
        if let idx = books.firstIndex(where: { $0.name == book.name && $0.author == book.author }) {
            books[idx].lastReadAt = Date()
        } else {
            books.insert(book, at: 0)
        }
        save()
    }

    func removeBook(_ book: Book) {
        books.removeAll { $0.id == book.id }
        Paths.removeChapters(bookID: book.id)
        bookmarks.removeAll { $0.bookID == book.id }
        save()
    }

    func toggleStick(_ book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx].stick.toggle()
        save()
    }

    func moveBook(_ book: Book, toGroup groupID: UUID?) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx].groupID = groupID
        save()
    }

    // MARK: - 书源

    func upsertSources(_ list: [BookSource]) {
        for source in list {
            if let idx = sources.firstIndex(where: { $0.id == source.id }) {
                sources[idx] = source
            } else if let idx = sources.firstIndex(where: { $0.name == source.name && $0.baseURL == source.baseURL }) {
                sources[idx] = source
            } else {
                sources.append(source)
            }
        }
        save()
    }

    func removeSource(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        save()
    }

    var enabledSources: [BookSource] {
        sources.filter { $0.enabled }.sorted { $0.weight > $1.weight }
    }

    // MARK: - 分组

    func addGroup(_ name: String) {
        groups.append(BookGroup(name: name, sort: groups.count))
        save()
    }

    func removeGroup(_ group: BookGroup) {
        groups.removeAll { $0.id == group.id }
        for idx in books.indices where books[idx].groupID == group.id {
            books[idx].groupID = nil
        }
        save()
    }

    // MARK: - 书签

    func addBookmark(_ mark: Bookmark) {
        bookmarks.insert(mark, at: 0)
        save()
    }

    func removeBookmark(_ mark: Bookmark) {
        bookmarks.removeAll { $0.id == mark.id }
        save()
    }

    func bookmarks(for bookID: UUID) -> [Bookmark] {
        bookmarks.filter { $0.bookID == bookID }
    }

    // MARK: - 阅读进度

    func updateProgress(bookID: UUID, chapter: Int, page: Int, progress: Double) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].currentChapter = chapter
        books[idx].currentPage = page
        books[idx].progress = progress
        books[idx].lastReadAt = Date()
        save()
    }

    // MARK: - 设置

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        save()
    }
}
