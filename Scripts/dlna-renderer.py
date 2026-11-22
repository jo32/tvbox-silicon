#!/usr/bin/env python3
"""A test DLNA media renderer for Yingxia's casting (#749). Local QA only.

Answers SSDP searches (multicast and unicast) as a Xiaomi-style TV (AVTransport in an embedded device, a control
address that looks like a URL scheme), logs every SOAP action, and when given a video it fetches it the way a TV
would: the first bytes with a Range request, and for HLS the playlist and its first segment. Nothing is played.
"""
import html, http.server, json, re, socket, socketserver, sys, threading, time, urllib.parse, urllib.request, uuid

NAME = sys.argv[1] if len(sys.argv) > 1 else "QA 客厅电视"
HTTP_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 49321
LOG = sys.argv[3] if len(sys.argv) > 3 else "/tmp/renderer.log"
UDN = "uuid:" + str(uuid.uuid5(uuid.NAMESPACE_DNS, NAME))
lock = threading.Lock()
state = {"uri": None, "state": "NO_MEDIA_PRESENT", "pos": 0.0, "since": None, "volume": 30, "fetched": []}

def log(*parts):
    line = time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts)
    with open(LOG, "a") as f: f.write(line + "\n")
    print(line, flush=True)

def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1)); return s.getsockname()[0]
    finally: s.close()

IP = lan_ip()
DESC = f"""<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>{NAME}</friendlyName>
<manufacturer>QA</manufacturer><modelName>QA-Renderer-1</modelName><UDN>{UDN}</UDN>
<serviceList><service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/cm</controlURL></service></serviceList>
<deviceList><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>inner</friendlyName><UDN>{UDN}-inner</UDN>
<serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><controlURL>_urn:schemas-upnp-org:service:AVTransport_control</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId><controlURL>/upnp/control/rendering</controlURL></service>
</serviceList></device></deviceList></device></root>"""

def position():
    with lock:
        pos = state["pos"]
        if state["state"] == "PLAYING" and state["since"]: pos += time.time() - state["since"]
        return pos

def clock(s):
    s = int(s); return f"{s//3600}:{s//60%60:02d}:{s%60:02d}"

