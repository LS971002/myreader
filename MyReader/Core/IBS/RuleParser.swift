import Foundation
import JavaScriptCore

/// IBS 规则执行器：按前缀分发，支持组合规则（contents[i] 引用前序结果）。
///
/// 前缀（逆向文档 01 模块 4.1 节）：
///   @dyn:  动态脚本（DynEngine）
///   @def:  JavaScript（组合中作为代码文本传递，contents[0]）
///   @ex: / 无前缀  XPath 选择器（ExSelector）
///   @str:  字符串拼接（self = 输入）
///   @regex: 正则（pattern @=>template，无 @=> 为提取）
///   @json: JSON 路径
final class RuleRunner {
    let ctx: DynContext

    init(ctx: DynContext) {
        self.ctx = ctx
    }

    // MARK: 组合规则

    /// 依次执行组合规则；每条结果的输入是前一条的输出，并累积到 ctx.contents。
    /// - Parameters:
    ///   - value: 规则（单条或数组）
    ///   - input: 首条规则的输入（响应 HTML / 上层传入值）
    ///   - dom: 首条输入对应的 DOM（响应已解析则传入，避免重复 parse）
    func run(_ value: RuleValue, input: String, dom: HTMLNode? = nil) -> String? {
        let rules = value.rules
        guard !rules.isEmpty else { return nil }
        var current = input
        ctx.contents.removeAll()

        for (index, rule) in rules.enumerated() {
            let firstDom = (index == 0) ? dom : nil
            let result = runSingle(rule, input: current, dom: firstDom) ?? ""
            ctx.contents.append(result)
            current = result
        }
        return current.isEmpty ? nil : current
    }

    // MARK: 单条规则

    func runSingle(_ rule: String, input: String, dom: HTMLNode?) -> String? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // @dyn: —— self.respContent 由 IBSEngine 维护；隐式变量 content = 输入
        if trimmed.hasPrefix("@dyn:") {
            let script = String(trimmed.dropFirst(5))
            let engine = DynEngine(ctx: ctx)
            ctx.vars["content"] = .str(input)
            let value = engine.execute(script)
            return value.isNull ? nil : value.stringValue
        }

        // @def: —— 组合场景返回代码文本（contents[0] 供 @dyn: evaluateScript）
        if trimmed.hasPrefix("@def:") {
            return String(trimmed.dropFirst(5))
        }

        // @str: 字符串拼接（"literal"+self）
        if trimmed.hasPrefix("@str:") {
            return evalStrExpr(String(trimmed.dropFirst(5)), input: input)
        }

        // @regex: pattern @=>template（可空 = 删除匹配）；无 @=> 为提取
        if trimmed.hasPrefix("@regex:") {
            let body = String(trimmed.dropFirst(7))
            let value = DynEngine.executeRegex(input, rule: body)
            return value.isNull ? nil : value.stringValue
        }

        // @json: 路径
        if trimmed.hasPrefix("@json:") {
            let path = String(trimmed.dropFirst(6))
            let values = JSONRule.path(path, in: input)
            return values.first
        }

        // ⚠️ JSON 项上下文必须先于选择器分支：
        // 猫眼 dirURL "/novel/{{$.novelId}}/chapters" 含 "." 会被 looksLikeSelector
        // 误判成选择器导致 dirURL 恒空 → link 兜底成搜索URL → 目录0章 → 正文空白。
        // JSON 项字段（无前缀键简写 / {{$.path}} 模板）优先于选择器。
        if hasJSONContext(input) && !trimmed.hasPrefix("@ex:") && !trimmed.hasPrefix("@xpath:") {
            if trimmed.contains("{{") {
                let expanded = expandJSONTemplate(stripQuotes(trimmed), input: input)
                if !expanded.isEmpty { return expanded }
            }
            if isPlainPath(trimmed), !trimmed.contains(" "),
               let value = JSONRule.path(trimmed, in: input).first, !value.isEmpty {
                return value
            }
            // JSON 上下文里选择器没有意义（输入不是HTML），直接按字面量返回
            if !looksLikeSelector(trimmed) {
                return stripQuotes(trimmed)
            }
        }

