import Foundation

/// 书源规则求值器。
///
/// 规则写法（`@` 串联，前面的选择器 + 后面的取值/清洗动作）：
/// ```
/// div.list ul li a@href@abs        // 取链接并补全为绝对地址
/// div.info h1@text                 // 取文本
/// div.content@html2text            // 保留段落换行
/// div.intro@text@regex(简介[：:](.*)) 
/// //div[@id="list"]/dl/dd[2]/a/text()
/// ```
/// JSON 接口：`json:data.books[0].title`
final class RuleEngine {
    private let baseURL: URL?
    /// 原始响应文本，供 JSON 规则使用。
    private let raw: String

    init(baseURL: String?, raw: String = "") {
        self.baseURL = baseURL.flatMap { URL(string: $0) }
        self.raw = raw
    }

    // MARK: - 对外接口

    /// 列表规则：返回多条字符串（链接 / 标题 / 作者…）。
    func list(_ rule: String, in doc: HTMLNode) -> [String] {
        evaluate(rule, doc: doc, node: nil).values
    }

    /// 单值规则：返回第一项。
    func value(_ rule: String, in doc: HTMLNode) -> String {
        list(rule, in: doc).first ?? ""
    }

    func value(_ rule: String, in node: HTMLNode, doc: HTMLNode) -> String {
        evaluate(rule, doc: doc, node: node).values.first ?? ""
    }

    /// 列表规则命中后的 DOM 节点（用于「列表项 → 逐项取字段」的二段式规则）。
    func nodes(_ rule: String, in doc: HTMLNode) -> [HTMLNode] {
        evaluate(rule, doc: doc, node: nil).nodes
    }

    // MARK: - 内部

    private struct Outcome {
        var nodes: [HTMLNode] = []
        var values: [String] = []
    }

    private func evaluate(_ rule: String, doc: HTMLNode, node: HTMLNode?) -> Outcome {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Outcome() }

        // JSON 规则
        if trimmed.hasPrefix("json:") || trimmed.hasPrefix("$.") {
            let path = trimmed.hasPrefix("json:") ? String(trimmed.dropFirst(5)) : trimmed
            let values = JSONRule.path(path, in: raw)
            return Outcome(nodes: [], values: values)
        }

        let parts = Selector.splitTopLevel(trimmed, separator: "@")
        let selectorText = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let actions = parts.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }

        let scope = node ?? doc
        var matched: [HTMLNode] = []
        if selectorText.isEmpty {
            matched = [scope]
        } else if selectorText == "self" || selectorText == "." {
            matched = [scope]
        } else {
            matched = Selector.parse(selectorText).select(scope)
        }

        var values: [String] = []
        var actionList = actions
        var extractor = "text"
        // 第一个动作如果是取值型，先取出字符串；其余作为清洗
        if let first = actionList.first, isExtractor(first) {
            extractor = first
            actionList.removeFirst()
        }

        for item in matched {
            var raw: String
            switch extractor {
            case let e where e.hasPrefix("attr("):
                let name = e.dropFirst(5).dropLast()
                raw = item.attr(String(name)) ?? ""
            case "html":
                raw = item.children.map { $0.outerHTML() }.joined()
            case "ownText", "own":
                raw = item.ownText
            default:
                raw = item.textContent
            }

            for action in actionList {
                raw = apply(action, to: raw, node: item)
            }
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { values.append(raw) }
        }

        return Outcome(nodes: matched, values: values)
    }

    private func isExtractor(_ action: String) -> Bool {
        let a = action.lowercased()
        return a == "text" || a == "html" || a == "owntext" || a == "own" || a.hasPrefix("attr(")
    }

    private func apply(_ action: String, to value: String, node: HTMLNode) -> String {
        let lower = action.lowercased()
        if lower == "trim" { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lower == "html2text" || lower == "text2" { return RuleEngine.htmlToText(value) }
        if lower == "abs" || lower == "absurl" || lower == "url" { return absolute(value) }
        if lower.hasPrefix("regex(") {
            let body = String(action.dropFirst(6).dropLast())
            let args = Selector.splitTopLevel(body, separator: ",")
            let pattern = args.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let group = args.count > 1 ? (Int(args[1].trimmingCharacters(in: .whitespaces)) ?? 1) : 1
            return RuleEngine.regex(pattern: pattern, group: group, in: value) ?? ""
        }
        if lower.hasPrefix("replace(") {
            let body = String(action.dropFirst(8).dropLast())
            let args = body.components(separatedBy: "||")
            if args.count >= 2 {
                return value.replacingOccurrences(of: args[0], with: args[1])
            }
            return value
        }
        if lower.hasPrefix("attr(") {
            return node.attr(String(action.dropFirst(5).dropLast())) ?? value
        }
        if lower.hasPrefix("index(") {
            let n = Int(action.dropFirst(6).dropLast()) ?? 0
            let comps = value.components(separatedBy: "\n")
            return comps.indices.contains(n) ? comps[n] : ""
        }
        if lower == "lastline" { return value.components(separatedBy: "\n").last ?? value }
        if lower == "firstline" { return value.components(separatedBy: "\n").first ?? value }
        return value
    }

    private func absolute(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return v }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return v }
        if v.hasPrefix("//") {
            return (baseURL?.scheme ?? "https") + ":" + v
        }
        guard let base = baseURL else { return v }
        if v.hasPrefix("/") {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.path = v
            comps?.query = nil
            return comps?.url?.absoluteString ?? v
        }
        return URL(string: v, relativeTo: base)?.absoluteString ?? v
    }

    // MARK: - 工具

    static func regex(pattern: String, group: Int, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        guard group < match.numberOfRanges else { return nil }
        let range = match.range(at: group)
        return range.location == NSNotFound ? nil : ns.substring(with: range)
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = HTMLParser.decodeEntities(text)
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

// MARK: - JSON 路径

enum JSONRule {
    /// 支持 `data.books[0].title`、`a.b[*].c`
    static func path(_ path: String, in text: String) -> [String] {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        var cleaned = path.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("$") { cleaned = String(cleaned.dropFirst()) }
        if cleaned.hasPrefix(".") { cleaned = String(cleaned.dropFirst()) }

        var keys: [String] = []
        var current = ""
        for c in cleaned {
            if c == "." { keys.append(current); current = "" }
            else if c == "[" { if !current.isEmpty { keys.append(current); current = "" } }
            else if c == "]" { if !current.isEmpty { keys.append(current); current = "" } }
            else { current.append(c) }
        }
        if !current.isEmpty { keys.append(current) }

        var currentValues: [Any] = [object]
        for key in keys {
            var next: [Any] = []
            if key == "*" {
                for value in currentValues {
                    if let array = value as? [Any] { next.append(contentsOf: array) }
                    else if let dict = value as? [String: Any] { next.append(contentsOf: dict.values) }
                }
            } else if let index = Int(key) {
                for value in currentValues {
                    if let array = value as? [Any], array.indices.contains(index) {
                        next.append(array[index])
                    }
                }
            } else {
                for value in currentValues {
                    if let dict = value as? [String: Any], let v = dict[key] {
                        next.append(v)
                    }
                }
            }
            currentValues = next
            if currentValues.isEmpty { return [] }
        }

        return currentValues.compactMap { value -> String? in
            switch value {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
    }
}


