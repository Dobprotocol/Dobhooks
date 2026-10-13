#!/usr/bin/env python3
"""R1 (verify_sites): builds app/<lang>/index.html from app/index.html.

The landing is hand-written static HTML, so translations are applied to the
source page instead of a runtime i18n layer:

  * text nodes   whose whitespace-normalised text is a key in <lang>.json
  * JS literals  ('...' / "...") whose exact content is a key
  * attributes   content/alt/aria-label/title whose value is a key

Keys are the English strings exactly as they appear in the HTML (entities
included). Anything without a translation stays in English. Also rewrites
<html lang>, canonical/og:url, og:locale and adds hreflang alternates to every
version (English included).

  python3 scripts/i18n/build_landing.py            # write app/{es,pt,zh,hi}/index.html + hreflang in app/index.html
  python3 scripts/i18n/build_landing.py --extract  # print untranslated keys per language
"""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'app' / 'index.html'
HERE = Path(__file__).resolve().parent
LANGS = ['es', 'pt', 'zh', 'hi']
OG_LOCALE = {'en': 'en_US', 'es': 'es_ES', 'pt': 'pt_BR', 'zh': 'zh_CN', 'hi': 'hi_IN'}
BASE = 'https://dex.dobprotocol.com'
ALT_START, ALT_END = '<!-- i18n:alternates -->', '<!-- /i18n:alternates -->'

def norm(t):
    return re.sub(r'\s+', ' ', t).strip()

def alternates(cur):
    out = [ALT_START]
    for l in ['en'] + LANGS:
        out.append(f'<link rel="alternate" hreflang="{l}" href="{BASE}/{"" if l == "en" else l + "/"}">')
    out.append(f'<link rel="alternate" hreflang="x-default" href="{BASE}/">')
    out.append(f'<meta property="og:locale" content="{OG_LOCALE[cur]}">')
    for l in ['en'] + LANGS:
        if l != cur:
            out.append(f'<meta property="og:locale:alternate" content="{OG_LOCALE[l]}">')
    out.append(ALT_END)
    return '\n'.join(out)

def with_alternates(html, cur):
    html = re.sub(re.escape(ALT_START) + r'.*?' + re.escape(ALT_END) + r'\n?', '', html, flags=re.S)
    return html.replace('<link rel="canonical"', alternates(cur) + '\n<link rel="canonical"', 1)

TOKEN = re.compile(r'(<script\b[^>]*>.*?</script>|<style\b[^>]*>.*?</style>|<!--.*?-->|<[^>]+>)', re.S)
JS_STR = re.compile(r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"")
ATTR = re.compile(r'\b(content|alt|aria-label|title|placeholder)="([^"]*)"')

def collect(html):
    keys = []
    for part in TOKEN.split(html):
        if not part:
            continue
        if part.startswith('<script') and 'src=' not in part.split('>', 1)[0]:
            for m in JS_STR.finditer(part):
                v = m.group(1) if m.group(1) is not None else m.group(2)
                if re.search(r'[A-Za-z]{3,} [A-Za-z]{2,}', v) and '<' not in v[:1] and not v.startswith(('http', '/', '.', '#')):
                    keys.append(v)
        elif part.startswith('<style') or part.startswith('<!--'):
            continue
        elif part.startswith('<'):
            for m in ATTR.finditer(part):
                if re.search(r'[A-Za-z]{3,}', m.group(2)) and not m.group(2).startswith(('http', '/', '#')):
                    keys.append(m.group(2))
        else:
            n = norm(part)
            if re.search(r'[A-Za-z]{2,}', n):
                keys.append(n)
    seen, out = set(), []
    for k in keys:
        if k not in seen:
            seen.add(k); out.append(k)
    return out

def translate(html, tr):
    def js(m):
        q = "'" if m.group(1) is not None else '"'
        v = m.group(1) if m.group(1) is not None else m.group(2)
        t = tr.get(v)
        if t is None:
            return m.group(0)
        return q + t.replace('\\', '\\\\').replace(q, '\\' + q) + q
    def attr(m):
        t = tr.get(m.group(2))
        return m.group(0) if t is None else f'{m.group(1)}="{t.replace(chr(34), "&quot;")}"'
    out = []
    for part in TOKEN.split(html):
        if not part:
            continue
        if part.startswith('<script') and 'src=' not in part.split('>', 1)[0]:
            out.append(JS_STR.sub(js, part))
        elif part.startswith('<style') or part.startswith('<!--'):
            out.append(part)
        elif part.startswith('<'):
            out.append(ATTR.sub(attr, part))
        else:
            t = tr.get(norm(part))
            if t is None:
                out.append(part)
            else:
                lead = re.match(r'\s*', part).group(0)
                trail = re.search(r'\s*$', part).group(0)
                out.append(lead + t + trail)
    return ''.join(out)

def main():
    src = SRC.read_text()
    keys = collect(with_alternates(src, 'en'))
    if '--extract' in sys.argv:
        for l in LANGS:
            f = HERE / f'{l}.json'
            tr = json.loads(f.read_text()) if f.exists() else {}
            miss = [k for k in keys if k not in tr]
            print(f'## {l}: {len(miss)} sin traducir')
            for k in miss:
                print(json.dumps(k, ensure_ascii=False))
        return
    SRC.write_text(with_alternates(src, 'en'))
    for l in LANGS:
        tr = json.loads((HERE / f'{l}.json').read_text())
        html = translate(with_alternates(src, l), tr)
        html = html.replace('<html lang="en">', f'<html lang="{l}">', 1)
        html = html.replace(f'<link rel="canonical" href="{BASE}/">', f'<link rel="canonical" href="{BASE}/{l}/">', 1)
        html = html.replace(f'<meta property="og:url" content="{BASE}/">', f'<meta property="og:url" content="{BASE}/{l}/">', 1)
        html = html.replace("toLocaleString('en-US'", f"toLocaleString('{OG_LOCALE[l].replace('_', '-')}'")
        out = ROOT / 'app' / l / 'index.html'
        out.parent.mkdir(exist_ok=True)
        out.write_text(html)
        print(f'{l}: {sum(1 for k in keys if k in tr)}/{len(keys)} strings -> {out.relative_to(ROOT)}')

if __name__ == '__main__':
    main()
