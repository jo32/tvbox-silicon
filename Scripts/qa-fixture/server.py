import http.server, socketserver, json, os, re
PORT=8899; BASE=f"http://127.0.0.1:{PORT}"
SUB={"sites":[{"key":"qa","name":"QA Fixture","type":1,"api":f"{BASE}/api","searchable":1,"quickSearch":1}],
     "lives":[{"name":"QA Live","type":0,"url":f"{BASE}/lives.json","playerType":1}]}
LIVES={"lives":[{"name":"QA Channel","group":"QA","urls":[{"name":"HD","url":f"{BASE}/clip.mp4"}]}]}
HOME={"class":[{"type_id":"movie","type_name":"Movies"}]}
LIST={"page":1,"pagecount":1,"list":[{"vod_id":"1","vod_name":"QA Fixture Movie","vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_remarks":"QA"}]}
DETAIL={"list":[{
  "vod_id":"1","vod_name":"QA Fixture Movie",
  "vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_content":"Fixture.",
  # 两条线路：qa 是 16:9，wide 是 2.35:1 —— 验证「按真实比例定高」
  "vod_play_from":"qa$$$wide",
  "vod_play_url":f"第1集${BASE}/clip.mp4#第2集${BASE}/clip.mp4$$$第1集${BASE}/wide.mp4",
  # 字幕（TVBox 用 vod_sub / 或 ext 里的 sub）
  
}]}

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self,fmt,*a): print("REQ "+self.path, flush=True)
    def _j(self,o):
        b=json.dumps(o).encode(); self.send_response(200)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _file(self, n):
        d=open(n,"rb").read(); total=len(d)
        mime={".mp4":"video/mp4",".jpg":"image/jpeg"}.get(os.path.splitext(n)[1],"application/octet-stream")
        rng=self.headers.get("Range")
        if rng:
            m=re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                s=int(m.group(1) or 0)
                e=int(m.group(2)) if m.group(2) else total-1
                e=min(e,total-1)
                chunk=d[s:e+1]
                self.send_response(206)
                self.send_header("Content-Type",mime)
                self.send_header("Content-Range",f"bytes {s}-{e}/{total}")
                self.send_header("Content-Length",str(len(chunk)))
                self.send_header("Accept-Ranges","bytes")
                self.end_headers(); self.wfile.write(chunk); return
        self.send_response(200); self.send_header("Content-Type",mime)
        self.send_header("Content-Length",str(total)); self.send_header("Accept-Ranges","bytes")
        self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        p=self.path.split("?")[0]
        if p=="/sub.json": return self._j(SUB)
        if p=="/lives.json": return self._j(LIVES)
        if p=="/qa.js":
            body=b"var rule={};"
            self.send_response(200); self.send_header("Content-Type","application/javascript")
            self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body); return
        if p.rstrip("/")=="/api":
            q=self.path.partition("?")[2]
            if "ac=detail" in q: return self._j(DETAIL)
            if "ac=list" in q or "t=" in q: return self._j(LIST)
            if "play=" in q:
                return self._j({"parse":0,"playUrl":"","url":f"{BASE}/clip.mp4",
                                "subs":[{"name":"QA 中文字幕","url":f"{BASE}/sub.srt","lang":"zh","format":"srt"}]})
            return self._j(HOME)
        n=p.lstrip("/")
        if n and os.path.exists(n): return self._file(n)
        self.send_error(404)

socketserver.TCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer(("127.0.0.1",PORT),H).serve_forever()
