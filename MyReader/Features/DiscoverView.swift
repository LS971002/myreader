import SwiftUI

/// 发现页：多书源并行搜索（先到先显示）→ 跨源聚合 → 选源加入书架。
struct DiscoverView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var manager = SearchManager()

    @State private var keyword = ""
    @State private var addedMessage: String?
    @State private var showSourceList = false
    @State private var expandedGroup: UUID?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar

                if manager.running {
                    statusView
                } else if manager.groups.isEmpty {
                    emptyState
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
            } else if !manager.failures.isEmpty {
                Text("未响应：\(manager.failures.joined(separator: "、"))")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 结果列表（跨源聚合）

    private var resultList: some View {
        List {
            ForEach(manager.groups) { group in
                Section {
                    GroupedResultRow(group: group, expanded: expandedGroup == group.id) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedGroup = (expandedGroup == group.id) ? nil : group.id
                        }
                    }
                    if expandedGroup == group.id {
                        ForEach(group.items) { item in
                            Button {
                                add(item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.sourceName)
                                            .font(.subheadline)
                                        if !item.intro.isEmpty {
                                            Text(item.intro)
                                                .font(.caption2).foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Text(addLabel(for: item))
                                        .font(.caption).foregroundStyle(.tint)
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.tint)
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !manager.failures.isEmpty {
                Section(header: Text("未响应的书源")) {
                    Text(manager.failures.joined(separator: "、"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }

    private func addLabel(for item: SearchResult) -> String {
        if store.books.contains(where: {
            $0.sourceID == item.sourceID && $0.name == item.title
        }) {
            return "已加书架"
        }
        return "加入书架"
    }

    // MARK: - 动作

    private func startSearch() {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        expandedGroup = nil
        manager.search(keyword: text, sources: store.enabledSources,
                       concurrency: store.settings.searchConcurrency)
    }

    private func add(_ item: SearchResult) {
        Task {
            do {
                let book = try await BookActions.add(result: item, store: store)
                addedMessage = "已加入书架：\(book.name)（\(book.chapters.count) 章）"
            } catch {
                addedMessage = "加入失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 聚合结果行

struct GroupedResultRow: View {
    let group: GroupedResult
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if !group.author.isEmpty {
                            Text(group.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(group.items.count) 个源")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !group.latest.isEmpty {
                        Text("最新：\(group.latest)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !group.intro.isEmpty && !expanded {
                        Text(group.intro)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
