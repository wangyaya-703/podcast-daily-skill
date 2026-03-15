#!/usr/bin/env bash
# podcast-daily.sh — 每日播客摘要抓取 + 转录存档 + 飞书推送
# 使用方式: bash podcast-daily.sh [--test]
#
# 必需环境变量:
#   FEISHU_APP_ID, FEISHU_APP_SECRET, FEISHU_RECEIVER
# 可选环境变量:
#   VOLC_APPID, VOLC_TOKEN, FEISHU_USER_ID

set -euo pipefail

# 确保 yt-dlp 在 PATH 中（pip 用户安装路径）
export PATH="$HOME/Library/Python/3.9/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$WORKSPACE_DIR/.podcast-cache"
LOG_FILE="$WORKSPACE_DIR/podcast-daily.log"
TODAY=$(date +%Y-%m-%d)
TODAY_DISPLAY=$(python3 -c "from datetime import date; d=date.today(); print(f'{d.month}月{d.day}日')")
TEST_MODE="${1:-}"

# 环境变量检查
if [[ -z "${FEISHU_APP_ID:-}" || -z "${FEISHU_APP_SECRET:-}" || -z "${FEISHU_RECEIVER:-}" ]]; then
  echo "错误: 请设置 FEISHU_APP_ID, FEISHU_APP_SECRET, FEISHU_RECEIVER 环境变量" >&2
  exit 1
fi

FEISHU_USER_ID="${FEISHU_USER_ID:-}"

VOLC_ASR_SCRIPT="$SCRIPT_DIR/volc-asr.sh"
export VOLC_APPID="${VOLC_APPID:-}"
export VOLC_TOKEN="${VOLC_TOKEN:-}"

# ── 播客订阅列表 ─────────────────────────────────────────
PODCAST_KEYS=(
  "LexFridman"
  "LinuxUnplugged"
  "AllIn"
  "Dwarkesh"
  "LatentSpace"
  "HardFork"
  "KnowledgeProject"
  "Lenny"
  "NoPriors"
  "JoeRogan"
  "TWIML"
)
PODCAST_URLS=(
  "https://lexfridman.com/feed/podcast/"
  "https://feeds.fireside.fm/linuxunplugged/rss"
  "https://allin.libsyn.com/rss"
  "https://www.dwarkeshpatel.com/feed/podcast"
  "https://feeds.transistor.fm/latent-space-the-ai-engineer-podcast"
  "https://feeds.simplecast.com/l2i9YnTd"
  "https://feeds.simplecast.com/gvtxUiIf"
  "https://api.substack.com/feed/podcast/10845.rss"
  "https://feeds.megaphone.fm/nopriors"
  "https://feeds.megaphone.fm/GLT1412515089"
  "https://twimlai.com/feed/"
)
PODCAST_DISPLAY=(
  "Lex Fridman Podcast"
  "Linux Unplugged"
  "All-In Podcast"
  "Dwarkesh Podcast"
  "Latent Space"
  "Hard Fork (NYT)"
  "The Knowledge Project"
  "Lenny's Podcast"
  "No Priors"
  "The Joe Rogan Experience"
  "TWIML AI Podcast"
)
# 时间窗口（小时）：JRE 发集频繁用 72h，其余 168h（7天）
PODCAST_HOURS=(
  168 168 168 168 168 168 168 168 168 72 168
)
# YouTube 频道 URL（用于搜索最新一期抓字幕，空字符串表示无 YouTube）
PODCAST_YOUTUBE=(
  "https://www.youtube.com/@lexfridman"
  ""
  ""
  "https://www.youtube.com/@DwarkeshPatel"
  ""
  ""
  ""
  "https://www.youtube.com/@LennysPodcast"
  "https://www.youtube.com/@NoPriorsPodcast"
  "https://www.youtube.com/@joerogan"
  "https://www.youtube.com/@twimlai"
)

# ── log 写 stderr，不污染 stdout ──────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2; }

# ── RSS 解析（调用独立 python 脚本）─────────────────────
parse_rss_latest() {
  local name="$1"
  local url="$2"
  local hours="${3:-168}"
  local parse_script="$SCRIPT_DIR/parse_rss.py"

  log "抓取 RSS: $name"
  local rss_content
  rss_content=$(curl -sL --max-time 20 "$url" 2>/dev/null) || { log "RSS 抓取失败: $name"; return 0; }

  echo "$rss_content" | python3 "$parse_script" "$name" "$hours" 2>>"$LOG_FILE" || true
}

