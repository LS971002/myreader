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
    @State private var showSourceSwitch = false
    @State private var dragOffset: CGFloat = 0
    @State private var isTurning = false            // 翻页动画进行中（防重入）
    @State private var zombieGesture = false        // 动画期间开始的手势会话 → 整段作废
    /// 翻页完成后的短冷却截止时刻：一次物理滑动被SwiftUI拆成两个手势会话时，
    /// 第二会话在此期间开始 → zombie 屏蔽（防连翻两页）。
    @State private var cooldownUntil = Date.distantPast
    /// 文本选择模式：开启后暂停翻页手势，正文换成可长按选字的 UITextView。
    @State private var selecting = false
    @State private var toast: String?

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
                        // 菜单出现时正文缩放居中：完整可见，不被上下菜单遮挡
                        .scaleEffect(menuScale(geo: geo), anchor: .center)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontal)
                .padding(.bottom, bottomInset)
                .padding(.top, 8)

                if settings.showBatteryAndTime && !selecting {
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

                if selecting {
                    selectionBar
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.footnote)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 90)
                            .transition(.opacity)
                    }
                    .allowsHitTesting(false)
                }

                if showMenu && !selecting {
                    menuOverlay
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard settings.pageTurn != .scroll else { return }
                        // 动画期间/冷却期内开始的手势会话：整段作废（防拆会话双翻）
                        if isTurning || Date() < cooldownUntil {
                            zombieGesture = true
                            return
                        }
                        dragOffset = max(-pageWidth, min(pageWidth, value.translation.width))
                    }
                    .onEnded { value in
                        guard settings.pageTurn != .scroll else { return }
                        if zombieGesture {
                            zombieGesture = false
                            return
                        }
                        guard !isTurning else { return }
                        // 用本会话自身位移判定（不用 dragOffset 残留）
                        let dx = value.translation.width
                        if abs(dx) < 12, abs(value.translation.height) < 12 {
                            handleTap(x: value.location.x, width: geo.size.width)
                            dragOffset = 0
                            return
                        }
                        dragOffset = max(-pageWidth, min(pageWidth, dx))
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
                    },
                // 选择模式下整体禁用翻页手势，把触摸让给 UITextView 的选字/菜单
                including: selecting ? .none : .all
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
        .sheet(isPresented: $showSourceSwitch) {
            SourceSwitchSheet(model: model)
                .environmentObject(store)
        }
    }

    // MARK: - 正文（双邻页跟手）

    @ViewBuilder
    private func pageContent(width: CGFloat) -> some View {
        if selecting {
            // 选择模式：正文渲染为可选 UITextView（长按/双击选字，系统菜单可拷贝）。
            // 上下滚动模式下给整章文本并允许滚动，分页模式只给当前页。
            let scrollMode = settings.pageTurn == .scroll
            SelectablePageCanvas(
                text: scrollMode ? model.pages.joined(separator: "\n") : currentPageText,
                settings: settings,
                theme: theme.current,
                scrollable: scrollMode
            )
        } else if settings.pageTurn == .scroll {
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

                // 当前页：拖拽/点击翻页统一走 offset 跟手动画。
                // 不再用 `.id()` + move transition —— 那会在每次翻页销毁并重建
                // UILabel，连翻时每页都要重新排版 + 重建视图，是卡顿主因。
                PageCanvas(text: currentPageText,
                           settings: settings,
                           theme: theme.current)
                    .offset(x: dragOffset)
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

    /// 菜单可见时的正文缩放比例（让出上下菜单区，内容完整可见）。
    private func menuScale(geo: GeometryProxy) -> CGFloat {
        guard showMenu else { return 1 }
        let menuTop: CGFloat = 56      // 顶部菜单条
        let menuBottom: CGFloat = 86   // 底部按钮条
        let available = geo.size.height - menuTop - menuBottom
        return max(0.5, min(1, available / geo.size.height))
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

    /// 翻页完成（拖拽松手 / 点击）：邻页已跟手滑入 → 提交翻页 → 归零，无缝停留。
    private func finishTurn(forward: Bool, width: CGFloat) {
        guard !isTurning else { return }
        isTurning = true
        let target: CGFloat = forward ? -width : width

        // 章末/章首越界：翻的是章节
        let crossForward = forward && model.neighborNext == nil
        let crossBack = !forward && model.neighborPrev == nil

        // 0.22s：比原先 0.30s 更快，连翻时手感更跟手
        withAnimation(.spring(response: 0.22, dampingFraction: 1.0)) {
            dragOffset = target
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            // 切页与归零放在同一帧、且禁用动画：避免中间出现一帧「页面已滑出但新页未就位」的空白
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if crossForward {
                    model.goNextChapter()
                } else if crossBack {
                    model.goPreviousChapter()
                } else {
                    if forward { model.nextPage() } else { model.prevPage() }
                }
                dragOffset = 0
            }
            isTurning = false
            // 冷却期：吸收同一次物理滑动的残余手势会话（连翻间隔尽量短）
            cooldownUntil = Date().addingTimeInterval(0.08)
        }
    }

    /// 点击翻页：与拖拽共用同一套 offset 动画（当前页滑出 → 切页 → 归零）。
    /// 不用 move 转场，避免每次翻页重建整页 UILabel。
    private func tapTurn(forward: Bool, width: CGFloat) {
        finishTurn(forward: forward, width: width)
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

    // MARK: - 选摘（选择 / 复制）

    private var selectionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("长按选字后可拷贝")
                    .font(.caption2)
                    .foregroundStyle(theme.current.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("复制本页") { copyToPasteboard(currentPageText, label: "本页") }
                    .font(.caption)
                Button("复制本章") { copyToPasteboard(model.pages.joined(separator: "\n"), label: "本章") }
                    .font(.caption)
                Button {
                    withAnimation { selecting = false }
                } label: {
                    Text("完成").font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            Spacer()
        }
        .foregroundStyle(Color.primary)
    }

    private func copyToPasteboard(_ text: String, label: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppLog.warn("READER", "复制\(label)失败：内容为空")
            return
        }
        UIPasteboard.general.string = trimmed
        AppLog.info("READER", "已复制\(label)：\(trimmed.count)字")
        withAnimation { toast = "已复制\(label)（\(trimmed.count)字）" }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation { toast = nil }
        }
    }

    // MARK: - 菜单

    private var menuOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.commitProgress()
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
                // 菜单"上一章"定位到上一章开头（对齐源APP；末页语义仅用于翻页越界连续回退）
                menuButton("上一章", "chevron.up") { model.jump(to: max(0, model.book.currentChapter - 1)) }
                menuButton("目录", "list.triangle") { showCatalog = true }
                menuButton("朗读", "waveform") { SpeechCenter.shared.begin(model: model) }
                // 选摘：进入文本选择模式，可长按选字 / 复制本页与本章
                menuButton("选摘", "textformat.alt") {
                    withAnimation {
                        showMenu = false
                        selecting = true
                    }
                }
                // 换源（在线书可用）
                menuButton(model.book.origin == .online ? "换源" : "设置", "arrow.triangle.2.circlepath") {
                    if model.book.origin == .online {
                        showSourceSwitch = true
                    } else {
                        showSettings = true
                    }
                }
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
            tapTurn(forward: false, width: width)
        } else if x > width - third {
            tapTurn(forward: true, width: width)
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

    /// 拖动翻页时 dragOffset 每帧变化都会重算 body，这里缓存上一次的排版 key，
    /// 文本/字体没变就跳过 NSAttributedString 重建（连翻卡顿的主要来源）。
    final class Coordinator {
        var key: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let key = Self.cacheKey(text: text, settings: settings, theme: theme)
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        label.attributedText = Typography.attributedCached(
            text,
            settings: settings,
            color: UIColor(theme.text),
            title: nil
        )
    }

    static func cacheKey(text: String, settings: AppSettings, theme: ReaderTheme) -> String {
        "\(text.count)|\(text.hashValue)|\(settings.fontSize)|\(settings.lineSpacing)"
            + "|\(settings.paragraphSpacing)|\(settings.fontName)|\(settings.bold)"
            + "|\(settings.indentFirstLine)|\(theme.text.description)"
    }
}

/// 可选中的正文页（选择模式）：排版与 PageCanvas 一致，底层换成 UITextView，
/// 以便长按/双击选字并调用系统「拷贝」菜单。
struct SelectablePageCanvas: UIViewRepresentable {
    let text: String
    let settings: AppSettings
    let theme: ReaderTheme
    /// 上下滚动模式：整章文本允许滚动；分页模式只显示当前页，不滚动。
    var scrollable: Bool = false

    final class Coordinator {
        var key: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = scrollable
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isScrollEnabled = scrollable
        let key = PageCanvas.cacheKey(text: text, settings: settings, theme: theme)
            + "|\(scrollable)"
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        view.attributedText = Typography.attributedCached(
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
