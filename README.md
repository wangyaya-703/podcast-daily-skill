# podcast-daily-skill

[中文](#中文) | [English](#english)

---

## 中文

### 这是什么？

一个 **Claude Code Skill**，实现播客日报全自动化工作流：

> RSS 监控 → 字幕转录 → AI 翻译摘要 → 飞书推送 → 多维表格归档

每天自动帮你追踪英文播客更新，生成中文深度摘要（含金句、PM Insight、推荐等级），推送到飞书，同时写入多维表格方便检索。

### 核心能力

| 能力 | 说明 |
|---|---|
| RSS 监控 | 支持自定义播客列表，可配置时间窗口 |
| 转录 | 优先 YouTube 字幕（免费），备选火山引擎 ASR |
| AI 翻译 | 英→中 批量翻译（10段/批，成本优化） |
| AI 摘要 | 核心观点 + 精彩金句 + PM Insight + 推荐等级（P0/P1/P2） |
| 飞书推送 | 日报消息 + 结构化文档（章节标题、高亮段落、Q/A 格式） |
| 多维表格 | 自动写入 Bitable，支持按等级/日期/播客筛选 |
| 三层去重 | 源级去重 + 转录缓存 + 处理结果缓存，杜绝重复推送 |

### 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/wangyaya-703/podcast-daily-skill.git
cd podcast-daily-skill

# 2. 配置环境变量（复制模板后填入你的密钥）
cp .env.example .env
# 编辑 .env，填入飞书 App ID/Secret、ARK API Key 等

# 3. 测试运行（跳过转录，仅验证 RSS + 飞书连通性）
source .env && bash scripts/podcast-daily.sh --test

# 4. 正式运行
source .env && bash scripts/podcast-daily.sh
```

### 自定义播客列表

复制模板，按需增删播客：

```bash
cp podcasts.example.json podcasts.json
```

每个播客只需填写：

```json
{
  "key": "MyPodcast",
  "name": "我喜欢的播客",
  "rss": "https://example.com/feed/rss",
  "hours": 168,
  "youtube": "https://www.youtube.com/@mypodcast"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `key` | 是 | 内部标识符（英文无空格，用于缓存文件名） |
| `name` | 是 | 显示名称（飞书消息和表格中展示） |
| `rss` | 是 | RSS 订阅地址 |
| `hours` | 否 | 时间窗口，默认 168 小时（7天） |
| `youtube` | 否 | YouTube 频道地址（有则优先抓免费字幕） |

**追加播客**：打开 `podcasts.json`，在 `podcasts` 数组末尾加一个条目即可，无需改任何代码。

**配置文件查找顺序**：`PODCAST_CONFIG` 环境变量 → 工作目录下 `podcasts.json` → 内置默认列表（11个播客）

### 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `FEISHU_APP_ID` | 是 | 飞书应用 App ID |
| `FEISHU_APP_SECRET` | 是 | 飞书应用 App Secret |
| `FEISHU_RECEIVER` | 是 | 接收者的 open_id |
| `ARK_API_KEY` | 是 | 火山引擎方舟 API Key |
| `ARK_ENDPOINT` | 是 | 方舟 API 地址 |
| `BITABLE_APP_TOKEN` | 否 | 飞书多维表格 app_token |
| `BITABLE_TABLE_ID` | 否 | 飞书多维表格 table_id |
| `VOLC_APPID` | 否 | 火山引擎 ASR App Key |
| `VOLC_TOKEN` | 否 | 火山引擎 ASR Access Key |

### 架构

```
podcast-daily.sh          # 主调度脚本（cron 定时触发）
├── parse_rss.py          # RSS 解析 → 最新一集元信息
├── extract_vtt.py        # YouTube VTT 字幕去重 + 时间戳 JSONL
├── process-transcript.py # 清洗 → 分段 → 翻译 → 摘要 → 打标
└── feishu-send.sh        # 飞书消息 + 文档 + 多维表格写入
```

### 定时任务（可选）

```bash
# 每天 17:00 自动运行
0 17 * * * source ~/.env && bash ~/podcast-workflow/scripts/podcast-daily.sh >> ~/podcast-daily.log 2>&1
```

### Fork 后如何配置

1. Fork 本仓库
2. 创建 `.env` 文件（已在 `.gitignore` 中，不会被提交）
3. 创建 `podcasts.json` 自定义你的播客列表
4. 按需修改 `process-transcript.py` 中的摘要 prompt（如果你不是产品经理角色）
5. 设置 cron 定时任务

> 详细配置说明见 [SKILL.md](SKILL.md)

---

## English

### What is this?

A **Claude Code Skill** that automates a daily podcast digest workflow:

> RSS monitoring → Transcription → AI translation & summarization → Feishu/Lark delivery → Bitable tracking

It automatically tracks English podcast updates, generates Chinese summaries (with golden quotes, PM insights, and recommendation levels), delivers them via Feishu, and archives everything in a Bitable.

### Key Features

| Feature | Description |
|---|---|
| RSS Monitoring | Customizable podcast list with configurable time windows |
| Transcription | YouTube subtitles (free) with Volcengine ASR fallback |
| AI Translation | EN→ZH batch translation (10 segments/batch, cost-optimized) |
| AI Summary | Key insights + golden quotes + PM insights + P0/P1/P2 levels |
| Feishu Delivery | Daily digest message + structured docs (chapters, highlights, Q/A) |
| Bitable | Auto-writes to Feishu Bitable for filtering by level/date/podcast |
| Deduplication | Three-layer dedup: source-level + transcript cache + processed cache |

### Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/wangyaya-703/podcast-daily-skill.git
cd podcast-daily-skill

# 2. Configure environment variables
cp .env.example .env
# Edit .env with your Feishu App ID/Secret, ARK API Key, etc.

# 3. Test run (skips transcription, validates RSS + Feishu connectivity)
source .env && bash scripts/podcast-daily.sh --test

# 4. Full run
source .env && bash scripts/podcast-daily.sh
```

### Custom Podcast List

```bash
cp podcasts.example.json podcasts.json
```

Each podcast entry:

```json
{
  "key": "MyPodcast",
  "name": "My Favorite Podcast",
  "rss": "https://example.com/feed/rss",
  "hours": 168,
  "youtube": "https://www.youtube.com/@mypodcast"
}
```

| Field | Required | Description |
|---|---|---|
| `key` | Yes | Internal ID (no spaces, used for cache filenames) |
| `name` | Yes | Display name in digest messages and Bitable |
| `rss` | Yes | RSS feed URL |
| `hours` | No | Lookback window in hours (default: 168 = 7 days) |
| `youtube` | No | YouTube channel URL for free subtitle extraction |

**Adding a podcast**: Open `podcasts.json`, append a new entry to the `podcasts` array. No code changes needed.

**Config lookup order**: `PODCAST_CONFIG` env var → `podcasts.json` in workspace → built-in defaults (11 podcasts)

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `FEISHU_APP_ID` | Yes | Feishu app ID |
| `FEISHU_APP_SECRET` | Yes | Feishu app secret |
| `FEISHU_RECEIVER` | Yes | Recipient's open_id |
| `ARK_API_KEY` | Yes | Volcengine Ark API key |
| `ARK_ENDPOINT` | Yes | Ark API endpoint URL |
| `BITABLE_APP_TOKEN` | No | Feishu Bitable app_token |
| `BITABLE_TABLE_ID` | No | Feishu Bitable table_id |
| `VOLC_APPID` | No | Volcengine ASR app key |
| `VOLC_TOKEN` | No | Volcengine ASR access key |

### Architecture

```
podcast-daily.sh          # Main orchestrator (cron-triggered)
├── parse_rss.py          # RSS XML → latest episode metadata
├── extract_vtt.py        # YouTube VTT → deduplicated text + timed JSONL
├── process-transcript.py # Clean → Segment → Translate → Summarize → Tag
└── feishu-send.sh        # Feishu message + document + bitable write
```

### Fork & Configure

1. Fork this repo
2. Create `.env` (already in `.gitignore`, won't be committed)
3. Create `podcasts.json` to customize your podcast list
4. Optionally edit the summary prompt in `process-transcript.py` (default is tailored for product managers)
5. Set up a cron job for daily execution

> See [SKILL.md](SKILL.md) for detailed setup instructions.

---

## License

MIT
