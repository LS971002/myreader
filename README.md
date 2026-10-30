# 我的阅读（MyReader）

一个完全免费的 iOS 本地 / 网络小说阅读器，参考「爱阅书香」的使用习惯重新实现：

- **没有任何会员、激励、试用、广告 SDK**。主题、朗读、导出、多书源等全部常驻开启。
- **没有开屏广告、没有开屏格言**，启动直接进书架。
- 自带书源规则引擎（CSS 选择器 + `@` 动作链 + XPath 子集），可导入自己的 JSON 书源。
- 支持本地 TXT / EPUB 导入、章节自动切分、离线缓存。
- 阅读器：CoreText 精确分页、7 套主题、字号行距段距可调、5 种翻页方式、TTS 朗读、书签与进度记忆。

## 1. 目录结构

```
MyReader/
├── project.yml                 # XcodeGen 工程描述
├── MyReader/
│   ├── Info.plist
│   ├── App/                    # 入口、Tab 根视图
│   ├── Core/                   # 数据模型、存储、网络、规则引擎、导入
│   │   ├── Models.swift        # Book / Chapter / BookSource / AppSettings
│   │   ├── Store.swift         # JSON 持久化的全局仓库
│   │   ├── Paths.swift         # 沙盒路径
│   │   ├── HTMLParser.swift    # 容错 HTML → DOM
│   │   ├── Selector.swift      # CSS / XPath 子集
│   │   ├── RuleEngine.swift    # 规则求值
│   │   ├── Fetcher.swift       # 网络 + 编码识别（UTF-8/GBK/Big5）
│   │   ├── BookSourceEngine.swift
│   │   ├── EPUB.swift          # 内置 ZIP 解包 + OPF 解析
│   │   ├── Importer.swift      # TXT / EPUB / 书源导入
│   │   └── LenientJSON.swift   # 缺字段自动补默认值
│   ├── Reader/                 # 分页、阅读器、目录、设置、TTS
│   └── Features/               # 书架、发现、我的、书源管理
└── .github/workflows/ios-ipa.yml   # 云端出 unsigned IPA
```

## 2. 出包（Windows 上也能做）

本机是 Windows，没法直接跑 Xcode。有两条路：

### A. GitHub Actions（推荐）

1. 新建一个空仓库，把 `MyReader/` 目录内容推上去（`.github/workflows/ios-ipa.yml` 必须在仓库根目录）。
2. 打开 Actions → `Build unsigned IPA` → Run workflow。
3. 跑完在 Artifact 里下载 `MyReader-unsigned-ipa`，解压得到 `MyReader-unsigned.ipa`（未签名）。

### B. macOS 本机

```bash
brew install xcodegen
cd MyReader
xcodegen generate
xcodebuild -project MyReader.xcodeproj -scheme MyReader -configuration Release \
  -sdk iphoneos -archivePath build/MyReader.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO
mkdir -p build/Payload && cp -R build/MyReader.xcarchive/Products/Applications/MyReader.app build/Payload/
cd build && zip -qry MyReader-unsigned.ipa Payload
```

想直连真机调试，也可以直接用 Xcode 打开工程，把 Signing Team 换成你自己的账号（免费账号 7 天有效，付费开发者 1 年）。

## 3. 用自己的证书自签

`MyReader-unsigned.ipa` 需要一个签名工具把**你的证书 + 描述文件**塞进去：

| 工具 | 平台 | 说明 |
| --- | --- | --- |
| Sideloadly | Win/Mac | 选 ipa → 填 Apple ID → Start，最省事 |
| AltStore | Win/Mac | 需装 AltServer，7 天自动续签 |
| Esign / zsign | iOS / CLI | 选 ipa + `.p12` + `.mobileprovision`，直接签 |
| ios-deploy / Xcode | Mac | `codesign -f -s "证书名" --entitlements ent.plist MyReader.app` |

命令行签名（Mac）：

```bash
unzip MyReader-unsigned.ipa -d work && cd work
codesign -f -s "iPhone Developer: Your Name (XXXXXXXXXX)" \
  --entitlements MyReader.entitlements Payload/MyReader.app
zip -qry ../MyReader-signed.ipa Payload
```

> Bundle ID 要和你描述文件里的一致。默认是 `com.example.myreader`，改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 后重新出包，或者签名时改 Info.plist 的 `CFBundleIdentifier`。

## 4. 书源规则怎么写

规则 = `选择器` + `@动作链`，例如：

```
div.result-list li            搜索结果列表
div.result-list li a@href@abs 详情链接（自动补全域名）
h1@text                       书名
#intro@html2text              简介（保留换行）
#list dd a@href@abs           章节链接
#content@html2text            正文
```

可用动作：`@text`、`@html`、`@ownText`、`@attr(名字)`、`@abs`、`@trim`、`@html2text`、
`@regex(正则,组号)`、`@replace(旧||新)`、`@index(n)`、`@firstline`、`@lastline`。

XPath 子集也支持：`//div[@class="list"]/ul/li[2]/a/text()`。
JSON 接口用 `json:data.books[*].title`。

书源 JSON 字段名与 `Core/Models.swift` 里的 `BookSource` 一一对应，
不认识/缺失的字段会自动补默认值，所以别人导出的书源大多能直接吃。

## 5. 数据位置

所有数据在 `Documents/MyReader/` 下（Info.plist 已开 `UIFileSharingEnabled`）：

```
books.json  sources.json  settings.json  bookmarks.json
Chapters/<bookID>/<章节号>.txt
Covers/<bookID>.jpg
Imported/<bookID>.txt|.epub
```

用「文件」App 或 iTunes 文件共享可以直接把整个目录拷出来备份。

## 6. 已知边界

- 只做了阅读器本身，没有做书城推荐、评论、社交分享（这些都需要后端服务）。
- 书源规则没有实现 JS 脚本（`@js:`）与 `@dyn` 动态 UA，遇到强反爬站点需要按站点改规则。
- EPUB 支持 spine + OPF，内嵌样式会被丢弃（纯文本重排更适合手机阅读）。
- 未签名 IPA 无法上架 App Store，仅自签个人使用。
