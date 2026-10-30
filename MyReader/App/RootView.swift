import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        TabView {
            ShelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }

            DiscoverView()
                .tabItem { Label("发现", systemImage: "safari") }

            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(Color(hex: 0x2F6B4F))
    }
}
