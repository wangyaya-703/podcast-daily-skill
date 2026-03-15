#!/usr/bin/env python3
# parse_rss.py — 解析 RSS 最新一集，供 podcast-daily.sh 调用
# 用法: echo <rss_content> | python3 parse_rss.py <name> <hours_limit>

import sys
import re
from datetime import datetime, timezone

name = sys.argv[1] if len(sys.argv) > 1 else "unknown"
hours_limit = int(sys.argv[2]) if len(sys.argv) > 2 else 48
content = sys.stdin.read()

def strip_tags(s):
    s = re.sub(r'<!\[CDATA\[(.*?)\]\]>', r'\1', s, flags=re.DOTALL)
    s = re.sub(r'<[^>]+>', '', s)
    return s.strip()

# 找第一个 <item>
m = re.search(r'<item[^>]*>(.*?)</item>', content, re.DOTALL)
if not m:
    sys.exit(0)
item = m.group(1)

def get(tag):
    m2 = re.search(r'<' + tag + r'[^>]*>(.*?)</' + tag + r'>', item, re.DOTALL)
    return strip_tags(m2.group(1)).replace('\n', ' ').strip() if m2 else ''

title   = get('title')
link    = get('link')
pubdate = get('pubDate')
desc    = get('description')[:300]

enc = re.search(r'<enclosure[^>]+url=["\']([^"\']+)', item)
audio = enc.group(1) if enc else ''

# 检查时间限制
if pubdate:
    try:
        from email.utils import parsedate_to_datetime
        pub_dt = parsedate_to_datetime(pubdate)
        now_dt = datetime.now(timezone.utc)
        hours_ago = (now_dt - pub_dt).total_seconds() / 3600
        if hours_ago > hours_limit:
            print(f"SKIP: {hours_ago:.0f}h ago", file=sys.stderr)
            sys.exit(0)
    except Exception:
        pass

if not title:
    sys.exit(0)

print(f"TITLE={title}")
print(f"LINK={link}")
print(f"PUBDATE={pubdate}")
print(f"DESC={desc}")
print(f"AUDIO={audio}")
