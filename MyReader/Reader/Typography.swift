import UIKit
import CoreText

/// 排版 + 分页。用 CoreText 精确切页，做到「翻页不切字」。
enum Typography {
    static func font(for settings: AppSettings) -> UIFont {
        let size = CGFloat(settings.fontSize)
        if !settings.fontName.isEmpty, let custom = UIFont(name: settings.fontName, size: size) {
            return custom
        }
        let weight: UIFont.Weight = settings.bold ? .semibold : .regular
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    static func paragraphStyle(for settings: AppSettings) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(settings.lineSpacing)
        style.paragraphSpacing = CGFloat(settings.paragraphSpacing)
        style.alignment = .justified
        if settings.indentFirstLine {
            style.firstLineHeadIndent = CGFloat(settings.fontSize) * 2
        }
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func attributed(
        _ text: String,
        settings: AppSettings,
        color: UIColor,
        title: String? = nil
    ) -> NSAttributedString {
        let body = NSMutableAttributedString()
        if let title, !title.isEmpty {
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.paragraphSpacing = 16
            titleStyle.alignment = .left
            let titleFont = UIFont.systemFont(ofSize: CGFloat(settings.fontSize) + 4, weight: .semibold)
            body.append(NSAttributedString(string: title + "\n", attributes: [
                .font: titleFont,
                .paragraphStyle: titleStyle,
                .foregroundColor: color
            ]))
        }
        let paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let joined = paragraphs.joined(separator: "\n")
        body.append(NSAttributedString(string: joined, attributes: [
            .font: font(for: settings),
            .paragraphStyle: paragraphStyle(for: settings),
            .foregroundColor: color
        ]))
        return body
    }

    /// 把整章正文切成若干页（纯文本，便于缓存与朗读定位）。
    static func paginate(_ text: String, settings: AppSettings, size: CGSize) -> [String] {
        guard size.width > 0, size.height > 0 else { return [text] }
        let attributed = attributed(text, settings: settings, color: .black)
        return paginate(attributed: attributed, size: size)
    }

    static func paginate(attributed: NSAttributedString, size: CGSize) -> [String] {
        guard attributed.length > 0 else { return [""] }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)

        var pages: [String] = []
        var location = 0
        let total = attributed.length

        while location < total {
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(location, 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            let range = NSRange(location: visible.location, length: visible.length)
            pages.append((attributed.string as NSString).substring(with: range))
            location = visible.location + visible.length
        }
        return pages.isEmpty ? [attributed.string] : pages
    }
}
