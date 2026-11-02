import SwiftUI

@main
struct MyReaderApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var theme = ThemeManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(theme)
                .preferredColorScheme(theme.colorScheme)
                .onAppear {
                    AppLog.info("APP", "启动：书架\(store.books.count)本 / 书源\(store.sources.count)个")
                }
                .onOpenURL { url in
                    AppLog.info("APP", "外部打开：\(url.lastPathComponent)")
                    handleOpen(url: url)
                }
        }
    }

    /// 「用其他应用打开」入口：同步读文件（安全域时序），后台解析，主线程呈现。
    private func handleOpen(url: URL) {
        guard let file = Importer.readIncoming(url: url) else {
            Store.shared.importNotice = "无法读取文件：\(url.lastPathComponent)"
            return
        }
        Task.detached(priority: .userInitiated) {
            let outcome = Importer.processIncoming(file)
            await MainActor.run {
                Store.shared.present(outcome)
            }
        }
    }
}
