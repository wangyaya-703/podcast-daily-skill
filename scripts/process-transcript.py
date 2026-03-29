#!/usr/bin/env python3
"""process-transcript.py — 播客转录处理（v2）

流程：
1. 清洗转录文本
2. 段落切分 + 连续重复段去重
3. 段落级英中翻译（双语对照）
4. 结构化中文摘要（one_liner/key_points/golden_quotes/pm_insights/recommendation）
5. 可选输出双语 Markdown 文档
"""

import argparse
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

ARK_API_KEY = os.environ.get("ARK_API_KEY", "")
ARK_BASE_URL = os.environ.get("ARK_BASE_URL", "https://ark.cn-beijing.volces.com/api/coding/v3").rstrip("/")
ARK_ENDPOINT = os.environ.get("ARK_ENDPOINT", f"{ARK_BASE_URL}/chat/completions")
TRANSLATE_MODEL = os.environ.get("TRANSLATE_MODEL", "doubao-seed-2.0-lite")
SUMMARY_MODEL = os.environ.get("SUMMARY_MODEL", "glm-4.7")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
PROMPTS_DIR = os.path.join(ROOT_DIR, "prompts")

DEFAULT_TRANSLATE_PROMPT = """你是资深科技播客翻译编辑。请把英文段落翻译为自然、准确的中文。
要求：
- 保留术语英文：AI, LLM, GPU, API, transformer, RAG, token, prompt, agent 等
- 人名、公司名、产品名保留英文
- URL 保持不变
- 语气专业但口语化
只输出中文翻译，不要解释。"""

DEFAULT_SUMMARY_PROMPT = """你正在为忙碌的产品经理重写播客内容。请基于英文转录输出简洁洞察。
输出必须是 JSON，字段：
- one_liner: 一句话核心结论（中文）
- key_points: 3 条核心观点（数组）
- golden_quotes: 1-2 条英文金句（数组）
- pm_insights: 1-3 条 PM 视角洞察（数组）
- tools_mentioned: 提到的工具/方法（数组，可空）
- recommendation: P0/P1/P2 之一
- summary_zh: 200-400 字中文摘要
只输出合法 JSON。"""


def log(msg: str) -> None:
    print(f"[process] {msg}", file=sys.stderr)


def ensure_env() -> None:
    if not ARK_API_KEY:
        print("错误: 请设置 ARK_API_KEY 环境变量", file=sys.stderr)
        sys.exit(1)


def load_prompt(filename: str, default: str) -> str:
    path = os.path.join(PROMPTS_DIR, filename)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            content = f.read().strip()
            if content:
                return content
    return default


def ark_chat(prompt: str, model: str, max_tokens: int = 4096, temperature: float = 0.2) -> str:
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": temperature,
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        ARK_ENDPOINT,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {ARK_API_KEY}",
        },
    )

    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = json.loads(resp.read())
                return data["choices"][0]["message"]["content"].strip()
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="ignore")
            log(f"HTTP 错误 (attempt {attempt}/3): {e.code}, {body[:200]}")
        except Exception as e:
            log(f"API 调用失败 (attempt {attempt}/3): {e}")
        time.sleep(attempt)
    return ""


