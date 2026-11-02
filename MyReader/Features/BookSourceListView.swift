import SwiftUI
import UniformTypeIdentifiers

/// 书源列表（IBS 书源）：启用开关 / 权重 / JSON 编辑 / 导入导出。
struct BookSourceListView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var editing: IBSBookSource?
    @State private var message: String?

    var body: some View {
        NavigationView {
            List {
                if store.sources.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("还没有书源").font(.headline)
                            Text("导入 .ibs 书源文件（爱阅书香格式），\n或从「文件」App 直接打开 .ibs。")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
                ForEach(store.sources.sorted { $0.weight > $1.weight }) { source in
                    SourceRow(source: source)
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
            }
            .navigationTitle("书源（\(store.sources.count)）")
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
                        if let url = exportSources() {
                            UIReferenceFileViewControllerUtils.share(url: url, from: self)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
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
                          allowedContentTypes: [.data, .json, .item],
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .sheet(item: $editing) { source in
                BookSourceJSONEditor(source: source)
                    .environmentObject(store)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var total = 0
            var errors: [String] = []
            for url in urls {
                let ext = url.pathExtension.lowercased()
                do {
                    if ext == "ibs" {
                        total += try Importer.importIBS(from: url)
                    } else {
                        total += try Importer.importBookSources(from: url)
                    }
                } catch {
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            message = errors.isEmpty ? "已导入 \(total) 个书源"
                : "导入 \(total) 个；失败：\(errors.joined(separator: "；"))"
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func exportSources() -> URL? {
        let texts = store.sourceRecords.map(\.rawJSON)
        guard !texts.isEmpty else { return nil }
        let json = "[" + texts.joined(separator: ",\n") + "]"
        let file = Paths.root.appendingPathComponent("书源导出.json")
        try? json.data(using: .utf8)?.write(to: file)
        return file
    }
}

// MARK: - 单行

struct SourceRow: View {
    @EnvironmentObject private var store: Store
    let source: IBSBookSource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(source.name.isEmpty ? "未命名书源" : source.name)
                    .font(.subheadline)
                if !source.group.isEmpty && source.group != "默认" {
                    Text(source.group)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { source.enabled },
                    set: { store.setSourceEnabled(source, enabled: $0) }
                ))
                .labelsHidden()
            }
            HStack(spacing: 8) {
                Text(source.homeURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("权重 \(source.weight)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                capability("搜索", source.searchBook != nil)
                capability("详情", source.bookDetail != nil && !(source.bookDetail?.url?.first ?? "").isEmpty)
                capability("目录", source.sourceDetail != nil)
                capability("正文", source.chapterDetail != nil)
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }

    private func capability(_ name: String, _ has: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: has ? "checkmark.circle.fill" : "minus.circle")
                .font(.caption2)
            Text(name)
        }
        .foregroundStyle(has ? Color.green.opacity(0.7) : Color.secondary.opacity(0.5))
    }
}

// MARK: - JSON 编辑器

struct BookSourceJSONEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let source: IBSBookSource
    @State private var jsonText = ""
    @State private var name = ""
    @State private var homeURL = ""
    @State private var enabled = true
    @State private var parseError: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Form {
                    Section("基本信息") {
                        TextField("书源名", text: $name)
                        TextField("主页（homeUrl）", text: $homeURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("启用", isOn: $enabled)
                    }
                }
                .frame(height: 190)

                if let parseError {
                    Text(parseError)
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal).padding(.top, 6)
                }

                TextEditor(text: $jsonText)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(alignment: .topLeading) {
                        if jsonText.isEmpty {
                            Text("书源 JSON（解密后的 BookFixConfig 格式）")
                                .font(.caption).foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 6)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .navigationTitle("编辑书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            jsonText = formatJSON(source.rawJSON)
            name = source.name
            homeURL = source.homeURL
            enabled = source.enabled
        }
    }

    private func save() {
        // 校验 JSON 与必填字段
        guard let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            parseError = "JSON 格式无效"
            return
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            parseError = "书源名不能为空"
            return
        }
        var updated = object
        updated["name"] = name.trimmingCharacters(in: .whitespaces)
        updated["homeUrl"] = homeURL.trimmingCharacters(in: .whitespaces)
        updated["enable"] = enabled

        guard let newData = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]),
              let newJSON = String(data: newData, encoding: .utf8),
              var newSource = IBSBookSource.parse(rawJSON: newJSON, id: source.id,
                                                  group: source.group, enabled: enabled) else {
            parseError = "保存失败：书源结构无效"
            return
        }
        newSource.id = source.id
        store.upsertSources([newSource])
        dismiss()
    }

    private func formatJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys]) else {
            return raw
        }
        return String(data: pretty, encoding: .utf8) ?? raw
    }
}

// MARK: - 分享工具

enum UIReferenceFileViewControllerUtils {
    static func share(url: URL, from view: BookSourceListView) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        if let window = scenes.first, let root = window.rootViewController {
            var top = root
            while let presented = top.presentedViewController { top = presented }
            activityVC.popoverPresentationController?.sourceView = top.view
            top.present(activityVC, animated: true)
        }
    }
}
