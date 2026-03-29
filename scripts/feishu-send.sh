#!/usr/bin/env bash
# feishu-send.sh — 从 feed-podcasts.json 推送飞书卡片 + 创建飞书文档 + 写入多维表格
#
# 用法:
#   bash scripts/feishu-send.sh
#   bash scripts/feishu-send.sh --feed ./feed-podcasts.json
#   bash scripts/feishu-send.sh --feed https://raw.githubusercontent.com/.../feed-podcasts.json
#   bash scripts/feishu-send.sh --feed ... --state ./.feishu-push-state.json --raw-base-url https://raw.githubusercontent.com/<repo>/main
#
# 必需环境变量:
#   FEISHU_APP_ID, FEISHU_APP_SECRET, FEISHU_RECEIVER
# 可选环境变量:
#   BITABLE_APP_TOKEN, BITABLE_TABLE_ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

FEED_SOURCE="${FEED_SOURCE:-$ROOT_DIR/feed-podcasts.json}"
STATE_PATH="${PUSH_STATE_FILE:-$ROOT_DIR/.feishu-push-state.json}"
RAW_BASE_URL="${RAW_BASE_URL:-}"
TRACKING_URL="${TRACKING_URL:-https://bytedance.larkoffice.com/base/QV53bJjHkay63psk2HGc3LuRnrN}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feed)
      FEED_SOURCE="$2"
      shift 2
      ;;
    --state)
      STATE_PATH="$2"
      shift 2
      ;;
    --raw-base-url)
      RAW_BASE_URL="$2"
      shift 2
      ;;
    --tracking-url)
      TRACKING_URL="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

FEISHU_APP_ID="${FEISHU_APP_ID:?请设置 FEISHU_APP_ID}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:?请设置 FEISHU_APP_SECRET}"
FEISHU_RECEIVER="${FEISHU_RECEIVER:?请设置 FEISHU_RECEIVER}"

python3 - "$FEED_SOURCE" "$STATE_PATH" "$RAW_BASE_URL" "$TRACKING_URL" <<'PYEOF'
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

(
    feed_source,
    state_path,
    raw_base_url,
    tracking_url,
    ) = sys.argv[1:5]

app_id = os.environ["FEISHU_APP_ID"]
app_secret = os.environ["FEISHU_APP_SECRET"]
receiver = os.environ["FEISHU_RECEIVER"]
bitable_app_token = os.environ.get("BITABLE_APP_TOKEN", "")
bitable_table_id = os.environ.get("BITABLE_TABLE_ID", "")


def log(msg):
    print(f"[feishu-send] {msg}", file=sys.stderr)


def http_json(url, payload=None, headers=None, timeout=30):
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="ignore")
        return json.loads(raw) if raw else {}


def get_tenant_token():
    resp = http_json(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        payload={"app_id": app_id, "app_secret": app_secret},
        timeout=15,
    )
    token = resp.get("tenant_access_token")
    if not token:
        raise RuntimeError(f"获取 tenant_access_token 失败: {resp}")
    return token


TOKEN = get_tenant_token()


def feishu_post(url, payload, retries=3):
    headers = {"Authorization": f"Bearer {TOKEN}"}
    for attempt in range(1, retries + 1):
        try:
            return http_json(url, payload=payload, headers=headers, timeout=45)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="ignore")
            log(f"HTTPError {e.code} (attempt {attempt}/{retries}): {body[:300]}")
            if attempt == retries:
                return {"code": e.code, "msg": body}
        except Exception as e:
            log(f"请求失败 (attempt {attempt}/{retries}): {e}")
            if attempt == retries:
                return {"code": -1, "msg": str(e)}
        time.sleep(attempt)
    return {"code": -1, "msg": "unknown"}


def grant_edit_permission(doc_token):
    payload = {
        "member_type": "openid",
        "member_id": receiver,
        "perm": "full_access",
    }
    url = f"https://open.feishu.cn/open-apis/drive/v1/permissions/{doc_token}/members?type=docx&need_notification=false"
    resp = feishu_post(url, payload)
    if resp.get("code") != 0:
        log(f"授予文档权限失败: {resp}")


# 参考 feishu-cli 的设计：
# 1) markdown 分段（避免把代码块打散）
# 2) 每次最多 50 blocks
# 3) 限流重试

