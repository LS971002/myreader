import Foundation
import UIKit
import Combine

final class ReaderModel: ObservableObject {
    let store: Store
    let bookID: UUID

    @Published var book: Book
    @Published var pages: [String] = [""]
    @Published var pageIndex: Int = 0
    @Published var loading = false
    @Published var errorMessage: String?

    private var pageCache: [Int: [String]] = [:]
    private var size: CGSize = .zero
    private var goToLastPage = false
    private var task: Task<Void, Never>?

    init(store: Store, book: Book) {
        self.store = store
        self.bookID = book.id
        self.book = book
    }

    var currentChapterTitle: String {
        guard book.chapters.indices.contains(book.currentChapter) else { return book.name }
        return book.chapters[book.currentChapter].title
    }

    var progressText: String {
        guard !book.chapters.isEmpty else { return "" }
        let chapterRatio = Double(book.currentChapter) / Double(max(book.chapters.count, 1))
        let pageRatio = pages.count > 1 ? Double(pageIndex) / Double(pages.count) : 0
        let overall = min(1, chapterRatio + pageRatio / Double(book.chapters.count))
        return String(format: "%.1f%%", overall * 100)
    }

    // MARK: - 布局变化

    func updateLayout(size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let changed = abs(size.width - self.size.width) > 1 || abs(size.height - self.size.height) > 1
        self.size = size
        guard changed else { return }
        pageCache.removeAll()
        Task { await reloadCurrentChapter(keepPosition: true) }
    }

    func reloadPagination() {
        pageCache.removeAll()
        Task { await reloadCurrentChapter(keepPosition: true) }
    }

    // MARK: - 打开 / 加载

    func onAppear() {
        Task { await reloadCurrentChapter(keepPosition: false) }
    }

    private func reloadCurrentChapter(keepPosition: Bool) async {
        let index = book.currentChapter
        let savedPage = keepPosition ? pageIndex : book.currentPage
        await load(chapterIndex: index, targetPage: savedPage)
    }

    func load(chapterIndex: Int, targetPage: Int = 0, useLastPage: Bool = false) async {
        guard book.chapters.indices.contains(chapterIndex) else { return }
        guard size.width > 10 else { return }

        loading = true
        defer { loading = false }
        errorMessage = nil

        let text = await chapterText(chapterIndex)
        guard !text.isEmpty else {
            errorMessage = "该章节暂时没有内容，可尝试换源或稍后重试"
            pages = [""]
            pageIndex = 0
            return
        }

        let settings = store.settings
        let layoutSize = CGSize(width: size.width, height: size.height)
        var newPages = pageCache[chapterIndex]
        if newPages == nil || newPages?.isEmpty == true {
            let attributed = Typography.attributed(
                text, settings: settings, color: .black,
                title: book.chapters[chapterIndex].title
            )
            newPages = Typography.paginate(attributed: attributed, size: layoutSize)
            pageCache[chapterIndex] = newPages
        }
        pages = newPages ?? [text]

        if useLastPage {
            pageIndex = max(0, pages.count - 1)
        } else {
            pageIndex = min(max(0, targetPage), max(0, pages.count - 1))
        }

        book.currentChapter = chapterIndex
        book.currentPage = pageIndex
        store.updateProgress(bookID: bookID, chapter: chapterIndex, page: pageIndex,
                             progress: overallProgress(chapter: chapterIndex, page: pageIndex))

        prefetchAround(chapterIndex)
    }

    private func overallProgress(chapter: Int, page: Int) -> Double {
        let total = max(book.chapters.count, 1)
        let within = pages.count > 1 ? Double(page) / Double(pages.count) : 0
        return min(1, (Double(chapter) + within) / Double(total))
    }

    func chapterText(_ index: Int) async -> String {
        if let cached = Paths.readChapter(bookID: bookID, index: index), !cached.isEmpty {
            return cached
        }
        guard book.origin == .online else { return "" }
        guard let sourceID = book.sourceID,
              let source = store.sources.first(where: { $0.id == sourceID }),
              book.chapters.indices.contains(index) else {
            return ""
        }
        let chapter = book.chapters[index]
        let engine = BookSourceEngine(source)
        do {
            let text = try await engine.content(of: chapter)
            if !text.isEmpty {
                Paths.writeChapter(text, bookID: bookID, index: index)
            }
            return text
        } catch {
            errorMessage = error.localizedDescription
            return ""
        }
    }

    private func prefetchAround(_ index: Int) {
        guard store.settings.autoCacheNext else { return }
        let count = store.settings.preloadCount
        Task { [weak self] in
            guard let self else { return }
            for offset in 1...max(1, count) {
                let target = index + offset
                guard self.book.chapters.indices.contains(target) else { break }
                if Paths.readChapter(bookID: self.bookID, index: target) != nil { continue }
                _ = await self.chapterText(target)
            }
        }
    }

    // MARK: - 翻页

    func nextPage() {
        if pageIndex + 1 < pages.count {
            pageIndex += 1
            persistProgress()
        } else {
            goNextChapter()
        }
    }

    func prevPage() {
        if pageIndex > 0 {
            pageIndex -= 1
            persistProgress()
        } else {
            goPreviousChapter()
        }
    }

    func goNextChapter() {
        let next = book.currentChapter + 1
        guard book.chapters.indices.contains(next) else { return }
        Task { await load(chapterIndex: next, targetPage: 0) }
    }

    func goPreviousChapter() {
        let prev = book.currentChapter - 1
        guard book.chapters.indices.contains(prev) else { return }
        Task { await load(chapterIndex: prev, useLastPage: true) }
    }

    func jump(to chapter: Int) {
        guard book.chapters.indices.contains(chapter) else { return }
        Task { await load(chapterIndex: chapter, targetPage: 0) }
    }

    private func persistProgress() {
        book.currentPage = pageIndex
        store.updateProgress(bookID: bookID, chapter: book.currentChapter, page: pageIndex,
                             progress: overallProgress(chapter: book.currentChapter, page: pageIndex))
    }

    // MARK: - 缓存

    func cacheCurrentChapter() async -> Int {
        let text = await chapterText(book.currentChapter)
        return text.count
    }

    func clearCache() {
        Paths.removeChapters(bookID: bookID)
        pageCache.removeAll()
    }
}
