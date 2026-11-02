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
        // 导入确认（TXT / EPUB 草稿）
        .sheet(item: $store.incomingDraft) { book in
            IncomingBookSheet(draft: book)
                .environmentObject(store)
        }
        // 全局导入提示（书源导入成功 / 失败原因）
        .overlay(alignment: .bottom) {
            if let notice = store.importNotice {
                Text(notice)
                    .font(.footnote)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 24)
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        store.importNotice = nil
                    }
            }
        }
    }
}