def split_markdown_segments(markdown_text):
    lines = markdown_text.splitlines()
    segments = []
    buf = []
    in_code = False

    def flush_paragraph():
        nonlocal buf
        if buf:
            content = "\n".join(buf).strip()
            if content:
                segments.append(("paragraph", content))
            buf = []

    for line in lines:
        stripped = line.strip()

        if stripped.startswith("```"):
            if in_code:
                buf.append(line)
                segments.append(("code", "\n".join(buf).strip()))
                buf = []
                in_code = False
            else:
                flush_paragraph()
                in_code = True
                buf.append(line)
            continue

        if in_code:
            buf.append(line)
            continue

        if re.match(r"^#{1,9}\s+", stripped):
            flush_paragraph()
            level = len(stripped) - len(stripped.lstrip("#"))
            text = stripped[level:].strip()
            if text:
                segments.append((f"heading{min(level, 9)}", text))
            continue

        if stripped in {"---", "***", "___"}:
            flush_paragraph()
            segments.append(("divider", ""))
            continue

        if not stripped:
            flush_paragraph()
            continue

        buf.append(line)

    flush_paragraph()
    return segments


def text_block(content):
    return {
        "block_type": 2,
        "text": {"elements": [{"text_run": {"content": content[:2000]}}], "style": {}},
    }


def code_block(content):
    return {
        "block_type": 14,
        "code": {
            "elements": [{"text_run": {"content": content[:2000]}}],
            "style": {"language": 49},
        },
    }


def heading_block(level, content):
    block_type = 2 + level
    key = f"heading{level}"
    return {
        "block_type": block_type,
        key: {"elements": [{"text_run": {"content": content[:200]}}]},
    }


def divider_block():
    return {"block_type": 22, "divider": {}}


def markdown_to_blocks(markdown_text):
    blocks = []
    segments = split_markdown_segments(markdown_text)

    for kind, content in segments:
        if kind.startswith("heading"):
            level = int(kind.replace("heading", ""))
            blocks.append(heading_block(level, content))
            continue
        if kind == "divider":
            blocks.append(divider_block())
            continue
        if kind == "code":
            blocks.append(code_block(content))
            continue

        # paragraph
        paragraph = content.strip()
        while len(paragraph) > 1800:
            cut = paragraph.rfind("\n", 0, 1800)
            if cut < 200:
                cut = 1800
            part = paragraph[:cut].strip()
            if part:
                blocks.append(text_block(part))
            paragraph = paragraph[cut:].strip()
        if paragraph:
            blocks.append(text_block(paragraph))

    return blocks


def append_blocks(document_id, blocks):
    if not blocks:
        return True

    url = f"https://open.feishu.cn/open-apis/docx/v1/documents/{document_id}/blocks/{document_id}/children"
    batch_size = 50

    for i in range(0, len(blocks), batch_size):
        batch = blocks[i : i + batch_size]
        payload = {"children": batch, "index": -1}

        # 限流重试
        ok = False
        for attempt in range(1, 6):
            resp = feishu_post(url, payload)
            code = resp.get("code")
            if code == 0:
                ok = True
                break
            msg = str(resp.get("msg", ""))
            log(f"写入 blocks 失败 (batch {i//batch_size}, attempt {attempt}/5): {resp}")
            if "too many requests" in msg.lower() or code in {99991663, 11247}:
                time.sleep(min(8, attempt * 2))
                continue
            time.sleep(attempt)

        if not ok:
            return False

    return True


def create_doc_from_markdown(title, markdown_text):
    resp = feishu_post(
        "https://open.feishu.cn/open-apis/docx/v1/documents",
        {"title": title},
    )
    if resp.get("code") != 0:
        log(f"创建文档失败: {resp}")
        return ""

    doc_token = resp["data"]["document"]["document_id"]
    grant_edit_permission(doc_token)

    blocks = markdown_to_blocks(markdown_text)
    ok = append_blocks(doc_token, blocks)
    if not ok:
        log(f"写入文档内容失败: {doc_token}")

    return f"https://feishu.cn/docx/{doc_token}"


