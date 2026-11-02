# 我的阅读（MyReader）

一个完全免费的 iOS 本地 / 网络小说阅读器，**完整复刻爱阅书香（iFreeTime）的 IBS 书源体系**：

- **完整兼容 .ibs 书源文件**：WinZip AES-256 解压 + 双层 AES-128-ECB 解密（含原版「全零 key」bug 的精确复刻），手机上「用其他应用打开」→ 选 MyReader → 自动解密导入为书源。
- **原生 IBS 规则引擎**：`@dyn:` 动态脚本解释器（def / rule.get / rule.put / check / calc / format / 方法链）、`@def:` JavaScript（JSContext）、`@ex:` XPath 选择器、`@str:` / `@regex:` / `@json:`，middleHandle 多级请求链、每节点独立 HTTP 头 / Cookie、`requestByWebView` 抓取。
- **多线程多书源并行搜索**：先到先显示 + 书名 / 作者精确模糊匹配 + 跨源聚合（同名同作者合并，N 个源任选）。
- **完整批量缓存**：整本 / 章节区间 / 仅补未缓存，4 并发下载 + 实时进度 + 失败重试。
- 本地 TXT / EPUB 导入、章节自动切分；阅读器 CoreText 分页、多主题、字号行距可调、本地 TTS 朗读（音色 / 语速 / 音调节，语速 0~100% 恒等映射、音调 0.5~1.5，对齐爱阅调节范围）。
- 没有任何会员、激励、广告、开屏。

## 1. 目录结构

```
MyReader/
├── project.yml                 # XcodeGen 工程描述（含 JavaScriptCore 依赖）
├── MyReader/
│   ├── Info.plist               # 已注册 .ibs 文件类型（打开方式可选本 App）
│   ├── App/                     # 入口、根视图
│   ├── Core/
│   │   ├── Models.swift         # IBSBookSource 规则树 / Book / Chapter / 设置
│   │   ├── Store.swift          # 书源持久化（SourceRecord = 解密 JSON 原文 + 元数据）
│   │   ├── Paths.swift / Fetcher.swift / HTMLParser.swift / LenientJSON.swift
│   │   ├── BookActions.swift / Importer.swift（.ibs / TXT / EPUB 导入）
│   │   ├── SearchManager.swift  # 多源并行搜索 + 跨源聚合
│   │   ├── CacheManager.swift   # 批量缓存（整本 / 区间 / 并发）
│   │   ├── EPUB.swift / Theme.swift
│   │   └── IBS/                 # ★ IBS 引擎核心
│   │       ├── IBSCrypto.swift      # WinZip AES + 双层 AES 解密
│   │       ├── DynCode.swift        # @dyn: 脚本解释器（8 类命令 + 对象图）
│   │       ├── RuleParser.swift     # 规则分发（@dyn/@def/@ex/@str/@regex/@json）
│   │       ├── ExSelector.swift     # @ex: 选择器（div[@class=x].li[0].a.@href）
│   │       ├── IBSEngine.swift      # 搜索/详情/目录/正文 四流程 + middleHandle 链
│   │       ├── HTTPClient.swift     # 动态头 / Cookie / GET / POST
│   │       └── WebViewFetcher.swift # WKWebView 抓取
│   ├── Reader/                  # 分页、阅读器、目录、设置、TTS
│   └── Features/                # 书架、发现（搜索聚合）、书源管理（JSON 编辑）、缓存
└── .github/workflows/ios-ipa.yml   # 云端出 unsigned IPA
```

## 2. .ibs 书源导入

**方式 A（推荐）**：手机「文件」/ 微信 / Safari 下载 .ibs → 长按 →「用其他应用打开」→ 选 MyReader → 自动解密导入 → 到「发现」搜索。

**方式 B**：书源管理页（发现页右上角）→ 导入按钮选 .ibs 文件。

解密链路（逆向自爱阅书香 6.8.5，逐指令验证）：
```
.ibs = WinZip AES-256 (AE-2) ZIP，固定密码（App 内算法生成）
  → configs.json = [{_passwordConfigs, _encodeConfigs}]
  → _passwordConfigs: AES-128-ECB(全零 key) → "authorId-密码"
  → _encodeConfigs: AES-128-ECB(MD5 前十六字符) → 书源 JSON（BookFixConfig 树）
```

## 3. IBS 规则引擎

书源 JSON 结构（解密后）：`searchBook / bookDetail / sourceDetail / chapterDetail` 四大规则节点，每个节点含 `url`（可为 `@dyn:` 脚本）、`params`、`parser`（字段→规则）、`middleHandle`（多级请求链）、`httpConfigs`（独立 headers / cookies）、`nextPageUrl`（翻页）。

规则前缀：`@dyn:` 动态脚本、`@def:` JavaScript、`@ex:` 选择器、`@str:` 字符串拼接、`@regex:` 正则、`@json:` 路径；规则值可为数组（组合规则，`contents[i]` 引用前序结果）。

`@dyn:` 脚本示例（真实书源）：
```
url=rule.get:cUrl;
kwN=def:null;
okCK=rule.get:ckok;
flagCK=okCK.containsString:kwN;
check(!okCK,flagCK=1);
check(flagCK<1,http.httpManager.requestSerializer setValue:okCK forHTTPHeaderField:Cookie);
return url
```

## 4. 出包与自签

见下文「出包」；GitHub Actions 跑 `Build unsigned IPA` → Artifact 下载 → Sideloadly / AltStore / Esign 自签安装。

## 5. 数据位置

`Documents/MyReader/`：`books.json`（书架）、`sources.json`（书源：解密 JSON 原文 + 启用状态）、`settings.json`、`Chapters/<bookID>/<章节号>.txt`（正文缓存）、`Covers/`、`Imported/`。开启文件共享可直接备份。

## 6. 已知边界

- `httpCreateCode`（书源自定义 Http 实例脚本）：解析保留，执行时仅应用其 headers 副作用。
- 书源编辑为 JSON 直接编辑（IBS 字段过多，表单不现实）；导出为明文 JSON 数组。
- 未签名 IPA 仅自签个人使用。
