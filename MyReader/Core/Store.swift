import Foundation
import Combine

/// 全局数据仓库。JSON + 文件系统持久化。
/// 书源以 SourceRecord（解密后的 IBS JSON 原文 + 元数据）落盘。
final class Store: ObservableObject {
    static let shared = Store()

    @Published var books: [Book] = []
    @Published var sourceRecords: [SourceRecord] = []
    @Published var groups: [BookGroup] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var settings: AppSettings = AppSettings()

    /// 「用其他应用打开」导入的书源/书籍草稿（导入确认 Sheet / 全局提示）。
    @Published var incomingDraft: Book?
    @Published var incomingSplitMode: Importer.SplitMode = .smart
    @Published var importNotice: String?

    /// 解析后的书源（records 变更时重建）。
    private(set) var sources: [IBSBookSource] = []

    private let io = DispatchQueue(label: "com.example.myreader.io")
    private var pendingSave: DispatchWorkItem?

    private init() {
        load()
        reloadSources()
    }

    // MARK: - 载入 / 保存

    private func load() {
        books = loadArray(Book.self, elementDefault: Book(), at: Paths.booksJSON)
        sourceRecords = loadArray(SourceRecord.self, elementDefault: SourceRecord(),
                                  at: Paths.sourcesJSON)
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
            json(books), json(sourceRecords), json(groups), json(bookmarks), json(settings)
        )
        io.async {
            do { try snapshot.0?.write(to: Paths.booksJSON, options: .atomic) }
            catch { AppLog.error("STORE", "books.json写入失败: \(error.localizedDescription)") }
            do { try snapshot.1?.write(to: Paths.sourcesJSON, options: .atomic) }
            catch { AppLog.error("STORE", "sources.json写入失败: \(error.localizedDescription)") }
            do { try snapshot.2?.write(to: Paths.groupsJSON, options: .atomic) }
            catch { AppLog.error("STORE", "groups.json写入失败: \(error.localizedDescription)") }
            do { try snapshot.3?.write(to: Paths.bookmarksJSON, options: .atomic) }
            catch { AppLog.error("STORE", "bookmarks.json写入失败: \(error.localizedDescription)") }
            do { try snapshot.4?.write(to: Paths.settingsJSON, options: .atomic) }
            catch { AppLog.error("STORE", "settings.json写入失败: \(error.localizedDescription)") }
        }
    }

    private func json<T: Encodable>(_ value: T) -> Data? {
        let encoder = LenientJSON.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    // MARK: - 导入结果呈现

    /// 主线程调用：书源 → 全局提示；书籍 → 弹出导入确认 Sheet。
    func present(_ outcome: Importer.IncomingOutcome) {
        switch outcome {
        case .sources(let count, let firstName):
            let name = firstName.isEmpty ? "" : "（\(firstName)）"
            importNotice = "已导入 \(count) 个书源\(name)，可到「发现」页搜索"
        case .bookDraft(let book):
            incomingSplitMode = .smart
            incomingDraft = book
        case .failed(let message):
            importNotice = message
        }
    }

    // MARK: - 书源

    func reloadSources() {
        sources = sourceRecords.compactMap { $0.resolve() }
    }

    var enabledSources: [IBSBookSource] {
        sources.filter { $0.enabled }.sorted { $0.weight > $1.weight }
    }

    func source(id: UUID) -> IBSBookSource? {
        sources.first { $0.id == id }
    }

    /// 导入 / 更新书源（同名同 homeURL 视为更新，保留启用状态）。
    func upsertSources(_ list: [IBSBookSource]) {
        for source in list {
            if let index = sourceRecords.firstIndex(where: {
                $0.id == source.id
                    || (recordName($0) == source.name && recordHome($0) == source.homeURL)
            }) {
                var record = SourceRecord.record(from: source)
                record.id = sourceRecords[index].id
                record.group = sourceRecords[index].group
                record.enabled = sourceRecords[index].enabled
                record.importedAt = Date()
                sourceRecords[index] = record
            } else {
                sourceRecords.append(SourceRecord.record(from: source))
            }
        }
        reloadSources()
        save()
    }

    private func recordName(_ record: SourceRecord) -> String {
        guard let data = record.rawJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        return (object["name"] as? String) ?? ""
    }

    private func recordHome(_ record: SourceRecord) -> String {
        guard let data = record.rawJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        return (object["homeUrl"] as? String) ?? ""
    }

    func removeSource(_ source: IBSBookSource) {
        sourceRecords.removeAll { $0.id == source.id }
        reloadSources()
        save()
    }

    func toggleSource(_ source: IBSBookSource) {
        guard let index = sourceRecords.firstIndex(where: { $0.id == source.id }) else { return }
        sourceRecords[index].enabled.toggle()
        reloadSources()
        save()
    }

    func setSourceEnabled(_ source: IBSBookSource, enabled: Bool) {
        guard let index = sourceRecords.firstIndex(where: { $0.id == source.id }) else { return }
        sourceRecords[index].enabled = enabled
        reloadSources()
        save()
    }

    // MARK: - 书籍

    func book(id: UUID) -> Book? { books.first { $0.id == id } }

    func updateBook(_ book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        save()
    }

    func addBook(_ book: Book) {
        // 同一本书（同 id 或 同书名同作者）只保留一条记录：不同源也只是换源，
        // 不允许书架出现两本同名书（用户明确要求）。
        if let idx = books.firstIndex(where: {
            $0.id == book.id || ($0.name == book.name && BookActions.sameAuthor($0.author, book.author))
        }) {
            var merged = book
            let old = books[idx]
            merged.id = old.id                         // 复用 id：章节缓存/书签/进度都挂在它上面
            merged.createdAt = old.createdAt
            merged.groupID = old.groupID
            merged.stick = old.stick
            merged.lastReadAt = Date()
            merged.currentPage = old.currentPage
            // 只有「同一源且章节数一致」才保留原进度；换源时进度已由
            // BookActions 按标题对齐好，直接采用传入值。
            if old.sourceID == book.sourceID, !book.chapters.isEmpty,
               old.chapters.count == book.chapters.count {
                merged.currentChapter = min(old.currentChapter, book.chapters.count - 1)
            }
            merged.currentChapter = min(merged.currentChapter, max(0, book.chapters.count - 1))
            if old.chapters.isEmpty {
                AppLog.info("STORE", "《\(book.name.prefix(16))》旧记录0章，已用新解析结果替换（\(book.chapters.count)章）")
            } else if old.sourceID != book.sourceID {
                AppLog.info("STORE", "《\(book.name.prefix(16))》换源更新（\(old.sourceName) → \(book.sourceName)，\(old.chapters.count)→\(book.chapters.count)章）")
            }
            books[idx] = merged
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
