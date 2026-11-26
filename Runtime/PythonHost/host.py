"""Run TVBox Python spiders with the same file protocol as ScriptHost/host.mjs.

macOS runs one sandboxed process per source: `host.py --serve request.json` loads the spider, writes
`ready.json`, then reads one JSON command per stdin line and writes `responses/<id>.json`. Without
`--serve` it answers `params` once on stdout. iOS and tvOS embed the interpreter and import this module
instead: `handle(json)` answers one request for any of the app's Python sources (ApplePython.c).
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


# The last upstream failure, so an empty spider result can explain itself. A process that serves one
# source keeps it process-wide (spiders fetch on their own threads too); an embedded interpreter
# serves many sources at once, so there each request thread keeps its own.
last_failure = None
_thread = threading.local()
_shared = True
_send = requests.Session.send


def record_failure(failure):
    global last_failure
    if _shared:
        last_failure = failure
    else:
        _thread.failure = failure


def recorded_failure():
    return last_failure if _shared else getattr(_thread, 'failure', None)


def send(session, prepared, **options):
    """Record the last upstream failure, and bound waits."""
    host = urlsplit(prepared.url).netloc
    if options.get('timeout') is None:
        options['timeout'] = 20
    try:
        response = _send(session, prepared, **options)
    except requests.RequestException as error:
        record_failure(RemoteFailure(host, 0, f'Network request failed: {error}'))
        log('PY_HTTP_FAILED', host, error)
        raise
    log('PY_HTTP', host + urlsplit(prepared.url).path, response.status_code)
    if response.status_code >= 400:
        record_failure(RemoteFailure(host, response.status_code, f'The source {host} returned HTTP {response.status_code}'))
    elif (failure := recorded_failure()) and failure.host == host:
        record_failure(None)
    return response


requests.Session.send = send


def envelope(error):
    log(''.join(traceback.format_exception(error)))
    if isinstance(error, requests.RequestException) and recorded_failure():
        error = recorded_failure()
    if isinstance(error, RemoteFailure):
        return {'error': str(error), 'errorCode': 'source_http' if error.status else 'source_network', 'host': error.host, 'status': error.status}
    return {'error': f'{type(error).__name__}: {error}', 'errorCode': 'script_error'}


def load_source(name, path):
    loader = SourceFileLoader(name, path)
    module = module_from_spec(spec_from_loader(name, loader))
    sys.modules[name] = module
    loader.exec_module(module)
    return module


def proxy_failure_status(error):
    """What a spider's failed proxy answers the player: the server's own 4xx (an expired or refused link, which asking
    again won't change), 504 when it took too long, otherwise 502 (the player asks a 502, 503 or 504 once more)."""
    status = getattr(error, 'status', None)
    if not isinstance(status, int):
        status = getattr(getattr(error, 'response', None), 'status_code', None)
    if isinstance(status, int) and 400 <= status < 500:
        return status
    if isinstance(error, (requests.Timeout, TimeoutError)):
        return 504
    return 502


_RANGE = re.compile(r'bytes=(\d*)-(\d*)$')
_CHUNK = 64 * 1024


def body_chunks(body):
    """A proxied body that isn't bytes (an upstream response, a file, an iterator), as it arrives. An upstream
    response is decoded, as `content` is."""
    if isinstance(body, requests.Response):
        parts = body.iter_content(_CHUNK)
    elif hasattr(body, 'read'):
        parts = iter(lambda: body.read(_CHUNK), b'')
    else:
        parts = body
    for part in parts:
        if not part:  # also a text file's '' at its end
            if hasattr(body, 'read'):
                return
            continue
        yield bytes(part) if isinstance(part, (bytes, bytearray, memoryview)) else str(part).encode('utf-8')


def close_body(body):
    close = getattr(body, 'close', None)
    if callable(close):
        try:
            close()
        except Exception:
            pass


def buffered(body):
    """The whole body as bytes: what a range is cut from, and what the proxy keeps for the next range."""
    if isinstance(body, bytes):
        return body
    try:
        return b''.join(body_chunks(body))
    finally:
        close_body(body)


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    session = None  # set on each source's subclass

    def do_GET(self):
        self.answer(True)

    def do_HEAD(self):
        self.answer(False)

    def answer(self, include_body):
        session = self.session
        match = _RANGE.match(self.headers.get('Range', '').strip())
        ranged = bool(match and (match.group(1) or match.group(2)))
        try:
            with open(os.path.join(session.cache, 'proxy-active'), 'w'):
                pass
            # AVPlayer reads progressive media in byte ranges, starting with `bytes=0-1`. Keep the last
            # complete response so each range does not make the spider download the file again.
            with session.cache_lock:
                cached_path, response = session.cached_response
                if cached_path != self.path:
                    response = session.proxy_response(self.path)
                    # Spiders never see the player's Range, so a range is cut from the whole body, kept for the
                    # next one. Any other request for a body that arrives as a stream gets it as it arrives,
                    # outside this lock: a live stream may never end, and a movie needn't wait in memory.
                    if ranged or isinstance(response[3], bytes):
                        response = response[:3] + (buffered(response[3]),)
                        if response[0] == 200 and len(response[3]) <= 512 * 1024 * 1024:
                            session.cached_response = (self.path, response)
            status, mime, headers, data = response
        except Exception as error:
            log('PY_PROXY_FAILED', ''.join(traceback.format_exception(error)))
            status, mime, headers, data = proxy_failure_status(error), 'text/plain', {}, str(error).encode()
        if not isinstance(data, bytes):
            return self.stream(status, mime, headers, data, include_body)
        extra = {}
        if status == 200:
            extra['Accept-Ranges'] = 'bytes'
            if ranged:
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
        self.send_spider_headers(headers)
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

    def send_spider_headers(self, headers):
        for key, value in headers.items():
            if key.lower() not in ('content-length', 'transfer-encoding', 'connection', 'content-type', 'content-range', 'accept-ranges'):
                self.send_header(key, str(value))

    def stream(self, status, mime, headers, body, include_body):
        """Sends a body that isn't bytes as it arrives: with the upstream's length when that is the length of what
        is sent (no content coding), otherwise in chunks. Ranges of it go through `answer`'s whole-body path."""
        length = None
        if isinstance(body, requests.Response):
            coding = body.headers.get('Content-Encoding', '').strip().lower()
            declared = body.headers.get('Content-Length', '').strip()
            if coding in ('', 'identity') and declared.isdigit():
                length = int(declared)
        try:
            self.send_response(status)
            self.send_spider_headers(headers)
            if status == 200:
                self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Type', mime)
            if length is None:
                self.send_header('Transfer-Encoding', 'chunked')
            else:
                self.send_header('Content-Length', str(length))
            self.end_headers()
            if not include_body:
                return
            sent = 0
            for chunk in body_chunks(body):
                if length is None:
                    self.wfile.write(b'%x\r\n' % len(chunk) + chunk + b'\r\n')
                    continue
                chunk = chunk[:length - sent]
                self.wfile.write(chunk)
                sent += len(chunk)
                if sent >= length:
                    break
            if length is None:
                self.wfile.write(b'0\r\n\r\n')
            elif sent < length:
                self.close_connection = True  # The upstream ended early: the player sees a short body.
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True  # The player went away: it drops streams and ranges it no longer needs.
        except Exception as error:
            # Headers are out: the answer can only be cut short, and this connection's framing is lost.
            log('PY_PROXY_FAILED', ''.join(traceback.format_exception(error)))
            self.close_connection = True
        finally:
            close_body(body)

    def log_message(self, format, *args):
        pass


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


class Session:
    """One source's spider, its profile and its loopback media proxy."""

    def __init__(self, request, process_wide=False):
        self.request = request
        self.cache = request['cache']
        self.profile = request.get('profile') or os.path.join(self.cache, 'profile')
        os.makedirs(self.profile, exist_ok=True)
        os.makedirs(os.path.join(self.cache, 'responses'), exist_ok=True)
        self.cached_response = (None, None)  # (path, response): players read one proxied file in many ranges
        self.cache_lock = threading.Lock()
        self.runtime = base._Runtime()
        self.runtime.cache_file = os.path.join(self.profile, 'cache.json')
        self.runtime.load_module = self.load_dependency
        if process_wide:
            base._runtime = self.runtime  # also for spiders the host never sees created
        self.server = None
        self.runtime.proxy_url = self.start_proxy()
        self.spider = self.initialize()

    def load_dependency(self, name):
        """`Spider.loadModule(name)`: a sibling `<name>.py` of the spider, cached in the profile."""
        if name in sys.modules:
            return sys.modules[name]
        if not re.fullmatch(r'[\w.-]{1,80}', name):
            raise ValueError('Invalid module name: ' + name)
        folder = os.path.join(self.profile, 'modules')
        os.makedirs(folder, exist_ok=True)
        address = urljoin(self.request['api'], name + '.py')
        path = os.path.join(folder, sha256(address.encode()).hexdigest() + '.py')
        if not os.path.exists(path):
            response = requests.get(address, headers={'User-Agent': 'Mozilla/5.0'}, timeout=20)
            response.raise_for_status()
            with open(path, 'wb') as stream:
                stream.write(response.content)
        return load_source(name, path)

    def start_proxy(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), type('SourceProxyHandler', (ProxyHandler,), {'session': self}))
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        # Not `/proxy?`: the app treats that path as an unsupported plugin proxy and never loads it.
        return f'http://127.0.0.1:{self.server.server_address[1]}/py-proxy?do=py'

    def initialize(self):
        request = self.request
        module = load_source('tvbox_spider_' + sha256(request['api'].encode()).hexdigest()[:16], request['script'])
        if not hasattr(module, 'Spider'):
            raise RuntimeError('The script defines no Spider class')
        spider_class = module.Spider
        # Some scripts declare a bare `class Spider:` instead of extending base.spider's. Put the base class
        # behind theirs, so the calls a script leaves out (getDependence, homeVideoContent…) get its defaults.
        if isinstance(spider_class, type) and not issubclass(spider_class, base.Spider):
            spider_class = type(spider_class.__name__, (spider_class, base.Spider), {'__module__': spider_class.__module__})
        instance = spider_class()
        instance._tvbox_runtime = self.runtime
        extension = request.get('ext') or ''
        if not extension:
            extension = dict(parse_qsl(urlsplit(request['api']).query)).get('extend', '')
        instance.extend = extension
        for name in instance.getDependence() or []:
            self.load_dependency(str(name))
        instance.init(extension)
        return instance

    def proxy_response(self, path):
        """Call the spider's localProxy and normalize its [status, mime, body, headers?, base64?] result. The body
        is bytes, or what the spider gave to be read on: an upstream response, a file or an iterator."""
        params = dict(parse_qsl(urlsplit(path).query, keep_blank_values=True))
        result = list(self.spider.localProxy(params) or [])
        status = int(result[0]) if result else 404
        mime = str(result[1]) if len(result) > 1 and result[1] else 'application/octet-stream'
        body = result[2] if len(result) > 2 else b''
        headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
        if len(result) > 4 and result[4] == 1 and isinstance(body, str):
            import base64
            body = base64.b64decode(body.split('base64,', 1)[-1])
        if isinstance(body, requests.Response):
            # Spiders return [200, mime, response] and let the upstream answer stand: a refusal stays one, not a
            # 200 whose error page the player (and the range cache) would take for the media.
            if status == 200 and body.status_code >= 400:
                status = body.status_code
            return status, mime, headers, body
        if body is None:
            body = b''
        elif isinstance(body, str):
            body = body.encode('utf-8')
        elif isinstance(body, (bytes, bytearray, memoryview)):
            body = bytes(body)
        return status, mime, headers, body

    def call(self, params):
        spider = self.spider
        record_failure(None)
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
            result = spider.categoryContent(params['t'], params.get('pg') or '1', True, json.loads(params.get('filters') or '{}'))
        else:
            result = parsed(spider.homeContent(True))
            if not result.get('list'):
                videos = parsed(spider.homeVideoContent())
                if videos.get('list'):
                    result['list'] = videos['list']
        if result is None or result == '' or result == {}:
            if recorded_failure():
                raise recorded_failure()
            result = {}
        return {'result': result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)}

    def close(self):
        try:
            self.spider.destroy()
        except Exception as error:
            log('PY_DESTROY_FAILED', error)
        if self.server:
            self.server.shutdown()
            self.server.server_close()


