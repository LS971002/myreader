import Foundation

/// 多源并行搜索管理器（复刻爱阅 BookSearchManager）：
/// - 多书源 TaskGroup 并行（并发数可配）
/// - 先到先显示（实时刷新）
/// - 书名 / 作者 精确 + 模糊匹配分类
/// - 跨源同名同作者聚合
@MainActor
final class SearchManager: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var groups: [GroupedResult] = []
    @Published private(set) var failures: [String] = []
    @Published private(set) var finishedSources = 0
    @Published private(set) var totalSources = 0

    private var searchTask: Task<Void, Never>?

    var keyword: String = ""

    // MARK: - 搜索

    func search(keyword: String, sources: [IBSBookSource], concurrency: Int = 6) {
        cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sources.isEmpty else { return }
        self.keyword = trimmed

        running = true
        groups = []
        failures = []
        finishedSources = 0
        totalSources = sources.count

        searchTask = Task { [weak self] in
            var collected: [SearchResult] = []
            var failed: [String] = []
            let sourceList = sources.sorted { $0.weight > $1.weight }

            await withTaskGroup(of: (String, [SearchResult]?)?.self) { group in
                var iterator = sourceList.makeIterator()
                let window = min(max(concurrency, 1), sourceList.count)

                func addNext() {
                    guard !Task.isCancelled else { return }
                    if let source = iterator.next() {
                        let name = source.name
                        group.addTask {
                            do {
                                try Task.checkCancellation()
                                let engine = IBSEngine(source: source)
                                let results = try await engine.search(keyword: trimmed)
                                return (name, results)
                            } catch is CancellationError {
                                return nil
                            } catch {
                                return (name, nil)
                            }
                        }
                    }
                }

                for _ in 0..<window { addNext() }
                for await result in group {
                    if Task.isCancelled { break }
                    if let (name, list) = result {
                        if let list {
                            collected.append(contentsOf: list)
                            await MainActor.run {
                                guard let self else { return }
                                self.merge(list)
                            }
                        } else {
                            failed.append(name)
                            await MainActor.run {
                                guard let self else { return }
                                self.failures.append(name)
                            }
                        }
                        await MainActor.run {
                            guard let self else { return }
                            self.finishedSources += 1
                        }
                    }
                    addNext()
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.running = false
                _ = collected
                _ = failed
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        running = false
    }

    // MARK: - 聚合

    /// 新结果合并进分组列表（同名同作者归并）。
    private func merge(_ results: [SearchResult]) {
        for item in results {
            let key = normalize(item.title) + "|" + normalize(item.author)
            if let index = groups.firstIndex(where: {
                normalize($0.title) + "|" + normalize($0.author) == key
            }) {
                // 同源去重
                if !groups[index].items.contains(where: { $0.sourceID == item.sourceID && $0.link == item.link }) {
                    groups[index].items.append(item)
                    groups[index].items.sort { $0.sourceName < $1.sourceName }
                }
                if groups[index].intro.isEmpty { groups[index].intro = item.intro }
                if groups[index].cover.isEmpty { groups[index].cover = item.cover }
                if groups[index].latest.isEmpty { groups[index].latest = item.latest }
            } else {
                if let group = GroupedResult(items: [item]) {
                    groups.append(group)
                }
            }
        }
        resort()
    }

    private func resort() {
        groups.sort { a, b in
            let aRank = a.items.map { $0.matchKind.rawValue }.min() ?? 3
            let bRank = b.items.map { $0.matchKind.rawValue }.min() ?? 3
            if aRank != bRank { return aRank < bRank }
            if a.items.count != b.items.count { return a.items.count > b.items.count }
            return a.title < b.title
        }
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
    }
}
