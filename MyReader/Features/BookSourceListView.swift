import SwiftUI
import UniformTypeIdentifiers

struct BookSourceListView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var editing: BookSource?
    @State private var newSource = false
    @State private var message: String?

    var body: some View {
        NavigationView {
            List {
                ForEach($store.sources) { $source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(source.name.isEmpty ? "未命名书源" : source.name)
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $source.enabled)
                                .labelsHidden()
                                .onChange(of: source.enabled) { _ in store.save() }
                        }
                        Text(source.baseURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = source }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.removeSource(source)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        store.removeSource(store.sources[index])
                    }
                }
            }
            .navigationTitle("书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Button {
                        editing = BookSource(name: "新建书源")
                        newSource = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json, .item],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        let count = try Importer.importBookSources(from: url)
                        message = "已导入 \(count) 个书源"
                    } catch {
                        message = "导入失败：\(error.localizedDescription)"
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .sheet(item: $editing) { source in
                BookSourceEditor(source: source, isNew: newSource)
                    .environmentObject(store)
                    .onDisappear { newSource = false }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct BookSourceEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BookSource
    let isNew: Bool

    init(source: BookSource, isNew: Bool) {
        _draft = State(initialValue: source)
        self.isNew = isNew
    }

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    field("名称", text: $draft.name)
                    field("域名（如 https://www.example.com）", text: $draft.baseURL)
                    field("编码（utf-8 / gbk）", text: $draft.charset)
                    Stepper("权重 \(draft.weight)", value: $draft.weight, in: 1...999, step: 10)
                }

                Section {
                    field("搜索地址", text: $draft.searchURL, prompt: "/search?q={{key}}&page={{page}}")
                    field("结果列表", text: $draft.searchList, prompt: ".result-list li")
                    field("书名", text: $draft.searchTitle)
                    field("详情链接", text: $draft.searchLink, prompt: "a@href@abs")
                    field("作者", text: $draft.searchAuthor)
                    field("封面", text: $draft.searchCover)
                    field("简介", text: $draft.searchIntro)
                    field("最新章节", text: $draft.searchLatest)
                } header: {
                    Text("搜索规则")
                } footer: {
                    Text("规则语法：CSS 选择器 + @动作，例如 `div.book h3 a@text`、`div.list a@href@abs`、`#intro@html2text`。也支持 `//div[@class=\"x\"]/a/text()` 形式的 XPath。")
                        .font(.caption2)
                }

                Section("详情 / 目录") {
                    field("简介规则", text: $draft.introRule)
                    field("封面规则", text: $draft.coverRule)
                    field("目录页地址（留空表示目录在详情页）", text: $draft.dirURL)
                    field("章节列表", text: $draft.dirList, prompt: "#list dd")
                    field("章节名", text: $draft.dirTitle, prompt: "a@text")
                    field("章节链接", text: $draft.dirLink, prompt: "a@href@abs")
                    field("目录下一页", text: $draft.dirNext)
                }

                Section("正文") {
                    field("正文规则", text: $draft.contentRule, prompt: "#content@html2text")
                    field("正文下一页", text: $draft.contentNext)
                }

                Section {
                    Button(role: .destructive) {
                        if !isNew { store.removeSource(draft) }
                        dismiss()
                    } label: {
                        Text(isNew ? "取消" : "删除这个书源")
                    }
                }
            }
            .navigationTitle(isNew ? "新建书源" : "编辑书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        store.upsertSources([draft])
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, design: .monospaced))
        }
    }
}
