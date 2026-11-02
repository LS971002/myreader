import SwiftUI
import UIKit

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showMenu = false
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var showTTS = false
    @State private var dragOffset: CGFloat = 0
    @State private var isTurning = false            // 翻页动画进行中（防重入）

    init(book: Book, store: Store) {
        _model = StateObject(wrappedValue: ReaderModel(store: store, book: book))
    }

    private var settings: AppSettings { store.settings }

    var body: some View {
        GeometryReader { geo in
            let horizontal: CGFloat = 20
            let bottomInset: CGFloat = settings.showBatteryAndTime ? 34 : 24
            let contentSize = CGSize(
                width: geo.size.width - horizontal * 2,
                height: geo.size.height - bottomInset - 30
            )
            let pageWidth = geo.size.width

            ZStack {
                theme.current.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    pageContent(width: pageWidth)
                        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
                        .clipped()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontal)
                .padding(.bottom, bottomInset)
                .padding(.top, 8)

                if settings.showBatteryAndTime {
                    statusBar
                }

                if model.loading {
                    ProgressView()
                        .tint(theme.current.text)
                }

                if let message = model.errorMessage, !model.loading {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 30)
                }

                if showMenu {
                    menuOverlay
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard settings.pageTurn != .scroll, !isTurning else { return }
                        dragOffset = max(-width, min(width, value.translation.width))
                    }
                    .onEnded { value in
                        guard settings.pageTurn != .scroll, !isTurning else { return }
                        let dx = dragOffset
                        if abs(dx) < 12, abs(value.translation.height) < 12 {
                            handleTap(x: value.location.x, width: geo.size.width)
                            dragOffset = 0
                            return
                        }
                        // 速度加成：快速轻扫也翻页
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        let shouldTurn = dx < -pageWidth * 0.32 || velocity < -pageWidth * 0.6
                        let shouldBack = dx > pageWidth * 0.32 || velocity > pageWidth * 0.6
                        if shouldTurn {
                            finishTurn(forward: true, width: pageWidth)
                        } else if shouldBack {
                            finishTurn(forward: false, width: pageWidth)
                        } else {
                            // 回弹
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .onAppear {
                model.updateLayout(size: contentSize)
                model.onAppear()
            }
            .onChange(of: geo.size) { _ in
                model.updateLayout(size: contentSize)
            }
            .onChange(of: settings.fontSize) { _ in model.reloadPagination() }
            .onChange(of: settings.lineSpacing) { _ in model.reloadPagination() }
            .onChange(of: settings.fontName) { _ in model.reloadPagination() }
            .statusBar(hidden: !settings.showStatusBar && settings.fullScreen)
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(model: model)
                .environmentObject(store)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsPanel(model: model)
                .environmentObject(store)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showTTS) {
            TTSBar(model: model)
                .environmentObject(store)
                .environmentObject(theme)
        }
    }

    // MARK: - 正文（双邻页跟手）

    @ViewBuilder
    private func pageContent(width: CGFloat) -> some View {
        if settings.pageTurn == .scroll {
            ScrollView(.vertical, showsIndicators: false) {
                PageCanvas(text: model.pages.joined(separator: "\n"),
                           settings: settings,
                           theme: theme.current)
                    .frame(width: nil)
            }
        } else {
            ZStack(alignment: .topLeading) {
                // 左邻页（章内上一页 / 上一章末页）
                neighborPage(edge: .leading, width: width)

                // 右邻页（章内下一页 / 下一章首页）
                neighborPage(edge: .trailing, width: width)

                // 当前页
                PageCanvas(text: currentPageText,
                           settings: settings,
                           theme: theme.current)
                    .offset(x: dragOffset)
                    .id(model.book.currentChapter * 100_000 + model.pageIndex)
                    .transition(.opacity)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func neighborPage(edge: Edge, width: CGFloat) -> some View {
        let isLeading = edge == .leading
        let offsetBase: CGFloat = isLeading ? -width : width

        if isLeading {
            if let text = model.neighborPrev {
                PageCanvas(text: text, settings: settings, theme: theme.current)
                    .offset(x: offsetBase + dragOffset)
            } else if let chapter = model.neighborChapterPrev {
                PageCanvas(text: chapter.text, settings: settings, theme: theme.current)
                    .overlay(alignment: .top) {
                        chapterHint("上一章 · \(chapter.title)")
                    }
                    .offset(x: offsetBase + dragOffset)
            } else if let title = model.chapterTitlePrev {
                chapterPlaceholder("上一章", title: title)
                    .offset(x: offsetBase + dragOffset)
            }
        } else {
            if let text = model.neighborNext {
                PageCanvas(text: text, settings: settings, theme: theme.current)
                    .offset(x: offsetBase + dragOffset)
            } else if let chapter = model.neighborChapterNext {
                PageCanvas(text: chapter.text, settings: settings, theme: theme.current)
                    .overlay(alignment: .top) {
                        chapterHint("下一章 · \(chapter.title)")
                    }
                    .offset(x: offsetBase + dragOffset)
            } else if let title = model.chapterTitleNext {
                chapterPlaceholder("下一章", title: title)
                    .offset(x: offsetBase + dragOffset)
            }
        }
    }

    private var currentPageText: String {
        model.pages.indices.contains(model.pageIndex) ? model.pages[model.pageIndex] : ""
    }

    private func chapterHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.current.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.current.background.opacity(0.9), in: Capsule())
            .padding(.top, -26)
    }

    private func chapterPlaceholder(_ label: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: label == "上一章" ? "chevron.up" : "chevron.down")
                .font(.title2)
                .foregroundStyle(theme.current.secondary)
            Text("\(label)：\(title)")
                .font(.subheadline)
                .foregroundStyle(theme.current.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("松手进入")
                .font(.caption2)
                .foregroundStyle(theme.current.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 翻页动画

    /// 拖拽已越界 → 动画滑完 → 提交翻页 → 新页从对侧滑入。
    private func finishTurn(forward: Bool, width: CGFloat) {
        guard !isTurning else { return }
        isTurning = true
        let target: CGFloat = forward ? -width : width

        // 章末/章首越界：翻的是章节（异步加载，不做两段滑入避免旧内容闪回）
        let crossForward = forward && model.neighborNext == nil
        let crossBack = !forward && model.neighborPrev == nil

        withAnimation(.spring(response: 0.30, dampingFraction: 1.0)) {
            dragOffset = target
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if crossForward {
                model.goNextChapter()
                dragOffset = 0
            } else if crossBack {
                model.goPreviousChapter()
                dragOffset = 0
            } else {
                if forward { model.nextPage() } else { model.prevPage() }
                // 瞬移到对侧（无动画），新页滑入
                dragOffset = forward ? width : -width
                withAnimation(.spring(response: 0.30, dampingFraction: 1.0)) {
                    dragOffset = 0
                }
                try? await Task.sleep(nanoseconds: 320_000_000)
            }
            isTurning = false
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        VStack {
            HStack {
                Text(model.currentChapterTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
                Text(model.progressText)
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.current.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            Spacer()
            HStack {
                Text("第 \(model.book.currentChapter + 1)/\(model.book.chapters.count) 章")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.current.secondary)
                Spacer()
                BatteryView(color: theme.current.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    // MARK: - 菜单

    private var menuOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    store.flush()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(model.book.name).font(.subheadline).lineLimit(1)
                    Text(model.currentChapterTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    showCatalog = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            Spacer()

            HStack(spacing: 0) {
                menuButton("上一章", "chevron.up") { model.goPreviousChapter() }
                menuButton("目录", "list.triangle") { showCatalog = true }
                menuButton("朗读", "waveform") { showTTS = true }
                menuButton("设置", "textformat.size") { showSettings = true }
                menuButton("下一章", "chevron.down") { model.goNextChapter() }
            }
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .foregroundStyle(Color.primary)
        .ignoresSafeArea(edges: .bottom)
    }

    private func menuButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 点击

    private func handleTap(x: CGFloat, width: CGFloat) {
        if showMenu {
            withAnimation { showMenu = false }
            return
        }
        guard settings.tapToTurn else {
            withAnimation { showMenu = true }
            return
        }
        let third = width / 3
        if x < third {
            finishTurn(forward: false, width: width)
        } else if x > width - third {
            finishTurn(forward: true, width: width)
        } else {
            withAnimation { showMenu = true }
        }
    }
}

/// 用 UILabel 渲染一页，保证与 CoreText 分页的行宽一致。
struct PageCanvas: UIViewRepresentable {
    let text: String
    let settings: AppSettings
    let theme: ReaderTheme

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = Typography.attributed(
            text,
            settings: settings,
            color: UIColor(theme.text),
            title: nil
        )
    }
}

struct BatteryView: View {
    let color: Color
    @State private var level: Float = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(timeString).font(.system(size: 11))
            Text("\(Int(level * 100))%").font(.system(size: 11))
        }
        .foregroundStyle(color)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = abs(UIDevice.current.batteryLevel)
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}
