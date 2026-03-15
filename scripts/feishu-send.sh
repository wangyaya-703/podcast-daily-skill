#!/usr/bin/env bash
# feishu-send.sh — 用飞书应用发送播客日报（含飞书文档存档 + 多维表格写入）
# 用法: bash feishu-send.sh <daily_message_dir>
#
# 必需环境变量: FEISHU_APP_ID, FEISHU_APP_SECRET, FEISHU_RECEIVER
# 可选环境变量: BITABLE_APP_TOKEN, BITABLE_TABLE_ID

set -euo pipefail

CACHE_DIR="${1:-}"
if [[ -z "$CACHE_DIR" || ! -d "$CACHE_DIR" ]]; then
  echo "用法: feishu-send.sh <日期缓存目录>" >&2
  exit 1
fi

# 从环境变量读取（不允许硬编码）
FEISHU_APP_ID="${FEISHU_APP_ID:?请设置 FEISHU_APP_ID}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:?请设置 FEISHU_APP_SECRET}"
FEISHU_RECEIVER="${FEISHU_RECEIVER:?请设置 FEISHU_RECEIVER}"

log() { echo "[feishu-send] $*" >&2; }

python3 - "$CACHE_DIR" "$FEISHU_APP_ID" "$FEISHU_APP_SECRET" "$FEISHU_RECEIVER" \
  "${BITABLE_APP_TOKEN:-}" "${BITABLE_TABLE_ID:-}" << 'PYEOF'
import sys, json, os, html, urllib.request, urllib.error, time
from datetime import date

cache_dir = sys.argv[1]
app_id = sys.argv[2]
app_secret = sys.argv[3]
receiver = sys.argv[4]
bitable_app_token = sys.argv[5] if len(sys.argv) > 5 else ""
bitable_table_id = sys.argv[6] if len(sys.argv) > 6 else ""

# ── 获取 tenant_access_token ──────────────────────────────
def get_token():
    req = urllib.request.Request(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode(),
        headers={"Content-Type": "application/json"}
    )
    return json.loads(urllib.request.urlopen(req, timeout=15).read())["tenant_access_token"]

TOKEN = get_token()

def feishu_post(url, payload):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"}
    )
    try:
        return json.loads(urllib.request.urlopen(req, timeout=30).read())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"[feishu] HTTP {e.code}: {body[:200]}", file=sys.stderr)
        return {}

# ── 给用户开启文档编辑权限 ────────────────────────────────
def grant_edit_permission(doc_token):
    member_resp = feishu_post(
        f"https://open.feishu.cn/open-apis/drive/v1/permissions/{doc_token}/members?type=docx&need_notification=false",
        {"member_type": "openid", "member_id": receiver, "perm": "full_access"}
    )
    if member_resp.get("code") == 0:
        print(f"[feishu] 已授予编辑权限", file=sys.stderr)
    else:
        print(f"[feishu] 授权失败: {member_resp}", file=sys.stderr)

# ── 向文档追加 blocks ─────────────────────────────────────
def append_blocks(doc_token, children):
    for i in range(0, len(children), 50):
        batch = children[i:i+50]
        resp = feishu_post(
            f"https://open.feishu.cn/open-apis/docx/v1/documents/{doc_token}/blocks/{doc_token}/children",
            {"children": batch, "index": -1}
        )
        if resp.get("code") not in (0, None):
            print(f"[feishu] 写入失败 batch {i//50}: {resp}", file=sys.stderr)
        if i + 50 < len(children):
            time.sleep(0.5)

# ── 构建文本 block ────────────────────────────────────────
def text_block(content, bold=False, bg_color=None):
    if not content or not content.strip():
        return None
    element = {"text_run": {"content": content[:2000]}}
    style_dict = {}
    if bold:
        style_dict["bold"] = True
    if bg_color is not None:
        style_dict["background_color"] = bg_color
    if style_dict:
        element["text_run"]["text_element_style"] = style_dict
    return {
        "block_type": 2,
        "text": {"elements": [element], "style": {}}
    }

