import SwiftUI

/// 换源：列出全部启用书源（排除当前源），选定后重拉目录并保持阅读进度。
struct SourceSwitchSheet: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var switching: UUID?
    @State private var message: String?

    private var availableSources: [IBSBookSource] {
        store.enabledSources.filter { $0.id != model.book.sourceID }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.book.name).font(.headline)
                        Text("当前源：\(model.book.sourceName.isEmpty ? "无" : model.book.sourceName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("切换到其他书源（重新解析目录与正文）") {
                    if availableSources.isEmpty {
                        Text("没有其他可用书源，请先在书源管理中导入")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(availableSources) { source in
                        Button {
                            switchSource(source)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(source.homeURL)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if switching == source.id {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(switching != nil)
                    }
                }
                if let message {
                    Section {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func switchSource(_ source: IBSBookSource) {
        switching = source.id
        Task {
            do {
                let updated = try await BookActions.changeSource(
                    book: model.book, to: source, store: store)
                // 就地更新阅读模型（保持阅读器打开）
                model.book = updated
                model.reloadAfterSourceChange()
                message = "已切换到「\(source.name)」，共 \(updated.chapters.count) 章"
                dismissAfterDelay()
            } catch {
                message = "换源失败：\(error.localizedDescription)"
                switching = nil
            }
        }
    }

    private func dismissAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        }
    }
}
