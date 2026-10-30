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
                .onOpenURL { url in
                    Importer.handleIncoming(url: url)
                }
        }
    }
}
