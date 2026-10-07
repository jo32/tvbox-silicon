"""Run one TVBox Python spider with the same file protocol as ScriptHost/host.mjs.

`host.py --serve request.json` loads the spider, writes `ready.json`, then reads one JSON command per
stdin line and writes `responses/<id>.json`. Without `--serve` it answers `params` once on stdout.
Spider `localProxy` responses are served from a loopback HTTP server for playback.
"""
import inspect
import json
import os
import re
import sys
import threading
import traceback
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from urllib.parse import parse_qsl, urljoin, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(HERE, 'site-packages')]
try:
    import certifi
    os.environ.setdefault('SSL_CERT_FILE', certifi.where())
except ImportError:
    pass

import requests
import urllib3
from base import spider as base

urllib3.disable_warnings()
serving = sys.argv[1:2] == ['--serve']
with open(sys.argv[2 if serving else 1], encoding='utf-8') as stream:
    request = json.load(stream)
cache = request['cache']
profile = request.get('profile') or os.path.join(cache, 'profile')
os.makedirs(profile, exist_ok=True)
os.makedirs(os.path.join(cache, 'responses'), exist_ok=True)
os.chdir(cache)


def log(*values):
    print(*values, file=sys.stderr, flush=True)


def write_json(path, value):
    with open(path + '.tmp', 'w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False)
    os.replace(path + '.tmp', path)


class RemoteFailure(Exception):
    def __init__(self, host, status, message):
        super().__init__(message)
        self.host, self.status = host, status


last_failure = None
_send = requests.Session.send


def send(session, prepared, **options):
    """Record the last upstream failure so an empty spider result can explain itself, and bound waits."""
    global last_failure
    host = urlsplit(prepared.url).netloc
    if options.get('timeout') is None:
        options['timeout'] = 20
    try:
        response = _send(session, prepared, **options)
    except requests.RequestException as error:
        last_failure = RemoteFailure(host, 0, f'Network request failed: {error}')
        log('PY_HTTP_FAILED', host, error)
        raise
    log('PY_HTTP', host + urlsplit(prepared.url).path, response.status_code)
    if response.status_code >= 400:
        last_failure = RemoteFailure(host, response.status_code, f'The source {host} returned HTTP {response.status_code}')
    elif last_failure and last_failure.host == host:
        last_failure = None
    return response


requests.Session.send = send


def envelope(error):
    log(''.join(traceback.format_exception(error)))
    if isinstance(error, requests.RequestException) and last_failure:
        error = last_failure
    if isinstance(error, RemoteFailure):
        return {'error': str(error), 'errorCode': 'source_http' if error.status else 'source_network', 'host': error.host, 'status': error.status}
    return {'error': f'{type(error).__name__}: {error}', 'errorCode': 'script_error'}


def load_source(name, path):
    loader = SourceFileLoader(name, path)
    module = module_from_spec(spec_from_loader(name, loader))
    sys.modules[name] = module
    loader.exec_module(module)
    return module


def load_dependency(name):
    """`Spider.loadModule(name)`: a sibling `<name>.py` of the spider, cached in the profile."""
    if name in sys.modules:
        return sys.modules[name]
    if not re.fullmatch(r'[\w.-]{1,80}', name):
        raise ValueError('Invalid module name: ' + name)
    folder = os.path.join(profile, 'modules')
    os.makedirs(folder, exist_ok=True)
    address = urljoin(request['api'], name + '.py')
    path = os.path.join(folder, sha256(address.encode()).hexdigest() + '.py')
    if not os.path.exists(path):
        response = requests.get(address, headers={'User-Agent': 'Mozilla/5.0'}, timeout=20)
        response.raise_for_status()
        with open(path, 'wb') as stream:
            stream.write(response.content)
    return load_source(name, path)


_RANGE = re.compile(r'bytes=(\d*)-(\d*)$')
_cached_response = (None, None)  # (path, response): players read one proxied file in many ranges
_cache_lock = threading.Lock()


def proxy_response(path):
    """Call the spider's localProxy and normalize its [status, mime, body, headers?, base64?] result."""
    params = dict(parse_qsl(urlsplit(path).query, keep_blank_values=True))
    result = list(spider.localProxy(params) or [])
    status = int(result[0]) if result else 404
    mime = str(result[1]) if len(result) > 1 and result[1] else 'application/octet-stream'
    body = result[2] if len(result) > 2 else b''
    headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
    if len(result) > 4 and result[4] == 1 and isinstance(body, str):
        import base64
        body = base64.b64decode(body.split('base64,', 1)[-1])
    if isinstance(body, requests.Response):
        body = body.content
    elif hasattr(body, 'read'):
        body = body.read()
    elif body is None:
        body = b''
    elif not isinstance(body, (bytes, bytearray, str)):
        body = b''.join(chunk if isinstance(chunk, bytes) else str(chunk).encode() for chunk in body)
    data = body.encode('utf-8') if isinstance(body, str) else bytes(body)
    return status, mime, headers, data


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        self.answer(True)

    def do_HEAD(self):
        self.answer(False)

    def answer(self, include_body):
        global _cached_response
        try:
            with open(os.path.join(cache, 'proxy-active'), 'w'):
                pass
            # AVPlayer reads progressive media in byte ranges, starting with `bytes=0-1`. Keep the last
            # complete response so each range does not make the spider download the file again.
            with _cache_lock:
                cached_path, response = _cached_response
                if cached_path != self.path:
                    response = proxy_response(self.path)
                    if response[0] == 200 and len(response[3]) <= 512 * 1024 * 1024:
                        _cached_response = (self.path, response)
            status, mime, headers, data = response
        except Exception as error:
            log('PY_PROXY_FAILED', ''.join(traceback.format_exception(error)))
            status, mime, headers, data = 502, 'text/plain', {}, str(error).encode()
        extra = {}
        if status == 200:
            extra['Accept-Ranges'] = 'bytes'
            match = _RANGE.match(self.headers.get('Range', '').strip())
            if match and (match.group(1) or match.group(2)):
                total = len(data)
                if match.group(1):
                    first = int(match.group(1))
                    last = min(int(match.group(2)), total - 1) if match.group(2) else total - 1
                else:
                    first, last = max(0, total - int(match.group(2))), total - 1
                if first >= total or first > last:
                    status, data, extra = 416, b'', {'Content-Range': f'bytes */{total}'}
                else:
                    status, data = 206, data[first:last + 1]
                    extra['Content-Range'] = f'bytes {first}-{last}/{total}'
        self.send_response(status)
        for key, value in headers.items():
            if key.lower() not in ('content-length', 'transfer-encoding', 'connection', 'content-type', 'content-range', 'accept-ranges'):
                self.send_header(key, str(value))
        for key, value in extra.items():
            self.send_header(key, value)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if include_body:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Players routinely drop a range once they have the bytes they need.

    def log_message(self, format, *args):
        pass


def start_proxy():
    server = ThreadingHTTPServer(('127.0.0.1', 0), ProxyHandler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # Not `/proxy?`: the app treats that path as an unsupported plugin proxy and never loads it.
    return f'http://127.0.0.1:{server.server_address[1]}/py-proxy?do=py'


def initialize():
    base._runtime.cache_file = os.path.join(profile, 'cache.json')
    base._runtime.load_module = load_dependency
    base._runtime.proxy_url = start_proxy()
    module = load_source('tvbox_spider_' + sha256(request['api'].encode()).hexdigest()[:16], request['script'])
    if not hasattr(module, 'Spider'):
        raise RuntimeError('The script defines no Spider class')
    instance = module.Spider()
    extension = request.get('ext') or ''
    if not extension:
        extension = dict(parse_qsl(urlsplit(request['api']).query)).get('extend', '')
    instance.extend = extension
    for name in instance.getDependence() or []:
        load_dependency(str(name))
    instance.init(extension)
    return instance


def accepts(method, count):
    try:
        parameters = inspect.signature(method).parameters.values()
    except (TypeError, ValueError):
        return True
    if any(item.kind == item.VAR_POSITIONAL for item in parameters):
        return True
    return len([item for item in parameters if item.kind in (item.POSITIONAL_ONLY, item.POSITIONAL_OR_KEYWORD)]) >= count


def parsed(value):
    if isinstance(value, (bytes, bytearray)):
        value = value.decode('utf-8')
    if isinstance(value, str):
        return json.loads(value) if value.strip() else {}
    return value or {}


def call(params):
    global last_failure
    last_failure = None
    if 'play' in params:
        result = spider.playerContent(params.get('flag') or '', params['play'], [])
    elif 'ids' in params:
        result = spider.detailContent([params['ids']])
    elif 'wd' in params:
        page = params.get('pg') or '1'
        if accepts(spider.searchContent, 3):
            result = spider.searchContent(params['wd'], False, page)
        else:
            result = spider.searchContent(params['wd'], False)
    elif 't' in params:
        result = spider.categoryContent(params['t'], params.get('pg') or '1', True, {})
    else:
        result = parsed(spider.homeContent(True))
        if not result.get('list'):
            videos = parsed(spider.homeVideoContent())
            if videos.get('list'):
                result['list'] = videos['list']
    if result is None or result == '' or result == {}:
        if last_failure:
            raise last_failure
        result = {}
    return {'result': result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)}


try:
    spider = initialize()
    if serving:
        write_json(os.path.join(cache, 'ready.json'), {'ready': True})
        for line in sys.stdin:
            if not line.strip():
                continue
            command = json.loads(line)
            if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', str(command.get('id'))):
                raise ValueError('Invalid request identifier')
            try:
                response = call(command.get('params') or {})
            except Exception as error:
                response = envelope(error)
            write_json(os.path.join(cache, 'responses', command['id'] + '.json'), response)
    else:
        print(json.dumps(call(request.get('params') or {}), ensure_ascii=False), flush=True)
    sys.exit(0)
except Exception as error:
    response = envelope(error)
    if serving:
        write_json(os.path.join(cache, 'ready.json'), response)
    else:
        print(json.dumps(response, ensure_ascii=False), flush=True)
    sys.exit(1)
