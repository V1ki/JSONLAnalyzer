# JSONL Analyzer

macOS 原生（Swift / SwiftUI）的 JSONL 文件分析工具，面向 DSH / Codex 等会话日志，
也适用于任意 JSONL。

## 功能

- **会话扫描**：自动扫描 `~/.dsh/sessions`、`~/.codex/sessions` 与 `~/.claude/projects`，
  按 **workspace 分组**显示——Codex/Claude 从文件头提取真实 cwd（`"cwd":"..."` 键或
  旧版 `<cwd>` 文本；Claude 会话若有 `summary` 行还会用它当标题），DSH 从目录 slug 还原，
  用"去横杠小写"键合并，同一工程的 DSH / Codex / Claude 会话归入同组
  （实测 1.1 万文件 0.6s）。侧栏支持搜索 + **筛选**（来源 DSH/Codex/Claude、
  最近 24 小时/7/30/90 天）与 **排序**（分组按最近活动或名称；组内按修改时间/名称/大小），
  结果带缓存，万级文件即时响应；组内每行带来源标签；也支持把文件拖进窗口打开。
  Token 统计覆盖三家字段：`inputTokens`/`outputTokens`、`input_tokens`/`cached_input_tokens`
  （Codex）、`cache_read_input_tokens`/`cache_creation_input_tokens`（Claude）。
- **zstd 支持**：`.zstd` / `.zst` 文件自动解压到 `~/Library/Caches/JSONLAnalyzer/`
  （按路径+大小+mtime 哈希缓存，内容不变不重复解压）。需要系统里有 `zstd` 命令
  （brew install zstd）。
- **会话视图**：把 JSONL 还原成对话流——用户消息、LLM 回复、推理（折叠样式）、
  工具调用（名称 + call_id + pretty 参数）与工具输出（长内容默认截断可展开）、
  Turn/压缩等关键事件作分隔线。兼容 DSH / Codex / Claude 三种格式；
  点击条目的"行 N"标签跳到原始行（进返回栈）。反过来，详情区停在"会话"页时，
  在记录列表里选中一行（或 ⌘G 跳转），会话视图会滚到这一行对应的条目并高亮其行号标签
  （没有对应条目的行，如 token_count 事件，取行号最近的条目）。
- **Codex 专项处理**（依据 codex-rs 源码勘察）：
  - Token：只统计 `token_usage_record.payload.usage`（单次请求），跳过
    `token_count` 事件与 `compacted` 内嵌快照；混合总量按官方公式
    (input−cached)+output，Claude 口径自动切换（input 不含 cached）
  - 列表徽标带 `payload.type` 子类型（如 `response_item·function_call`）、
    顶层 `ordinal` 进序号列
  - 关联页：`call_id` 工具调用↔输出配对（含类型族校验）、turn 区间与压缩点、
    首行 `session_meta` 的 fork 来源（可在已扫描文件中打开父会话）
- **记录浏览**：三栏窗口。中间是逐行列表（行号 / 类型徽标 / 时间 / 大小 / 预览），
  支持按类型（多选）、关键字过滤（关键字是纯数字时同时匹配行号），可只看损坏行；
  **⌘G 跳转到行**（自动清除筛选、选中并滚动到目标行）；
  右侧格式化 + 语法高亮显示单条 JSON，
  **支持点击折叠/展开**（▾/▸ 标记在行首对齐；超过 300 行的记录打开时自动折叠到第一层；
  搜索时含匹配的折叠块自动展开），支持全部折叠/全部展开按钮与一键复制。
- **文本（Markdown）视图**：自动抽取选中行里的长文本字段（对象字段：含换行、长度 ≥ 60、
  或字段名为 text/content/message 等且长度 ≥ 8；数组内字符串元素需 ≥ 60，过滤流式逐词碎片），
  默认渲染最长的一条。渲染使用自研块级 Markdown 引擎（标题字号/列表圆点与编号/代码块底色/
  引用缩进/水平线，行内粗体、斜体、行内代码、链接交给 Foundation 行内解析）——
  Foundation 的 `.full` 解析不产出可显示的字体且会剥掉块间换行，无法直接用于文本视图。
  支持：字面 `\n` 自动转真实换行（双击转义场景，带徽标提示）、外层 XML 包裹标签
  （如 `<system-reminder>`）自动剥离、详情页搜索高亮（黄底标记 + 上/下一个跳转），
  多个文本字段可下拉切换，支持复制原文。
- **概览统计**：行数（有效/损坏）、类型分布条形图、时间范围、Token 用量合计。
- **字段探查**：递归聚合所有行的 key 路径（`a.b[*].c`），给出出现次数、频率
  （出现次数 ÷ 有效行数，数组元素路径可能超过 100%）、值类型、示例值，
  用于快速了解陌生 JSONL 的结构。
