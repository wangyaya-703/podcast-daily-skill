#!/usr/bin/env python3
"""extract_vtt.py — 从 YouTube VTT 字幕文件提取去重纯文本
YouTube 自动字幕用滚动窗口格式，每个 cue 包含两行：
  - 第一行：前一句的纯文本（重复）
  - 第二行：新词（带 <c> 时间标签）
本脚本只提取不重复的文本，输出干净的逐字稿。

用法:
  python3 extract_vtt.py input.vtt output.txt              # 纯文本
  python3 extract_vtt.py input.vtt output.txt --timed out_timed.jsonl  # 额外输出带时间戳的 JSONL
"""
import sys, re, html, json

def parse_timestamp(ts):
    m = re.match(r'(\d{2}):(\d{2}):(\d{2})[.,](\d{3})', ts)
    if not m:
        return 0.0
    h, mi, s, ms = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
    return h * 3600 + mi * 60 + s + ms / 1000.0

def extract_vtt(filepath):
    with open(filepath, encoding="utf-8", errors="replace") as f:
        content = f.read()

    content = re.sub(r'^WEBVTT.*?\n\n', '', content, flags=re.DOTALL)
    cues = re.split(r'\n\n+', content.strip())

    seen_texts = set()
    result_parts = []
    timed_parts = []

    for cue in cues:
        lines = cue.strip().split('\n')
        start_sec = 0.0
        text_lines = []
        for line in lines:
            line = line.strip()
            ts_match = re.match(r'(\d{2}:\d{2}:\d{2}[.,]\d{3})\s*-->', line)
            if ts_match:
                start_sec = parse_timestamp(ts_match.group(1))
                continue
            if not line or line.startswith('Kind:') or line.startswith('Language:'):
                continue
            text_lines.append(line)

        for tl in text_lines:
            clean = re.sub(r'<[^>]+>', '', tl).strip()
            if not clean:
                continue
            clean = html.unescape(clean)
            if clean not in seen_texts:
                seen_texts.add(clean)
                result_parts.append(clean)
                timed_parts.append((start_sec, clean))

    full_text = ' '.join(result_parts)
    full_text = re.sub(r'\s+', ' ', full_text).strip()
    return full_text, timed_parts

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python3 extract_vtt.py <input.vtt> [output.txt] [--timed timed.jsonl]", file=sys.stderr)
        sys.exit(1)

    text, timed = extract_vtt(sys.argv[1])

    if len(sys.argv) >= 3 and not sys.argv[2].startswith('--'):
        with open(sys.argv[2], 'w', encoding='utf-8') as f:
            f.write(text)
        print(f"提取完成: {len(text)} 字符 -> {sys.argv[2]}", file=sys.stderr)
    else:
        print(text)

    timed_idx = None
    for i, arg in enumerate(sys.argv):
        if arg == '--timed' and i + 1 < len(sys.argv):
            timed_idx = i + 1
            break
    if timed_idx:
        with open(sys.argv[timed_idx], 'w', encoding='utf-8') as f:
            for sec, txt in timed:
                f.write(json.dumps({"t": round(sec, 1), "text": txt}, ensure_ascii=False) + "\n")
        print(f"时间戳文件: {len(timed)} 条 -> {sys.argv[timed_idx]}", file=sys.stderr)
