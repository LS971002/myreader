import Foundation

/// 极简、容错的 HTML 解析器（无第三方依赖）。
/// 只做书源规则需要的事：建一棵可查询的 DOM 树。
final class HTMLNode {
    var tag: String
    var attrs: [String: String]
    private(set) var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    var textValue: String? = nil      // 仅文本节点使用
    var isText: Bool { tag == "#text" }
    var isRoot: Bool { tag == "#root" }

    init(tag: String, attrs: [String: String] = [:], text: String? = nil) {
        self.tag = tag.lowercased()
        self.attrs = attrs
        self.textValue = text
    }

    func append(_ node: HTMLNode) {
        node.parent = self
        children.append(node)
    }

    var textContent: String {
        if isText { return textValue ?? "" }
        return children.map(\.textContent).joined()
    }

    var ownText: String {
        children.filter(\.isText).map { $0.textValue ?? "" }.joined()
    }

    func allNodes() -> [HTMLNode] {
        var out: [HTMLNode] = []
        var stack: [HTMLNode] = [self]
        while let node = stack.popLast() {
            out.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return out
    }

    func elements() -> [HTMLNode] {
        allNodes().filter { !$0.isText }
    }

    func attr(_ name: String) -> String? {
        attrs[name.lowercased()]
    }

    var classList: [String] {
        (attrs["class"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }

    var idValue: String? { attrs["id"] }

    /// 用于调试 / @html 取值
    func outerHTML() -> String {
        if isText { return textValue ?? "" }
        let a = attrs.map { " \($0.key)=\"\($0.value)\"" }.joined()
        return "<\(tag)\(a)>\(children.map { $0.outerHTML() }.joined())</\(tag)>"
    }
}

enum HTMLParser {
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]
    private static let rawTags: Set<String> = ["script", "style"]

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(tag: "#root")
        var stack: [HTMLNode] = [root]
        let chars = Array(html)
        var i = 0

        func appendText(_ text: String) {
            guard !text.isEmpty, let top = stack.last else { return }
            top.append(HTMLNode(tag: "#text", text: decodeEntities(text)))
        }

        while i < chars.count {
            if chars[i] == "<" {
                if matches(chars, i, "<!--") {
                    var j = i + 4
                    while j + 2 < chars.count && !matches(chars, j, "-->") { j += 1 }
                    i = min(j + 3, chars.count)
                    continue
                }
                if matches(chars, i, "<!") || matches(chars, i, "<?") {
                    var j = i + 2
                    while j < chars.count && chars[j] != ">" { j += 1 }
                    i = min(j + 1, chars.count)
                    continue
                }
                // 结束标签
                if i + 1 < chars.count && chars[i + 1] == "/" {
                    var j = i + 2
                    var name = ""
                    while j < chars.count && chars[j] != ">" {
                        name.append(chars[j]); j += 1
                    }
                    i = min(j + 1, chars.count)
                    let tagName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let index = stack.lastIndex(where: { $0.tag == tagName }), index > 0 {
                        stack.removeSubrange(index...)
                    }
                    continue
                }
                // 开始标签
                var j = i + 1
                var name = ""
                while j < chars.count && !isSpace(chars[j]) && chars[j] != ">" && chars[j] != "/" {
                    name.append(chars[j]); j += 1
                }
                var attrString = ""
                var selfClosed = false
                while j < chars.count && chars[j] != ">" {
                    if chars[j] == "/" && j + 1 < chars.count && chars[j + 1] == ">" {
                        selfClosed = true
                    }
                    attrString.append(chars[j]); j += 1
                }
                i = min(j + 1, chars.count)
                let tagName = name.lowercased()
                guard !tagName.isEmpty else { continue }

                let node = HTMLNode(tag: tagName, attrs: parseAttrs(attrString))
                stack.last?.append(node)

                if voidTags.contains(tagName) || selfClosed { continue }

                if rawTags.contains(tagName) {
                    // 跳过脚本/样式内容直到对应结束标签
                    var j2 = i
                    var content = ""
                    while j2 < chars.count {
                        if chars[j2] == "<", matches(chars, j2, "</\(tagName)") { break }
                        content.append(chars[j2]); j2 += 1
                    }
                    node.append(HTMLNode(tag: "#text", text: content))
                    while j2 < chars.count && chars[j2] != ">" { j2 += 1 }
                    i = min(j2 + 1, chars.count)
                    continue
                }
                stack.append(node)
                continue
            }

            var j = i
            var text = ""
            while j < chars.count && chars[j] != "<" {
                text.append(chars[j]); j += 1
            }
            appendText(text)
            i = j
        }
        return root
    }

    private static func isSpace(_ c: Character) -> Bool {
        c == " " || c == "\n" || c == "\t" || c == "\r"
    }

    private static func matches(_ chars: [Character], _ start: Int, _ pattern: String) -> Bool {
        let p = Array(pattern)
        guard start + p.count <= chars.count else { return false }
        for k in 0..<p.count where chars[start + k] != p[k] { return false }
        return true
    }

    private static func parseAttrs(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(string)
        var i = 0
        while i < chars.count {
            while i < chars.count && (isSpace(chars[i]) || chars[i] == "/") { i += 1 }
            guard i < chars.count else { break }
            var key = ""
            while i < chars.count && chars[i] != "=" && !isSpace(chars[i]) && chars[i] != ">" {
                key.append(chars[i]); i += 1
            }
            while i < chars.count && isSpace(chars[i]) { i += 1 }
            var value = ""
            if i < chars.count && chars[i] == "=" {
                i += 1
                while i < chars.count && isSpace(chars[i]) { i += 1 }
                if i < chars.count && (chars[i] == "\"" || chars[i] == "'") {
                    let quote = chars[i]; i += 1
                    while i < chars.count && chars[i] != quote {
                        value.append(chars[i]); i += 1
                    }
                    if i < chars.count { i += 1 }
                } else {
                    while i < chars.count && !isSpace(chars[i]) && chars[i] != ">" {
                        value.append(chars[i]); i += 1
                    }
                }
            }
            let k = key.lowercased()
            if !k.isEmpty {
                result[k] = decodeEntities(value)
            }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        let map = [
            "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&amp;": "&",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&ldquo;": "“",
            "&rdquo;": "”", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // 数字实体
        if out.contains("&#") {
            let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
            let ns = out as NSString
            var result = ""
            var last = 0
            regex?.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, let range = Range(match.range(at: 1), in: out) else { return }
                let body = String(out[range])
                let scalarValue: UInt32?
                if body.hasPrefix("x") || body.hasPrefix("X") {
                    scalarValue = UInt32(body.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(body)
                }
                if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                    result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                    result.append(Character(scalar))
                    last = match.range.location + match.range.length
                }
            }
            if last < ns.length {
                result += ns.substring(with: NSRange(location: last, length: ns.length - last))
            }
            out = result
        }
        return out
    }
}
