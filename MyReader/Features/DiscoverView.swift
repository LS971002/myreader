import SwiftUI

/// 发现页：多源并行搜索 → 书籍聚合列表（标题行操作）→ 详情页按源列表选源加入。
struct DiscoverView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var manager = SearchManager()

    @State private var keyword = ""
    @State private var addedMessage: String?
    @State private var showSourceList = false
    /// 最近一次搜索的词（区分"未搜索"与"搜完无结果"两种空态）。
    @State private var lastSearched: String?
    /// 详情页（按源列表选源加入）。
    @State private var detailGroup: GroupedResult?
    /// 导出日志文件（分享面板）。
    @State private var exportedLog: URL?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar

                if manager.running {
                    statusView
                } else if manager.groups.isEmpty {
                    if lastSearched != nil {
                        noResultState
                    } else {
                        emptyState
                    }
                } else {
                    resultList
                }
            }
            .navigationTitle("发现")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSourceList = true
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                }
            }
            .sheet(isPresented: $showSourceList) {
                BookSourceListView()
                    .environmentObject(store)
            }
            // 详情页（按源列表选源加入）
            .sheet(item: $detailGroup) { group in
                BookSourcePickerView(group: group)
                    .environmentObject(store)
            }
            .sheet(item: Binding(
                get: { exportedLog.map { ExportItem(url: $0) } },
                set: { exportedLog = $0?.url }
            )) { item in
                ShareSheet(items: [item.url])
            }
            .overlay(alignment: .bottom) {
                if let message = addedMessage {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            addedMessage = nil
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("书名或作者", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { startSearch() }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        manager.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Button(manager.running ? "取消" : "搜索") {
                if manager.running { manager.cancel() } else { startSearch() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty && !manager.running)
        }
        .padding(14)
    }

    private var statusView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在搜索 \(manager.totalSources) 个书源（已完成 \(manager.finishedSources)）…")
                .font(.footnote).foregroundStyle(.secondary)
            if !manager.groups.isEmpty {
                Text("已找到 \(manager.groups.count) 本书，先到先显示")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari").font(.system(size: 46)).foregroundStyle(.secondary)
            Text("输入书名开始搜索").font(.headline)
            Text("支持书名精确 / 模糊匹配与作者搜索\n当前启用 \(store.enabledSources.count) 个书源")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if store.enabledSources.isEmpty {
                Button("去添加书源") { showSourceList = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 搜完无结果（区别于未搜索的初始态）。
    private var noResultState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42)).foregroundStyle(.secondary)
            Text("未找到「\(lastSearched ?? "")」相关书籍")
                .font(.headline)
            Text("已响应 \(manager.totalSources - manager.failures.count)/\(manager.totalSources) 个书源\n可换个关键词，或检查书源是否可用")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !manager.failures.isEmpty {
                VStack(spacing: 4) {
                    Text("未响应的书源：")
                        .font(.caption2).foregroundStyle(.orange)
                    ForEach(manager.failures.prefix(3), id: \.self) { entry in
                        Text(entry).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            Button {
                exportedLog = AppLog.shared.exportFileURL()
            } label: {
                Label("导出诊断日志", systemImage: "doc.text.magnifyingglass")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 结果列表（书籍聚合：标题行 + 操作）

    private var resultList: some View {
        List {
            ForEach(manager.groups) { group in
                BookRow(group: group,
                        onShelf: store.books.contains {
                            $0.name == group.title && $0.author == group.author
                        },
                        onAdd: { addBest(group) },
                        onDetail: { detailGroup = group })
            }
            if !manager.failures.isEmpty {
                Section(header: Text("未响应的书源")) {
                    ForEach(manager.failures, id: \.self) { entry in
                        Text(entry).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 动作

    private func startSearch() {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastSearched = text
        manager.search(keyword: text, sources: store.enabledSources,
                       concurrency: store.settings.searchConcurrency)
    }

    /// 一键加入书架：默认第一个可用书源（权重最高）。
    private func addBest(_ group: GroupedResult) {
        guard let best = group.items.first else { return }
        addToShelf(best)
    }

    private func addToShelf(_ item: SearchResult) {
        Task {
            do {
                let book = try await BookActions.add(result: item, store: store)
                addedMessage = "已加入书架：\(book.name)（\(book.chapters.count) 章）"
                AppLog.info("SEARCH", "加入书架：\(book.name)（源:\(item.sourceName)，\(book.chapters.count)章）")
            } catch {
                addedMessage = "加入失败：\(error.localizedDescription)"
                AppLog.error("SEARCH", "加入书架失败[\(item.sourceName)]: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 书籍行（标题 + 作者 + 双操作）

struct BookRow: View {
    let group: GroupedResult
    let onShelf: Bool
    let onAdd: () -> Void
    let onDetail: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !group.author.isEmpty {
                    Text(group.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !group.latest.isEmpty {
                    Text("最新：\(group.latest)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                // 加入书架（默认第一个书源）
                Button(action: onAdd) {
                    Text(onShelf ? "已在架" : "加入书架")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(minWidth: 68)
                        .background(
                            Capsule().fill(onShelf ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(0.16))
                        )
                        .foregroundStyle(onShelf ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(onShelf)

                // 查看详情（按源列表）
                Button(action: onDetail) {
                    HStack(spacing: 3) {
                        Text("详情")
                        Text("\(group.items.count)源")
                            .font(.caption2)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(minWidth: 68)
                    .background(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 详情页（按源列表选源加入）

/// 同一本书的多源列表：展示各源链接/最新章节，选定后加入书架。
struct BookSourcePickerView: View {
    let group: GroupedResult
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var adding: String?
    @State private var message: String?

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.headline)
                        if !group.author.isEmpty {
                            Text("作者：\(group.author)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !group.intro.isEmpty {
                            Text(group.intro)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(6)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("选择书源加入书架（\(group.items.count) 个）") {
                    ForEach(group.items) { item in
                        Button {
                            add(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.sourceName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if !item.latest.isEmpty {
                                        Text(item.latest)
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if adding == item.sourceName {
                                    ProgressView()
                                } else if store.books.contains(where: {
                                    $0.sourceID == item.sourceID && $0.name == item.title
                                }) {
                                    Text("已在架")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(adding != nil)
                    }
                }

                if let message {
                    Section {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("书籍详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func add(_ item: SearchResult) {
        adding = item.sourceName
        Task {
            do {
                let book = try await BookActions.add(result: item, store: store)
                message = "已加入：\(book.name)（\(book.chapters.count) 章）"
                AppLog.info("SEARCH", "详情页加入：\(book.name)（源:\(item.sourceName)，\(book.chapters.count)章）")
            } catch {
                message = "加入失败：\(error.localizedDescription)"
                AppLog.error("SEARCH", "详情页加入失败[\(item.sourceName)]: \(error.localizedDescription)")
            }
            adding = nil
        }
    }
}
