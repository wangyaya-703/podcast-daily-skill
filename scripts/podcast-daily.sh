#!/usr/bin/env bash
# podcast-daily.sh — 生产播客日报产出（feed + transcripts + state）
# 用法:
#   bash scripts/podcast-daily.sh
#   bash scripts/podcast-daily.sh --test   # 仅做 RSS 探测，不调用转录/LLM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/.podcast-cache}"
STATE_FILE="${STATE_FILE:-$ROOT_DIR/state-feed.json}"
FEED_FILE="${FEED_FILE:-$ROOT_DIR/feed-podcasts.json}"
TRANSCRIPTS_ROOT="${TRANSCRIPTS_ROOT:-$ROOT_DIR/transcripts}"

TODAY="${RUN_DATE:-$(date +%Y-%m-%d)}"
GENERATED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TEST_MODE="${1:-}"

LOG_FILE="${LOG_FILE:-$ROOT_DIR/podcast-daily.log}"

TRANSLATE_MODEL="${TRANSLATE_MODEL:-doubao-seed-2.0-lite}"
SUMMARY_MODEL="${SUMMARY_MODEL:-glm-4.7}"

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "缺少依赖命令: $cmd"
    exit 1
  fi
}

sha256_8() {
  python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest()[:8])
PY
}

ensure_dirs() {
  mkdir -p "$CACHE_DIR/$TODAY" "$TRANSCRIPTS_ROOT/$TODAY"
  touch "$LOG_FILE"
}