        // @ex: / 无前缀 —— XPath 选择器
        var selectorText = trimmed
        if trimmed.hasPrefix("@ex:") {
            selectorText = String(trimmed.dropFirst(4))
        } else if trimmed.hasPrefix("@xpath:") {
            selectorText = String(trimmed.dropFirst(7))
        }
        if trimmed.hasPrefix("@ex:") || trimmed.hasPrefix("@xpath:") || looksLikeSelector(selectorText) {
            // `A||B` 组合规则（爱阅 executeCombi 语义：逐条尝试，取第一个非空结果）。
            // 真实书源：`@ex:div[@id=rtext].p||@ex:div[@id=rtext]`。
            if selectorText.contains("||") {
                for part in selectorText.components(separatedBy: "||") {
                    let candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { continue }
                    let nested = candidate.hasPrefix("@ex:") || candidate.hasPrefix("@xpath:")
                        ? candidate : "@ex:" + candidate
                    if let value = runSingle(nested, input: input, dom: dom), !value.isEmpty {
                        return value
                    }
                }
                return nil
            }
            let selector = ExSelector.parse(selectorText)
            let scope: HTMLNode
            if let dom {
                scope = dom
            } else if let parsed = parseDOM(input) {
                scope = parsed
            } else {
                return nil
            }
            let value = selector.value(from: scope)
            return value?.isEmpty == true ? nil : value
        }

