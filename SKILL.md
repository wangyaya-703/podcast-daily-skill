---
name: podcast-daily
description: "播客日报 v2：GitHub Actions 负责 RSS/转录/翻译/摘要生产，Luna 端只做 feed 驱动的飞书推送（卡片 + 文档 + 多维表格）。当用户要搭建播客监控、双语转录、日报推送、飞书自动化时使用。"
---

# Podcast Daily Skill (v2)

## 能力概览

本技能将播客日报拆为两段：

1. 生产端（GitHub Actions）：`scripts/podcast-daily.sh`
- RSS 发现新集
- 获取字幕并转录
- 连续重复段去重
- 段落级英中翻译
- 中文结构化摘要
- 产出 `feed-podcasts.json`、`transcripts/*`、`state-feed.json`

2. 推送端（Luna/OpenClaw）：`scripts/feishu-send.sh`
- 读取 feed（本地文件或 GitHub raw URL）
- 从 Markdown 创建飞书文档
- 推送互动卡片（含追踪表按钮）
- 写入多维表格（可选）
- 本地去重（`.feishu-push-state.json`）

## 关键修复

- 转录缓存错配修复：缓存键从 `key` 升级为 `key + title_hash`
- heartbeat 超时规避：耗时链路迁移到 Actions
- 转录重复段修复：清洗阶段去除连续重复段

## 目录结构

- `scripts/podcast-daily.sh`：生产主脚本
- `scripts/process-transcript.py`：清洗/翻译/摘要/Markdown
- `scripts/feishu-send.sh`：feed 到飞书
- `prompts/summarize-podcast.md`
- `prompts/translate-bilingual.md`
- `.github/workflows/podcast-daily.yml`
- `feed-podcasts.json`
- `state-feed.json`
- `transcripts/`

## 环境变量

### 生产端必填

- `ARK_API_KEY`

### 生产端可选

- `ARK_BASE_URL`（默认 `https://ark.cn-beijing.volces.com/api/coding/v3`）
- `ARK_ENDPOINT`（默认 `${ARK_BASE_URL}/chat/completions`）
- `TRANSLATE_MODEL`（默认 `doubao-seed-2.0-lite`）
- `SUMMARY_MODEL`（默认 `glm-4.7`）
- `PODCAST_CONFIG`（自定义播客配置）

### 推送端必填

- `FEISHU_APP_ID`
- `FEISHU_APP_SECRET`
- `FEISHU_RECEIVER`

### 推送端可选

- `BITABLE_APP_TOKEN`
- `BITABLE_TABLE_ID`
- `RAW_BASE_URL`
- `TRACKING_URL`

## 常用命令

```bash
# 生产端（建议在 GitHub Actions）
bash scripts/podcast-daily.sh

# 推送端（本地文件）
bash scripts/feishu-send.sh --feed ./feed-podcasts.json

# 推送端（GitHub raw）
bash scripts/feishu-send.sh \
  --feed https://raw.githubusercontent.com/<owner>/<repo>/main/feed-podcasts.json \
  --raw-base-url https://raw.githubusercontent.com/<owner>/<repo>/main
```

## 注意事项

- `state-feed.json` 需要提交到仓库（生产去重状态）。
- `.feishu-push-state.json` 为本地推送状态，不应提交。
- 推送脚本的 Markdown→文档采用“分段 + 50 块批量 + 限流重试”策略，参考了 `feishu-cli` 的导入设计。
