"""Minimal, dependency-free SKILL.md frontmatter parser.

Handles the subset of YAML that Agent Skills frontmatter uses: scalar keys, quoted
strings, folded (>) and literal (|) block scalars, one level of nested mapping
(for ``metadata:``), and ``- item`` lists. It is deliberately strict about layout
so malformed files surface as errors rather than silently parsing wrong.
"""
from __future__ import annotations

import re
from typing import Any

_KEY = re.compile(r"^([^\s:#][^\s:]*):(?:\s+(.*))?$")


class FrontmatterError(ValueError):
    pass


def split(text: str) -> tuple[str, str]:
    """Return (frontmatter_text, body). Raises if the file has no frontmatter block."""
    if not text.startswith("---"):
        raise FrontmatterError("file does not start with '---'")
    lines = text.splitlines()
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1 :])
    raise FrontmatterError("frontmatter block is never closed with '---'")


def _unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        inner = v[1:-1]
        if v[0] == '"':
            inner = inner.replace('\\"', '"').replace("\\n", "\n")
        return inner
    return v


def _parse_list(lines: list[str], start: int, indent: int) -> tuple[list[str], int]:
    items: list[str] = []
    i = start
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        cur = len(line) - len(line.lstrip())
        if cur < indent or not line.lstrip().startswith("- "):
            break
        items.append(_unquote(line.lstrip()[2:]))
        i += 1
    return items, i


def _parse_block_scalar(lines: list[str], start: int, indent: int, folded: bool) -> tuple[str, int]:
    collected: list[str] = []
    i = start
    while i < len(lines):
        line = lines[i]
        if line.strip() == "":
            collected.append("")
            i += 1
            continue
        cur = len(line) - len(line.lstrip())
        if cur < indent:
            break
        collected.append(line[indent:] if cur >= indent else line.lstrip())
        i += 1
    while collected and collected[-1] == "":
        collected.pop()
    if folded:
        out: list[str] = []
        para: list[str] = []
        for c in collected:
            if c == "":
                if para:
                    out.append(" ".join(para))
                    para = []
                out.append("")
            else:
                para.append(c.strip())
        if para:
            out.append(" ".join(para))
        return "\n".join(out).strip(), i
    return "\n".join(collected), i


def _inline_map(v: str) -> dict[str, Any] | None:
    v = v.strip()
    if not (v.startswith("{") and v.endswith("}")):
        return None
    out: dict[str, Any] = {}
    for part in v[1:-1].split(","):
        if ":" in part:
            k, val = part.split(":", 1)
            out[k.strip()] = _unquote(val)
    return out


def _inline_list(v: str) -> list[str] | None:
    v = v.strip()
    if not (v.startswith("[") and v.endswith("]")):
        return None
    inner = v[1:-1].strip()
    return [_unquote(p) for p in inner.split(",")] if inner else []


def parse_mapping(lines: list[str], start: int = 0, indent: int = 0) -> tuple[dict[str, Any], int]:
    out: dict[str, Any] = {}
    i = start
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        cur = len(line) - len(line.lstrip())
        if cur < indent:
            break
        if cur > indent:
            raise FrontmatterError(f"unexpected indentation at line: {line!r}")
        m = _KEY.match(line.strip())
        if not m:
            raise FrontmatterError(f"cannot parse line: {line!r}")
        key, val = m.group(1), (m.group(2) or "").strip()
        i += 1
        if val in (">", ">-", "|", "|-", ">+", "|+"):
            child_indent = _next_indent(lines, i, indent)
            out[key], i = _parse_block_scalar(lines, i, child_indent, folded=val.startswith(">"))
        elif val == "":
            child_indent = _next_indent(lines, i, indent)
            if child_indent is None:
                out[key] = ""
            elif lines[_next_nonblank(lines, i)].lstrip().startswith("- "):
                out[key], i = _parse_list(lines, i, child_indent)
            else:
                out[key], i = parse_mapping(lines, i, child_indent)
        else:
            parsed = _inline_map(val)
            if parsed is None:
                parsed_list = _inline_list(val)
                out[key] = parsed_list if parsed_list is not None else _unquote(val)
            else:
                out[key] = parsed
    return out, i


def _next_nonblank(lines: list[str], i: int) -> int:
    while i < len(lines) and not lines[i].strip():
        i += 1
    return i


def _next_indent(lines: list[str], i: int, parent: int) -> int | None:
    j = _next_nonblank(lines, i)
    if j >= len(lines):
        return None
    ind = len(lines[j]) - len(lines[j].lstrip())
    return ind if ind > parent else None


def parse(text: str) -> dict[str, Any]:
    fm, _ = split(text)
    data, _ = parse_mapping(fm.splitlines())
    return data


def load(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as f:
        return parse(f.read())


if __name__ == "__main__":  # quick manual check: python3 -I frontmatter.py path/to/SKILL.md
    import json
    import sys

    print(json.dumps(load(sys.argv[1]), indent=2, ensure_ascii=False))