# ── YouTube 字幕获取 ──────────────────────────────────────
get_youtube_subtitles() {
  local yt_url="$1"
  local output_base="$2"
  log "获取 YouTube 字幕: $yt_url"
  yt-dlp --write-subs --write-auto-sub --sub-lang "en.*,zh-Hans.*,zh.*" \
    --skip-download --convert-subs srt \
    -o "${output_base}" "$yt_url" >/dev/null 2>&1 || true

  local sub_file
  sub_file=$(ls "${output_base}"*.srt "${output_base}"*.vtt 2>/dev/null | head -1 || true)
  if [[ -n "$sub_file" ]]; then
    local extract_script="$SCRIPT_DIR/extract_vtt.py"
    if [[ -f "$extract_script" ]]; then
      python3 "$extract_script" "$sub_file" "${output_base}.txt" \
        --timed "${output_base}.timed.jsonl" 2>/dev/null || true
    else
      grep -v '^[0-9]*$' "$sub_file" | grep -v '^[0-9:.,]* --> ' | \
        grep -v '^WEBVTT' | grep -v '^Kind:' | grep -v '^Language:' | \
        grep -v '^$' | sed 's/<[^>]*>//g' | tr '\n' ' ' | sed 's/  */ /g' \
        > "${output_base}.txt"
    fi
    if [[ -s "${output_base}.txt" ]]; then
      echo "${output_base}.txt"
    fi
  fi
}

# ── 在 YouTube 频道搜索视频并抓字幕 ─────────────────────
search_youtube_subtitle() {
  local yt_channel="$1"
  local title="$2"
  local output_base="$3"

  [[ -z "$yt_channel" ]] && return 1

  log "YouTube 搜索字幕: $yt_channel"

  local video_info
  video_info=$(yt-dlp --flat-playlist --print "%(id)s|||%(title)s" \
    --playlist-items 1:5 "${yt_channel}/videos" 2>/dev/null) || true
  [[ -z "$video_info" ]] && return 1

  local search_word
  search_word=$(echo "$title" | sed 's/[#:—–\-]/ /g' | awk '{for(i=1;i<=NF&&i<=3;i++) printf "%s ", $i}' | xargs)

  local video_id=""
  while IFS= read -r line; do
    local vid="${line%%|||*}"
    local vtitle="${line#*|||}"
    for word in $search_word; do
      if echo "$vtitle" | grep -qi "$word" 2>/dev/null; then
        video_id="$vid"
        log "匹配到 YouTube 视频: $vtitle ($vid)"
        break 2
      fi
    done
  done <<< "$video_info"

  if [[ -z "$video_id" ]]; then
    video_id=$(echo "$video_info" | head -1 | cut -d'|' -f1)
    log "未精确匹配，使用最新视频: $video_id"
  fi

  [[ -z "$video_id" ]] && return 1

  local subtitle_file
  subtitle_file=$(get_youtube_subtitles "https://www.youtube.com/watch?v=${video_id}" "$output_base" || true)
  if [[ -n "$subtitle_file" && -f "$subtitle_file" && -s "$subtitle_file" ]]; then
    yt-dlp --print "%(chapters)j" "https://www.youtube.com/watch?v=${video_id}" \
      > "${output_base}.chapters.json" 2>/dev/null || true
    echo "$subtitle_file"
    return 0
  fi
  return 1
}

