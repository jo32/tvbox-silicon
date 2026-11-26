#!/usr/bin/env python3
"""A local /v1/reports for QA: stores uploads as the Worker does (schema.sql), logs each body.

Usage: Scripts/error-reports-mock.py <port> <sqlite> <log.jsonl>, then launch a debug build with
`-qaErrorReports http://127.0.0.1:<port>/v1/reports` and read it with `Scripts/error-reports.py --stats --local <sqlite>`.
"""
import hashlib, http.server, json, pathlib, sqlite3, sys, time
root = pathlib.Path(__file__).resolve().parents[1]
db = sqlite3.connect(sys.argv[2], check_same_thread=False)
db.executescript((root / "Services/error-reports/schema.sql").read_text())
log = open(sys.argv[3], "a")
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        log.write(json.dumps(body, ensure_ascii=False) + "\n"); log.flush()
        now = int(time.time())
        for item in body["items"][:50]:
            sig = hashlib.sha256((item["category"] + "\n" + item["message"]).encode()).hexdigest()[:12]
            db.execute("INSERT INTO reports (received, install, platform, os, model, lang, app, build, country, signature, category, message, count, first, last) "
                       "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (now, body["install"], body["platform"], body["os"], body["model"], body["lang"],
                       body["app"], body["build"], "XX", sig, item["category"], item["message"], max(1, item["count"]), item["first"], item["last"]))
        db.commit()
        self.send_response(204); self.end_headers()
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