def heading_block(content, level=2):
    block_type = 2 + level
    key = "heading%d" % level
    return {
        "block_type": block_type,
        key: {
            "elements": [{"text_run": {"content": content[:200]}}]
        }
    }

def divider_block():
    return {"block_type": 22, "divider": {}}

# ── 从处理后的 JSON 创建结构化文档 ─────────────────────────
def create_structured_doc(title, processed_json_path):
    with open(processed_json_path, encoding="utf-8") as f:
        data = json.load(f)

    resp = feishu_post(
        "https://open.feishu.cn/open-apis/docx/v1/documents",
        {"title": title}
    )
    if resp.get("code") != 0:
        print(f"[feishu] 创建文档失败: {resp}", file=sys.stderr)
        return ""

    doc_token = resp["data"]["document"]["document_id"]
    doc_url = f"https://feishu.cn/docx/{doc_token}"
    grant_edit_permission(doc_token)

    children = []

    # ── 摘要部分 ──
    summary = data.get("summary", "")
    if summary:
        for line in summary.split("\n"):
            line = line.strip()
            if not line:
                continue
            if line.startswith("## "):
                blk = heading_block(line[3:].strip(), level=2)
                if blk:
                    children.append(blk)
            elif line.startswith("· ") or line.startswith("- "):
                blk = text_block(line)
                if blk:
                    children.append(blk)
            else:
                blk = text_block(line)
                if blk:
                    children.append(blk)

    children.append(divider_block())
    children.append(heading_block("对话原文（中英双语）", level=2))

    segments = data.get("segments", [])
    chapter_segments = data.get("chapter_segments", {})

    for si, seg in enumerate(segments):
        seg_type = seg.get("type", "A")
        en = seg.get("en", "").strip()
        zh = seg.get("zh", "").strip()
        is_highlight = seg.get("highlight", False)
        if not en:
            continue

        si_str = str(si)
        if si_str in chapter_segments:
            ch_title = chapter_segments[si_str]
            children.append(divider_block())
            children.append(heading_block(ch_title, level=3))

        label = "【Q】" if seg_type == "Q" else "【A】"
        bg = 7 if is_highlight else None

        prefix = "⭐ " if is_highlight else ""
        en_blk = text_block(f"{prefix}{label} {en}", bg_color=bg)
        if en_blk:
            children.append(en_blk)

        if zh and zh != "（翻译失败）":
            zh_blk = text_block(f"　　{zh}", bg_color=bg)
            if zh_blk:
                children.append(zh_blk)

    if children:
        print(f"[feishu] 写入 {len(children)} 个 blocks", file=sys.stderr)
        append_blocks(doc_token, children)

    return doc_url

# ── 从原始转录创建文档（降级方案）─────────────────────────
def create_raw_doc(title, transcript_text):
    resp = feishu_post(
        "https://open.feishu.cn/open-apis/docx/v1/documents",
        {"title": title}
    )
    if resp.get("code") != 0:
        print(f"[feishu] 创建文档失败: {resp}", file=sys.stderr)
        return ""

    doc_token = resp["data"]["document"]["document_id"]
    doc_url = f"https://feishu.cn/docx/{doc_token}"
    grant_edit_permission(doc_token)

    text = html.unescape(transcript_text)
    chunks = []
    while text:
        if len(text) <= 1500:
            chunks.append(text)
            break
        cut = text.rfind(' ', 0, 1500)
        if cut <= 0:
            cut = 1500
        chunks.append(text[:cut])
        text = text[cut:].lstrip()

    children = []
    for chunk in chunks:
        blk = text_block(chunk)
        if blk:
            children.append(blk)

    if children:
        print(f"[feishu] 写入 {len(children)} 个 blocks（原始模式）", file=sys.stderr)
        append_blocks(doc_token, children)

    return doc_url

