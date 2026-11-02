import Foundation

/// 批量缓存管理器（复刻爱阅 DownChapterManager）：
/// 整本 / 章节区间 / 仅补未缓存，多线程并发下载 + 实时进度 + 取消。
@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()

    @Published private(set) var progress: [UUID: CacheProgress] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - 缓存书籍

    /// - Parameters:
    ///   - book: 书籍（含章节列表与书源引用）
    ///   - range: 章节区间（nil = 全部）
    ///   - onlyMissing: 只补未缓存章节
    ///   - store: 数据仓库（取书源 / 回写 cached 标记）
    func cacheBook(_ book: Book, range: ClosedRange<Int>? = nil,
                   onlyMissing: Bool = true, store: Store) {
        guard book.origin == .online, let sourceID = book.sourceID,
              let record = store.sourceRecords.first(where: { $0.id == sourceID }),
              let source = record.resolve() else { return }
        guard tasks[book.id] == nil else { return }

        let chapters = book.chapters
        let scope: [Chapter]
        if let range {
            scope = chapters.filter { range.contains($0.index) }
        } else {
            scope = chapters
        }
        let targets = onlyMissing ? scope.filter { !$0.cached } : scope
        guard !targets.isEmpty else { return }

        let state = CacheProgress(bookID: book.id, total: targets.count, running: true)
        progress[book.id] = state

        let bookID = book.id
        let engine = IBSEngine(source: source)

        tasks[book.id] = Task { [weak self] in
            var finished = 0
            var failed = 0
            let concurrency = 4
            let queue = targets

            await withTaskGroup(of: Bool.self) { group in
                var iterator = queue.makeIterator()
                let window = min(concurrency, queue.count)

                func addNext() {
                    guard !Task.isCancelled else { return }
                    if let chapter = iterator.next() {
                        group.addTask {
                            do {
                                try Task.checkCancellation()
                                if let cached = Paths.readChapter(bookID: bookID, index: chapter.index),
                                   !cached.isEmpty {
                                    return true
                                }
                                let text = try await engine.content(chapter: chapter)
                                guard !text.isEmpty else { return false }
                                Paths.writeChapter(text, bookID: bookID, index: chapter.index)
                                return true
                            } catch is CancellationError {
                                return true
                            } catch {
                                return false
                            }
                        }
                    }
                }

                for _ in 0..<window { addNext() }
                for await ok in group {
                    if Task.isCancelled { break }
                    if ok { finished += 1 } else { failed += 1 }
                    await MainActor.run {
                        guard let self else { return }
                        if var p = self.progress[bookID] {
                            p.finished = finished
                            p.failed = failed
                            self.progress[bookID] = p
                        }
                    }
                    addNext()
                }
            }

            await MainActor.run {
                guard let self else { return }
                if var p = self.progress[bookID] {
                    p.running = false
                    p.cancelled = Task.isCancelled
                    p.finished = finished
                    p.failed = failed
                    self.progress[bookID] = p
                }
                self.tasks[bookID] = nil
                // 回写 cached 标记
                if var latest = store.book(id: bookID) {
                    for index in latest.chapters.indices {
                        if Paths.readChapter(bookID: bookID, index: latest.chapters[index].index) != nil {
                            latest.chapters[index].cached = true
                        }
                    }
                    store.updateBook(latest)
                }
            }
        }
    }

    func cancel(bookID: UUID) {
        tasks[bookID]?.cancel()
        tasks[bookID] = nil
        if var p = progress[bookID] {
            p.running = false
            p.cancelled = true
            progress[bookID] = p
        }
    }

    func clearProgress(bookID: UUID) {
        progress.removeValue(forKey: bookID)
    }

    // MARK: - 统计

    /// 某书缓存统计（章节数 + 字节数）。
    nonisolated static func cacheStat(bookID: UUID, chapterCount: Int) -> CacheStat {
        let dir = Paths.chapterDir.appendingPathComponent(bookID.uuidString, isDirectory: true)
        var bytes = 0
        var files = 0
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += size
                    files += 1
                }
            }
        }
        return CacheStat(bookID: bookID, chapterCount: files, bytes: bytes)
    }

    /// 全部缓存字节数。
    nonisolated static func totalCacheBytes() -> Int {
        let dir = Paths.chapterDir
        var bytes = 0
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += size
                }
            }
        }
        return bytes
    }
}
