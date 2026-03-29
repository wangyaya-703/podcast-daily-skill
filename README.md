# podcast-daily-skill

播客日报 v2：把重计算放到 GitHub Actions，Luna 端只做轻量飞书推送。

## 架构

### 内容生产（GitHub Actions）

`bash scripts/podcast-daily.sh` 每日生成并提交：

- `feed-podcasts.json`：摘要 + 元数据
- `transcripts/YYYY-MM-DD/*.md`：双语对照原文
- `state-feed.json`：处理去重状态

核心能力：

- RSS 新集探测（11 个默认播客，可自定义）
- 转录获取（YouTube 字幕优先）
- 修复缓存错配：缓存键升级为 `key + title_hash`
- 连续重复段落去重
- 段落级双语翻译（英中交替）
- 结构化摘要（核心观点、金句、PM 洞察、推荐等级）

### 推送（Luna / OpenClaw）

`bash scripts/feishu-send.sh --feed <path-or-url>`：

- 读取 `feed-podcasts.json`
- 按未推送集创建飞书文档（由 Markdown 转 block）
- 发送飞书互动卡片（含“查看播客追踪表”按钮）
- 可选写入多维表格
- 本地状态去重（默认 `.feishu-push-state.json`）

## 快速开始

### 1) 本地准备

```bash
git clone https://github.com/wangyaya-703/podcast-daily-skill.git
cd podcast-daily-skill
pip install yt-dlp
```

### 2) 生产端环境变量（Actions）

必填：

- `ARK_API_KEY`

可选：

- `ARK_BASE_URL`（默认 `https://ark.cn-beijing.volces.com/api/coding/v3`）
- `ARK_ENDPOINT`（默认 `${ARK_BASE_URL}/chat/completions`）
- `TRANSLATE_MODEL`（默认 `doubao-seed-2.0-lite`）
- `SUMMARY_MODEL`（默认 `glm-4.7`）
- `PODCAST_CONFIG`（自定义播客配置 JSON）

### 3) 运行内容生产

```bash
bash scripts/podcast-daily.sh
```

### 4) 运行飞书推送

必填：

- `FEISHU_APP_ID`
- `FEISHU_APP_SECRET`
- `FEISHU_RECEIVER`

可选：

- `BITABLE_APP_TOKEN`
- `BITABLE_TABLE_ID`
- `RAW_BASE_URL`（feed 中 transcript 路径的 raw 前缀）

```bash
bash scripts/feishu-send.sh --feed ./feed-podcasts.json
# 或
bash scripts/feishu-send.sh --feed https://raw.githubusercontent.com/<owner>/<repo>/main/feed-podcasts.json --raw-base-url https://raw.githubusercontent.com/<owner>/<repo>/main
```

## GitHub Actions

仓库已包含：`.github/workflows/podcast-daily.yml`

- 定时：每天 `09:00 UTC`
- 手动：`workflow_dispatch`
- 自动提交产出文件到 `main`

需要在 GitHub Secrets 配置：

- `ARK_API_KEY`

## 配置文件

- `podcasts.example.json`：播客源模板
- `prompts/summarize-podcast.md`：摘要 prompt
- `prompts/translate-bilingual.md`：翻译 prompt

## 数据格式

`feed-podcasts.json` 示例结构：

```json
{
  "generatedAt": "2026-03-29T09:00:00Z",
  "date": "2026-03-29",
  "episodes": [
    {
      "id": "LexFridman_a1b2c3d4",
      "key": "LexFridman",
      "name": "Lex Fridman Podcast",
      "title": "#494 – Jensen Huang ...",
      "recommendation": "P1",
      "summary": {
        "key_points": ["..."],
        "golden_quotes": ["..."],
        "pm_insights": ["..."]
      },
      "transcript": {
        "bilingualUrl": "transcripts/2026-03-29/LexFridman.md"
      }
    }
  ]
}
```

## 说明

- `state-feed.json` 是生产端去重状态，应提交到仓库。
- `.feishu-push-state.json` 是推送端本地状态，不应提交。
