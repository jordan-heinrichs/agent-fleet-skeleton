#!/usr/bin/env python3
"""Web grounding for the fleet — search + fetch + extract, with a Redis cache.

Queries SearXNG, fetches + extracts top pages, prints a markdown context block
with REAL urls for the model to synthesize from. Every search and every page
fetch is cached in Redis with a TTL, so repeat work across fires is instant.

CACHE / EVICTION
  Cache keys carry a TTL (CACHE_TTL, default 24h). Redis is configured with
  maxmemory-policy=volatile-lru, so when memory fills it evicts the
  least-recently-used keys that HAVE a TTL — i.e. stale cache entries get shed,
  while the job/result queue keys (which have NO TTL) are protected. That gives
  the "keep hot, drop cold" cache you want without ever evicting live work.

Usage:  research.py "<query>" [num_results]
Env:
  SEARXNG_URL                 default http://searxng:8080
  REDIS_URL                   default redis://redis:6379  (cache; optional)
  CACHE_TTL                   seconds, default 86400
  SEARCH_PREFERRED_DOMAINS    space-separated, ranked first (from the pack)
  SEARCH_BLOCK_DOMAINS        space-separated, dropped (from the pack)
"""
import os
import re
import sys
import json
import hashlib
import urllib.parse
import urllib.request

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://searxng:8080")
UA = "Mozilla/5.0 (compatible; fleet-research/1.0)"
PER_PAGE_CHARS = int(os.environ.get("RESEARCH_PAGE_CHARS", "3500"))
MAX_RESULTS = int(os.environ.get("RESEARCH_RESULTS", "6"))
CACHE_TTL = int(os.environ.get("CACHE_TTL", "86400"))

PREFERRED = tuple(d for d in os.environ.get("SEARCH_PREFERRED_DOMAINS", "").split() if d)
BLOCK_DEFAULT = ("merriam-webster", "accounts.google", "account.microsoft",
                 "login.", "/signin", "youtube.com", "facebook.com",
                 "linkedin.com", "pinterest", "quora.com")
BLOCK = BLOCK_DEFAULT + tuple(d for d in os.environ.get("SEARCH_BLOCK_DOMAINS", "").split() if d)

# ── Redis cache (optional — degrades gracefully if unavailable) ──────────────
try:
    import redis
    _R = redis.from_url(os.environ.get("REDIS_URL", "redis://redis:6379"),
                        socket_timeout=3, socket_connect_timeout=3)
    _R.ping()
except Exception:
    _R = None


def _ckey(kind, s):
    return f"cache:{kind}:{hashlib.sha1(s.encode('utf-8')).hexdigest()}"


def cache_get(key):
    if not _R:
        return None
    try:
        v = _R.get(key)
        return v.decode("utf-8", "replace") if v is not None else None
    except Exception:
        return None


def cache_set(key, val):
    if not _R:
        return
    try:
        _R.set(key, val, ex=CACHE_TTL)   # TTL => evictable under volatile-lru
    except Exception:
        pass


def http_get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(), r.headers.get("Content-Type", "")


def searxng(query):
    key = _ckey("search", query)
    hit = cache_get(key)
    if hit is not None:
        return json.loads(hit)
    qs = urllib.parse.urlencode({"q": query, "format": "json"})
    raw, _ = http_get(f"{SEARXNG_URL}/search?{qs}")
    results = json.loads(raw.decode("utf-8", "replace")).get("results", [])
    cache_set(key, json.dumps(results))
    return results


def rank(results):
    def score(r):
        u = (r.get("url") or "").lower()
        if any(b in u for b in BLOCK):
            return -1
        return sum(2 for p in PREFERRED if p in u)
    return [r for s, r in sorted(((score(r), r) for r in results),
                                 key=lambda x: -x[0]) if s >= 0]


def extract_pdf(data):
    try:
        import io
        import pypdf
        reader = pypdf.PdfReader(io.BytesIO(data))
        return "\n".join((p.extract_text() or "") for p in reader.pages[:8])
    except Exception:
        return ""


def extract_text(url):
    key = _ckey("fetch", url)
    hit = cache_get(key)
    if hit is not None:
        return hit
    try:
        data, ctype = http_get(url, timeout=18)
    except Exception:
        return ""
    if "pdf" in ctype.lower() or url.lower().endswith(".pdf"):
        text = extract_pdf(data)
    else:
        text = ""
        try:
            import trafilatura
            text = trafilatura.extract(data.decode("utf-8", "replace"),
                                       include_comments=False) or ""
        except Exception:
            text = ""
        if not text:
            try:
                html = data.decode("utf-8", "replace")
                html = re.sub(r"(?is)<(script|style|nav|footer|header).*?>.*?</\1>", " ", html)
                text = re.sub(r"\s+", " ", re.sub(r"(?s)<[^>]+>", " ", html)).strip()
            except Exception:
                text = ""
    cache_set(key, text)
    return text


def main():
    if len(sys.argv) < 2:
        print("(no query provided)")
        return
    base = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else MAX_RESULTS

    angles = [base, base + " vulnerability exploit", base + " analysis 2025"]
    seen, results = set(), []
    for q in angles:
        try:
            for r in searxng(q):
                u = r.get("url")
                if u and u not in seen:
                    seen.add(u)
                    results.append(r)
        except Exception:
            continue

    results = rank(results)[:n]
    if not results:
        print("(no search results)")
        return

    blocks = []
    for r in results:
        url = (r.get("url") or "").strip()
        title = (r.get("title") or url).strip()
        body = (extract_text(url) or (r.get("content") or ""))[:PER_PAGE_CHARS]
        if len(body) < 120:
            continue
        blocks.append(f"### {title}\nURL: {url}\n\n{body}\n")

    cached_note = " (redis cache active)" if _R else " (no cache)"
    print(f"LIVE WEB CONTEXT — {len(blocks)} sources for: {base}{cached_note}\n")
    print("\n---\n".join(blocks))


if __name__ == "__main__":
    main()
