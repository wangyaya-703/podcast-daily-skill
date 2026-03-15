#!/usr/bin/env python3
# process-transcript.py — 播客转录后处理
# 清洗 → 章节分段 → 翻译 → Q/A格式化 → 增强摘要+金句 → 高亮标记
#
# 用法: python3 process-transcript.py <transcript.txt> <podcast_name> <episode_title> --out <output.json>
#       [--chapters chapters.json] [--timed timed.jsonl]
#
# 必需环境变量: ARK_API_KEY
# 可选环境变量: ARK_ENDPOINT, TRANSLATE_MODEL, SUMMARY_MODEL, RECOMMEND_MODE

import sys, json, os, re, html, urllib.request, urllib.error, time, argparse

ARK_API_KEY = os.environ.get("ARK_API_KEY")
if not ARK_API_KEY:
    print("错误: 请设置 ARK_API_KEY 环境变量", file=sys.stderr)
    sys.exit(1)

TRANSLATE_MODEL = os.environ.get("TRANSLATE_MODEL", "doubao-seed-2-0-mini-260215")
SUMMARY_MODEL = os.environ.get("SUMMARY_MODEL", "doubao-seed-2-0-mini-260215")
ARK_ENDPOINT = os.environ.get("ARK_ENDPOINT")
if not ARK_ENDPOINT:
    print("错误: 请设置 ARK_ENDPOINT 环境变量（例如: https://your-provider/api/v3/chat/completions）", file=sys.stderr)
    sys.exit(1)

def log(msg):
    print(f"[process] {msg}", file=sys.stderr)

