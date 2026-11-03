#!/usr/bin/env python3
"""Rank catalog entries for a task description.

Usage:
  python3 -I search.py "<query>" [--top 5] [--json] [--catalog PATH] [--category C]
                                 [--kinds skill,collection,plugin] [--min-score 15] [--explain]
Exit codes: 0 results printed; 3 nothing scored >= --min-score; 2 catalog unreadable.

Scoring (0-100): every query token that occurs somewhere in the catalog carries an IDF weight
(rare tokens count more). For each entry, a token earns its IDF times the best field weight it
hits (name 12, alias 12, tag 8, category 4, description 5; fuzzy hits at 60%). The entry score is
that sum divided by the best possible sum for the query, times 100, plus bonuses for an exact name
match, trigger phrases and the whole query appearing in the description. Rough reading:
>= 60 strong, 35-59 plausible, < 35 weak.
"""
from __future__ import annotations

import argparse
import difflib
import json
import math
import os
import re
import sys

STOP = {
    "a", "an", "the", "to", "for", "of", "in", "on", "with", "and", "or", "my", "me", "i", "it", "is", "are",
    "do", "does", "how", "can", "you", "there", "skill", "skills", "find", "need", "want", "please", "help",
    "make", "that", "this", "some", "any", "use", "using", "via", "about", "into", "from", "be", "get", "then",
    "when", "what", "which", "should", "would", "could", "like", "just", "also", "very", "really", "them",
    "so", "if", "at", "by", "as", "we", "our", "your", "its", "up", "out", "more", "less", "look", "looking",
}
W_NAME, W_ALIAS, W_TAG, W_CAT, W_DESC = 12.0, 12.0, 8.0, 4.0, 5.0
B_NAME_EXACT, B_TRIGGER, B_PHRASE = 30.0, 15.0, 10.0
FUZZY = 0.6


def stem(t: str) -> str:
    for suf in ("ing", "ed", "es", "s"):
        if len(t) > 4 and t.endswith(suf):
            t = t[: -len(suf)]
            break
    return t


def norm(s: str) -> list[str]:
    out = []
    for t in re.split(r"[^a-z0-9]+", s.lower()):
        if t and t not in STOP:
            out.append(stem(t))
    return out


def fuzzy(a: str, b: str) -> bool:
    return a != b and len(a) > 3 and len(b) > 3 and a[0] == b[0] and difflib.SequenceMatcher(None, a, b).ratio() >= 0.8


class Doc:
    def __init__(self, e: dict):
        self.e = e
        self.name = set(norm(e.get("name", "")))
        self.alias = {t for a in e.get("aliases", []) for t in norm(a)}
        self.tag = {t for a in e.get("tags", []) for t in norm(a)}
        self.cat = set(norm(e.get("category", "") + " " + e.get("category_label", "")))
        self.desc = set(norm(e.get("description", "")))
        self.all = self.name | self.alias | self.tag | self.cat | self.desc
        self.triggers = [t.lower() for t in e.get("triggers", []) if t]

    def field_weight(self, t: str) -> tuple[float, str]:
        if t in self.name: return W_NAME, f"name:{t}"
        if t in self.alias: return W_ALIAS, f"alias:{t}"
        if t in self.tag: return W_TAG, f"tag:{t}"
        if t in self.desc: return W_DESC, f"desc:{t}"
        if t in self.cat: return W_CAT, f"category:{t}"
        for n in self.name | self.alias:
            if fuzzy(t, n): return W_NAME * FUZZY, f"name~{t}"
        for n in self.tag:
            if fuzzy(t, n): return W_TAG * FUZZY, f"tag~{t}"
        for n in self.desc:
            if fuzzy(t, n): return W_DESC * FUZZY, f"desc~{t}"
        return 0.0, ""