state_has_episode() {
  local episode_id="$1"
  python3 - "$STATE_FILE" "$episode_id" <<'PY'
import json, os, sys
state_file, episode_id = sys.argv[1], sys.argv[2]
if not os.path.exists(state_file):
    sys.exit(1)
try:
    with open(state_file, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
processed = data.get('processedEpisodes', {})
sys.exit(0 if episode_id in processed else 1)
PY
}

# ── 播客订阅列表（支持自定义配置文件）─────────────────────
# 优先级：PODCAST_CONFIG 环境变量 > 工作目录/podcasts.json > 内置默认
load_podcast_config() {
  local podcast_config="${PODCAST_CONFIG:-}"
  local podcast_config_file=""
  if [[ -n "$podcast_config" && -f "$podcast_config" ]]; then
    podcast_config_file="$podcast_config"
  elif [[ -f "$ROOT_DIR/podcasts.json" ]]; then
    podcast_config_file="$ROOT_DIR/podcasts.json"
  fi

  if [[ -n "$podcast_config_file" ]]; then
    log "加载播客配置: $podcast_config_file"
    local data
    data=$(python3 - "$podcast_config_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    cfg = json.load(f)
for p in cfg.get('podcasts', []):
    print('\t'.join([
        p.get('key', ''),
        p.get('name', ''),
        p.get('rss', ''),
        str(p.get('hours', 168)),
        p.get('youtube', '')
    ]))
PY
)

    PODCAST_KEYS=()
    PODCAST_URLS=()
    PODCAST_DISPLAY=()
    PODCAST_HOURS=()
    PODCAST_YOUTUBE=()

    while IFS=$'\t' read -r key name rss hours youtube; do
      [[ -z "$key" ]] && continue
      PODCAST_KEYS+=("$key")
      PODCAST_DISPLAY+=("$name")
      PODCAST_URLS+=("$rss")
      PODCAST_HOURS+=("${hours:-168}")
      PODCAST_YOUTUBE+=("${youtube:-}")
    done <<< "$data"

    log "已加载 ${#PODCAST_KEYS[@]} 个播客"
  else
    PODCAST_KEYS=(
      "LexFridman" "LinuxUnplugged" "AllIn" "Dwarkesh" "LatentSpace"
      "HardFork" "KnowledgeProject" "Lenny" "NoPriors" "JoeRogan" "TWIML"
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
      "Lex Fridman Podcast" "Linux Unplugged" "All-In Podcast" "Dwarkesh Podcast"
      "Latent Space" "Hard Fork (NYT)" "The Knowledge Project" "Lenny's Podcast"
      "No Priors" "The Joe Rogan Experience" "TWIML AI Podcast"
    )
    PODCAST_HOURS=(168 168 168 168 168 168 168 168 168 72 168)
    PODCAST_YOUTUBE=(
      "https://www.youtube.com/@lexfridman" "" ""
      "https://www.youtube.com/@DwarkeshPatel" "" "" ""
      "https://www.youtube.com/@LennysPodcast"
      "https://www.youtube.com/@NoPriorsPodcast"
      "https://www.youtube.com/@joerogan"
      "https://www.youtube.com/@twimlai"
    )
  fi
}

# ── RSS 解析（调用独立 python 脚本）─────────────────────
parse_rss_latest() {
  local name="$1"
  local url="$2"
  local hours="${3:-168}"
  local parse_script="$SCRIPT_DIR/parse_rss.py"

  log "抓取 RSS: $name"
  local rss_content
  rss_content=$(curl -fsSL --max-time 20 "$url" 2>/dev/null) || {
    log "RSS 抓取失败: $name"
    return 0
  }

  echo "$rss_content" | python3 "$parse_script" "$name" "$hours" 2>>"$LOG_FILE" || true
}

# ── YouTube 字幕获取 ─────────────────────────────────────
get_youtube_subtitles() {
  local yt_url="$1"
  local output_base="$2"

  if ! command -v yt-dlp >/dev/null 2>&1; then
    return 1
  fi

  log "获取 YouTube 字幕: $yt_url"
  yt-dlp --write-subs --write-auto-sub --sub-lang "en.*,zh-Hans.*,zh.*" \
    --skip-download --convert-subs srt \
    -o "${output_base}" "$yt_url" >/dev/null 2>&1 || true

  local sub_file
  sub_file=$(ls "${output_base}"*.srt "${output_base}"*.vtt 2>/dev/null | head -1 || true)
  if [[ -z "$sub_file" ]]; then
    return 1
  fi

  local extract_script="$SCRIPT_DIR/extract_vtt.py"
  if [[ -f "$extract_script" ]]; then
    python3 "$extract_script" "$sub_file" "${output_base}.txt" \
      --timed "${output_base}.timed.jsonl" 2>>"$LOG_FILE" || true
  fi

  if [[ -s "${output_base}.txt" ]]; then
    yt-dlp --print "%(chapters)j" "$yt_url" > "${output_base}.chapters.json" 2>/dev/null || true
    echo "${output_base}.txt"
    return 0
  fi
  return 1
}

search_youtube_subtitle() {
  local yt_channel="$1"
  local title="$2"
  local output_base="$3"

  [[ -z "$yt_channel" ]] && return 1
  command -v yt-dlp >/dev/null 2>&1 || return 1

  log "YouTube 搜索字幕: $yt_channel"
  local video_info
  video_info=$(yt-dlp --flat-playlist --print "%(id)s|||%(title)s" \
    --playlist-items 1:8 "${yt_channel}/videos" 2>/dev/null) || true
  [[ -z "$video_info" ]] && return 1

  local search_word
  search_word=$(echo "$title" | sed 's/[#:—–\-]/ /g' | awk '{for(i=1;i<=NF&&i<=4;i++) printf "%s ", $i}' | xargs)

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
    [[ -n "$video_id" ]] && log "未精确匹配，使用最新视频: $video_id"
  fi

  [[ -z "$video_id" ]] && return 1
  get_youtube_subtitles "https://www.youtube.com/watch?v=${video_id}" "$output_base"
}

# ── 转录（修复缓存键：key + title_hash）──────────────────
transcribe_audio() {
  local audio_url="$1"
  local key="$2"
  local title="$3"
  local title_hash="$4"
  local yt_channel="$5"

  local cache_key="${key}_${title_hash}"
  local output_dir="$CACHE_DIR/$TODAY"
  local output_base="$output_dir/${cache_key}.transcript"
  mkdir -p "$output_dir"

  # 当天缓存
  if [[ -s "${output_base}.txt" ]]; then
    log "转录缓存命中: $cache_key"
    echo "${output_base}.txt"
    return 0
  fi

  # 跨天缓存（同 key + 同 title_hash）
  local prev_transcript=""
  prev_transcript=$(ls -t "$CACHE_DIR"/*/"${cache_key}.transcript.txt" 2>/dev/null | head -1 || true)
  if [[ -n "$prev_transcript" && -s "$prev_transcript" ]]; then
    log "复用历史转录: $cache_key ← $prev_transcript"
    cp "$prev_transcript" "${output_base}.txt"

    local prev_base="${prev_transcript%.txt}"
    [[ -f "${prev_base}.timed.jsonl" ]] && cp "${prev_base}.timed.jsonl" "${output_base}.timed.jsonl"
    [[ -f "${prev_base}.chapters.json" ]] && cp "${prev_base}.chapters.json" "${output_base}.chapters.json"

    echo "${output_base}.txt"
    return 0
  fi

  # 优先 YouTube 字幕
  if [[ -n "$yt_channel" ]]; then
    local yt_result=""
    yt_result=$(search_youtube_subtitle "$yt_channel" "$title" "$output_base" || true)
    if [[ -n "$yt_result" && -s "$yt_result" ]]; then
      echo "$yt_result"
      return 0
    fi
  fi

  # 音频链接本身是 YouTube
  if [[ "$audio_url" =~ youtube|youtu\.be ]]; then
    local direct_sub=""
    direct_sub=$(get_youtube_subtitles "$audio_url" "$output_base" || true)
    if [[ -n "$direct_sub" && -s "$direct_sub" ]]; then
      echo "$direct_sub"
      return 0
    fi
  fi

  log "转录失败: ${key}（未获取到可用字幕）"
  return 1
}

finalize_outputs() {
  local episodes_jsonl="$1"
  local processed_ids_jsonl="$2"

  python3 - "$STATE_FILE" "$FEED_FILE" "$episodes_jsonl" "$processed_ids_jsonl" "$TODAY" "$GENERATED_AT_UTC" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone

state_file, feed_file, episodes_jsonl, ids_jsonl, run_date, generated_at = sys.argv[1:7]

episodes = []
if os.path.exists(episodes_jsonl):
    with open(episodes_jsonl, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            episodes.append(json.loads(line))

def sort_key(ep):
    return ep.get('publishedAt') or ''

episodes.sort(key=sort_key, reverse=True)

stats = {
    'totalEpisodes': len(episodes),
    'byRecommendation': {'P0': 0, 'P1': 0, 'P2': 0}
}
for ep in episodes:
    level = ep.get('recommendation', 'P1')
    if level not in stats['byRecommendation']:
        stats['byRecommendation'][level] = 0
    stats['byRecommendation'][level] += 1

feed = {
    'generatedAt': generated_at,
    'date': run_date,
    'episodes': episodes,
    'stats': stats,
}

with open(feed_file, 'w', encoding='utf-8') as f:
    json.dump(feed, f, ensure_ascii=False, indent=2)

state = {'processedEpisodes': {}, 'lastRunAt': None}
if os.path.exists(state_file):
    try:
      with open(state_file, encoding='utf-8') as f:
          loaded = json.load(f)
      if isinstance(loaded, dict):
          state.update(loaded)
          if not isinstance(state.get('processedEpisodes'), dict):
              state['processedEpisodes'] = {}
    except Exception:
      pass

processed = state['processedEpisodes']

# 清理 7 天前记录
cutoff = datetime.now(timezone.utc) - timedelta(days=7)
keys_to_delete = []
for k, v in processed.items():
    ts = v.get('processedAt', '') if isinstance(v, dict) else ''
    try:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        if dt < cutoff:
            keys_to_delete.append(k)
    except Exception:
        keys_to_delete.append(k)
for k in keys_to_delete:
    processed.pop(k, None)

if os.path.exists(ids_jsonl):
    with open(ids_jsonl, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            episode_id = item.get('episodeId')
            if not episode_id:
                continue
            processed[episode_id] = {
                'title': item.get('title', ''),
                'processedAt': generated_at,
                'titleHash': item.get('titleHash', ''),
            }

state['lastRunAt'] = generated_at
with open(state_file, 'w', encoding='utf-8') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)

print(f'feed: {feed_file}')
print(f'state: {state_file}')
print(f'episodes: {len(episodes)}')
PY
}

main() {
  require_cmd curl
  require_cmd python3
  ensure_dirs
  load_podcast_config

  local episodes_jsonl
  local processed_ids_jsonl
  episodes_jsonl="$(mktemp)"
  processed_ids_jsonl="$(mktemp)"

  log "=== 播客日报生成开始: $TODAY ==="
  [[ "$TEST_MODE" == "--test" ]] && log ">>> TEST MODE：只做 RSS 探测，不进行转录与 LLM"

  local total=${#PODCAST_KEYS[@]}
  local found=0

  for (( i=0; i<total; i++ )); do
    local key="${PODCAST_KEYS[$i]}"
    local rss_url="${PODCAST_URLS[$i]}"
    local display="${PODCAST_DISPLAY[$i]}"
    local hours="${PODCAST_HOURS[$i]}"
    local yt_channel="${PODCAST_YOUTUBE[$i]:-}"

    local rss_data
    rss_data=$(parse_rss_latest "$key" "$rss_url" "$hours") || true
    [[ -z "$rss_data" ]] && continue

    local title link desc audio_url pubdate
    title=$(echo "$rss_data" | awk -F= '/^TITLE=/{sub(/^TITLE=/,""); print; exit}')
    link=$(echo "$rss_data" | awk -F= '/^LINK=/{sub(/^LINK=/,""); print; exit}')
    desc=$(echo "$rss_data" | awk -F= '/^DESC=/{sub(/^DESC=/,""); print; exit}')
    audio_url=$(echo "$rss_data" | awk -F= '/^AUDIO=/{sub(/^AUDIO=/,""); print; exit}')
    pubdate=$(echo "$rss_data" | awk -F= '/^PUBDATE=/{sub(/^PUBDATE=/,""); print; exit}')

    [[ -z "$title" ]] && continue

    local title_hash
    title_hash="$(sha256_8 "$title")"
    local episode_id="${key}_${title_hash}"

    if state_has_episode "$episode_id"; then
      log "跳过（已处理）: $display — $title"
      continue
    fi

    log "处理: $display — $title"

    if [[ "$TEST_MODE" == "--test" ]]; then
      log "TEST 模式跳过实际处理: $episode_id"
      continue
    fi

    local transcript_file=""
    transcript_file=$(transcribe_audio "$audio_url" "$key" "$title" "$title_hash" "$yt_channel" || true)
    if [[ -z "$transcript_file" || ! -s "$transcript_file" ]]; then
      log "跳过（无转录）: $display — $title"
      continue
    fi

    local process_script="$SCRIPT_DIR/process-transcript.py"
    local processed_json="$CACHE_DIR/$TODAY/processed_${episode_id}.json"
    local md_abs="$TRANSCRIPTS_ROOT/$TODAY/${key}.md"
    local md_rel="transcripts/$TODAY/${key}.md"

    local extra_args=()
    local transcript_base="${transcript_file%.txt}"
    [[ -f "${transcript_base}.chapters.json" ]] && extra_args+=("--chapters" "${transcript_base}.chapters.json")
    [[ -f "${transcript_base}.timed.jsonl" ]] && extra_args+=("--timed" "${transcript_base}.timed.jsonl")

    log "LLM 处理: $display"
    TRANSLATE_MODEL="$TRANSLATE_MODEL" SUMMARY_MODEL="$SUMMARY_MODEL" \
      python3 "$process_script" "$transcript_file" "$display" "$title" \
      --out "$processed_json" \
      --markdown-out "$md_abs" \
      --date "$TODAY" \
      --episode-link "$link" \
      "${extra_args[@]}" 2>>"$LOG_FILE" || true

    if [[ ! -f "$processed_json" ]]; then
      log "处理失败，跳过: $episode_id"
      continue
    fi

    python3 - "$processed_json" "$key" "$display" "$title" "$link" "$audio_url" "$pubdate" "$md_rel" "$episode_id" <<'PY' >> "$episodes_jsonl"
import json, sys
from email.utils import parsedate_to_datetime

(
    processed_json,
    key,
    name,
    title,
    link,
    audio_url,
    pubdate,
    md_rel,
    episode_id,
) = sys.argv[1:10]

with open(processed_json, encoding='utf-8') as f:
    data = json.load(f)

published_iso = ''
if pubdate:
    try:
        published_iso = parsedate_to_datetime(pubdate).astimezone().isoformat().replace('+00:00', 'Z')
    except Exception:
        published_iso = ''

meta = data.get('meta', {})
summary = data.get('summary', {})
recommendation = data.get('recommendation', 'P1')
segments = data.get('segments', [])
chapters = data.get('chapters', [])

sec = int(meta.get('estimated_duration_seconds', 0) or 0)
h = sec // 3600
m = (sec % 3600) // 60
if h > 0:
    duration = f"{h}h {m}min"
elif m > 0:
    duration = f"{m}min"
else:
    duration = ''

entry = {
    'id': episode_id,
    'key': key,
    'name': name,
    'title': title,
    'link': link,
    'audioUrl': audio_url,
    'duration': duration,
    'publishedAt': published_iso,
    'recommendation': recommendation,
    'summary': {
        'one_liner': summary.get('one_liner', ''),
        'key_points': summary.get('key_points', []),
        'golden_quotes': summary.get('golden_quotes', []),
        'pm_insights': summary.get('pm_insights', []),
        'tools_mentioned': summary.get('tools_mentioned', []),
    },
    'transcript': {
        'bilingualUrl': md_rel,
        'rawLength': int(meta.get('raw_length', 0) or 0),
        'segments': len(segments),
        'chapters': len(chapters),
    },
}
print(json.dumps(entry, ensure_ascii=False))
PY

    python3 - "$episode_id" "$title" "$title_hash" <<'PY' >> "$processed_ids_jsonl"
import json, sys
print(json.dumps({'episodeId': sys.argv[1], 'title': sys.argv[2], 'titleHash': sys.argv[3]}, ensure_ascii=False))
PY

    found=$((found + 1))
  done

  finalize_outputs "$episodes_jsonl" "$processed_ids_jsonl" | tee -a "$LOG_FILE" >&2
  rm -f "$episodes_jsonl" "$processed_ids_jsonl"

  log "=== 播客日报生成完成: 新处理 $found 集 ==="
}

main "$@"
