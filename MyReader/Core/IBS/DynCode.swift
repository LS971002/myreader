import Foundation
import JavaScriptCore

// MARK: - 动态 HTTP 头存储（http.httpManager.requestSerializer 的桥）

final class HeaderStore {
    var values: [String: String] = [:]
    /// 已被 removeObjectForKey 删除的头（墓碑：覆盖静态配置里的同名头）。
    var removed: Set<String> = []

    func setValue(_ value: String, forKey field: String) {
        values[field] = value
        removed.remove(field)
    }
    func removeObject(forKey field: String) {
        values.removeValue(forKey: field)
        removed.insert(field)
    }

    /// 动态头合并到静态头（动态优先，墓碑删除）。
    func merged(over staticHeaders: [String: String]) -> [String: String] {
        var result = staticHeaders.filter { removed.contains($0.key) == false }
        for (k, v) in values { result[k] = v }
        return result
    }
}

// MARK: - 执行上下文

struct ParentFrame {
    var currentRequestUrl: String = ""
    var respContent: String = ""
}

struct DynSourceRef {
    var configName = ""
    var dirURL = ""
    var detailURL = ""
    var chapterURL = ""
}

final class DynArr {
    var items: [DynValue] = []
}

/// rule.get / rule.put 变量的共享存储（引用语义，跨节点存活）。
final class RuleStore {
    var values: [String: DynValue] = [:]
}

/// @dyn: 脚本的执行上下文：局部变量 + rule 全局存储 + 对象图。
final class DynContext {
    var vars: [String: DynValue] = [:]
    /// rule.get / rule.put 全局变量（跨节点共享，由 IBSEngine 持有传入）。
    var store: RuleStore
    var respContent: String = ""
    var responseHeaders: [String: String] = [:]
    var parentChain: [ParentFrame] = []
    var source = DynSourceRef()
    var headers = HeaderStore()
    var contents: [String] = []

    init(store: RuleStore = RuleStore()) {
        self.store = store
    }
}

// MARK: - 值模型

enum DynValue {
    case null
    case str(String)
    case num(Double)
    case bool(Bool)
    case arr(DynArr)
    case headers([String: String])           // allHeaderFields
    case serializer(HeaderStore)              // requestSerializer
    case serializerHeaders(HeaderStore)       // mutableHTTPRequestHeaders
    case jsContext(JSContext)
    case jsValue(JSValue)
    case classRef(String)
    // 对象图中间节点
    case selfObj
    case taskObj
    case sessionObj
    case respObj
    case parentObj(Int)
    case sourceObj
    case sourceChapterObj
    case httpObj
    case httpManagerObj
    case ruleObj