# ── 读取 daily_message.txt 的元信息 ──────────────────────
msg_file = os.path.join(cache_dir, "daily_message.txt")
meta = {}
blocks = []
current = {}
for line in open(msg_file):
    line = line.rstrip()
    if line == "---":
        if current:
            blocks.append(current)
            current = {}
    elif "=" in line and not line.startswith("FEISHU") and not line.startswith("FOUND") and not line.startswith("TODAY"):
        k, v = line.split("=", 1)
        current[k] = v
    elif line.startswith("TODAY_DISPLAY="):
        meta["today"] = line.split("=", 1)[1]
    elif line.startswith("FOUND_COUNT="):
        meta["count"] = line.split("=", 1)[1]

today = meta.get("today", f"{date.today().month}月{date.today().day}日")
count = meta.get("count", str(len(blocks)))
today_iso = date.today().isoformat()

def read_summary(key):
    sf = os.path.join(cache_dir, f"summary_{key}.txt")
    if os.path.exists(sf):
        return open(sf).read().strip()
    return ""

def read_transcript(transcript_path):
    if transcript_path and os.path.exists(transcript_path):
        return open(transcript_path, encoding="utf-8", errors="replace").read().strip()
    return ""

# ── 多维表格配置 ─────────────────────────────────────────
LEVEL_LABELS = {"P0": "P0 特别推荐", "P1": "P1 一般推荐", "P2": "P2 空闲再看"}

def recommend_by_keywords(podcast_name, title):
    p0_podcasts = {"No Priors", "Latent Space", "Lenny's Podcast", "Dwarkesh Podcast"}
    p0_keywords = ["ai", "product", "startup", "agent", "llm", "founder", "ceo",
                   "notion", "anthropic", "openai", "google", "meta", "infrastructure"]
    if podcast_name in p0_podcasts:
        return "P0"
    for kw in p0_keywords:
        if kw in title.lower():
            return "P0"
    p1_podcasts = {"Lex Fridman Podcast", "Hard Fork (NYT)", "TWIML AI Podcast",
                   "All-In Podcast", "The Knowledge Project"}
    if podcast_name in p1_podcasts:
        return "P1"
    return "P2"

def extract_guest(title):
    import re
    m = re.search(r'(?:with|featuring)\s+(.+?)(?:\s*[-\u2013\u2014]|$)', title, re.IGNORECASE)
    if m:
        return m.group(1).strip()
    m = re.search(r'#\d+\s*[-\u2013\u2014:]\s*(.+)', title)
    if m:
        return re.split(r'\s*[-\u2013\u2014:]\s*', m.group(1).strip())[0].strip()
    m = re.search(r'The\s+(.+?)\s+Interview', title, re.IGNORECASE)
    if m:
        return m.group(1).strip()
    return ""

def extract_section(summary, section_name):
    if not summary:
        return ""
    lines = summary.split("\n")
    result = []
    in_section = False
    for line in lines:
        s = line.strip()
        if s.startswith("## ") or s.startswith("# "):
            if in_section:
                break
            if section_name in s:
                in_section = True
                continue
        elif in_section and s:
            result.append(s)
    return "\n".join(result)

# ── 组装飞书消息 + 创建文档 + 收集表格数据 ────────────────
lines = [f"\U0001f399\ufe0f \u64ad\u5ba2\u65e5\u62a5 \u00b7 {today}", ""]
bitable_records = []

