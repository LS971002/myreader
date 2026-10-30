import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var store: Store

    @State private var keyword = ""
    @State private var searching = false
    @State private var results: [SearchResult] = []
    @State private var failures: [String] = []
    @State private var addedMessage: String?
    @State private var showSourceList = false

    private struct SourceSection: Identifiable {
        let id: String
        let source: String
        let items: [SearchResult]
    }

    private var grouped: [SourceSection] {
        let dict = Dictionary(grouping: results, by: { $0.sourceName })
        return dict.map { SourceSection(id: $0.key, source: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar

                if searching {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索 \(store.enabledSources.count) 个书源…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(grouped) { section in
                            Section(header: Text("\(section.source) · \(section.items.count) 条")) {
                                ForEach(section.items) { item in
                                    Button {
                                        add(item)
                                    } label: {
                                        ResultRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !failures.isEmpty {
                            Section(header: Text("未响应的书源")) {
                                Text(failures.joined(separator: "、"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
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

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("书名或作者", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { search() }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Button("搜索") { search() }
                .buttonStyle(.borderedProminent)
                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || searching)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari").font(.system(size: 46)).foregroundStyle(.secondary)
            Text("输入书名开始搜索").font(.headline)
            Text("当前启用 \(store.enabledSources.count) 个书源")
                .font(.footnote).foregroundStyle(.secondary)
            if store.enabledSources.isEmpty {
                Button("去添加书源") { showSourceList = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 搜索

    private func search() {
        let text = keyword.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        results = []
        failures = []

        Task {
            let sources = store.enabledSources
            await withTaskGroup(of: (String, [SearchResult]?).self) { group in
                for source in sources {
                    group.addTask {
                        do {
                            let list = try await BookSourceEngine(source).search(text)
                            return (source.name, list)
                        } catch {
                            return (source.name, nil)
                        }
                    }
                }
                for await (name, list) in group {
                    if let list {
                        await MainActor.run {
                            // 实时刷新，先到的先显示
                            let existingIDs = Set(results.map(\.id))
                            results.append(contentsOf: list.filter { !existingIDs.contains($0.id) })
                            results.sort { $0.title < $1.title }
                        }
                    } else {
                        await MainActor.run { failures.append(name) }
                    }
                }
            }
            await MainActor.run { searching = false }
        }
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

struct ResultRow: View {
    let item: SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline).lineLimit(1)
                Text(item.author.isEmpty ? "佚名" : item.author)
                    .font(.caption2).foregroundStyle(.secondary)
                if !item.latest.isEmpty {
                    Text("最新：\(item.latest)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "plus.circle")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
