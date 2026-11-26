#!/usr/bin/env python3
"""Summarize the app's error reports (Services/error-reports) for the last N days, worst first.

Usage: Scripts/error-reports.py [days=1] [--json] [--signature <sig>] [--stats [--by platform,build,live,via,format]]
NEW marks groups first reported inside the window. --signature lists that group's recent reports;
a crash's or hang's app frames get code lines from the release's saved dSYM (build/release-*/<v>/dSYMs).
--stats: the play success rate from the `player.stats` counters (PlayAttempt), by platform and build, then by
the --by fields. --local <sqlite> reads a local copy of the table instead of D1 (QA).
One full scan of a table that keeps 30 days, well inside D1's free reads.
"""
import argparse
import collections
import json
import pathlib
import re
import sqlite3
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
service = root / "Services/error-reports"
wrangler = root / "website/node_modules/.bin/wrangler"

parser = argparse.ArgumentParser()
parser.add_argument("days", nargs="?", type=float, default=1)
parser.add_argument("--json", action="store_true")
parser.add_argument("--signature")
parser.add_argument("--stats", action="store_true")
parser.add_argument("--by", default="platform,build,live,via,format")
parser.add_argument("--local")
args = parser.parse_args()
since = int(time.time() - args.days * 86400)


def symbolicate(platform, message):
    """Appends file:line to each "TVBox-iOS+0x1a2b" frame of the version named by "app=1.6.5 (16)"."""
    version = re.search(r"^app=(\S+) ", message, re.M) or re.search(r" app=(\S+) ", message)
    if not version:
        return message
    folder = root / ("build/release-mac" if platform == "macos" else "build/release-apple") / version.group(1) / "dSYMs"
    lines = message.split("\n")
    for index, line in enumerate(lines):
        frame = re.fullmatch(r"(TVBox-(?:iOS|tvOS|macOS))\+0x([0-9a-f]+)", line)
        dwarf = frame and folder / f"{frame.group(1)}.app.dSYM/Contents/Resources/DWARF/{frame.group(1)}"
        if dwarf and dwarf.exists():
            # Main executables load their text at 0x100000000; MetricKit's offset is from there.
            address = hex(0x100000000 + int(frame.group(2), 16))
            found = subprocess.run(["atos", "-o", str(dwarf), "-l", "0x100000000", address], capture_output=True, text=True)
            lines[index] = f"{line}  {found.stdout.strip()}"
        elif dwarf:
            lines[index] = f"{line}  (no dSYM in {folder.relative_to(root)})"
    return "\n".join(lines)


STATS_FIELDS = ("platform", "build", "live", "via", "format")
COUNTER = re.compile(r"^(attempt|started|failed|abandoned|recovered rung=(\S+)) live=([01]) via=(\S+) format=(\S+)$")


def play_stats(rows, by):
    """Sums counter rows (platform, build, message, events, installs) into one line per value of the `by` fields."""
    table = collections.defaultdict(lambda: collections.Counter())
    rungs = collections.defaultdict(lambda: collections.Counter())
    for row in rows:
        match = COUNTER.match(row["message"])
        if not match:
            continue
        fields = {"platform": row["platform"], "build": str(row["build"]), "live": "live" if match.group(3) == "1" else "vod",
                  "via": match.group(4), "format": match.group(5)}
        key = tuple(fields[name] for name in by)
        kind = "recovered" if match.group(2) else match.group(1)
        table[key][kind] += row["events"]
        table[key]["installs"] = max(table[key]["installs"], row["installs"])
        if match.group(2):
            rungs[key][match.group(2)] += row["events"]
    lines = []
    for key, counts in sorted(table.items(), key=lambda item: -item[1]["attempt"]):
        attempts = counts["attempt"]
        rate = lambda n: f"{100 * n / attempts:5.1f}%" if attempts else "    -"
        ended = counts["started"] + counts["failed"]
        lines.append({"key": key, "attempts": attempts, "started": counts["started"], "failed": counts["failed"],
                      "abandoned": counts["abandoned"], "recovered": counts["recovered"], "installs": counts["installs"],
                      "success": rate(counts["started"]), "failure": rate(counts["failed"]),
                      "success_of_ended": f"{100 * counts['started'] / ended:5.1f}%" if ended else "    -",
                      "rungs": dict(rungs[key].most_common())})
    return lines