def clean_text(text: str) -> str:
    text = html.unescape(text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[.,]\d{3}", "", text)
    text = re.sub(r"\[(music|applause|laughter)\]", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def normalize_for_dedup(s: str) -> str:
    s = s.lower()
    s = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", "", s)
    return s


def split_into_segments(text: str, max_chars: int = 1200):
    # 优先按句子边界切块，避免逐句调用模型导致成本暴涨
    sentences = re.split(r"(?<=[.!?。！？])\s+", text)
    segments = []
    cur = ""

    for sent in sentences:
        sent = sent.strip()
        if not sent:
            continue

        if len(cur) + len(sent) + 1 <= max_chars:
            cur = f"{cur} {sent}".strip()
            continue

        if cur:
            segments.append(cur)

        # 单句超长时强制切片
        if len(sent) > max_chars:
            for i in range(0, len(sent), max_chars):
                segments.append(sent[i : i + max_chars].strip())
            cur = ""
        else:
            cur = sent

    if cur:
        segments.append(cur)

    # 去掉很短噪声段
    segments = [s for s in segments if len(s) >= 20]

    # 修复 bug: 去掉连续重复段
    deduped = []
    prev_norm = ""
    for seg in segments:
        n = normalize_for_dedup(seg)
        if n and n == prev_norm:
            continue
        deduped.append(seg)
        prev_norm = n

    return deduped


def load_chapters(chapters_file: str):
    if not chapters_file or not os.path.exists(chapters_file):
        return []
    try:
        with open(chapters_file, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, list):
            return []
        out = []
        for ch in data:
            start = ch.get("start_time", 0)
            title = (ch.get("title") or "").strip()
            if title:
                out.append((float(start), title))
        return out
    except Exception:
        return []


def load_timed_data(timed_file: str):
    if not timed_file or not os.path.exists(timed_file):
        return []
    result = []
    with open(timed_file, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                t = float(d.get("t", 0))
                txt = str(d.get("text", ""))
                if txt:
                    result.append((t, txt))
            except Exception:
                continue
    return result


def map_segments_to_chapters(segments, chapters, timed_data):
    if not chapters or not timed_data:
        return {}

    seg_to_time = {}
    timed_len = len(timed_data)

    for i, seg in enumerate(segments):
        probe = normalize_for_dedup(seg[:120])
        if not probe:
            continue
        est_idx = int((i / max(len(segments), 1)) * max(timed_len - 1, 0))
        best_t = timed_data[est_idx][0]

        for j in range(max(0, est_idx - 20), min(timed_len, est_idx + 40)):
            ttxt = normalize_for_dedup(timed_data[j][1])
            if probe[:20] and probe[:20] in ttxt:
                best_t = timed_data[j][0]
                break

        seg_to_time[i] = best_t

    chapter_starts = sorted(chapters, key=lambda x: x[0])
    chapter_first_seg = {}

    for i, ts in sorted(seg_to_time.items()):
        current_title = chapter_starts[0][1]
        for cs, ct in chapter_starts:
            if ts >= cs:
                current_title = ct
            else:
                break
        if current_title not in chapter_first_seg:
            chapter_first_seg[current_title] = i

    return chapter_first_seg


def translate_segments(segments, prompt_template: str):
    translated = []
    total = len(segments)

    for idx, seg in enumerate(segments, 1):
        prompt = (
            f"{prompt_template}\n\n"
            "[英文原文]\n"
            f"{seg}\n\n"
            "[输出要求]\n"
            "只输出对应的中文翻译，不要解释。"
        )
        log(f"翻译段落 {idx}/{total}")
        zh = ark_chat(prompt, model=TRANSLATE_MODEL, max_tokens=1800, temperature=0.2)
        if not zh:
            zh = "（翻译失败）"
        translated.append(zh.strip())
    return translated


def parse_first_json(text: str):
    text = text.strip()
    if not text:
        return None

    # 优先直接解析
    try:
        return json.loads(text)
    except Exception:
        pass

    # 回退：提取首个 JSON 对象
    m = re.search(r"\{[\s\S]*\}", text)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except Exception:
        return None


def fallback_summary(segments):
    excerpt = " ".join(segments[:3])[:280]
    return {
        "one_liner": "这期对话围绕技术趋势与实践展开，值得快速浏览关键观点。",
        "key_points": [
            "讨论了技术演进与落地路径",
            "包含可执行的方法或判断",
            "对产品与工程协作有参考价值",
        ],
        "golden_quotes": [],
        "pm_insights": ["建议结合自身业务场景验证，而非直接照搬。"],
        "tools_mentioned": [],
        "recommendation": "P1",
        "summary_zh": excerpt if excerpt else "摘要生成失败，建议查看原文。",
    }


def normalize_summary(data):
    if not isinstance(data, dict):
        return fallback_summary([])

    rec = str(data.get("recommendation", "P1")).upper().strip()
    if rec not in {"P0", "P1", "P2"}:
        rec = "P1"

    def ensure_list(key, limit, default=None):
        value = data.get(key, default if default is not None else [])
        if isinstance(value, str):
            value = [value] if value.strip() else []
        if not isinstance(value, list):
            value = []
        out = [str(x).strip() for x in value if str(x).strip()]
        return out[:limit]

    one_liner = str(data.get("one_liner", "")).strip()
    summary_zh = str(data.get("summary_zh", "")).strip()

    key_points = ensure_list("key_points", 5, default=[])
    if len(key_points) < 3:
        key_points = (key_points + ["观点待补充"] * 3)[:3]

    golden_quotes = ensure_list("golden_quotes", 3, default=[])
    pm_insights = ensure_list("pm_insights", 5, default=[])
    if not pm_insights:
        pm_insights = ["建议结合团队现状做小规模验证，再扩大投入。"]

    tools = ensure_list("tools_mentioned", 8, default=[])

    return {
        "one_liner": one_liner,
        "key_points": key_points,
        "golden_quotes": golden_quotes,
        "pm_insights": pm_insights,
        "tools_mentioned": tools,
        "recommendation": rec,
        "summary_zh": summary_zh,
    }


def generate_summary(podcast_name: str, episode_title: str, transcript_text: str, prompt_template: str):
    prompt = (
        f"{prompt_template}\n\n"
        f"播客：{podcast_name}\n"
        f"标题：{episode_title}\n\n"
        "转录（可能截断）：\n"
        f"{transcript_text[:12000]}\n"
    )
    log("生成结构化摘要")
    raw = ark_chat(prompt, model=SUMMARY_MODEL, max_tokens=2200, temperature=0.3)
    parsed = parse_first_json(raw)
    if parsed is None:
        log("摘要 JSON 解析失败，使用兜底摘要")
        return fallback_summary(split_into_segments(transcript_text, max_chars=1000)[:5])
    return normalize_summary(parsed)


def build_markdown(
    output_path: str,
    podcast_name: str,
    episode_title: str,
    date_str: str,
    duration: str,
    recommendation: str,
    summary: dict,
    segments,
    chapter_first_seg,
    episode_link: str,
):
    lines = []
    lines.append(f"# {podcast_name} {episode_title}")

    meta = [date_str, f"{recommendation} 推荐"]
    if duration:
        meta.append(duration)
    lines.append(f"> {' | '.join(meta)}")
    if episode_link:
        lines.append(f"> 原链接: {episode_link}")
    lines.append("")

    lines.append("## 摘要")
    if summary.get("summary_zh"):
        lines.append(summary["summary_zh"])
    if summary.get("one_liner"):
        lines.append("")
        lines.append(f"- 一句话结论：{summary['one_liner']}")
    if summary.get("key_points"):
        lines.append("- 核心观点：")
        for p in summary["key_points"]:
            lines.append(f"  - {p}")
    if summary.get("golden_quotes"):
        lines.append("- 金句：")
        for q in summary["golden_quotes"]:
            lines.append(f"  - {q}")
    if summary.get("pm_insights"):
        lines.append("- PM 洞察：")
        for insight in summary["pm_insights"]:
            lines.append(f"  - {insight}")

    chapter_by_index = {idx: title for title, idx in chapter_first_seg.items()}

    for i, seg in enumerate(segments):
        if i in chapter_by_index:
            lines.append("")
            lines.append(f"## {chapter_by_index[i]}")
            lines.append("")

        lines.append(seg["en"])
        lines.append("")
        lines.append(seg["zh"])
        lines.append("")

    lines.append("---")
    lines.append("Generated by podcast-daily-skill")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines).strip() + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript_file")
    parser.add_argument("podcast_name")
    parser.add_argument("episode_title")
    parser.add_argument("--out", required=True)
    parser.add_argument("--chapters", default="")
    parser.add_argument("--timed", default="")
    parser.add_argument("--markdown-out", default="")
    parser.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"))
    parser.add_argument("--duration", default="")
    parser.add_argument("--episode-link", default="")
    args = parser.parse_args()

    ensure_env()

    if not os.path.exists(args.transcript_file):
        log(f"文件不存在: {args.transcript_file}")
        sys.exit(1)

    with open(args.transcript_file, encoding="utf-8", errors="replace") as f:
        raw_text = f.read()

    cleaned = clean_text(raw_text)
    segments_en = split_into_segments(cleaned, max_chars=1200)

    if not segments_en:
        log("分段后为空，退出")
        sys.exit(1)

    log(f"原文长度: {len(cleaned)} 字符")
    log(f"段落数: {len(segments_en)}")

    translate_prompt = load_prompt("translate-bilingual.md", DEFAULT_TRANSLATE_PROMPT)
    summary_prompt = load_prompt("summarize-podcast.md", DEFAULT_SUMMARY_PROMPT)

    segments_zh = translate_segments(segments_en, translate_prompt)
    summary = generate_summary(args.podcast_name, args.episode_title, cleaned, summary_prompt)

    chapters = load_chapters(args.chapters)
    timed_data = load_timed_data(args.timed)
    chapter_first_seg = map_segments_to_chapters(segments_en, chapters, timed_data)

    segment_items = []
    for en, zh in zip(segments_en, segments_zh):
        segment_items.append({"en": en, "zh": zh})

    estimated_duration_seconds = int(max((t for t, _ in timed_data), default=0))

    out = {
        "podcast_name": args.podcast_name,
        "episode_title": html.unescape(args.episode_title),
        "recommendation": summary.get("recommendation", "P1"),
        "summary": {
            "one_liner": summary.get("one_liner", ""),
            "key_points": summary.get("key_points", []),
            "golden_quotes": summary.get("golden_quotes", []),
            "pm_insights": summary.get("pm_insights", []),
            "tools_mentioned": summary.get("tools_mentioned", []),
            "summary_zh": summary.get("summary_zh", ""),
        },
        "chapters": [{"start": s, "title": t} for s, t in chapters],
        "chapter_segments": {str(v): k for k, v in chapter_first_seg.items()},
        "segments": segment_items,
        "meta": {
            "raw_length": len(cleaned),
            "total_segments": len(segment_items),
            "chapter_count": len(chapters),
            "estimated_duration_seconds": estimated_duration_seconds,
            "processed_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
    }

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    if args.markdown_out:
        build_markdown(
            output_path=args.markdown_out,
            podcast_name=args.podcast_name,
            episode_title=html.unescape(args.episode_title),
            date_str=args.date,
            duration=args.duration,
            recommendation=out["recommendation"],
            summary=out["summary"],
            segments=segment_items,
            chapter_first_seg=chapter_first_seg,
            episode_link=args.episode_link,
        )

    log(f"处理完成: {args.out}")


if __name__ == "__main__":
    main()