class _Slot:
    def __init__(self):
        self.lock = threading.Lock()  # a spider answers one request at a time
        self.session = None
        self.used = 0


_slots = {}
_slots_lock = threading.Lock()
_uses = 0
MAX_SESSIONS = 8


def handle(text):
    """One request from the app (iOS and tvOS): `session` names the source's spider, opened on first use
    from `script`, `cache`, `profile`, `api`, `key` and `ext`, and `params` is the TVBox call. Answers like
    `responses/<id>.json`. Requests for different sources run side by side."""
    global _shared, _uses
    _shared = False
    try:
        request = json.loads(text)
        if request.get('command'):
            return '{}'  # `cancel`: running Python can't be interrupted; the app stops waiting instead.
        key = str(request['session'])
        with _slots_lock:
            _uses += 1
            slot = _slots.get(key) or _slots.setdefault(key, _Slot())
            slot.used = _uses
            retired = _retire(keep=slot)
        for session in retired:
            session.close()
        with slot.lock:
            if slot.session is None:
                slot.session = Session(request)
            response = slot.session.call(request.get('params') or {})
    # SystemExit too: a spider's sys.exit() or exit() must not reach ApplePython.c, whose PyErr_Print
    # exits the whole app on it, with no crash report (issue #187).
    except (Exception, SystemExit) as error:
        response = envelope(error)
    return json.dumps(response, ensure_ascii=False)


