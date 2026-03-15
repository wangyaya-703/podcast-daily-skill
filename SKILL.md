---
name: podcast-daily
description: "Automated podcast daily digest workflow: RSS monitoring, audio transcription (YouTube subtitles + Volcengine ASR), AI-powered translation and summarization (Volcengine Doubao/Ark), Feishu/Lark message delivery and document archiving, and Bitable (multi-dimensional table) tracking. Use this skill when the user wants to set up a podcast monitoring pipeline, generate podcast summaries, send daily podcast digests via Feishu, manage podcast records in a spreadsheet/database, or automate any podcast-related workflow. Also trigger when the user mentions: podcast transcription, RSS feed processing, Feishu document creation, podcast recommendation ranking, or bilingual transcript generation."
---

# Podcast Daily Digest Skill

Automated daily podcast monitoring and summarization pipeline with Feishu/Lark integration.

## What This Skill Does

This skill provides a complete end-to-end podcast digest workflow:

1. **RSS Monitoring** — Polls 11+ podcast RSS feeds for new episodes within configurable time windows
2. **Transcription** — Obtains transcripts via YouTube subtitles (free, fast) or Volcengine BigASR (fallback)
3. **AI Processing** — Cleans, segments, translates (EN→ZH), generates structured summaries with golden quotes, PM insights, and recommendation levels (P0/P1/P2)
4. **Feishu Delivery** — Sends daily digest message + creates structured bilingual documents with chapter headings, highlighted segments, and Q/A formatting
5. **Bitable Tracking** — Writes episode records to a Feishu Bitable (multi-dimensional table) with fields for podcast name, title, guest, date, recommendation level, summary, PM insights, quotes, and links
6. **Deduplication** — Three-layer dedup: source-level (cross-day title check), transcript cache (reuse across days), and processed JSON cache (skip re-processing)

## Architecture

```
podcast-daily.sh (orchestrator)
├── parse_rss.py          — RSS XML parsing, time window filtering
├── extract_vtt.py        — YouTube VTT subtitle dedup + timed JSONL output
├── process-transcript.py — Clean → Segment → Translate → Summarize → Tag
└── feishu-send.sh        — Feishu message + document + bitable integration
```

## Prerequisites

### Required Environment Variables

All secrets must be set as environment variables. **Never hardcode secrets.**

| Variable | Description | Where to get |
|---|---|---|
| `FEISHU_APP_ID` | Feishu app ID | [Feishu Open Platform](https://open.feishu.cn/) |
| `FEISHU_APP_SECRET` | Feishu app secret | Feishu Open Platform |
| `FEISHU_RECEIVER` | Recipient's open_id | Feishu API |
| `ARK_API_KEY` | Volcengine Ark API key | [Volcengine Console](https://console.volcengine.com/) |
| `ARK_ENDPOINT` | Ark API endpoint URL | Provider's API docs |
| `BITABLE_APP_TOKEN` | Feishu Bitable app token | Create a Bitable, get from URL |
| `BITABLE_TABLE_ID` | Feishu Bitable table ID | Create a table, get from URL |

### Optional Environment Variables

| Variable | Default | Description |
|---|---|---|
| `VOLC_APPID` | _(none)_ | Volcengine ASR app key (for audio fallback) |
| `VOLC_TOKEN` | _(none)_ | Volcengine ASR access key |
| `TRANSLATE_MODEL` | `doubao-seed-2-0-mini-260215` | Ark model for translation |
| `SUMMARY_MODEL` | `doubao-seed-2-0-mini-260215` | Ark model for summarization |
| `RECOMMEND_MODE` | `ai` | `ai` or `keywords` for recommendation tagging |
| `FEISHU_USER_ID` | _(none)_ | Additional user ID for metadata |

### Required Feishu App Permissions

The Feishu app needs these scopes:
- `im:message:send_as_bot` — Send messages
- `docx:document` — Create/edit documents
- `drive:drive` — File permissions
- `bitable:app` — Read/write Bitable

### System Dependencies

- `python3` (3.8+)
- `bash` (3.2+ compatible, no bash 4+ features used)
- `yt-dlp` — For YouTube subtitle extraction
- `curl` — For RSS fetching

## Setup Instructions

### Step 1: Install the skill scripts

Copy all files from `scripts/` to your working directory (e.g., `~/podcast-workflow/scripts/`):

```bash
SKILL_DIR="<path-to-this-skill>/scripts"
TARGET_DIR="~/podcast-workflow/scripts"
mkdir -p "$TARGET_DIR"
cp "$SKILL_DIR"/*.sh "$SKILL_DIR"/*.py "$TARGET_DIR/"
chmod +x "$TARGET_DIR"/*.sh
```

### Step 2: Configure environment variables

Create a `.env` file (do NOT commit this file):

```bash
export FEISHU_APP_ID="your_app_id"
export FEISHU_APP_SECRET="your_app_secret"
export FEISHU_RECEIVER="recipient_open_id"
export ARK_API_KEY="your_ark_api_key"
export BITABLE_APP_TOKEN="your_bitable_app_token"
export BITABLE_TABLE_ID="your_bitable_table_id"
# Optional
export VOLC_APPID="your_volc_appid"
export VOLC_TOKEN="your_volc_token"
```

### Step 3: Create Feishu Bitable

Create a Bitable with these fields:
- 播客名称 (Text)
- 集标题 (Text)
- 嘉宾 (Text)
- 日期 (Date)
- 推荐等级 (Single Select: P0 特别推荐 / P1 一般推荐 / P2 空闲再看)
- 核心摘要 (Text)
- PM Insights (Text)
- 精彩金句 (Text)
- 原文文档 (URL)
- 播客链接 (URL)

### Step 4: Set up cron job (optional)

```bash
# Run daily at 17:00
0 17 * * * source ~/.env && bash ~/podcast-workflow/scripts/podcast-daily.sh >> ~/podcast-daily.log 2>&1
```

### Step 5: Test run

```bash
source .env
bash scripts/podcast-daily.sh --test
```

## Customizing Podcast Subscriptions

Edit the arrays at the top of `podcast-daily.sh`:
- `PODCAST_KEYS` — Internal keys (no spaces)
- `PODCAST_URLS` — RSS feed URLs
- `PODCAST_DISPLAY` — Display names
- `PODCAST_HOURS` — Time window per feed (hours)
- `PODCAST_YOUTUBE` — YouTube channel URLs (empty string if none)

## How the AI Processing Works

The `process-transcript.py` script performs these steps:

1. **Clean** — Strip HTML, timestamps, noise markers
2. **Segment** — Split into ~500-char segments at sentence boundaries
3. **Detect Q/A** — Mark segments as Question or Answer
4. **Chapter mapping** — Align segments to YouTube chapters via timed subtitle data
5. **Translate** — Batch translate EN→ZH (10 segments per batch, ~60 API calls for a typical episode)
6. **Summarize + Tag** — Single API call generates: recommendation level (P0/P1/P2), core summary, key insights, golden quotes, PM insights, recommended tools
7. **Highlight** — Match golden quotes back to source segments for visual highlighting

## Cost Optimization

- Translation uses `doubao-seed-2-0-mini` (128K context, low cost)
- Summary + recommendation merged into single API call (saves 1 call/episode)
- Batch size of 10 segments halves translation API calls
- Three-layer caching prevents redundant processing
- YouTube subtitles are free; ASR is only used as fallback