def fetch(uri):
    """What a TV does with the address: the first bytes, and for HLS the playlist and a segment."""
    try:
        req = urllib.request.Request(uri, headers={"Range": "bytes=0-1023", "User-Agent": "QA-TV/1.0 DLNADOC/1.50"})
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read(); ctype = r.headers.get("Content-Type", "")
            log("TV fetched", uri, "status", r.status, "type", ctype, "bytes", len(body), "content-range", r.headers.get("Content-Range"))
            state["fetched"].append({"uri": uri, "status": r.status, "bytes": len(body)})
        if body.startswith(b"#EXTM3U"):
            with urllib.request.urlopen(uri, timeout=15) as r: text = r.read().decode()
            lines = [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("#")]
            log("TV playlist lines", lines[:3])
            if lines:
                nxt = urllib.parse.urljoin(uri, lines[0])
                fetch(nxt)
    except Exception as e:
        log("TV fetch FAILED", uri, repr(e))
        state["fetched"].append({"uri": uri, "error": repr(e)})


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/desc.xml"):
            body = DESC.encode(); self.send_response(200); self.send_header("Content-Type", "text/xml; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); log("description read by", self.client_address[0])
        elif self.path == "/state":
            body = json.dumps({**state, "position": position()}).encode(); self.send_response(200); self.end_headers(); self.wfile.write(body)
        else: self.send_response(404); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        action = (self.headers.get("SOAPACTION") or "").strip('"').split("#")[-1]
        args = dict(re.findall(r"<(\w+)>([^<]*)</\1>", body))
        out = {}
        fault = None
        with lock:
            if action == "SetAVTransportURI":
                state.update(uri=args.get("CurrentURI"), state="STOPPED", pos=0.0, since=None)
                meta = html.unescape(args.get("CurrentURIMetaData", ""))
                title = re.search(r"<dc:title>(.*?)</dc:title>", meta); pinfo = re.search(r'protocolInfo="([^"]*)"', meta)
                log("SetAVTransportURI", state["uri"], "title=", html.unescape(title.group(1)) if title else None, "protocolInfo=", pinfo.group(1) if pinfo else None)
                threading.Thread(target=fetch, args=(html.unescape(args.get("CurrentURI", "")),), daemon=True).start()
            elif action == "Play":
                if not state["uri"]: fault = ("701", "Transition not available")
                else:
                    if state["state"] != "PLAYING": state.update(state="PLAYING", since=time.time())
            elif action == "Pause":
                if state["state"] == "PLAYING": state.update(pos=state["pos"] + time.time() - state["since"], since=None, state="PAUSED_PLAYBACK")
            elif action == "Stop":
                state.update(state="STOPPED", since=None, pos=0.0)
            elif action == "Seek":
                parts = [float(x) for x in args.get("Target", "0:0:0").split(":")]
                target = parts[0] * 3600 + parts[1] * 60 + parts[2]
                state["pos"] = target
                if state["state"] == "PLAYING": state["since"] = time.time()
            elif action == "SetVolume": state["volume"] = int(args.get("DesiredVolume", "0"))
        if action == "GetPositionInfo":
            out = {"Track": "1", "TrackDuration": "0:10:00" if state["uri"] else "0:00:00", "RelTime": clock(position()), "AbsTime": "NOT_IMPLEMENTED"}
        elif action == "GetTransportInfo":
            out = {"CurrentTransportState": state["state"], "CurrentTransportStatus": "OK", "CurrentSpeed": "1"}
        elif action == "GetVolume":
            out = {"CurrentVolume": str(state["volume"])}
        if action not in ("GetPositionInfo", "GetTransportInfo"):
            log("SOAP", action, {k: v for k, v in args.items() if k not in ("CurrentURIMetaData",)}, "->", fault or "ok", "state=", state["state"])
        if fault:
            xml = (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode>'
                   f'<faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>{fault[0]}</errorCode>'
                   f'<errorDescription>{fault[1]}</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>').encode()
            self.send_response(500)
        else:
            fields = "".join(f"<{k}>{v}</{k}>" for k, v in out.items())
            xml = (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
                   f'<u:{action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">{fields}</u:{action}Response></s:Body></s:Envelope>').encode()
            self.send_response(200)
        self.send_header("Content-Type", 'text/xml; charset="utf-8"'); self.send_header("Content-Length", str(len(xml))); self.end_headers(); self.wfile.write(xml)

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True

def ssdp(unicast=False):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"): s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    if unicast:
        # Bound to the LAN address: another SSDP listener on this machine (Yingxia's own receiver) would otherwise get
        # the unicast searches, which go to one socket only, while every socket gets the multicast ones.
        s.bind((IP, 1900))
    else:
        s.bind(("", 1900))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton("239.255.255.250") + socket.inet_aton(IP))
    location = f"http://{IP}:{HTTP_PORT}/desc.xml"
    while True:
        data, addr = s.recvfrom(4096)
        text = data.decode("utf-8", "replace")
        if not text.startswith("M-SEARCH"): continue
        st = re.search(r"(?im)^ST:\s*(.+?)\s*$", text); st = st.group(1) if st else ""
        if st not in ("ssdp:all", "upnp:rootdevice", "urn:schemas-upnp-org:device:MediaRenderer:1", "urn:schemas-upnp-org:service:AVTransport:1"): continue
        host = re.search(r"(?im)^HOST:\s*(.+?)\s*$", text); host = host.group(1) if host else ""
        log("M-SEARCH from", addr, "st=", st, "unicast" if not host.startswith("239.") else "multicast")
        reply = (f"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: {location}\r\nSERVER: QA/1.0 UPnP/1.0 Renderer/1.0\r\n"
                 f"ST: {st}\r\nUSN: {UDN}::{st}\r\n\r\n").encode()
        s.sendto(reply, addr)

if __name__ == "__main__":
    open(LOG, "w").close()
    threading.Thread(target=ssdp, daemon=True).start()
    threading.Thread(target=ssdp, args=(True,), daemon=True).start()
    log("renderer", NAME, "at", f"http://{IP}:{HTTP_PORT}/desc.xml")
    Server(("", HTTP_PORT), Handler).serve_forever()
