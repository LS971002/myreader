import SwiftUI

/// 批量缓存面板：整本 / 章节区间 / 仅补未缓存，并发下载 + 实时进度。
struct CacheSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cache = CacheManager.shared

    let book: Book

    @State private var stat = CacheStat(bookID: UUID(), chapterCount: 0, bytes: 0)
    @State private var useRange = false
    @State private var rangeStart = 0
    @State private var rangeEnd = 0
    @State private var onlyMissing = true

    private var progress: CacheProgress? { cache.progress[book.id] }
    private var chapterCount: Int { book.chapters.count }

    var body: some View {
        NavigationView {
            List {
                // 统计
                Section("缓存状态") {
                    HStack {
                        Text("已缓存章节")
                        Spacer()
                        Text("\(stat.chapterCount) / \(chapterCount)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("缓存大小")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(stat.bytes), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        Paths.removeChapters(bookID: book.id)
                        refreshStat()
                        var updated = book
                        for index in updated.chapters.indices {
                            updated.chapters[index].cached = false
                        }
                        store.updateBook(updated)
                    } label: {
                        Text("清空本书缓存")
                    }
                }

                // 下载选项
                if book.origin == .online && chapterCount > 0 {
                    Section("批量缓存") {
                        Toggle("自定义章节区间", isOn: $useRange)
                        if useRange {
                            Picker("起始章", selection: $rangeStart) {
                                ForEach(0..<chapterCount, id: \.self) { i in
                                    Text(chapterLabel(i)).tag(i)
                                }
                            }
                            Picker("结束章", selection: $rangeEnd) {
                                ForEach(0..<chapterCount, id: \.self) { i in
                                    Text(chapterLabel(i)).tag(i)
                                }
                            }
                            .onChange(of: rangeStart) { newValue in
                                if rangeEnd < newValue { rangeEnd = newValue }
                            }
                        }
                        Toggle("仅补未缓存章节", isOn: $onlyMissing)
                    }

                    // 进度
                    if let p = progress {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(p.running ? "正在缓存…" : (p.cancelled ? "已取消" : "缓存完成"))
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(p.finished + p.failed) / \(p.total)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: p.fraction)
                                if p.failed > 0 {
                                    Text("失败 \(p.failed) 章（可稍后重试）")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // 动作
                    Section {
                        if progress?.running == true {
                            Button(role: .destructive) {
                                cache.cancel(bookID: book.id)
                            } label: {
                                Label("停止缓存", systemImage: "stop.circle")
                            }
                        } else {
                            Button {
                                startCache()
                            } label: {
                                Label(cacheRangeTitle, systemImage: "arrow.down.circle")
                            }
                        }
                    }
                } else {
                    Section {
                        Text("本地书籍无需缓存").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("缓存管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        cache.cancel(bookID: book.id)
                        dismiss()
                    }
                }
            }
            .onAppear {
                rangeStart = 0
                rangeEnd = max(0, chapterCount - 1)
                refreshStat()
            }
            .onChange(of: progress?.running) { running in
                if running == false { refreshStat() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var cacheRangeTitle: String {
        if useRange {
            return "缓存第 \(rangeStart + 1) ~ \(rangeEnd + 1) 章"
        }
        return onlyMissing ? "补全未缓存章节" : "缓存整本书"
    }

    private func chapterLabel(_ index: Int) -> String {
        let title = book.chapters.indices.contains(index) ? book.chapters[index].title : ""
        let trimmed = title.count > 18 ? String(title.prefix(18)) + "…" : title
        return "第\(index + 1)章 \(trimmed)"
    }

    private func startCache() {
        let range = useRange ? rangeStart...rangeEnd : nil
        if let range, rangeStart > rangeEnd { return }
        var target = book
        // 只补未缓存时把 cached 状态先同步一遍
        if onlyMissing {
            for index in target.chapters.indices {
                target.chapters[index].cached =
                    Paths.readChapter(bookID: book.id, index: target.chapters[index].index) != nil
            }
        }
        cache.cacheBook(target, range: range, onlyMissing: onlyMissing, store: store)
    }

    private func refreshStat() {
        stat = CacheManager.cacheStat(bookID: book.id, chapterCount: chapterCount)
    }
}
