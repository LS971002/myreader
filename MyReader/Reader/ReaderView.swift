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
    /// 拖拽提交翻页期间禁用 move 转场（邻页已跟手滑入，直接切换防叠加闪动）。
    @State private var suppressTransition = false
    /// 翻页完成后的短冷却截止时刻：一次物理滑动被SwiftUI拆成两个手势会话时，
    /// 第二会话在此期间开始 → zombie 屏蔽（防连翻两页）。
    @State private var cooldownUntil = Date.distantPast

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
        .sheet(isPresented: $showSourceSwitch) {
            SourceSwitchSheet(model: model)
                .environmentObject(store)
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

                // 当前页：点击翻页用 move 转场（新页从翻页方向滑入、旧页向对侧滑出），
                // 拖拽翻页用 offset 跟手（dragOffset 由手势驱动）
                PageCanvas(text: currentPageText,
                           settings: settings,
                           theme: theme.current)
                    .offset(x: dragOffset)
                    .id(model.book.currentChapter * 100_000 + model.pageIndex)
                    .transition(pageTransition)
            }
            .allowsHitTesting(false)
        }
    }

    /// 转场方向：跟随最近一次章节跳转/翻页方向。
    /// 拖拽提交期间 suppressTransition=true（邻页已跟手滑入，id 变化直接切换，
    /// 避免 move 转场与滑入动画叠加闪动）。
    private var pageTransition: AnyTransition {
        if suppressTransition { return .identity }
        return .asymmetric(
            insertion: .move(edge: model.lastJumpForward ? .trailing : .leading),
            removal: .move(edge: model.lastJumpForward ? .leading : .trailing)
        )
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

    /// 翻页完成（拖拽松手路径）：邻页已跟手滑入 → 提交翻页 → 归零，无缝停留。
    private func finishTurn(forward: Bool, width: CGFloat) {
        guard !isTurning else { return }
        isTurning = true
        let target: CGFloat = forward ? -width : width

        // 章末/章首越界：翻的是章节
        let crossForward = forward && model.neighborNext == nil
        let crossBack = !forward && model.neighborPrev == nil

        withAnimation(.spring(response: 0.30, dampingFraction: 1.0)) {
            dragOffset = target
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            suppressTransition = true
            if crossForward {
                model.goNextChapter()
            } else if crossBack {
                model.goPreviousChapter()
            } else {
                if forward { model.nextPage() } else { model.prevPage() }
            }
            dragOffset = 0
            isTurning = false
            // 冷却期：吸收同一次物理滑动的残余手势会话
            cooldownUntil = Date().addingTimeInterval(0.15)
            // 转场恢复延后（等 id 变化的渲染提交完成后；期间 isTurning/cooldown 挡住点击翻页）
            try? await Task.sleep(nanoseconds: 250_000_000)
            suppressTransition = false
        }
    }

    /// 点击翻页：原生 move 转场（当前页 id 变化触发，新页沿翻页方向滑入、旧页滑出）。
    private func tapTurn(forward: Bool) {
        guard !isTurning else { return }
        isTurning = true
        model.lastJumpForward = forward
        withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
            if forward { model.nextPage() } else { model.prevPage() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            isTurning = false
            cooldownUntil = Date().addingTimeInterval(0.12)
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
                // 菜单"上一章"定位到上一章开头（对齐源APP；末页语义仅用于翻页越界连续回退）
                menuButton("上一章", "chevron.up") { model.jump(to: max(0, model.book.currentChapter - 1)) }
                menuButton("目录", "list.triangle") { showCatalog = true }
                menuButton("朗读", "waveform") { SpeechCenter.shared.begin(model: model) }
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
            tapTurn(forward: false)
        } else if x > width - third {
            tapTurn(forward: true)
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
