import http.server, socketserver, json, os, re
PORT=8899; BASE=f"http://127.0.0.1:{PORT}"
SUB={"sites":[{"key":"qa","name":"QA Fixture","type":1,"api":f"{BASE}/api","searchable":1,"quickSearch":1}],"lives":[]}
HOME={"class":[{"type_id":"movie","type_name":"Movies"}]}
LIST={"page":1,"pagecount":1,"list":[{"vod_id":"1","vod_name":"QA Fixture Movie","vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_remarks":"QA"}]}
DETAIL={"list":[{"vod_id":"1","vod_name":"QA Fixture Movie","vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_content":"Fixture.","vod_play_from":"qa","vod_play_url":f"第1集${BASE}/clip.mp4"}]}

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
        if p.rstrip("/")=="/api":
            q=self.path.partition("?")[2]
            if "ac=detail" in q: return self._j(DETAIL)
            if "ac=list" in q or "t=" in q: return self._j(LIST)
            if "play=" in q: return self._j({"parse":0,"playUrl":"","url":f"{BASE}/clip.mp4"})
            return self._j(HOME)
        n=p.lstrip("/")
        if n and os.path.exists(n): return self._file(n)
        self.send_error(404)

socketserver.TCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer(("127.0.0.1",PORT),H).serve_forever()