for b in blocks:
    name  = b.get("PODCAST_NAME", "")
    title = html.unescape(b.get("PODCAST_TITLE", ""))
    link  = b.get("PODCAST_LINK", "")
    transcript_path = b.get("PODCAST_TRANSCRIPT", "")
    key   = b.get("PODCAST_SUMMARY", "").split("/summary_")[-1].replace(".txt", "") if "PODCAST_SUMMARY" in b else ""

    processed_json = os.path.join(cache_dir, f"processed_{key}.json")
    pdata = None
    summary = ""
    if os.path.exists(processed_json):
        with open(processed_json, encoding="utf-8") as f:
            pdata = json.load(f)
        summary = pdata.get("summary", "")
    else:
        summary = read_summary(key)

    lines.append(f"\u2501\u2501\u2501 {name} \u2501\u2501\u2501")
    lines.append(f"\U0001f4cc {title}")
    if link:
        lines.append(f"\U0001f517 {link}")

    if summary:
        for sl in summary.split("\n"):
            sl = sl.strip()
            if sl:
                sl = sl.lstrip("*# ").lstrip("1234567890. ")
                if sl:
                    lines.append(f"  {sl}")

    doc_url = ""
    if transcript_path and os.path.exists(transcript_path):
        doc_title = f"[\u64ad\u5ba2\u539f\u6587] {name} \u00b7 {title[:30]} \u00b7 {today_iso}"
        print(f"[feishu] 创建文档: {doc_title}", file=sys.stderr)

        if os.path.exists(processed_json):
            doc_url = create_structured_doc(doc_title, processed_json)
        else:
            raw_text = read_transcript(transcript_path)
            if raw_text:
                doc_url = create_raw_doc(doc_title, raw_text)

        if doc_url:
            lines.append(f"\U0001f4c4 完整转录原文: {doc_url}")

    lines.append("")

    # ── 收集多维表格记录 ──
    level = "P1"
    if pdata and pdata.get("recommend_level"):
        level = pdata["recommend_level"]
    else:
        level = recommend_by_keywords(name, title)

    guest = extract_guest(title)
    core_summary = extract_section(summary, "核心摘要")
    if not core_summary:
        slines = [l.strip() for l in summary.split("\n") if l.strip() and not l.strip().startswith("#")]
        core_summary = "\n".join(slines[:5])
    pm_insights = extract_section(summary, "产品经理 Insight")
    quotes = extract_section(summary, "精彩金句")

    from datetime import datetime
    dt = datetime.strptime(today_iso, "%Y-%m-%d")
    ts_ms = int(dt.timestamp() * 1000)

    fields = {
        "播客名称": name,
        "集标题": title,
        "嘉宾": guest,
        "日期": ts_ms,
        "推荐等级": LEVEL_LABELS.get(level, "P1 一般推荐"),
    }
    if core_summary:
        fields["核心摘要"] = core_summary[:2000]
    if pm_insights:
        fields["PM Insights"] = pm_insights[:2000]
    if quotes:
        fields["精彩金句"] = quotes[:2000]
    if doc_url:
        fields["原文文档"] = {"link": doc_url, "text": "[\u67e5\u770b\u539f\u6587]"}
    if link:
        fields["播客链接"] = {"link": link, "text": title[:50]}

    bitable_records.append({"fields": fields})

lines.append(f"\U0001f4ee \u4eca\u65e5\u5171 {count} \u671f\u65b0\u96c6 | \u6df1\u5ea6\u6458\u8981 + \u7ffb\u8bd1 by AI")

message = "\n".join(lines)

# ── 发送 ──────────────────────────────────────────────────
payload = json.dumps({
    "receive_id": receiver,
    "msg_type": "text",
    "content": json.dumps({"text": message})
}).encode()

req = urllib.request.Request(
    "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id",
    data=payload,
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"}
)
resp = json.loads(urllib.request.urlopen(req, timeout=15).read())
if resp.get("code") == 0:
    print(f"[feishu-send] 发送成功: {resp['data']['message_id']}")
else:
    print(f"[feishu-send] 发送失败: {resp}", file=sys.stderr)
    sys.exit(1)

# ── 写入多维表格 ─────────────────────────────────────────
if bitable_records and bitable_app_token and bitable_table_id:
    print(f"[feishu-send] 写入多维表格: {len(bitable_records)} 条记录", file=sys.stderr)
    for i in range(0, len(bitable_records), 10):
        batch = bitable_records[i:i+10]
        bt_resp = feishu_post(
            f"https://open.feishu.cn/open-apis/bitable/v1/apps/{bitable_app_token}/tables/{bitable_table_id}/records/batch_create",
            {"records": batch}
        )
        bt_code = bt_resp.get("code", "?")
        print(f"[feishu-send] bitable batch {i//10}: code={bt_code}", file=sys.stderr)
        if bt_code != 0:
            print(f"[feishu-send] bitable error: {bt_resp.get('msg', '')[:200]}", file=sys.stderr)
        if i + 10 < len(bitable_records):
            time.sleep(0.5)
    print(f"[feishu-send] 多维表格写入完成")
PYEOF
