#!/usr/bin/env python3
"""Writes the release notes of one version from CHANGELOG.md.

Usage: release_notes.py VERSION OUTPUT.html   (Sparkle's update window; generate_appcast embeds it)
       release_notes.py VERSION OUTPUT.md     (the GitHub release text)
"""
import html
import re
import sys

version, output = sys.argv[1], sys.argv[2]
text = open("CHANGELOG.md", encoding="utf-8").read()
match = re.search(rf"^## {re.escape(version)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
if not match:
    sys.exit(f"CHANGELOG.md has no section for {version}")


if output.endswith(".md"):
    with open(output, "w", encoding="utf-8") as f:
        f.write(match.group(1).strip() + "\n")
    sys.exit(0)


def inline(line):
    line = html.escape(line)
    line = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", line)
    line = re.sub(r"`(.+?)`", r"<code>\1</code>", line)
    return re.sub(r"\[(.+?)\]\((.+?)\)", r'<a href="\2">\1</a>', line)


parts, items = [], []
for line in match.group(1).strip().splitlines():
    if line.startswith("- "):
        items.append(f"<li>{inline(line[2:])}</li>")
        continue
    if items:
        parts.append("<ul>" + "".join(items) + "</ul>")
        items = []
    if line.strip():
        parts.append(f"<p>{inline(line)}</p>")
if items:
    parts.append("<ul>" + "".join(items) + "</ul>")

style = "body{font:13px -apple-system,sans-serif;margin:0}ul{padding-left:18px}li{margin:3px 0}"
with open(output, "w", encoding="utf-8") as f:
    f.write(f"<!doctype html><html><head><meta charset=\"utf-8\"><style>{style}</style></head>"
            f"<body>{''.join(parts)}</body></html>\n")
