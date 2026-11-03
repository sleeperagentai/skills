#!/usr/bin/env python3
"""Generate catalog.json (and the README index tables) from the repo contents.

Usage:
  python3 -I scripts/build-catalog.py            # rewrite catalog.json and README.md tables
  python3 -I scripts/build-catalog.py --check    # exit 1 if catalog.json or README.md would change
  python3 -I scripts/build-catalog.py --stdout   # print catalog JSON only

Sources: skills/<category>/<name>/SKILL.md (+ optional metadata.json), collections/*.json,
plugins/*.json, categories.json. Output is deterministic (sorted, no timestamps).
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import frontmatter  # noqa: E402

REPO_SLUG = "sleeperagentai/skills"
README_START = "<!-- catalog:start -->"
README_END = "<!-- catalog:end -->"


def read_json(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def skill_entries(root: str, categories: dict) -> list[dict]:
    out = []
    skills_dir = os.path.join(root, "skills")
    for cat in sorted(os.listdir(skills_dir)):
        cat_dir = os.path.join(skills_dir, cat)
        if not os.path.isdir(cat_dir) or cat.startswith("."):
            continue
        for name in sorted(os.listdir(cat_dir)):
            skill_dir = os.path.join(cat_dir, name)
            skill_md = os.path.join(skill_dir, "SKILL.md")
            if not os.path.isfile(skill_md):
                continue
            with open(skill_md, encoding="utf-8") as f:
                text = f.read()
            try:
                fm = frontmatter.parse(text)
            except frontmatter.FrontmatterError as e:
                print(f"warning: {skill_md}: {e}; using lenient parse", file=sys.stderr)
                fm = _lenient(text)
            meta_path = os.path.join(skill_dir, "metadata.json")
            meta = read_json(meta_path) if os.path.isfile(meta_path) else {}
            desc = str(meta.get("description") or fm.get("description") or "").strip()
            desc = re.sub(r"\s+", " ", desc)
            tags = sorted(set(meta.get("tags", [])) | _tags_from_fm(fm))
            entry = {
                "kind": "skill",
                "name": name,
                "category": cat,
                "category_label": categories.get(cat, cat),
                "path": f"skills/{cat}/{name}",
                "description": desc,
                "license": meta.get("license") or fm.get("license") or "",
                "compatibility": fm.get("compatibility", ""),
                "tags": tags,
                "aliases": sorted(meta.get("aliases", [])),
                "triggers": sorted(meta.get("triggers", [])),
                "vendored": bool(meta.get("vendored", True)),
                "added": meta.get("added", ""),
                "source": meta.get("source", {}),
                "install": meta.get("install") or {
                    "project": f"npx -y skills add {REPO_SLUG} --skill {name} -y",
                    "global": f"npx -y skills add {REPO_SLUG} --skill {name} -g -y",
                },
            }
            out.append(entry)
    return out


def _lenient(text: str) -> dict:
    """Regex fallback for frontmatter the strict parser rejects: name/description/license only."""
    try:
        fm, _ = frontmatter.split(text)
    except frontmatter.FrontmatterError:
        return {}
    out = {}
    for key in ("name", "description", "license", "compatibility"):
        m = re.search(rf"^{key}:\s*(.*)$", fm, re.M)
        if m:
            v = m.group(1).strip()
            if v in (">", ">-", "|", "|-"):
                rest = fm[m.end():].splitlines()[1:]
                v = " ".join(l.strip() for l in itertools.takewhile(lambda l: l.startswith("  ") or not l.strip(), rest) if l.strip())
            out[key] = v.strip('"').strip("'")
    return out


def _tags_from_fm(fm: dict) -> set[str]:
    md = fm.get("metadata")
    if isinstance(md, dict):
        hermes = md.get("hermes")
        if isinstance(hermes, dict) and isinstance(hermes.get("tags"), list):
            return {str(t).strip().lower() for t in hermes["tags"] if str(t).strip()}
        if isinstance(md.get("tags"), list):
            return {str(t).strip().lower() for t in md["tags"]}
    return set()


def pointer_entries(root: str, sub: str, kind: str) -> list[dict]:
    out = []
    d = os.path.join(root, sub)
    if not os.path.isdir(d):
        return out
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".json"):
            e = read_json(os.path.join(d, fn))
            e.setdefault("kind", kind)
            e.setdefault("name", fn[:-5])
            e["path"] = f"{sub}/{fn}"
            out.append(e)
    return out


def build(root: str) -> dict:
    categories = read_json(os.path.join(root, "categories.json"))
    skills = skill_entries(root, categories)
    collections = pointer_entries(root, "collections", "collection")
    plugins = pointer_entries(root, "plugins", "plugin")
    return {
        "schema_version": 1,
        "repo": REPO_SLUG,
        "default_branch": "main",
        "categories": categories,
        "counts": {"skills": len(skills), "collections": len(collections), "plugins": len(plugins)},
        "skills": skills,
        "collections": collections,
        "plugins": plugins,
    }


def dumps(cat: dict) -> str:
    return json.dumps(cat, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _md_escape(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def _short(s: str, n: int = 110) -> str:
    s = s.strip()
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def readme_tables(cat: dict) -> str:
    lines = [README_START, ""]
    c = cat["counts"]
    lines.append(f"**{c['skills']} skills** in {len(cat['categories'])} categories, "
                 f"**{c['collections']} collections** and **{c['plugins']} plugins** referenced.")
    lines.append("")
    by_cat: dict[str, list[dict]] = {}
    for s in cat["skills"]:
        by_cat.setdefault(s["category"], []).append(s)
    for cname in sorted(by_cat):
        lines.append(f"### {cname} — {cat['categories'].get(cname, '')}")
        lines.append("")
        lines.append("| Skill | What it does | Source | Install |")
        lines.append("|---|---|---|---|")
        for s in by_cat[cname]:
            src = s.get("source", {})
            if src.get("repo"):
                src_cell = f"[{src['repo']}]({src.get('url') or 'https://github.com/' + src['repo']})"
            else:
                src_cell = src.get("type", "local")
            install = f"`npx -y skills add {REPO_SLUG} --skill {s['name']} -y`"
            lines.append(f"| [{s['name']}]({s['path']}) | {_md_escape(_short(s['description']))} | {src_cell} | {install} |")
        lines.append("")
    if cat["collections"]:
        lines.append("### Collections (not vendored, install from upstream)")
        lines.append("")
        lines.append("| Collection | What it is | Install |")
        lines.append("|---|---|---|")
        for e in cat["collections"]:
            inst = e.get("install", {})
            cmd = inst.get("example") or inst.get("all") or inst.get("usage") or inst.get("clone") or ""
            lines.append(f"| [{e['name']}]({e['path']}) ([{e.get('repo','')}]({e.get('url','')})) | "
                         f"{_md_escape(_short(e.get('description',''), 120))} | `{_md_escape(cmd)}` |")
        lines.append("")
    if cat["plugins"]:
        lines.append("### Plugins")
        lines.append("")
        lines.append("| Plugin | What it does | Install |")
        lines.append("|---|---|---|")
        for e in cat["plugins"]:
            inst = e.get("install", {})
            cmd = inst.get("claude_code") or inst.get("skills_cli") or ""
            lines.append(f"| [{e['name']}]({e['path']}) ([{e.get('repo','')}]({e.get('url','')})) | "
                         f"{_md_escape(_short(e.get('description',''), 120))} | `{_md_escape(cmd)}` |")
        lines.append("")
    lines.append(README_END)
    return "\n".join(lines)


def splice_readme(readme: str, tables: str) -> str:
    if README_START not in readme or README_END not in readme:
        raise SystemExit("README.md is missing the catalog:start/catalog:end markers")
    pre = readme.split(README_START)[0]
    post = readme.split(README_END, 1)[1]
    return pre + tables + post


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.dirname(HERE))
    ap.add_argument("--out", default="catalog.json")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--stdout", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.repo)
    cat = build(root)
    text = dumps(cat)
    if a.stdout:
        sys.stdout.write(text)
        return 0
    out_path = os.path.join(root, a.out)
    readme_path = os.path.join(root, "README.md")
    new_readme = None
    if os.path.isfile(readme_path):
        with open(readme_path, encoding="utf-8") as f:
            cur = f.read()
        new_readme = splice_readme(cur, readme_tables(cat))
    if a.check:
        changed = []
        if not os.path.isfile(out_path) or open(out_path, encoding="utf-8").read() != text:
            changed.append(a.out)
        if new_readme is not None and new_readme != cur:
            changed.append("README.md")
        if changed:
            print("out of date: " + ", ".join(changed) + "  (run: python3 -I scripts/build-catalog.py)")
            return 1
        print("catalog up to date")
        return 0
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(text)
    if new_readme is not None:
        with open(readme_path, "w", encoding="utf-8") as f:
            f.write(new_readme)
    c = cat["counts"]
    print(f"wrote {a.out}: {c['skills']} skills, {c['collections']} collections, {c['plugins']} plugins")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