    var stringValue: String {
        switch self {
        case .null: return ""
        case .str(let s): return s
        case .num(let n): return DynEngine.trimNumber(n)
        case .bool(let b): return b ? "1" : "0"
        case .jsValue(let v): return v.toString() ?? ""
        default: return ""
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - 解释器

/// 爱阅 @dyn: 脚本解释器。
/// 语句按行分割，支持：
///   x = <expr>            赋值
///   return <expr>         返回（中断）
///   rule.put:<expr> withKey:<key>
///   check(<cond>, <stmt;stmt;...>)
///   裸 <expr>             副作用 / 尾值
/// 表达式：
///   def:<字面量到行尾>      （\; → ;）
///   format("fmt",args)    %@ 按序替换
///   calc(a±b)             算术
///   contents[i]
///   对象链/消息发送：obj.prop.prop method:arg label:arg（. 与空格混排）
final class DynEngine {
    let ctx: DynContext

    init(ctx: DynContext) {
        self.ctx = ctx
    }

    // MARK: 入口

    /// 执行脚本，返回尾值（显式 return 优先）。
    func execute(_ script: String) -> DynValue {
        var lastValue = DynValue.null
        for rawLine in script.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let result = execStatement(line)
            if let ret = result.returnValue { return ret }
            lastValue = result.value
        }
        return lastValue
    }

    /// 便捷：执行并转字符串（null / "null" 哨兵 / 空 → nil）。
    func executeString(_ script: String) -> String? {
        let value = execute(script)
        if value.isNull { return nil }
        let s = value.stringValue
        if s.isEmpty || s == "null" { return nil }
        return s
    }

    // MARK: 语句

    private struct StmtResult {
        var value: DynValue = .null
        var returnValue: DynValue? = nil
    }

    private func execStatement(_ stmt: String) -> StmtResult {
        var line = stmt

        // 语句级剥尾部 `;`（`\;` 是字面量转义，不剥）
        if line.hasSuffix(";") {
            let chars = Array(line)
            if chars.count < 2 || chars[chars.count - 2] != "\\" {
                line = String(line.dropLast())
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 赋值：IDENT = expr（标识符行首）
        if let assign = parseAssignment(line) {
            let value = evalExpr(assign.expr)
            ctx.vars[assign.name] = value
            return StmtResult(value: value)
        }

        // return（nil → 真 null）
        if line.hasPrefix("return ") || line == "return" {
            let rest = line == "return" ? "nil" : String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if rest == "nil" || rest == "null" {
                return StmtResult(value: .null, returnValue: .null)
            }
            return StmtResult(value: .null, returnValue: evalExpr(rest))
        }

        // rule.put:value withKey:key
        if line.hasPrefix("rule.put:") {
            let body = String(line.dropFirst("rule.put:".count))
            var valueExpr = body
            var key = ""
            if let range = body.range(of: " withKey:") {
                valueExpr = String(body[body.startIndex..<range.lowerBound])
                key = String(body[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            }
            let value = evalExpr(valueExpr)
            let keyName = key.isEmpty ? "" : key
            ctx.store.values[keyName] = value
            return StmtResult(value: .null)
        }

        // check(cond, stmts)
        if line.hasPrefix("check("), line.hasSuffix(")") {
            let inner = String(line.dropFirst("check(".count).dropLast())
            if let comma = topLevelComma(inner) {
                let cond = String(inner[inner.startIndex..<comma])
                let body = String(inner[comma...].dropFirst())
                if truthy(evalCond(cond)) {
                    for sub in splitStatements(body) {
                        let result = execStatement(sub)
                        if let ret = result.returnValue {
                            return StmtResult(value: .null, returnValue: ret)
                        }
                    }
                }
                return StmtResult(value: .null)
            }
        }

        // 裸表达式（尾部分号已在语句级剥过）
        return StmtResult(value: evalExpr(line))
    }

    private func parseAssignment(_ line: String) -> (name: String, expr: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let name = String(line[line.startIndex..<eq])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              name.first?.isLetter == true || name.first == "_" else { return nil }
        // 排除 == 比较
        let after = line.index(after: eq)
        if after < line.endIndex, line[after] == "=" { return nil }
        let expr = String(line[after...]).trimmingCharacters(in: .whitespaces)
        guard !expr.isEmpty else { return nil }
        return (name, expr)
    }

    /// 按顶层（括号外、非转义）`;` 分割语句。
    private func splitStatements(_ body: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var escaped = false
        for c in body {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if c == "\\" {
                current.append(c)
                escaped = true
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" { depth = max(0, depth - 1) }
            if c == ";" && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 括号深度 0 处的第一个逗号。
    private func topLevelComma(_ text: String) -> String.Index? {
        var depth = 0
        var inQuote = false
        for (index, c) in text.enumerated() {
            if c == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            if c == "(" { depth += 1 }
            if c == ")" { depth = max(0, depth - 1) }
            if c == "," && depth == 0 { return text.index(text.startIndex, offsetBy: index) }
        }
        return nil
    }

    // MARK: 表达式

    private func evalExpr(_ raw: String) -> DynValue {
        let expr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else { return .null }

        // def: 字面量（到行尾；\; → ;；剥尾部语句分号）
        if expr.hasPrefix("def:") {
            return .str(defLiteral(String(expr.dropFirst(4))))
        }

        // format("...", args)
        if expr.hasPrefix("format(") {
            return evalFormat(String(expr.dropFirst(7)))
        }

        // calc(...)
        if expr.hasPrefix("calc(") {
            let inner = String(expr.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: ")"))
            return evalCalc(inner)
        }

        // nil / null
        if expr == "nil" || expr == "null" { return .null }
        if let n = Double(expr) { return .num(n) }

        // contents[N]
        if expr.hasPrefix("contents["), expr.hasSuffix("]") {
            let idx = Int(expr.dropFirst("contents[".count).dropLast()) ?? 0
            guard ctx.contents.indices.contains(idx) else { return .null }
            return .str(ctx.contents[idx])
        }

        // 链式 / 消息
        let tokens = expr.split(whereSeparator: { $0 == "." || $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return .null }
        return evalChain(tokens)
    }

    /// def: 字面量：`\;` → `;`，其余 `\x` 原样（语句级分号已剥过）。
    private func defLiteral(_ raw: String) -> String {
        var out = ""
        var escaped = false
        for c in raw {
            if escaped {
                if c == ";" { out.append(";") } else { out.append("\\"); out.append(c) }
                escaped = false
                continue
            }
            if c == "\\" {
                escaped = true
                continue
            }
            out.append(c)
        }
        if escaped { out.append("\\") }
        return out
    }

    private func evalChain(_ tokens: [String]) -> DynValue {
        var current = resolveRoot(tokens[0])
        var i = 1
        while i < tokens.count {
            let token = tokens[i]
            if token.contains(":") {
                // 消息发送：本 token 及之后全部为参数
                return sendMessage(current, tokens: Array(tokens[i...]))
            }
            current = getProperty(current, name: token)
            i += 1
        }
        return current
    }

    private func resolveRoot(_ name: String) -> DynValue {
        switch name {
        case "self": return .selfObj
        case "source": return .sourceObj
        case "rule": return .ruleObj
        case "http": return .httpObj
        case "NSMutableArray": return .classRef("NSMutableArray")
        case "JSContext": return .classRef("JSContext")
        case "JxdSecuritySub": return .classRef("JxdSecuritySub")
        case "nil", "null": return .null
        default:
            if let v = ctx.vars[name] { return v }
            // 未知标识符 → 字符串字面量（Cookie / Referer / Set-Cookie / main…）
            if let n = Double(name) { return .num(n) }
            return .str(name)
        }
    }

    // MARK: 属性访问

    private func getProperty(_ obj: DynValue, name: String) -> DynValue {
        switch obj {
        case .selfObj:
            switch name {
            case "respContent": return .str(ctx.respContent)
            case "taskObject": return .taskObj
            case "parent": return .parentObj(0)
            default: return .null
            }
        case .parentObj(let depth):
            switch name {
            case "parent":
                return .parentObj(depth + 1)
            case "currentRequestUrl":
                return .str(ctx.parentChain.indices.contains(depth) ? ctx.parentChain[depth].currentRequestUrl : "")
            case "respContent":
                return .str(ctx.parentChain.indices.contains(depth) ? ctx.parentChain[depth].respContent : "")
            default: return .null
            }
        case .taskObj:
            return name == "session" ? .sessionObj : .null
        case .sessionObj:
            return name == "response" ? .respObj : .null
        case .respObj:
            return name == "allHeaderFields" ? .headers(ctx.responseHeaders) : .null
        case .sourceObj:
            switch name {
            case "configName": return .str(ctx.source.configName)
            case "dirURL": return .str(ctx.source.dirURL)
            case "detailURL": return .str(ctx.source.detailURL)
            case "chapter": return .sourceChapterObj
            default: return .null
            }
        case .sourceChapterObj:
            return name == "url" ? .str(ctx.source.chapterURL) : .null
        case .httpObj:
            return name == "httpManager" ? .httpManagerObj : .null
        case .httpManagerObj:
            return name == "requestSerializer" ? .serializer(ctx.headers) : .null
        case .serializer(let store):
            if name == "mutableHTTPRequestHeaders" { return .serializerHeaders(store) }
            return .null
        case .str(let s):
            if name == "length" { return .num(Double(s.utf16.count)) }
            return .null
        case .classRef(let cls):
            switch (cls, name) {
            case ("NSMutableArray", "array"): return .arr(DynArr())
            case ("JSContext", "alloc"), ("JSContext", "init"):
                return .jsContext(JSContext())
            default: return .null
            }
        case .jsContext:
            // JSContext.alloc.init 链：init 再次产生可用实例
            return name == "init" ? .jsContext(JSContext()) : .null
        case .headers(let h):
            if name == "allHeaderFields" { return .headers(h) }
            return .null
        default:
            return .null
        }
    }

    // MARK: 消息发送

    /// tokens[0] 形如 `sel:arg0` 或 `sel`；后续 token 形如 `label:arg`。
    private func sendMessage(_ receiver: DynValue, tokens: [String]) -> DynValue {
        let first = tokens[0]
        var selector = first
        var arg0: DynValue? = nil
        if let colon = first.firstIndex(of: ":") {
            selector = String(first[first.startIndex..<colon])
            let raw = String(first[first.index(after: colon)...])
            if !raw.isEmpty { arg0 = evalAtom(raw) }
        }
        var labels: [(String, DynValue)] = []
        for token in tokens.dropFirst() where token.contains(":") {
            if let colon = token.firstIndex(of: ":") {
                let label = String(token[token.startIndex..<colon])
                let raw = String(token[token.index(after: colon)...])
                labels.append((label, evalAtom(raw)))
            }
        }
        return dispatch(receiver, selector: selector, arg0: arg0, labels: labels)
    }

    /// 参数原子：nil → "null" 哨兵字符串（爱阅 DSL 无真 nil，
    /// rule.put:nil / 变量 nil 统一为 "null" 字符串，containsString:"null" 检测依赖此）。
    private func evalAtom(_ raw: String) -> DynValue {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .null }
        if s == "nil" || s == "null" { return .str("null") }
        if s.hasPrefix("contents["), s.hasSuffix("]") {
            let idx = Int(s.dropFirst("contents[".count).dropLast()) ?? 0
            guard ctx.contents.indices.contains(idx) else { return .str("null") }
            return .str(ctx.contents[idx])
        }
        if let v = ctx.vars[s] { return v }
        if let n = Double(s) { return .num(n) }
        return .str(s)
    }

    private func dispatch(_ receiver: DynValue, selector: String,
                          arg0: DynValue?, labels: [(String, DynValue)]) -> DynValue {
        switch receiver {
        case .ruleObj:
            if selector == "get", let key = arg0 {
                // 未设置 → "null" 哨兵（与 rule.put:nil 一致）
                return ctx.store.values[key.stringValue] ?? .str("null")
            }
            if selector == "put", let value = arg0 {
                let key = labels.first { $0.0 == "withKey" }?.1.stringValue ?? ""
                if !key.isEmpty { ctx.store.values[key] = value }
                return .null
            }
            return .null

        case .str(let s):
            switch selector {
            case "containsString":
                return .bool(s.contains(arg0?.stringValue ?? ""))
            case "substringFromIndex":
                let idx = Int(arg0?.stringValue ?? "0") ?? 0
                let utf16 = Array(s.utf16)
                guard idx >= 0, idx < utf16.count else { return .str("") }
                return .str(String(decoding: utf16[idx...], as: UTF16.self))
            case "substringToIndex":
                let idx = Int(arg0?.stringValue ?? "0") ?? 0
                let utf16 = Array(s.utf16)
                guard idx >= 0 else { return .str("") }
                return .str(String(decoding: utf16[..<min(idx, utf16.count)], as: UTF16.self))
            case "jxd_executeRegexRules":
                return Self.executeRegex(s, rule: arg0?.stringValue ?? "")
            case "componentsSeparatedByString":
                let sep = arg0?.stringValue ?? ","
                return .arr2(s.components(separatedBy: sep).map { .str($0) })
            case "stringByReplacingOccurrencesOfString":
                let from = arg0?.stringValue ?? ""
                let to = labels.first { $0.0 == "withString" }?.1.stringValue ?? ""
                return .str(s.replacingOccurrences(of: from, with: to))
            default:
                return .null
            }

        case .headers(let h):
            if selector == "objectForKey", let key = arg0 {
                // HTTP 头大小写不敏感
                if let value = h[key.stringValue] { return .str(value) }
                let lower = key.stringValue.lowercased()
                for (k, v) in h where k.lowercased() == lower { return .str(v) }
                return .null
            }
            return .null

        case .serializer(let store):
            if selector == "setValue", let value = arg0 {
                let field = labels.first { $0.0 == "forHTTPHeaderField" }?.1.stringValue ?? ""
                if !field.isEmpty { store.setValue(value.stringValue, forKey: field) }
                return .null
            }
            return .null

        case .serializerHeaders(let store):
            if selector == "removeObjectForKey", let key = arg0 {
                store.removeObject(forKey: key.stringValue)
                return .null
            }
            return .null

        case .arr(let box):
            if selector == "addObject" {
                box.items.append(arg0 ?? .null)
                return .null
            }
            if selector == "count" { return .num(Double(box.items.count)) }
            return .null

        case .jsContext(let js):
            switch selector {
            case "evaluateScript":
                let code = arg0?.stringValue ?? ""
                return .jsValue(js.evaluateScript(code))
            case "objectForKeyedSubscript":
                return .jsValue(js.objectForKeyedSubscript(arg0?.stringValue ?? ""))
            default:
                return .null
            }

        case .jsValue(let value):
            if selector == "callWithArguments", let args = arg0, case .arr(let box) = args {
                let natives = box.items.map { $0.jsNative }
                return .jsValue(value.call(withArguments: natives))
            }
            if selector == "toString" { return .str(value.toString() ?? "") }
            return .null

        case .classRef("JxdSecuritySub"):
            if selector == "Utf8Encoded", let input = arg0 {
                return .str(percentEncode(input.stringValue))
            }
            return .null

        case .null:
            // 对 null 调方法：containsString 语义为 false，其余 null
            if selector == "containsString" { return .bool(false) }
            return .null

        default:
            return .null
        }
    }

    // MARK: jxd_executeRegexRules

    /// 规则含 ` @=>`：替换模式（pattern @=>replacement，可空=删除）；
    /// 否则提取模式：返回第一个匹配（group 1 优先）。
    static func executeRegex(_ content: String, rule: String) -> DynValue {
        if let range = rule.range(of: " @=>") {
            let pattern = String(rule[rule.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let replacement = String(rule[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return .str(content) }
            let ns = content as NSString
            let result = regex.stringByReplacingMatches(
                in: content, range: NSRange(location: 0, length: ns.length),
                withTemplate: replacement)
            return .str(result)
        }
        guard let regex = try? NSRegularExpression(pattern: rule) else { return .null }
        let ns = content as NSString
        guard let match = regex.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) else {
            return .null
        }
        if match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            if range.location != NSNotFound { return .str(ns.substring(with: range)) }
        }
        return .str(ns.substring(with: match.range))
    }

    // MARK: format / calc

    private func evalFormat(_ inner: String) -> DynValue {
        var body = inner
        if body.hasSuffix(")") { body = String(body.dropLast()) }
        body = body.trimmingCharacters(in: .whitespaces)

        // 首个引号字符串 = 模板
        guard body.hasPrefix("\"") else { return .null }
        var template = ""
        var index = body.index(after: body.startIndex)
        while index < body.endIndex {
            let c = body[index]
            if c == "\\" && body.index(after: index) < body.endIndex {
                let next = body[body.index(after: index)]
                if next == "\"" || next == "\\" {
                    template.append(next)
                    index = body.index(after: body.index(after: index))
                    continue
                }
                template.append(c)
                index = body.index(after: index)
                continue
            }
            if c == "\"" { break }
            template.append(c)
            index = body.index(after: index)
        }
        let rest = body[index...].dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        let argExprs = rest.isEmpty ? [] : splitArgs(rest)

        var out = template
        for argExpr in argExprs {
            let value = evalExpr(argExpr)
            if let range = out.range(of: "%@") {
                out.replaceSubrange(range, with: formatValue(value))
            } else { break }
        }
        return .str(out)
    }

    private func splitArgs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        for c in text {
            if c == "\"" { inQuote.toggle(); current.append(c); continue }
            if inQuote { current.append(c); continue }
            if c == "(" || c == "[" { depth += 1 }
            if c == ")" || c == "]" { depth = max(0, depth - 1) }
            if c == "," && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func formatValue(_ value: DynValue) -> String {
        switch value {
        case .jsValue(let v): return v.toString() ?? ""
        default: return value.stringValue
        }
    }

    private func evalCalc(_ inner: String) -> DynValue {
        let expr = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        // 单运算符（左折叠）
        for op in ["+", "-", "*", "/"] where expr.contains(op) && !expr.hasPrefix(op) {
            if let range = expr.range(of: op, options: .literal) {
                // 找 depth0 的首个运算符（避免负号误切：跳过开头）
                let left = String(expr[expr.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let right = String(expr[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if left.isEmpty || right.isEmpty { continue }
                let l = numeric(evalAtom(left))
                let r = numeric(evalAtom(right))
                switch op {
                case "+": return .num(l + r)
                case "-": return .num(l - r)
                case "*": return .num(l * r)
                case "/": return r == 0 ? .num(0) : .num(l / r)
                default: break
                }
            }
        }
        return .num(numeric(evalAtom(expr)))
    }

    // MARK: 条件

    private func evalCond(_ raw: String) -> DynValue {
        let cond = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cond.hasPrefix("!") {
            let rest = String(cond.dropFirst()).trimmingCharacters(in: .whitespaces)
            return .bool(!truthy(evalExpr(rest)))
        }
        for op in ["<=", ">=", "<", ">", "=="] {
            if let range = cond.range(of: op, options: .literal) {
                let left = String(cond[cond.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let right = String(cond[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let l = numeric(evalAtom(left))
                let r = numeric(evalAtom(right))
                switch op {
                case "<=": return .bool(l <= r)
                case ">=": return .bool(l >= r)
                case "<": return .bool(l < r)
                case ">": return .bool(l > r)
                case "==": return .bool(l == r)
                default: break
                }
            }
        }
        return evalExpr(cond)
    }

    private func truthy(_ value: DynValue) -> Bool {
        switch value {
        case .null: return false
        case .bool(let b): return b
        case .num(let n): return n != 0
        case .str(let s): return !s.isEmpty
        case .arr(let box): return !box.items.isEmpty
        default: return true
        }
    }

    private func numeric(_ value: DynValue) -> Double {
        switch value {
        case .num(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .str(let s): return Double(s) ?? 0
        case .jsValue(let v): return Double(v.toString() ?? "") ?? 0
        default: return 0
        }
    }

    // MARK: 工具

    static func trimNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(format: "%g", n)
    }

    private func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }
}

// MARK: - DynValue 扩展

extension DynValue {
    /// 给 componentsSeparatedByString 用的数组包装。
    static func arr2(_ items: [DynValue]) -> DynValue {
        let box = DynArr()
        box.items = items
        return .arr(box)
    }

    var jsNative: Any {
        switch self {
        case .str(let s): return s
        case .num(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .arr(let box): return box.items.map { $0.jsNative }
        default: return NSNull()
        }
    }
}