def score_all(docs: list[Doc], query: str) -> list[tuple[float, Doc, list[str]]]:
    q_tokens = list(dict.fromkeys(norm(query)))  # unique, ordered
    n = len(docs)
    df = {t: sum(1 for d in docs if t in d.all or any(fuzzy(t, x) for x in d.all)) for t in q_tokens}
    idf = {t: math.log(1 + n / df[t]) for t in q_tokens if df[t] > 0}
    if not idf:
        return []
    denom = sum(w * W_NAME for w in idf.values())
    q_low = query.lower()
    out = []
    for d in docs:
        num = 0.0
        hits: list[str] = []
        for t, w in idf.items():
            fw, label = d.field_weight(t)
            if fw:
                num += w * fw
                hits.append(label)
        s = 100.0 * num / denom if denom else 0.0
        if q_tokens and set(q_tokens) == d.name:
            s += B_NAME_EXACT; hits.append("name=exact")
        for trig in d.triggers:
            if trig in q_low:
                s += B_TRIGGER; hits.append(f"trigger:{trig}")
        if len(q_tokens) >= 2 and q_low.strip() in d.e.get("description", "").lower():
            s += B_PHRASE; hits.append("phrase")
        if s > 0:
            out.append((min(100.0, s), d, hits))
    out.sort(key=lambda r: (-r[0], r[1].e.get("kind") != "skill", r[1].e.get("name", "")))
    return out


def load_catalog(path: str | None) -> dict:
    if path is None:
        cache = os.environ.get("SKILL_FINDER_CACHE") or os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "sleeperagentai-skills")
        path = os.path.join(cache, "repo", "catalog.json")
        if not os.path.isfile(path):
            gen = os.path.join(cache, "repo", "scripts", "build-catalog.py")
            if os.path.isfile(gen):
                import subprocess
                out = subprocess.run([sys.executable, "-I", gen, "--repo", os.path.join(cache, "repo"), "--stdout"], capture_output=True, text=True)
                if out.returncode == 0:
                    return json.loads(out.stdout)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def install_cmd(e: dict) -> str:
    inst = e.get("install", {})
    return inst.get("global") or inst.get("example") or inst.get("all") or inst.get("claude_code") or inst.get("usage") or inst.get("clone") or ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("query")
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--catalog")
    ap.add_argument("--category")
    ap.add_argument("--kinds", default="skill,collection,plugin")
    ap.add_argument("--min-score", type=float, default=15)
    ap.add_argument("--explain", action="store_true")
    a = ap.parse_args()
    try:
        cat = load_catalog(a.catalog)
    except Exception as e:  # noqa: BLE001
        print(f"cannot read catalog: {e}", file=sys.stderr)
        return 2
    kinds = set(a.kinds.split(","))
    entries = [e for k in ("skills", "collections", "plugins") for e in cat.get(k, []) if e.get("kind", k[:-1]) in kinds]
    if a.category:
        entries = [e for e in entries if e.get("category") == a.category or e.get("kind") != "skill"]
    ranked = [r for r in score_all([Doc(e) for e in entries], a.query) if r[0] >= a.min_score][: a.top]
    if not ranked:
        print("[]" if a.json else f"no catalog entry scored >= {a.min_score:g} for: {a.query}")
        return 3
    if a.json:
        out = []
        for s, d, hits in ranked:
            e = d.e
            out.append({
                "score": round(s, 1), "kind": e.get("kind"), "name": e.get("name"), "category": e.get("category", ""),
                "description": e.get("description", ""), "path": e.get("path", ""), "install": install_cmd(e),
                "install_project": e.get("install", {}).get("project", ""),
                "repo": (e.get("source") or {}).get("repo") or e.get("repo", ""), "matched_on": hits,
            })
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        print(f"{'#':>2} {'score':>5}  {'name':<34} {'kind':<10} {'category':<13} description")
        for i, (s, d, hits) in enumerate(ranked, 1):
            e = d.e
            desc = re.sub(r"\s+", " ", e.get("description", ""))
            desc = desc if len(desc) <= 90 else desc[:89] + "…"
            print(f"{i:>2} {s:5.1f}  {e.get('name',''):<34} {e.get('kind',''):<10} {e.get('category',''):<13} {desc}")
            if a.explain:
                print(f"{'':>9}matched: {', '.join(hits)}")
        print()
        for _, d, _ in ranked:
            print(f"  {d.e.get('name','')}: {install_cmd(d.e)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