def read_json_source(source):
    if source.startswith("http://") or source.startswith("https://"):
        with urllib.request.urlopen(source, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    with open(source, encoding="utf-8") as f:
        return json.load(f)


def read_markdown_content(path_or_rel):
    if not path_or_rel:
        return ""

    if os.path.exists(path_or_rel):
        with open(path_or_rel, encoding="utf-8", errors="replace") as f:
            return f.read()

    # 相对 feed 路径，尝试拼接 feed 文件所在目录
    if not (feed_source.startswith("http://") or feed_source.startswith("https://")):
        base_dir = os.path.dirname(os.path.abspath(feed_source))
        local_try = os.path.join(base_dir, path_or_rel)
        if os.path.exists(local_try):
            with open(local_try, encoding="utf-8", errors="replace") as f:
                return f.read()

    # 远程 raw 回源
    if raw_base_url:
        url = raw_base_url.rstrip("/") + "/" + path_or_rel.lstrip("/")
        try:
            with urllib.request.urlopen(url, timeout=20) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except Exception as e:
            log(f"拉取远程 markdown 失败: {url} ({e})")

    return ""


def load_state(path):
    if not os.path.exists(path):
        return {"sentFeedDates": [], "sentEpisodeIds": [], "lastSentAt": ""}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {"sentFeedDates": [], "sentEpisodeIds": [], "lastSentAt": ""}
        data.setdefault("sentFeedDates", [])
        data.setdefault("sentEpisodeIds", [])
        data.setdefault("lastSentAt", "")
        return data
    except Exception:
        return {"sentFeedDates": [], "sentEpisodeIds": [], "lastSentAt": ""}


def save_state(path, state):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def recommendation_label(level):
    return {
        "P0": "P0 特别推荐",
        "P1": "P1 一般推荐",
        "P2": "P2 空闲再看",
    }.get(level, "P1 一般推荐")


def safe_list(value):
    if isinstance(value, list):
        return [str(x).strip() for x in value if str(x).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def format_feed_date(date_str):
    try:
        d = datetime.strptime(date_str, "%Y-%m-%d")
        return f"{d.month}月{d.day}日"
    except Exception:
        now = datetime.now()
        return f"{now.month}月{now.day}日"


def send_interactive_card(card):
    payload = {
        "receive_id": receiver,
        "msg_type": "interactive",
        "content": json.dumps(card, ensure_ascii=False),
    }
    url = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id"
    resp = feishu_post(url, payload)
    if resp.get("code") != 0:
        raise RuntimeError(f"发送飞书卡片失败: {resp}")
    return resp.get("data", {}).get("message_id", "")


def build_card(feed_date, episodes):
    title = f"🎙️ 播客日报 · {format_feed_date(feed_date)}"
    elements = []

    if episodes:
        for ep in episodes:
            summary = ep.get("summary", {}) or {}
            key_points = safe_list(summary.get("key_points"))[:3]
            quotes = safe_list(summary.get("golden_quotes"))[:2]
            insights = safe_list(summary.get("pm_insights"))[:2]
            rec_label = recommendation_label(ep.get("recommendation", "P1"))
            duration = ep.get("duration", "")
            line_meta = f"⏱️ {duration}  |  ⭐ {rec_label}" if duration else f"⭐ {rec_label}"

            block_lines = [
                f"📻 **{ep.get('name', '')}**",
                f"🎙️ {ep.get('title', '')}",
                line_meta,
            ]

            if key_points:
                block_lines.append("\n**核心观点：**")
                for kp in key_points:
                    block_lines.append(f"- {kp}")

            if quotes:
                block_lines.append("\n**💬 金句：**")
                for q in quotes:
                    block_lines.append(f"> {q}")

            if insights:
                block_lines.append("\n**🛠️ PM 洞察：**")
                for it in insights:
                    block_lines.append(f"- {it}")

            if ep.get("doc_url"):
                block_lines.append(f"\n📄 双语原文：[查看飞书文档]({ep['doc_url']})")

            elements.append({"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(block_lines)}})
            elements.append({"tag": "hr"})

        elements.append(
            {
                "tag": "div",
                "text": {
                    "tag": "lark_md",
                    "content": f"📮 今日共 **{len(episodes)}** 期新集",
                },
            }
        )
    else:
        elements.append(
            {
                "tag": "div",
                "text": {
                    "tag": "lark_md",
                    "content": "所有订阅均无新集，明日见～",
                },
            }
        )

    elements.append(
        {
            "tag": "action",
            "actions": [
                {
                    "tag": "button",
                    "text": {"tag": "plain_text", "content": "📊 查看播客追踪表"},
                    "type": "primary",
                    "url": tracking_url,
                }
            ],
        }
    )

    return {
        "config": {"wide_screen_mode": True, "enable_forward": True},
        "header": {
            "title": {"tag": "plain_text", "content": title},
            "template": "blue",
        },
        "elements": elements,
    }


def write_bitable_records(episodes):
    if not episodes or not bitable_app_token or not bitable_table_id:
        return

    url = f"https://open.feishu.cn/open-apis/bitable/v1/apps/{bitable_app_token}/tables/{bitable_table_id}/records"

    for ep in episodes:
        summary = ep.get("summary", {}) or {}
        published = ep.get("publishedAt", "")
        ts_ms = int(time.time() * 1000)
        if published:
            try:
                dt = datetime.fromisoformat(published.replace("Z", "+00:00"))
                ts_ms = int(dt.timestamp() * 1000)
            except Exception:
                pass

        fields = {
            "播客名称": ep.get("name", ""),
            "集标题": ep.get("title", ""),
            "日期": ts_ms,
            "推荐等级": recommendation_label(ep.get("recommendation", "P1")),
            "核心摘要": "\n".join(safe_list(summary.get("key_points"))[:3])[:2000],
            "PM Insights": "\n".join(safe_list(summary.get("pm_insights"))[:3])[:2000],
            "精彩金句": "\n".join(safe_list(summary.get("golden_quotes"))[:2])[:2000],
        }

        if ep.get("doc_url"):
            fields["原文文档"] = {"text": "[查看原文]", "link": ep["doc_url"]}
        if ep.get("link"):
            fields["播客链接"] = {"text": ep.get("title", "")[:80], "link": ep["link"]}

        resp = feishu_post(url, {"fields": fields})
        if resp.get("code") != 0:
            log(f"写入多维表格失败: {resp}")
        time.sleep(0.2)


def pick_new_episodes(feed, state):
    feed_date = str(feed.get("date", "")).strip()
    episodes = feed.get("episodes", [])
    if not isinstance(episodes, list):
        episodes = []

    sent_ids = set(state.get("sentEpisodeIds", []))
    out = []
    for ep in episodes:
        ep_id = ep.get("id") or f"{ep.get('key', '')}_{ep.get('title', '')}"
        if ep_id in sent_ids:
            continue
        ep = dict(ep)
        ep["_id"] = ep_id
        out.append(ep)

    return feed_date, out


def main():
    feed = read_json_source(feed_source)
    state = load_state(state_path)

    feed_date, new_eps = pick_new_episodes(feed, state)
    if not feed_date:
        feed_date = datetime.now().strftime("%Y-%m-%d")

    # 如果这个 feed 日期已经发过，直接退出
    if feed_date in set(state.get("sentFeedDates", [])):
        log(f"日期 {feed_date} 已推送，跳过")
        print("SKIP_ALREADY_SENT")
        return

    # 先创建文档链接
    for ep in new_eps:
        transcript_info = ep.get("transcript", {}) or {}
        md_path = transcript_info.get("bilingualUrl", "")
        markdown = read_markdown_content(md_path)
        if not markdown:
            ep["doc_url"] = ""
            continue

        title = ep.get("title", "")
        podcast_name = ep.get("name", "")
        doc_title = f"[播客双语原文] {podcast_name} · {title[:60]}"
        log(f"创建飞书文档: {doc_title}")
        ep["doc_url"] = create_doc_from_markdown(doc_title, markdown)

    card = build_card(feed_date, new_eps)
    message_id = send_interactive_card(card)
    log(f"卡片发送成功: {message_id}")

    write_bitable_records(new_eps)

    # 更新状态
    sent_dates = state.get("sentFeedDates", [])
    sent_dates.append(feed_date)
    state["sentFeedDates"] = sent_dates[-60:]

    sent_episode_ids = state.get("sentEpisodeIds", [])
    sent_episode_ids.extend([ep.get("_id") for ep in new_eps])
    # 去重并截断
    dedup = []
    seen = set()
    for eid in reversed(sent_episode_ids):
        if not eid or eid in seen:
            continue
        seen.add(eid)
        dedup.append(eid)
    state["sentEpisodeIds"] = list(reversed(dedup))[-1000:]

    state["lastSentAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    state["lastFeedDate"] = feed_date

    save_state(state_path, state)

    print(json.dumps({
        "feedDate": feed_date,
        "newEpisodes": len(new_eps),
        "messageId": message_id,
        "state": state_path,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
PYEOF