# ── Ark API ───────────────────────────────────────────────
def ark_chat(prompt, model=TRANSLATE_MODEL, max_tokens=4096, temperature=0.3):
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature
    }).encode()
    req = urllib.request.Request(
        ARK_ENDPOINT, data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {ARK_API_KEY}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            d = json.loads(resp.read())
            return d["choices"][0]["message"]["content"].strip()
    except urllib.error.HTTPError as e:
        log(f"API 错误 HTTP {e.code}: {e.read().decode()[:200]}")
        return ""
    except Exception as e:
        log(f"API 调用失败: {e}")
        return ""

# ── 文本清洗 ──────────────────────────────────────────────
def clean_text(text):
    text = html.unescape(text)
    text = re.sub(r'<[^>]+>', '', text)
    text = re.sub(r'\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[.,]\d{3}', '', text)
    text = re.sub(r'>>\s*', '', text)
    text = re.sub(r'\[(?:music|applause|laughter)\]', '', text, flags=re.IGNORECASE)
    text = re.sub(r'\s+', ' ', text).strip()
    return text

# ── 分段 ──────────────────────────────────────────────────
def split_into_segments(text, max_chars=500):
    sentences = re.split(r'(?<=[.!?])\s+(?=[A-Z])', text)
    segments = []
    current = ""
    for sent in sentences:
        if len(current) + len(sent) + 1 > max_chars and current:
            segments.append(current.strip())
            current = sent
        else:
            current = (current + " " + sent).strip()
    if current:
        segments.append(current.strip())
    return [s for s in segments if len(s) > 10]

# ── Q/A 类型检测 ──────────────────────────────────────────
def detect_qa_type(segment):
    s = segment.strip()
    if s.endswith('?') and len(s) < 300:
        return "Q"
    q_starters = ['what ', 'how ', 'why ', 'when ', 'where ', 'who ',
                  'do you ', 'can you ', 'could you ', 'would you ',
                  'tell me', 'is it ', 'are you ', 'have you ',
                  'so what', 'so how', "what's ", "how's "]
    lower = s.lower()
    for starter in q_starters:
        if lower.startswith(starter) or lower.startswith('- ' + starter):
            return "Q"
    if '?' in s and len(s) < 200:
        return "Q"
    return "A"

# ── 章节信息加载 ──────────────────────────────────────────
def load_chapters(chapters_file):
    if not chapters_file or not os.path.exists(chapters_file):
        return []
    try:
        with open(chapters_file) as f:
            data = json.load(f)
        if isinstance(data, list):
            return [(ch.get("start_time", 0), ch.get("title", "")) for ch in data if ch.get("title")]
        return []
    except (json.JSONDecodeError, IOError):
        return []

def load_timed_data(timed_file):
    if not timed_file or not os.path.exists(timed_file):
        return []
    parts = []
    with open(timed_file) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    d = json.loads(line)
                    parts.append((d["t"], d["text"]))
                except (json.JSONDecodeError, KeyError):
                    pass
    return parts

def map_segments_to_chapters(segments, chapters, timed_data):
    if not chapters or not timed_data:
        return {}

    total_segs = len(segments)
    total_timed = len(timed_data)

    seg_times = {}
    timed_idx = 0
    for si, seg in enumerate(segments):
        seg_words = seg[:60].lower().split()
        estimated = max(timed_idx, int(si / total_segs * total_timed) - 5)
        search_start = max(0, estimated - 10)
        search_end = min(total_timed, estimated + 50)

        best_t = None
        for ti in range(search_start, search_end):
            timed_text = timed_data[ti][1].lower()
            if len(seg_words) >= 3:
                match_str = " ".join(seg_words[:4])
                if match_str in timed_text or timed_text[:30] in seg[:60].lower():
                    best_t = timed_data[ti][0]
                    timed_idx = ti
                    break
            elif timed_text[:25] in seg[:60].lower() and len(timed_text) > 5:
                best_t = timed_data[ti][0]
                timed_idx = ti
                break

        if best_t is None and total_timed > 0:
            ratio = si / max(total_segs, 1)
            est_idx = min(int(ratio * total_timed), total_timed - 1)
            best_t = timed_data[est_idx][0]
            timed_idx = est_idx

        if best_t is not None:
            seg_times[si] = best_t

    chapter_starts = sorted(chapters, key=lambda x: x[0])
    chapter_first_seg = {}

    for si, t in sorted(seg_times.items()):
        chapter_title = chapter_starts[0][1]
        for cs, ct in chapter_starts:
            if t >= cs:
                chapter_title = ct
            else:
                break
        if chapter_title not in chapter_first_seg:
            chapter_first_seg[chapter_title] = si

    return chapter_first_seg

# ── 翻译 ──────────────────────────────────────────────────
def translate_batch(segments, batch_size=10):
    translations = []
    total = len(segments)
    for i in range(0, total, batch_size):
        batch = segments[i:i+batch_size]
        numbered = "\n".join(f"[{j+1}] {seg}" for j, seg in enumerate(batch))
        prompt = f"""请将以下英文播客对话翻译成中文。保持原意，语言自然流畅。每段用 [编号] 开头，一一对应。只输出翻译。

{numbered}"""
        log(f"翻译 {i+1}-{min(i+batch_size, total)}/{total}")
        result = ark_chat(prompt, model=TRANSLATE_MODEL, max_tokens=4096, temperature=0.2)
        if not result:
            translations.extend(["（翻译失败）"] * len(batch))
            continue
        parsed = {}
        current_num = None
        current_text = []
        for line in result.strip().split("\n"):
            m = re.match(r'\[(\d+)\]\s*(.*)', line)
            if m:
                if current_num is not None:
                    parsed[current_num] = " ".join(current_text).strip()
                current_num = int(m.group(1))
                current_text = [m.group(2)]
            elif current_num is not None:
                current_text.append(line.strip())
        if current_num is not None:
            parsed[current_num] = " ".join(current_text).strip()
        for j in range(len(batch)):
            translations.append(parsed.get(j+1, "（翻译失败）"))
        if i + batch_size < total:
            time.sleep(1)
    return translations

# ── 增强摘要 + 金句 ──────────────────────────────────────
def generate_enhanced_summary(podcast_name, episode_title, transcript_text):
    text_for_summary = transcript_text[:8000]
    prompt = f"""你是一位资深产品经理和科技行业分析师。请根据以下播客转录内容，生成深度结构化摘要。

播客：{podcast_name}
标题：{episode_title}

转录内容：
{text_for_summary}

请严格按以下格式输出（中文）：

## 推荐等级
根据内容与产品经理/科技从业者的相关度，只输出 P0、P1 或 P2 之一：
- P0 特别推荐：AI/大模型/产品策略/创业/技术趋势高度相关，嘉宾是行业重量级人物，内容对产品经理有直接可操作启发
- P1 一般推荐：科技/商业/技术话题，有一定参考价值但不是核心关注领域
- P2 空闲再看：娱乐/体育/生活话题，与产品经理工作关联度低

## 核心摘要
用3-5段话总结本期核心内容，包含主要话题、嘉宾关键论点、重要数据或案例。

## 核心观点
· 观点1（一句话概括）
· 观点2
· 观点3
· 观点4（如有）
· 观点5（如有）

## 精彩金句
从原文中挑选3-5句最有洞察力、最值得记住的金句，保留英文原文并附中文翻译：
1. "English quote here" — 中文翻译
2. "English quote here" — 中文翻译
3. "English quote here" — 中文翻译

## 产品经理 Insight
从产品经理视角提炼可操作洞察（3-5条，每条1-2句话，要具体可落地）：
· 产品设计/策略启发
· 增长/获客方法论
· 组织管理/团队协作
· 技术趋势对产品的影响
· 用户需求洞察

## 推荐工具/方法
列出播客中提到的工具、框架或方法（没有则写"无"）

只输出上述内容。"""

    log("生成增强摘要+金句+打标...")
    result = ark_chat(prompt, model=SUMMARY_MODEL, max_tokens=3000, temperature=0.3) or "（摘要生成失败）"

    level = None
    for line in result.split("\n"):
        stripped = line.strip()
        if stripped in ("P0", "P1", "P2"):
            level = stripped
            break
        for lv in ["P0", "P1", "P2"]:
            if stripped.startswith(lv) or stripped == lv:
                level = lv
                break
        if level:
            break

    if not level:
        level = recommend_by_keywords(podcast_name, episode_title)
        log(f"摘要中未提取到等级，fallback 关键词: {level}")
    else:
        log(f"AI 推荐等级: {level}")

    return result, level

# ── 推荐等级打标 ─────────────────────────────────────────
RECOMMEND_MODE = os.environ.get("RECOMMEND_MODE", "ai")

def recommend_by_keywords(podcast_name, episode_title):
    p0_podcasts = {"No Priors", "Latent Space", "Lenny's Podcast", "Dwarkesh Podcast"}
    p0_keywords = ["ai", "product", "startup", "agent", "llm", "founder", "ceo",
                   "notion", "anthropic", "openai", "google", "meta", "apple",
                   "infrastructure", "scaling", "reasoning", "model"]
    title_lower = episode_title.lower()
    if podcast_name in p0_podcasts:
        return "P0"
    for kw in p0_keywords:
        if kw in title_lower:
            return "P0"
    p1_podcasts = {"Lex Fridman Podcast", "Hard Fork (NYT)", "TWIML AI Podcast",
                   "All-In Podcast", "The Knowledge Project"}
    if podcast_name in p1_podcasts:
        return "P1"
    return "P2"

def recommend_by_ai(podcast_name, episode_title, summary_text):
    summary_excerpt = summary_text[:2000] if summary_text else ""
    prompt = f"""你是一位科技行业产品经理的播客推荐助手。请根据以下播客信息判断推荐等级。

播客：{podcast_name}
标题：{episode_title}
摘要：{summary_excerpt}

推荐等级标准：
- P0 特别推荐：与 AI/大模型/产品策略/创业/技术趋势高度相关，嘉宾是行业重量级人物
- P1 一般推荐：科技/商业/技术话题，有一定参考价值但不是核心关注领域
- P2 空闲再看：娱乐/体育/非科技话题，或与产品经理工作关联度低

请只输出一个词：P0 或 P1 或 P2"""

    log("AI 推荐等级打标...")
    result = ark_chat(prompt, model=TRANSLATE_MODEL, max_tokens=10, temperature=0.1)
    if result:
        result = result.strip().upper()
        for level in ["P0", "P1", "P2"]:
            if level in result:
                log(f"AI 打标结果: {level}")
                return level
    log("AI 打标失败，fallback 到关键词")
    return None

def get_recommend_level(podcast_name, episode_title, summary_text=""):
    if RECOMMEND_MODE == "ai":
        ai_result = recommend_by_ai(podcast_name, episode_title, summary_text)
        if ai_result:
            return ai_result
    return recommend_by_keywords(podcast_name, episode_title)

# ── 从摘要中提取金句用于高亮 ─────────────────────────────
def extract_quotes_for_highlight(summary, segments):
    highlight_indices = set()
    quotes = re.findall(r'"([^"]{20,})"', summary)
    if not quotes:
        quotes = re.findall(r'\u201c([^\u201d]{20,})\u201d', summary)

    for quote in quotes:
        quote_lower = quote.lower()[:60]
        for i, seg in enumerate(segments):
            if quote_lower in seg.lower():
                highlight_indices.add(i)
                break
    return highlight_indices

# ── 主流程 ────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript_file")
    parser.add_argument("podcast_name")
    parser.add_argument("episode_title")
    parser.add_argument("--out", required=True)
    parser.add_argument("--chapters", default="")
    parser.add_argument("--timed", default="")
    args = parser.parse_args()

    if not os.path.exists(args.transcript_file):
        log(f"文件不存在: {args.transcript_file}")
        sys.exit(1)

    # 0. 缓存去重
    if os.path.exists(args.out):
        try:
            with open(args.out, encoding="utf-8") as f:
                existing = json.load(f)
            if existing.get("episode_title") == html.unescape(args.episode_title) and existing.get("segments"):
                log(f"缓存命中，跳过处理: {args.out} ({len(existing['segments'])} 段)")
                return
        except (json.JSONDecodeError, KeyError, IOError):
            pass

    # 1. 读取并清洗
    with open(args.transcript_file, encoding="utf-8", errors="replace") as f:
        raw_text = f.read()
    text = clean_text(raw_text)
    log(f"原文长度: {len(text)} 字符")

    # 2. 加载章节和时间戳数据
    chapters = load_chapters(args.chapters)
    timed_data = load_timed_data(args.timed)
    if chapters:
        log(f"加载 {len(chapters)} 个章节")

    # 3. 分段
    segments = split_into_segments(text, max_chars=500)
    log(f"分成 {len(segments)} 段")

    # 4. Q/A 类型检测
    qa_types = [detect_qa_type(seg) for seg in segments]

    # 5. 章节映射
    chapter_first_seg = map_segments_to_chapters(segments, chapters, timed_data)

    # 6. 翻译
    log("开始翻译...")
    translations = translate_batch(segments)

    # 7. 增强摘要 + 金句 + 推荐等级
    summary, recommend_level = generate_enhanced_summary(args.podcast_name, args.episode_title, text)

    # 8. 高亮标记
    highlight_indices = extract_quotes_for_highlight(summary, segments)
    if highlight_indices:
        log(f"标记 {len(highlight_indices)} 段高亮")

    # 9. 组装 segments
    result_segments = []
    for i, (en, zh, qtype) in enumerate(zip(segments, translations, qa_types)):
        seg_data = {
            "en": en,
            "zh": zh,
            "type": qtype,
        }
        if i in highlight_indices:
            seg_data["highlight"] = True
        result_segments.append(seg_data)

    # 10. 输出
    output = {
        "podcast_name": args.podcast_name,
        "episode_title": html.unescape(args.episode_title),
        "recommend_level": recommend_level,
        "summary": summary,
        "chapters": [{"start": s, "title": t} for s, t in chapters] if chapters else [],
        "chapter_segments": {str(v): k for k, v in chapter_first_seg.items()},
        "segments": result_segments,
        "meta": {
            "total_chars": len(text),
            "total_segments": len(result_segments),
            "highlight_count": len(highlight_indices),
            "chapter_count": len(chapters),
            "processed_at": time.strftime("%Y-%m-%d %H:%M:%S")
        }
    }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    log(f"处理完成: {args.out} ({len(result_segments)} 段, {len(highlight_indices)} 高亮, {len(chapters)} 章节)")

if __name__ == "__main__":
    main()