        // 兜底：纯文本（type 0）直接返回
        return trimmed
    }

    /// 输入是 JSON 对象形态（以 { 开头）。
    private func hasJSONContext(_ input: String) -> Bool {
        input.hasPrefix("{")
    }

    /// `"/novel/{{$.novelId}}/chapters"` → 剥首尾引号。
    private func stripQuotes(_ text: String) -> String {
        var t = text
        if t.hasPrefix("\"") { t = String(t.dropFirst()) }
        if t.hasSuffix("\"") { t = String(t.dropLast()) }
        return t
    }

    /// 纯路径词（字母数字点下划线，非选择器形态）。
    private func isPlainPath(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { c in
            c.isLetter || c.isNumber || c == "." || c == "_"
        }
    }

    /// {{$.a.b}} 模板插值（值来自输入 JSON）。
    private func expandJSONTemplate(_ template: String, input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\$\.([^}]+)\}\}"#) else {
            return template
        }
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for m in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            let key = ns.substring(with: m.range(at: 1))
            out += JSONRule.path(key, in: input).first ?? ""
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    /// 列表项字段规则：在节点子树内执行。
    func runOnNode(_ rule: String, node: HTMLNode) -> String? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("@dyn:") {
            let script = String(trimmed.dropFirst(5))
            ctx.vars["content"] = .str(node.textContent)
            let engine = DynEngine(ctx: ctx)
            let value = engine.execute(script)
            return value.isNull ? nil : value.stringValue
        }
        if trimmed.hasPrefix("@str:") {
            return evalStrExpr(String(trimmed.dropFirst(5)), input: node.textContent)
        }
        if trimmed.hasPrefix("@regex:") {
            let body = String(trimmed.dropFirst(7))
            let value = DynEngine.executeRegex(node.textContent, rule: body)
            return value.isNull ? nil : value.stringValue
        }

        var selectorText = trimmed
        if trimmed.hasPrefix("@ex:") { selectorText = String(trimmed.dropFirst(4)) }
        else if trimmed.hasPrefix("@xpath:") { selectorText = String(trimmed.dropFirst(7)) }

        let selector = ExSelector.parse(selectorText)
        let value = selector.value(from: node)
        return value?.isEmpty == true ? nil : value
    }

    // MARK: @str: 表达式（JxdStringParser）

    /// `@str:` 语义 = 字符串方法链。
    /// 逆向依据：`Reverse/rea/01_书源模块.md` 4.3 与 `03_内容过滤与替换模块.md` 第四节
    /// （JxdStringParser：pos / rpos / mid / del / sub / mark / split / trim / left / right / replace）。
    /// 真实书源用例：`@str:replace(/book,/book/chapter/)`、`@str:pos(").rpos(").mid`、
    /// `@str:replace(字数：,)`。
    /// 同时兼容旧的 `"literal"+self` 拼接写法。
    private func evalStrExpr(_ expr: String, input: String) -> String? {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        // 以引号开头 = 旧式拼接（`"<li>…</li>"+self`），其中可能含括号
        if !trimmed.hasPrefix("\""), trimmed.contains("(") {
            var text = input
            var pos: Int?
            var rpos: Int?
            for call in splitStrCalls(trimmed) {
                text = applyStrCall(call, to: text, pos: &pos, rpos: &rpos)
            }
            return text.isEmpty ? nil : text
        }

        var out = ""
        var rest = trimmed
        while !rest.isEmpty {
            if rest.hasPrefix("\"") {
                guard let close = rest.dropFirst().firstIndex(of: "\"") else {
                    out += String(rest.dropFirst())
                    return out.isEmpty ? nil : out
                }
                out += String(rest[rest.index(after: rest.startIndex)...close])
                rest = String(rest[rest.index(after: close)...])
            } else {
                let piece: String
                if let plus = rest.firstIndex(of: "+") {
                    piece = String(rest[rest.startIndex..<plus])
                    rest = String(rest[rest.index(after: plus)...])
                } else {
                    piece = rest
                    rest = ""
                }
                let atom = piece.trimmingCharacters(in: .whitespaces)
                if atom == "self" { out += input }
                else if atom.isEmpty { continue }
                else if let v = ctx.vars[atom] { out += v.stringValue }
                else { out += atom }
            }
            if rest.hasPrefix("+") { rest = String(rest.dropFirst()) }
        }
        return out.isEmpty ? nil : out
    }

    /// 按方法链拆 `.`（括号内的点不拆；`pos(")` 这类单引号参数也能正确保留）。
    private func splitStrCalls(_ expr: String) -> [String] {
        var calls: [String] = []
        var current = ""
        var depth = 0
        for ch in expr {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == ".", depth == 0 {
                if !current.isEmpty { calls.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { calls.append(current) }
        return calls
    }

    private func splitStrArgs(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var depth = 0
        for ch in raw {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == ",", depth == 0 {
                args.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        args.append(current.trimmingCharacters(in: .whitespaces))
        return args
    }

    private func applyStrCall(_ rawCall: String, to text: String,
                              pos: inout Int?, rpos: inout Int?) -> String {
        let call = rawCall.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !call.isEmpty else { return text }

        guard let lp = call.firstIndex(of: "(") else {
            switch call.lowercased() {
            case "mid":
                guard let a = pos, let b = rpos, b >= a,
                      let start = text.index(text.startIndex, offsetBy: a, limitedBy: text.endIndex),
                      let end = text.index(text.startIndex, offsetBy: b, limitedBy: text.endIndex) else {
                    return text
                }
                var piece = String(text[start..<end])
                if piece.hasPrefix("\"") { piece = String(piece.dropFirst()) }
                if piece.hasSuffix("\"") { piece = String(piece.dropLast()) }
                return piece
            case "left":
                // `@str:pos(:).left` → 取标记左侧内容
                guard let a = pos,
                      let cut = text.index(text.startIndex, offsetBy: a, limitedBy: text.endIndex) else {
                    return text
                }
                return String(text[text.startIndex..<cut])
            case "right":
                guard let b = rpos,
                      let cut = text.index(text.startIndex, offsetBy: b, limitedBy: text.endIndex) else {
                    return text
                }
                return String(text[cut...])
            case "trim":
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                return text
            }
        }

        let name = String(call[call.startIndex..<lp]).lowercased()
        var argsRaw = String(call[call.index(after: lp)...])
        if argsRaw.hasSuffix(")") { argsRaw = String(argsRaw.dropLast()) }
        let args = splitStrArgs(argsRaw)

        switch name {
        case "replace", "replacingoccurrencesofstring":
            guard args.count >= 2 else { return text }
            return text.replacingOccurrences(of: args[0], with: args[1])
        case "pos", "rpos":
            let token = args.first ?? "\""
            guard !token.isEmpty else { return text }
            let options: String.CompareOptions = (name == "rpos") ? .backwards : String.CompareOptions()
            // 半角/全角冒号互通（书源常用 `pos(:)`，正文却是「作者：xxx」）
            var found = text.range(of: token, options: options)
            if found == nil {
                let alternate = token == ":" ? "：" : (token == "：" ? ":" : nil)
                if let alternate {
                    found = text.range(of: alternate, options: options)
                }
            }
            guard let range = found else { return text }
            pos = text.distance(from: text.startIndex, to: range.lowerBound)
            rpos = text.distance(from: text.startIndex, to: range.upperBound)
            return text
        case "mid":
            guard let a = pos, let b = rpos, b >= a,
                  let start = text.index(text.startIndex, offsetBy: a, limitedBy: text.endIndex),
                  let end = text.index(text.startIndex, offsetBy: b, limitedBy: text.endIndex) else {
                return text
            }
            var piece = String(text[start..<end])
            if piece.hasPrefix("\"") { piece = String(piece.dropFirst()) }
            if piece.hasSuffix("\"") { piece = String(piece.dropLast()) }
            return piece
        case "del":
            guard let n = Int(args.first ?? "0"), n >= 0 else { return text }
            let utf16 = Array(text.utf16)
            guard n < utf16.count else { return "" }
            return String(decoding: utf16[n...], as: UTF16.self)
        case "sub":
            guard args.count >= 2,
                  let a = Int(args[0]), let b = Int(args[1]), a >= 0, b >= a else { return text }
            let utf16 = Array(text.utf16)
            guard a < utf16.count else { return "" }
            return String(decoding: utf16[a..<min(b, utf16.count)], as: UTF16.self)
        case "left":
            guard let n = Int(args.first ?? "0"), n >= 0 else { return text }
            let utf16 = Array(text.utf16)
            return String(decoding: utf16[..<min(n, utf16.count)], as: UTF16.self)
        case "right":
            guard let n = Int(args.first ?? "0"), n >= 0 else { return text }
            let utf16 = Array(text.utf16)
            let start = max(0, utf16.count - n)
            return String(decoding: utf16[start...], as: UTF16.self)
        case "split":
            let sep = args.first ?? ","
            let index = args.count > 1 ? (Int(args[1]) ?? 0) : 0
            let parts = text.components(separatedBy: sep)
            return parts.indices.contains(index) ? parts[index] : ""
        case "mark":
            // 标记定位：mark(x) 仅记录位置，不改变文本
            if let token = args.first, let range = text.range(of: token) {
                pos = text.distance(from: text.startIndex, to: range.lowerBound)
                rpos = text.distance(from: text.startIndex, to: range.upperBound)
            }
            return text
        default:
            return text
        }
    }

    // MARK: 工具

    private func parseDOM(_ html: String) -> HTMLNode? {
        guard !html.isEmpty else { return nil }
        return HTMLParser.parse(html)
    }

    /// 判断是否为选择器形态（含 [ 或以 @ 开头的段）。
    private func looksLikeSelector(_ text: String) -> Bool {
        text.contains("[") || text.contains(".") || text.contains("@")
    }
}

// MARK: - JSON 路径（自旧引擎迁移）

enum JSONRule {
    /// `data.books` → 原始对象/数组项列表（搜索 _list 用：保留 dict 形态）。
    /// 路径终点的数组会被展平为元素列表（日志实锤：七猫 data.books 曾把
    /// 整个数组当单个值返回，列表项=1 且字段解析失败）。
    static func objectArray(_ path: String, in text: String) -> [Any] {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let values = pathValues(path, roots: [object])
        if values.count == 1, let array = values.first as? [Any] {
            return array
        }
        return values
    }

    /// `data.books[0].title`、`a.b[*].c` → 字符串值列表
    static func path(_ path: String, in text: String) -> [String] {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        return pathValues(path, roots: [object]).compactMap { value -> String? in
            switch value {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
    }

    /// 路径求值核心（roots 为起点对象集合，返回原始值）。
    private static func pathValues(_ path: String, roots: [Any]) -> [Any] {
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

        var currentValues: [Any] = roots
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
        return currentValues
    }
}
