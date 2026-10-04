#!/usr/bin/env python3
"""Check translation completeness, format arguments, and static Swift keys."""
import collections
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
languages = ("en", "zh-Hans", "zh-Hant", "ja")
entry = re.compile(r'^("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");$', re.M)
formats = re.compile(r'%(?:\d+\$)?(?:ll)?[@du]')
tables = {}
for language in languages:
    path = root / "Sources/TVCore/Resources" / f"{language}.lproj/Localizable.strings"
    rows = [(json.loads(k), json.loads(v)) for k, v in entry.findall(path.read_text())]
    assert len(rows) == len(dict(rows)), f"Duplicate keys: {language}"
    tables[language] = dict(rows)
source = tables["en"]
for language, table in tables.items():
    assert table.keys() == source.keys(), f"Mismatched keys: {language}"
    for key, value in table.items():
        assert value.strip(), f"Empty translation: {language} {key}"
        assert collections.Counter(formats.findall(key)) == collections.Counter(formats.findall(value)), f"Format mismatch: {language} {key}"
        if language == "en":
            assert key == value, f"English source drift: {key}"
for folder in (root / "App", root / "Sources/TVCore"):
    for path in folder.glob("*.swift"):
        for literal in re.findall(r'L10n.text\(("(?:[^"\\]|\\.)*")', path.read_text()):
            key = json.loads(literal)
            assert key in source, f"Missing localization: {path.name}: {key}"
print(f"Verified {len(source)} keys in {len(languages)} languages, including format arguments and Swift references.")
