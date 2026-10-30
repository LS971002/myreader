import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

struct ReaderTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: Color
    let text: Color
    let secondary: Color
    var isDark: Bool = false
}

enum ThemeCatalog {
    static let all: [ReaderTheme] = [
        ReaderTheme(id: "paper", name: "纸白", background: Color(hex: 0xFAF7F2),
                    text: Color(hex: 0x2B2B2B), secondary: Color(hex: 0x9A9A9A)),
        ReaderTheme(id: "green", name: "护眼", background: Color(hex: 0xCCE8CF),
                    text: Color(hex: 0x21301F), secondary: Color(hex: 0x6E8B6E)),
        ReaderTheme(id: "wheat", name: "米黄", background: Color(hex: 0xF3E9D2),
                    text: Color(hex: 0x4A3B28), secondary: Color(hex: 0xA08C6E)),
        ReaderTheme(id: "gray", name: "灰白", background: Color(hex: 0xEDEDED),
                    text: Color(hex: 0x3A3A3A), secondary: Color(hex: 0x8C8C8C)),
        ReaderTheme(id: "night", name: "夜间", background: Color(hex: 0x1C1C1E),
                    text: Color(hex: 0xB9B9BE), secondary: Color(hex: 0x6A6A70), isDark: true),
        ReaderTheme(id: "black", name: "纯黑", background: Color(hex: 0x000000),
                    text: Color(hex: 0x8A8A8A), secondary: Color(hex: 0x5A5A5A), isDark: true),
        ReaderTheme(id: "blue", name: "深蓝", background: Color(hex: 0x121E2B),
                    text: Color(hex: 0xAEC6DC), secondary: Color(hex: 0x6C8299), isDark: true)
    ]

    static func theme(id: String) -> ReaderTheme {
        all.first { $0.id == id } ?? all[0]
    }
}

final class ThemeManager: ObservableObject {
    @Published var current: ReaderTheme = ThemeCatalog.all[0] {
        didSet { accent = current.isDark ? Color(hex: 0xE8E8EA) : Color(hex: 0x1F1F1F) }
    }
    @Published var accent: Color = Color(hex: 0x1F1F1F)

    var colorScheme: ColorScheme? {
        let settings = Store.shared.settings
        if !settings.followSystemDark {
            return current.isDark ? .dark : .light
        }
        return nil
    }

    init() {
        refresh()
    }

    func refresh() {
        current = ThemeCatalog.theme(id: Store.shared.settings.themeID)
    }

    func apply(themeID: String) {
        Store.shared.updateSettings { $0.themeID = themeID }
        current = ThemeCatalog.theme(id: themeID)
    }
}
