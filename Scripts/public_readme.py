#!/usr/bin/env python3
"""Writes the README of the public releases repository from README.md.

Usage: public_readme.py OUTPUT.md
Images point to the copies next to the website (icon.png, demos/), and the sections about
building from source are left out: that repository holds releases, not source code.
"""
import re
import sys

text = open("README.md", encoding="utf-8").read()
text = text.replace("Docs/icon.png", "icon.png").replace("Docs/demos/", "demos/")
for title in ("Building from source", "Project layout"):
    text = re.sub(rf"^## {re.escape(title)}\n.*?(?=^## )", "", text, flags=re.S | re.M)
text = text.replace("and in `Resources/Licenses`", "and in the app")
open(sys.argv[1], "w", encoding="utf-8").write(text)