- **时间线分析**：按类型的事件散点图、`*/start`↔`*/end` 配对的区间时长、
  Token 用量随时间曲线。
- **sequence 关联（DSH）**：详情区"关联"标签页展示当前记录的引用关系——
  入向（哪些行引用了当前 seq）与出向（当前行引用了哪些 seq、对应到哪一行）。
  字段识别规则（键名规范化后按后缀）：`*Seq` 单值、`*Seqs` 数组、`seq_from`/`seq_to`
  同层配对展开为范围（跨度 ≤ 1000），根级 `seq` 视为自身序号不计引用。
  点击任一关联项跳转到对应行并压入返回栈，顶栏"返回"逐层回退（最多 200 层）。

通用性规则（自动识别，无需配置）：

| 项目 | 识别顺序 |
| --- | --- |
| 类型字段 | `type` → `record_type` → `event` |
| 时间字段 | `time` / `timestamp` / `ts` / `createdAt` / `created_at`（毫秒、秒、ISO8601 自动判断） |
| Token 字段 | 递归查找 `inputTokens` / `output_tokens` / `cached_input_tokens` 等叶子；同一记录内取最小值（单次请求口径，避免 Codex 的 turn/thread 累计字段膨胀统计） |

## 构建与运行

```bash
cd JSONLAnalyzer
swift build            # 开发调试
swift test             # 单元测试（52 个）
./make-app.sh          # 生成 release 并打包 "JSONL Analyzer.app"（ad-hoc 签名，可双击）
```

双击 `JSONL Analyzer.app`，或在 Finder 里把 `.jsonl` / `.zstd` 拖到 App 图标上打开。

## 命令行模式（顺手可用，非主打）

```bash
.build/release/JSONLAnalyzer --stats  <file>        # 概览：行数/类型分布/时间/Token
.build/release/JSONLAnalyzer --fields <file>        # 概览 + 前 60 个字段路径与频率
.build/release/JSONLAnalyzer --line   <file> <n>    # 调试：打印第 n 行抽取到的文本字段
```

## 性能说明

- 侧栏只枚举文件元数据（本机 1.1 万个会话文件约 0.6 秒）。
- 选中文件才解析；流式逐行读取。每行只做一次 JSON 解析，字段聚合、Token 扫描与
  sequence 引用扫描合并在一次遍历里完成（`LineScanner`）。本机实测（release）：
  Codex 58 MB ≈ 0.5 秒，Claude 108 MB ≈ 1.0 秒，DSH 138 MB ≈ 1.6 秒。
  耗时主要取决于节点数而不是字节数——DSH 的行嵌套更深、节点更多，相对更慢。
- 列表只保存每行的偏移与摘要，点击查看详情时再按偏移回读原文，
  100 MB 级文件内存占用为行索引级别。
- 会话视图逐行回读、建完条目就丢掉解析树，内存只与条目正文总量有关，不随文件大小增长。
- 文本视图的抽取结果与 Markdown 渲染结果按行缓存，搜索时不再重复读取和渲染。

## 目录结构

```
Sources/JSONLAnalyzer/
  App.swift                 入口：SwiftUI App、AppModel、--stats/--fields 等 CLI、菜单命令
  Model/
    JsonlFile.swift         文件访问层：zstd 解压缓存、LineReader 流式逐行 + 偏移回读
    Analysis.swift          LineParser 单行解析、LineScanner 单次遍历扫描（字段 / Token / sequence）、时长配对
    RecordStore.swift       单文件解析状态机（后台解析、增量发布、过滤）
    SessionStore.swift      ~/.dsh、~/.codex、~/.claude 会话扫描与分组
    Conversation.swift      把 JSONL 还原成对话流（批量与流式两种构建方式）
    TextExtractor.swift     从一条记录里抽取适合按 Markdown 阅读的长文本字段
    MarkdownRenderer.swift  轻量块级 Markdown 渲染器
    JsonHighlighter.swift   JSON 语法着色 + NSTextView 封装
  Views/                    三栏窗口、侧栏、记录列表、详情（会话/记录/关联/文本/概览/字段/时间线）
Tests/JSONLAnalyzerTests/   解析、扫描、读取器、会话还原、缓存与加载状态机的单元测试
make-app.sh                 打包 .app
```

## 已知限制

- 类型徽标取前 8 类进入时间线散点图，其余类型不显示在该图中。
- Token 曲线最多采集 5000 个采样点；字段聚合深度限制 8 层、数组采样前 100 个元素。
- `.zstd` 依赖系统 `zstd` 命令；未安装时会给出明确错误提示。