def _retire(keep):
    """Closes the least recently used idle sources past MAX_SESSIONS. Call with `_slots_lock` held."""
    retired = []
    for key, slot in sorted(_slots.items(), key=lambda item: item[1].used):
        if len(_slots) <= MAX_SESSIONS:
            break
        if slot is keep or not slot.lock.acquire(blocking=False):
            continue
        try:
            del _slots[key]
            if slot.session:
                retired.append(slot.session)
                slot.session = None
        finally:
            slot.lock.release()
    return retired


def main(arguments):
    serving = arguments[:1] == ['--serve']
    with open(arguments[1 if serving else 0], encoding='utf-8') as stream:
        request = json.load(stream)
    cache = request['cache']
    try:
        os.makedirs(cache, exist_ok=True)
        os.chdir(cache)
        session = Session(request, process_wide=True)
        if serving:
            write_json(os.path.join(cache, 'ready.json'), {'ready': True})
            for line in sys.stdin:
                if not line.strip():
                    continue
                command = json.loads(line)
                if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', str(command.get('id'))):
                    raise ValueError('Invalid request identifier')
                try:
                    response = session.call(command.get('params') or {})
                except Exception as error:
                    response = envelope(error)
                write_json(os.path.join(cache, 'responses', command['id'] + '.json'), response)
        else:
            print(json.dumps(session.call(request.get('params') or {}), ensure_ascii=False), flush=True)
        return 0
    except Exception as error:
        response = envelope(error)
        if serving:
            write_json(os.path.join(cache, 'ready.json'), response)
        else:
            print(json.dumps(response, ensure_ascii=False), flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
