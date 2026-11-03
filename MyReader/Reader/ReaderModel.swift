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
    /// 上一次章节跳转方向（跨章过渡动画方向）。
    @Published var lastJumpForward = true

    private var pageCache: [Int: [String]] = [:]
    private var size: CGSize = .zero
    private var goToLastPage = false
    private var task: Task<Void, Never>?
    /// load 代次：用于并发去重（同一章被多次触发时只让最后一次生效）。
    private var loadGeneration = 0
    /// 在途的正文请求（章节序号 → 任务）。同一章并发请求只发一次。
    private var inflight: [Int: Task<String, Never>] = [:]
    private var inflightToken: [Int: Int] = [:]
    private var inflightSeq = 0

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
        Task { @MainActor in await self.reloadCurrentChapter(keepPosition: true) }
    }

    func reloadPagination() {
        pageCache.removeAll()
        Task { @MainActor in await self.reloadCurrentChapter(keepPosition: true) }
    }

    // MARK: - 打开 / 加载

    func onAppear() {
        Task { @MainActor in await self.reloadCurrentChapter(keepPosition: false) }
    }

    private func reloadCurrentChapter(keepPosition: Bool) async {
        let index = book.currentChapter
        let savedPage = keepPosition ? pageIndex : book.currentPage
        await load(chapterIndex: index, targetPage: savedPage)
    }

    func load(chapterIndex: Int, targetPage: Int = 0, useLastPage: Bool = false) async {
        guard book.chapters.indices.contains(chapterIndex) else { return }
        guard size.width > 10 else { return }

        // 并发去重：onAppear / updateLayout(reloadPagination) / 手势 可能在同一瞬间
        // 各起一次 load，日志(13) 出现过同一章被请求并分页 6 次。
        // 只让最后一次生效，先前那次在 await 之后主动放弃（不写状态、不写缓存）。
        loadGeneration += 1
        let generation = loadGeneration

        loading = true
        errorMessage = nil

        let text = await chapterText(chapterIndex)
        guard generation == loadGeneration else { return }
        loading = false
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
        AppLog.info("READER", "章节[\(chapterIndex)]分页完成：\(pages.count)页 / \(text.count)字\(useLastPage ? "（定位末页）" : "")")

        if useLastPage {
            pageIndex = max(0, pages.count - 1)
        } else {
            pageIndex = min(max(0, targetPage), max(0, pages.count - 1))
        }

        book.currentChapter = chapterIndex
        book.currentPage = pageIndex
        progressTask?.cancel()
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
            // 旧版本曾把接口错误 JSON（正文规则未命中时的整页兜底）写进缓存，
            // 识别后丢弃重取，避免修好解析仍显示 115 字的错误内容。
            if IBSEngine.looksLikeAPIErrorPayload(cached) {
                AppLog.warn("READER", "章节[\(index)]缓存为接口错误响应（\(cached.count)字），已丢弃重取")
                Paths.removeChapter(bookID: bookID, index: index)
            } else {
                return cached
            }
        }
        // 并发合流：正读章节与预取可能同时请求同一章
        // （日志(14)：章节[0] 被连续请求 2 次，1~6 章各被预取 2 轮）。
        // 已在途则直接等它的结果，不再发第二个请求。
        if let inflightTask = inflight[index] {
            return await inflightTask.value
        }
        inflightSeq += 1
        let token = inflightSeq
        inflightToken[index] = token
        let task = Task { @MainActor [weak self] () -> String in
            guard let self else { return "" }
            let text = await self.fetchChapterText(index)
            // 仅清理自己这一轮（期间可能已发起新一轮，别把新任务清掉）
            if self.inflightToken[index] == token {
                self.inflight[index] = nil
                self.inflightToken[index] = nil
            }
            return text
        }
        inflight[index] = task
        return await task.value
    }

    /// 实际取正文（网络 + 落盘）。只由 chapterText 的合流任务调用。
    private func fetchChapterText(_ index: Int) async -> String {
        guard book.origin == .online else { return "" }
        guard let sourceID = book.sourceID,
              let source = store.source(id: sourceID),
              book.chapters.indices.contains(index) else {
            return ""
        }
        // 旧版本目录 URL 里 helpId 为空（`...?id=&chapterId=...`）→ 正文接口必报参数错误，
        // 首次取正文时重建一次目录（同源同书，章节顺序不变）。
        await refreshDirectoryIfStale()
        guard book.chapters.indices.contains(index) else { return "" }

        let chapter = book.chapters[index]
        let engine = IBSEngine(source: source)
        // helpId 为空（旧书数据）时由引擎从 detailURL 的 id= 参数兜底解析。
        engine.helpId = book.helpId.isEmpty
            ? IBSEngine.helpIdFromURL(book.detailURL) : book.helpId
        if book.helpId.isEmpty && !engine.helpId.isEmpty {
            AppLog.warn("READER", "书籍helpId为空，已从详情URL兜底解析：\(engine.helpId)")
        }
        do {
            AppLog.debug("READER", "取章节[\(index)] \(chapter.title.prefix(20))（源:\(source.name)，helpId:\(engine.helpId.isEmpty ? "空" : engine.helpId)）")
            let text = try await engine.content(chapter: chapter, detailURL: book.detailURL)
            if !text.isEmpty && !engine.lastContentUsedFallback {
                Paths.writeChapter(text, bookID: bookID, index: index)
            } else if text.isEmpty {
                AppLog.warn("READER", "章节[\(index)]内容为空")
            } else {
                AppLog.warn("READER", "章节[\(index)]仅拿到兜底内容（\(text.count)字），不写缓存")
            }
            return text
        } catch {
            AppLog.error("READER", "章节[\(index)]获取失败: \(error.localizedDescription)")
            // @Published 写一律回主线程（chapterText 可能被后台 Task 调用）
            let message = error.localizedDescription
            await MainActor.run { [weak self] in self?.errorMessage = message }
            return ""
        }
    }

    // MARK: - 目录自愈

    private var directoryChecked = false

    /// 旧版本 helpId 未注入时目录URL是 `...?id=&chapterId=...`（sign 也随之算错），
    /// 正文接口只会返回参数错误。首次取正文时自动重建一次目录。
    private func refreshDirectoryIfStale() async {
        guard !directoryChecked, book.origin == .online else { return }
        directoryChecked = true
        let stale = book.chapters.contains {
            $0.url.contains("id=&") || $0.url.hasSuffix("id=")
        }
        guard stale else { return }
        AppLog.warn("READER", "《\(book.name.prefix(16))》旧目录URL缺少id参数，自动重建目录")
        guard let updated = try? await BookActions.refreshDirectory(book: book, store: store),
              !updated.chapters.isEmpty else {
            AppLog.error("READER", "目录重建失败，正文可能继续为空")
            return
        }
        // @Published 写回主线程（本函数可能被后台 Task 调用）
        await MainActor.run { [weak self] in
            self?.book = updated
            self?.pageCache.removeAll()
        }
        AppLog.info("READER", "目录已重建：\(updated.chapters.count)章（第\(updated.currentChapter + 1)章）")
    }

    private func prefetchAround(_ index: Int) {
        guard store.settings.autoCacheNext else { return }
        let count = store.settings.preloadCount
        // ⚠️ 必须 @MainActor：非隔离方法里的裸 `Task {}` 跑在全局并发执行器（后台），
        // 而 chapterText 内部会写 @Published（errorMessage / book），
        // 后台写 → Combine send → SwiftUI 在后台线程触发布局 →
        // CoreAutoLayout 抛 NSInternalInconsistencyException → SIGABRT。
        // 崩溃日志(13) 调用栈正是这条线。
        Task { @MainActor [weak self] in
            guard let self else { return }
            for offset in 1...max(1, count) {
                let target = index + offset
                guard self.book.chapters.indices.contains(target) else { break }
                if let cached = Paths.readChapter(bookID: self.bookID, index: target),
                   !IBSEngine.looksLikeAPIErrorPayload(cached) { continue }
                _ = await self.chapterText(target)
            }
        }
    }

    // MARK: - 翻页

    /// UIScrollView 分页回调：翻页（不重新加载章节，只更新进度）。
    func setPage(_ index: Int) {
        guard pages.indices.contains(index), index != pageIndex else { return }
        lastJumpForward = index > pageIndex
        pageIndex = index
        book.currentPage = index
        persistProgress()
    }

    func nextPage() {
        lastJumpForward = true
        if pageIndex + 1 < pages.count {
            pageIndex += 1
            persistProgress()
        } else {
            goNextChapter()
        }
    }

    func prevPage() {
        lastJumpForward = false
        if pageIndex > 0 {
            pageIndex -= 1
            persistProgress()
        } else {
            goPreviousChapter()
        }
    }

    // MARK: - 邻页（双页跟手翻页）

    /// 左侧邻页文本：章内上一页；处于章首页时为 nil（跨章交给占位卡）。
    var neighborPrev: String? {
        guard pageIndex > 0 else { return nil }
        return pages.indices.contains(pageIndex - 1) ? pages[pageIndex - 1] : nil
    }

    /// 右侧邻页文本：章内下一页；处于章末页时为 nil。
    var neighborNext: String? {
        guard pageIndex + 1 < pages.count else { return nil }
        return pages[pageIndex + 1]
    }

    /// 章节占位：左侧（上一章末页，若已缓存分页则给真实内容）。
    var neighborChapterPrev: (title: String, text: String)? {
        let prev = book.currentChapter - 1
        guard book.chapters.indices.contains(prev) else { return nil }
        if let cached = pageCache[prev], let last = cached.last, !last.isEmpty {
            return (book.chapters[prev].title, last)
        }
        return nil
    }

    /// 章节占位：右侧（下一章首页，若已缓存分页则给真实内容）。
    var neighborChapterNext: (title: String, text: String)? {
        let next = book.currentChapter + 1
        guard book.chapters.indices.contains(next) else { return nil }
        if let cached = pageCache[next], let first = cached.first, !first.isEmpty {
            return (book.chapters[next].title, first)
        }
        return nil
    }

    var chapterTitlePrev: String? {
        let prev = book.currentChapter - 1
        return book.chapters.indices.contains(prev) ? book.chapters[prev].title : nil
    }

    var chapterTitleNext: String? {
        let next = book.currentChapter + 1
        return book.chapters.indices.contains(next) ? book.chapters[next].title : nil
    }

    func goNextChapter() {
        let next = book.currentChapter + 1
        guard book.chapters.indices.contains(next) else { return }
        lastJumpForward = true
        Task { @MainActor in await self.load(chapterIndex: next, targetPage: 0) }
    }

    func goPreviousChapter() {
        let prev = book.currentChapter - 1
        guard book.chapters.indices.contains(prev) else { return }
        lastJumpForward = false
        Task { @MainActor in await self.load(chapterIndex: prev, useLastPage: true) }
    }

    func jump(to chapter: Int) {
        guard book.chapters.indices.contains(chapter) else { return }
        lastJumpForward = chapter > book.currentChapter
        Task { @MainActor in await self.load(chapterIndex: chapter, targetPage: 0) }
    }

    /// 翻页进度写库节流：每次翻页都写 Store 会让 `@Published books` 变化，
    /// ReaderView 整个 body（含 3 个邻页）随之重算 → 连翻卡顿。
    private var progressTask: Task<Void, Never>?

    private func persistProgress() {
        book.currentPage = pageIndex
        let chapter = book.currentChapter
        let page = pageIndex
        let progress = overallProgress(chapter: chapter, page: page)
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store.updateProgress(bookID: self.bookID, chapter: chapter,
                                      page: page, progress: progress)
        }
    }

    /// 退出阅读/切章前立即落库（取消节流任务）。
    func commitProgress() {
        progressTask?.cancel()
        progressTask = nil
        store.updateProgress(bookID: bookID, chapter: book.currentChapter, page: pageIndex,
                             progress: overallProgress(chapter: book.currentChapter, page: pageIndex))
    }

    // MARK: - 换源

    /// 换源后：清分页缓存并重新加载当前章（书对象已由 Sheet 就地更新）。
    func reloadAfterSourceChange() {
        pageCache.removeAll()
        goToLastPage = false
        Task { @MainActor in await self.load(chapterIndex: self.book.currentChapter, targetPage: 0) }
    }

    // MARK: - 朗读定位

    /// 跳到指定章并定位到包含 snippet 的页（朗读退出时回到正在读的句子）。
    func revealPage(chapter: Int, snippet: String) {
        guard book.chapters.indices.contains(chapter), !snippet.isEmpty else { return }
        Task { @MainActor in
            if book.currentChapter != chapter || pages.count <= 1 {
                await load(chapterIndex: chapter, targetPage: 0)
            }
            guard pages.indices.contains(book.currentPage) || !pages.isEmpty else { return }
            if let idx = pages.firstIndex(where: { $0.contains(snippet) }) {
                pageIndex = idx
                persistProgress()
            } else {
                // 找不到精确页：按该段在章内的比例估算
                let full = pages.joined()
                if !full.isEmpty, let r = full.range(of: snippet) {
                    let ratio = Double(full.distance(from: full.startIndex, to: r.lowerBound)) / Double(full.count)
                    pageIndex = min(max(0, Int(ratio * Double(pages.count))), max(0, pages.count - 1))
                    persistProgress()
                }
            }
        }
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