def print_stats(title, by, lines):
    print(f"\n{title}")
    header = "  ".join(f"{name:<12}" for name in by)
    print(f"{header}  attempts  started  failed  left  success  failure  ok/ended  recovered (rungs)")
    for line in lines:
        cells = "  ".join(f"{value:<12}" for value in line["key"])
        rungs = ", ".join(f"{name} {n}" for name, n in line["rungs"].items())
        print(f"{cells}  {line['attempts']:>8}  {line['started']:>7}  {line['failed']:>6}  {line['abandoned']:>4}  "
              f"{line['success']:>7}  {line['failure']:>7}  {line['success_of_ended']:>8}  {line['recovered']}"
              + (f" ({rungs})" if rungs else ""))


if args.stats:
    by = [name for name in args.by.split(",") if name]
    if not by or any(name not in STATS_FIELDS for name in by):
        raise SystemExit(f"--by takes {','.join(STATS_FIELDS)}")
    sql = f"""SELECT platform, build, message, SUM(count) AS events, COUNT(DISTINCT install) AS installs FROM reports
        WHERE category = 'player.stats' AND received >= {since} GROUP BY platform, build, message"""
elif args.signature:
    if not args.signature.isalnum():
        raise SystemExit("bad signature")
    sql = f"""SELECT datetime(received, 'unixepoch') AS received, platform, os, app, build, country, count,
        model, lang, substr(install, 1, 8) AS install, message FROM reports
        WHERE signature = '{args.signature}' AND received >= {since} ORDER BY received DESC LIMIT 30"""
else:
    sql = f"""SELECT signature, category,
        COUNT(DISTINCT CASE WHEN received >= {since} THEN install END) AS installs,
        SUM(CASE WHEN received >= {since} THEN count ELSE 0 END) AS events,
        group_concat(DISTINCT CASE WHEN received >= {since} THEN platform END) AS platforms,
        group_concat(DISTINCT CASE WHEN received >= {since} THEN app END) AS versions,
        datetime(MAX(last), 'unixepoch') AS last_seen,
        MIN(received) >= {since} AS new,
        MAX(message) AS sample
        FROM reports WHERE category != 'player.stats' GROUP BY signature HAVING events > 0
        ORDER BY installs DESC, events DESC LIMIT 60"""

if args.local:
    database = sqlite3.connect(args.local)
    database.row_factory = sqlite3.Row
    rows = [dict(row) for row in database.execute(" ".join(sql.split()))]
else:
    out = subprocess.run([str(wrangler), "d1", "execute", "yingxia-reports", "--remote", "--json", "--command", " ".join(sql.split())],
                         cwd=service, capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(out.stdout + out.stderr)
    rows = json.loads(out.stdout)[0]["results"]
if args.stats:
    overall = play_stats(rows, ["platform", "build"])
    detail = play_stats(rows, by)
    if args.json:
        print(json.dumps({"by_platform_build": overall, "by": by, "detail": detail}, ensure_ascii=False, indent=1))
    else:
        print(f"Play success in the last {args.days:g} day(s): success = started / attempts; "
              "left = closed while loading; ok/ended = started / (started + failed)")
        print_stats("By platform and build", ["platform", "build"], overall)
        print_stats("By " + ", ".join(by), by, detail)
elif args.json:
    print(json.dumps(rows, ensure_ascii=False, indent=1))
elif args.signature:
    for row in rows:
        print(f"{row['received']}  {row['platform']} {row['os']} {row['model']} {row['lang']}  {row['app']} ({row['build']})  "
              f"{row['country']}  x{row['count']}  {row['install']}")
        print("   ", symbolicate(row["platform"], row["message"]).replace("\n", "\n    "))
else:
    print(f"{len(rows)} error groups in the last {args.days:g} day(s)")
    for row in rows:
        flag = "NEW " if row["new"] else ""
        print(f"\n{flag}{row['signature']}  {row['category']}  installs={row['installs']} events={row['events']}  "
              f"{row['platforms']}  v{row['versions']}  last={row['last_seen']}")
        print("   ", row["sample"].split("\n")[0][:300])