# ── 转录音频（优先 YouTube 字幕，备选火山 ASR）───────────
transcribe_audio() {
  local audio_url="$1"
  local key="$2"
  local title="$3"
  local yt_channel="$4"
  local output_dir="$CACHE_DIR/$TODAY"
  mkdir -p "$output_dir"
  local output_base="$output_dir/${key}.transcript"

  # 0. 缓存：已有转录文件则直接复用（含跨天查找）
  if [[ -f "${output_base}.txt" && -s "${output_base}.txt" ]]; then
    log "转录缓存命中: ${key}"
    echo "${output_base}.txt"; return
  fi
  local prev_transcript
  prev_transcript=$(ls -t "$CACHE_DIR"/*/"${key}.transcript.txt" 2>/dev/null | head -1 || true)
  if [[ -n "$prev_transcript" && -f "$prev_transcript" && -s "$prev_transcript" ]]; then
    log "复用历史转录: ${key} ← $prev_transcript"
    cp "$prev_transcript" "${output_base}.txt"
    local prev_dir
    prev_dir=$(dirname "$prev_transcript")
    [[ -f "${prev_dir}/${key}.transcript.timed.jsonl" ]] && cp "${prev_dir}/${key}.transcript.timed.jsonl" "${output_base}.timed.jsonl"
    [[ -f "${prev_dir}/${key}.transcript.chapters.json" ]] && cp "${prev_dir}/${key}.transcript.chapters.json" "${output_base}.chapters.json"
    echo "${output_base}.txt"; return
  fi

  # 1. 优先：YouTube 频道搜索字幕（免费、快速）
  if [[ -n "$yt_channel" ]]; then
    local yt_result
    yt_result=$(search_youtube_subtitle "$yt_channel" "$title" "$output_base" || true)
    if [[ -n "$yt_result" && -f "$yt_result" ]]; then
      echo "$yt_result"; return
    fi
  fi

  # 2. 音频 URL 是 YouTube 链接时直接抓字幕
  if echo "$audio_url" | grep -qE 'youtube|youtu\.be'; then
    local subtitle_file
    subtitle_file=$(get_youtube_subtitles "$audio_url" "$output_base" || true)
    if [[ -n "$subtitle_file" && -f "$subtitle_file" ]]; then
      echo "$subtitle_file"; return
    fi
  fi

  # 3. 降级：火山引擎 BigASR（海外音频 URL 可能下载失败）
  if [[ -x "$VOLC_ASR_SCRIPT" && -n "$audio_url" && "$audio_url" == http* ]]; then
    log "火山引擎 ASR 转录: $key"
    local transcript_file="${output_base}.txt"
    bash "$VOLC_ASR_SCRIPT" "$audio_url" --out "$transcript_file" 2>>"$LOG_FILE" || true
    if [[ -f "$transcript_file" && -s "$transcript_file" ]]; then
      echo "$transcript_file"; return
    fi
  fi

  log "转录失败: ${key} (无可用字幕源)"
  echo ""
}

# ── 主流程 ───────────────────────────────────────────────
main() {
  mkdir -p "$CACHE_DIR/$TODAY"
  log "=== 播客日报开始 $TODAY ==="
  [[ "$TEST_MODE" == "--test" ]] && log ">>> TEST MODE：跳过转录"

  local found_count=0
  local msg_file="$CACHE_DIR/$TODAY/daily_message.txt"
  : > "$msg_file"

  local total=${#PODCAST_KEYS[@]}
  for (( i=0; i<total; i++ )); do
    local key="${PODCAST_KEYS[$i]}"
    local url="${PODCAST_URLS[$i]}"
    local display="${PODCAST_DISPLAY[$i]}"
    local hours="${PODCAST_HOURS[$i]}"

    local rss_data
    rss_data=$(parse_rss_latest "$key" "$url" "$hours") || true
    [[ -z "$rss_data" ]] && continue

    local title link desc audio_url
    title=$(echo    "$rss_data" | grep '^TITLE=' | cut -d= -f2- || true)
    link=$(echo     "$rss_data" | grep '^LINK='  | cut -d= -f2- || true)
    desc=$(echo     "$rss_data" | grep '^DESC='  | cut -d= -f2- || true)
    audio_url=$(echo "$rss_data" | grep '^AUDIO=' | cut -d= -f2- || true)

    [[ -z "$title" ]] && continue

    # 去重：检查前几天是否已推送过同一集（同 key + 同 title）
    local already_sent=false
    for prev_msg in "$CACHE_DIR"/*/daily_message.txt; do
      [[ "$prev_msg" == "$CACHE_DIR/$TODAY/daily_message.txt" ]] && continue
      [[ ! -f "$prev_msg" ]] && continue
      if grep -qF "PODCAST_TITLE=$title" "$prev_msg" 2>/dev/null; then
        already_sent=true
        break
      fi
    done
    if [[ "$already_sent" == "true" ]]; then
      log "跳过（已推送过）: $display — $title"
      continue
    fi

    log "处理: $display — $title"

    # 转录（--test 模式跳过）
    local transcript_file=""
    local yt_channel="${PODCAST_YOUTUBE[$i]:-}"
    if [[ "$TEST_MODE" != "--test" ]]; then
      transcript_file=$(transcribe_audio "$audio_url" "$key" "$title" "$yt_channel" || true)
    fi

    # 后处理：翻译 + Q/A格式化 + 增强摘要（有转录文件时执行）
    local processed_json="$CACHE_DIR/$TODAY/processed_${key}.json"
    local summary_file="$CACHE_DIR/$TODAY/summary_${key}.txt"
    local process_script="$SCRIPT_DIR/process-transcript.py"
    if [[ -n "$transcript_file" && -f "$transcript_file" && -f "$process_script" && "$TEST_MODE" != "--test" ]]; then
      log "后处理（翻译+摘要）: $display"
      local chapters_file="$CACHE_DIR/$TODAY/${key}.transcript.chapters.json"
      local timed_file="$CACHE_DIR/$TODAY/${key}.transcript.timed.jsonl"
      local extra_args=""
      [[ -f "$chapters_file" ]] && extra_args="$extra_args --chapters $chapters_file"
      [[ -f "$timed_file" ]] && extra_args="$extra_args --timed $timed_file"
      python3 "$process_script" "$transcript_file" "$display" "$title" \
        --out "$processed_json" $extra_args 2>>"$LOG_FILE" || true
      if [[ -f "$processed_json" ]]; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('summary', ''))
" "$processed_json" > "$summary_file" 2>/dev/null || true
      fi
    elif [[ "$TEST_MODE" == "--test" || -z "$transcript_file" ]]; then
      local prompt_file="$CACHE_DIR/$TODAY/prompt_${key}.txt"
      {
        echo "请根据以下播客信息，用中文生成结构化摘要。"
        echo "播客：$display"
        echo "标题：$title"
        echo "描述：$desc"
        echo "请输出：核心摘要（3-5句话）、核心观点（3-5条）、产品经理 Insight（3条）、推荐工具/方法"
      } > "$prompt_file"
      local summarize_script="$SCRIPT_DIR/summarize.sh"
      if [[ -x "$summarize_script" ]]; then
        log "生成简单摘要: $display"
        bash "$summarize_script" "$prompt_file" --out "$summary_file" 2>>"$LOG_FILE" || true
      fi
    fi

    # 追加到消息汇总文件
    {
      echo "PODCAST_NAME=$display"
      echo "PODCAST_TITLE=$title"
      echo "PODCAST_LINK=$link"
      echo "PODCAST_AUDIO=$audio_url"
      echo "PODCAST_TRANSCRIPT=${transcript_file:-}"
      echo "PODCAST_SUMMARY=$summary_file"
      echo "---"
    } >> "$msg_file"

    (( found_count++ )) || true
  done

  # 写元信息
  echo "FEISHU_USER=$FEISHU_USER_ID"    >> "$msg_file"
  echo "FOUND_COUNT=$found_count"       >> "$msg_file"
  echo "TODAY_DISPLAY=$TODAY_DISPLAY"   >> "$msg_file"

  log "=== 完成：$found_count 个新集 ==="
  log "消息文件: $msg_file"

  # 自动发送飞书消息
  local send_script="$SCRIPT_DIR/feishu-send.sh"
  if [[ -x "$send_script" && $found_count -gt 0 ]]; then
    log "发送飞书日报..."
    bash "$send_script" "$CACHE_DIR/$TODAY" 2>>"$LOG_FILE" || log "飞书发送失败，见日志"
  elif [[ $found_count -eq 0 ]]; then
    log "无新集，发送无更新通知"
    python3 - "$FEISHU_RECEIVER" "$TODAY_DISPLAY" "$FEISHU_APP_ID" "$FEISHU_APP_SECRET" << 'NOPYEOF'
import sys, json, urllib.request
receiver, today, app_id, app_secret = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
req = urllib.request.Request(
    "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
    data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode(),
    headers={"Content-Type": "application/json"}
)
TOKEN = json.loads(urllib.request.urlopen(req, timeout=15).read())["tenant_access_token"]
msg = "\U0001f399\ufe0f \u64ad\u5ba2\u65e5\u62a5 \u00b7 " + today + "\n\n\U0001f4ed \u4eca\u65e5\u65e0\u65b0\u96c6\u66f4\u65b0\uff0c\u5df2\u8ba2\u9605\u7684\u64ad\u5ba2\u5747\u65e0\u65b0\u5185\u5bb9\u3002"
payload = json.dumps({
    "receive_id": receiver, "msg_type": "text",
    "content": json.dumps({"text": msg})
}).encode()
req2 = urllib.request.Request(
    "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id",
    data=payload, headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"}
)
urllib.request.urlopen(req2, timeout=15)
NOPYEOF
  fi

  echo "DONE:$msg_file"
}

main "$@"
