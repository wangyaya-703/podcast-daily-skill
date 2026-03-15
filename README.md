# podcast-daily-skill

Claude Code skill: 播客日报自动化工作流

每日自动监控 11+ 英文播客 RSS → YouTube 字幕转录 → AI 翻译摘要 → 飞书推送日报 + 文档存档 + 多维表格追踪

## Features

- RSS feed monitoring with configurable time windows
- YouTube subtitle extraction (free) with Volcengine ASR fallback
- AI-powered EN→ZH translation (batch mode, cost-optimized)
- Structured summaries with PM insights, golden quotes, recommendation levels (P0/P1/P2)
- Feishu/Lark message delivery with rich document archiving (chapters, highlights, Q/A formatting)
- Bitable (multi-dimensional table) for episode tracking and filtering
- Three-layer deduplication (source-level, transcript cache, processed JSON cache)

## Quick Start

1. Copy `scripts/` to your working directory
2. Copy `.env.example` to `.env` and fill in your credentials
3. Run: `source .env && bash scripts/podcast-daily.sh --test`

See [SKILL.md](SKILL.md) for detailed setup instructions.

## Architecture

```
podcast-daily.sh          # Main orchestrator (cron-triggered)
├── parse_rss.py          # RSS XML → latest episode metadata
├── extract_vtt.py        # YouTube VTT → deduplicated text + timed JSONL
├── process-transcript.py # Clean → Segment → Translate → Summarize → Tag
└── feishu-send.sh        # Feishu message + document + bitable write
```

## License

MIT
