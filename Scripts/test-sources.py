#!/usr/bin/env python3
"""Test every source of a TVBox subscription the way the app does.

Pipeline per site: home -> (category list) -> detail -> play -> fetch the media URL.
Type 3 csp_* sites run through the bundled Java host (build/JavaHost), one persistent process per
source like LocalJarHost. Type 1/4 sites use plain HTTP like CatalogClient.

Usage: Scripts/test-sources.py [subscription-url] [--workers N] [--only substring]
Output: build/site-test/results.json, per-request evidence, and a summary on stdout.
Use --output to keep separate runs. A successful media fetch is not a decoder test.
"""
import argparse
import concurrent.futures as cf
import json, os, re, shutil, subprocess, sys, tempfile, time, uuid
import urllib.error, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = ROOT + '/build/JavaHost'
OUT = ROOT + '/build/site-test'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('subscription', nargs='?', default='https://raw.githubusercontent.com/qist/tvbox/master/fty.json')
parser.add_argument('--workers', type=int, default=4)
parser.add_argument('--only', action='append', help='Test sources containing this text (repeat for multiple matches)')
parser.add_argument('--output', default=OUT, help='Directory for results and per-request evidence')
args = parser.parse_args()
workers, only, SUB, OUT = args.workers, args.only, args.subscription, os.path.abspath(args.output)
if workers < 1:
    parser.error('--workers must be positive')


def http_get(url, headers=None, timeout=30, limit=None):
    url = urllib.parse.quote(url, safe=":/?&=%#@+,;~!*'()$[]")
    request = urllib.request.Request(url, headers={'User-Agent': UA, **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return (response.read(limit) if limit else response.read()), response.status


NOISE = ('Stub!', '127.0.0.1/shutdown', 'at java.base', 'at com.github.unidbg', 'at tvbox.runtime')


def interesting(stderr):
    keep = [l.strip() for l in stderr.splitlines() if re.search(r'Exception|Error|HTTP|failed|Unsupported|not found|denied|timed out', l) and not any(n in l for n in NOISE)]
    seen, result = set(), []
    for line in keep:
        if line not in seen:
            seen.add(line); result.append(line[:300])
    return result[:8]


def run_jar(site, jar, params, timeout=60):
    job = tempfile.mkdtemp(dir=OUT + '/jobs')
    try:
        ext = site.get('ext', '')
        if not isinstance(ext, str):
            ext = json.dumps(ext, ensure_ascii=False, separators=(',', ':'))
        json.dump({'jar': jar, 'cache': job, 'api': site['api'], 'key': site['key'], 'ext': ext, 'params': params}, open(job + '/request.json', 'w'))
        command = [HOST + '/jre/bin/java', '--add-opens', 'java.base/java.lang=ALL-UNNAMED', '--add-opens', 'java.base/sun.net.www.protocol.jar=ALL-UNNAMED',
                   '-Dorg.slf4j.simpleLogger.defaultLogLevel=error', '-cp', HOST + '/host.jar:' + HOST + '/lib/*',
                   'tvbox.runtime.NativeProbe', job + '/request.json']
        try:
            done = subprocess.run(command, cwd=job, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired as e:
            err = (e.stderr.decode('utf8', 'replace') if isinstance(e.stderr, bytes) else (e.stderr or ''))
            raise Failure('timeout after %ds' % timeout, interesting(err))
        # Keep the original host envelope and stderr: plugins often swallow failures.
        evidence = os.path.join(OUT, 'evidence', re.sub(r'[^\w.-]', '_', site['key']))
        os.makedirs(evidence, exist_ok=True)
        label = ('play' if 'play' in params else 'detail' if 'ids' in params else
                 'search' if 'wd' in params else 'category' if 't' in params else 'home')
        prefix = os.path.join(evidence, label + '-' + os.path.basename(job))
        with open(prefix + '.log', 'w') as stream: stream.write(done.stderr)
        with open(prefix + '.json', 'w') as stream: stream.write(done.stdout)
        with open(prefix + '.params.json', 'w') as stream: json.dump(params, stream, ensure_ascii=False)
        lines = [l for l in done.stdout.splitlines() if l.strip()]
        diag = interesting(done.stderr)
        diag += ['TAIL| ' + l.strip()[:200] for l in done.stderr.splitlines() if l.strip() and not any(n in l for n in NOISE)][-14:]
        if not lines:
            raise Failure('host produced no output (exit %d)' % done.returncode, diag)
        envelope = json.loads(lines[-1])
        if 'error' in envelope:
            extra = ''
            if envelope.get('errorCode') == 'source_http':
                extra = ' [%s HTTP %s]' % (envelope.get('host'), envelope.get('status'))
            raise Failure(envelope['error'][:300] + extra, diag, code=envelope.get('errorCode'))
        text = envelope.get('result')
        if not text:
            raise Failure('plugin returned empty result', diag)
        try:
            return json.loads(text)
        except ValueError:
            raise Failure('plugin returned non-JSON: ' + text[:120], diag)
    finally:
        shutil.rmtree(job, ignore_errors=True)


class JarSession:
    """Use the app's persistent request protocol, preserving per-source spider state."""
    def __init__(self, site, jar, base=None):
        self.site = site
        self.job = tempfile.mkdtemp(dir=OUT + '/jobs')
        self.log = open(self.job + '/session.log', 'w+')
        self.offset = 0
        ext = site.get('ext', '')
        if not isinstance(ext, str): ext = json.dumps(ext, ensure_ascii=False, separators=(',', ':'))
        with open(self.job + '/request.json', 'w') as stream:
            json.dump({'jar': jar, 'cache': self.job, 'api': site['api'], 'key': site['key'], 'ext': ext}, stream)
        command = [HOST + '/jre/bin/java', '--add-opens', 'java.base/java.lang=ALL-UNNAMED', '--add-opens', 'java.base/sun.net.www.protocol.jar=ALL-UNNAMED',
                   '-Dorg.slf4j.simpleLogger.defaultLogLevel=error', '-cp', HOST + '/host.jar:' + HOST + '/lib/*',
                   'tvbox.runtime.NativeProbe', '--serve', self.job + '/request.json']
        if not site['api'].startswith('csp_'):
            from urllib.parse import urljoin
            api = urljoin(base, site['api'])
            script = self.job + '/plugin.js'
            subprocess.run(['/usr/bin/curl', '-fsSL', '--max-time', '30', api, '-o', script], check=True)
            with open(self.job + '/request.json', 'w') as stream:
                json.dump({'script': script, 'cache': self.job, 'api': api, 'key': site['key'], 'ext': urljoin(base, ext)}, stream)
            host = os.path.abspath('build/ScriptHost')
            command = [host + '/node', '--no-warnings', '--experimental-vm-modules', host + '/host.mjs', '--serve', self.job + '/request.json']
        self.process = subprocess.Popen(command, cwd=self.job, stdin=subprocess.PIPE, stdout=self.log, stderr=self.log, text=True)

    def wait(self, path, deadline):
        while time.monotonic() < deadline:
            if os.path.exists(path):
                with open(path) as stream: return json.load(stream)
            if self.process.poll() is not None: raise Failure('host exited before responding')
            time.sleep(.05)
        raise Failure('timeout after 60s')

    def request(self, params):
        # Match the app's single bounded retry for NewCz's cookie challenge.
        for attempt in range(2):
            try: return self.once(params)
            except Failure as failure:
                if attempt or self.site['api'] != 'csp_NewCzGuard' or failure.code != 'source_http' or 'HTTP 403' not in str(failure): raise
                time.sleep(.3)

    def once(self, params):
        deadline = time.monotonic() + 60
        ident = str(uuid.uuid4())
        envelope = None
        try:
            ready = self.wait(self.job + '/ready.json', deadline)
            if ready.get('error'): envelope = ready
            else:
                self.process.stdin.write(json.dumps({'id': ident, 'params': params}) + '\n'); self.process.stdin.flush()
                path = self.job + '/responses/' + ident + '.json'
                envelope = self.wait(path, deadline)
                os.unlink(path)
        finally:
            self.log.seek(self.offset); stderr = self.log.read(); self.offset = self.log.tell()
            folder = OUT + '/evidence/' + re.sub(r'[^\w.-]', '_', self.site['key'])
            os.makedirs(folder, exist_ok=True)
            stage = 'play' if 'play' in params else 'detail' if 'ids' in params else 'search' if 'wd' in params else 'category' if 't' in params else 'home'
            prefix = folder + '/' + stage + '-' + ident
            with open(prefix + '.log', 'w') as stream: stream.write(stderr)
            with open(prefix + '.json', 'w') as stream: json.dump(envelope, stream, ensure_ascii=False)
            with open(prefix + '.params.json', 'w') as stream: json.dump(params, stream, ensure_ascii=False)
        diag = interesting(stderr)
        if envelope.get('error'):
            suffix = ' [%s HTTP %s]' % (envelope.get('host'), envelope.get('status')) if envelope.get('errorCode') == 'source_http' else ''
            raise Failure(envelope['error'] + suffix, diag, envelope.get('errorCode'))
        value = envelope.get('result')
        if not value: raise Failure('plugin returned empty result', diag)
        try: return json.loads(value)
        except ValueError: raise Failure('plugin returned non-JSON: ' + value[:120], diag)

    def close(self):
        try:
            self.process.stdin.close()
            try: self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
        finally:
            self.log.close(); shutil.rmtree(self.job, ignore_errors=True)


def run_http(site, base, params):
    endpoint = urllib.parse.urljoin(base, site['api'])
    values = dict(params)
    ext = site.get('ext')
    if ext is not None:
        values['extend'] = ext if isinstance(ext, str) else json.dumps(ext, ensure_ascii=False, separators=(',', ':'))
    url = endpoint + ('&' if '?' in endpoint else '?') + urllib.parse.urlencode(values)
    headers = site.get('header') if isinstance(site.get('header'), dict) else {}
    try:
        data, _ = http_get(url, headers, timeout=30)
    except urllib.error.HTTPError as e:
        raise Failure('HTTP %d from %s' % (e.code, urllib.parse.urlparse(url).netloc))
    except Exception as e:
        raise Failure('%s: %s' % (type(e).__name__, e))
    try:
        return json.loads(data)
    except ValueError:
        raise Failure('non-JSON response: ' + data[:100].decode('utf8', 'replace'))


class Failure(Exception):
    def __init__(self, message, diag=None, code=None):
        super().__init__(message); self.diag = diag or []; self.code = code


def num(value):
    try: return int(value or 0)
    except (TypeError, ValueError): return 1


def test_site(site, base, jar):
    record = {'key': site.get('key'), 'name': site.get('name'), 'type': site.get('type'), 'api': site.get('api'),
              'ext': site.get('ext') if isinstance(site.get('ext'), str) else None, 'stages': {}}
    started = time.time()
    native = site.get('type') in (1, 4)
    csp = site.get('type') == 3
    if not native and not csp:
        record.update(ok=False, failed='support', error='app has no runner for type %s api %s' % (site.get('type'), str(site.get('api'))[:60]))
        return record
    session = None
    stage = 'home'
    try:
        if csp: session = JarSession(site, jar, base)
        call = (lambda p: run_http(site, base, p)) if native else session.request
        try:
            home = call({'filter': 'true'} if site.get('type') == 4 else {})
        except Failure as failure:
            if str(failure) != 'plugin returned empty result':
                raise
            record['home_warning'] = str(failure)
            home = {}  # An empty home is valid for search-only spiders.

        videos = home.get('list') or []
        classes = home.get('class') or []
        record['stages']['home'] = '%d categories, %d videos' % (len(classes), len(videos))
        if not videos and classes:
            stage = 'category'
            for category in classes[:4]:  # the first one is often a login / settings page
                try:
                    listing = call({'pg': '1', 'ac': 'detail', 't': str(category.get('type_id'))})
                except Failure as failure:
                    record.setdefault('category_warnings', []).append(str(failure))
                    continue  # Search-only providers may expose nonfunctional placeholder categories.

                videos = [v for v in (listing.get('list') or []) if v.get('vod_id') not in (None, '')]
                record['stages']['category'] = '%d videos in category %s' % (len(videos), category.get('type_name'))
                if videos: break
        searchable = site.get('searchable') in (1, '1', True)
        search_error = None
        if not videos:
            stage = 'search'
            for keyword in ('爱', '我的'):
                try:
                    found = call({'wd': keyword, 'pg': '1', 'quick': 'false'})
                except Failure as f:
                    search_error = f; continue
                videos = found.get('list') or []
                if videos:
                    record['stages']['search'] = '%d results for %s (no home page: search-only source)' % (len(videos), keyword); break
        if not videos:
            why = 'home/category empty' if classes else 'no categories'
            raise Failure('%s and search found nothing%s' % (why, (' (search error: %s)' % search_error) if search_error else ' (searchable=%s)' % searchable), search_error.diag if search_error else None)
        # Entries carrying an `action` are plugin UI (login, settings), not videos.
        withid = [v for v in videos if v.get('vod_id') not in (None, '')]
        if not withid:
            raise Failure('%d entries but none is an openable video (missing vod_id or plugin action entries)' % len(videos))
        stage = 'detail'
        episodes, last = [], None
        for video in withid[:4]:
            try:
                detail = call({'ac': 'detail', 'ids': str(video['vod_id'])})
            except Failure as f:
                last = f; continue
            items = detail.get('list') or []
            if not items:
                last = Failure('detail returned no list'); continue
            item = items[0]
            flags = (item.get('vod_play_from') or '').split('$$$')
            episodes = []
            for gi, group in enumerate((item.get('vod_play_url') or '').split('$$$')):
                for ep in group.split('#'):
                    if ep:
                        parts = ep.split('$', 1)
                        episodes.append((flags[gi] if gi < len(flags) else '', parts[-1]))
            if episodes:
                record['stages']['detail'] = '%s: %d episodes' % (str(video.get('vod_name'))[:20], len(episodes)); break
            last = Failure('detail has no playable episodes')
        if not episodes:
            raise last or Failure('detail has no playable episodes')
        stage = 'play'
        flag, address = episodes[0]
        played = call({'play': address, 'flag': flag, 'detailID': str(video['vod_id'])}) if (site.get('type') in (3, 4)) else {'url': address}
        direct = isinstance(played.get('url'), str) and urllib.parse.urlparse(played['url']).path.lower().endswith(('.mp4', '.m4v', '.m3u8', '.mp3', '.m4a', '.aac')) and not played.get('playUrl')
        if not direct and (num(played.get('parse')) != 0 or num(played.get('jx')) != 0 or (played.get('playUrl') or '')):
            raise Failure('needs web sniffing / extra parsing (parse=%s jx=%s playUrl=%s)' % (played.get('parse'), played.get('jx'), bool(played.get('playUrl'))))
        headers = dict(site.get('header') or {})
        if isinstance(played.get('header'), dict): headers.update(played['header'])
        if isinstance(played.get('header'), str):
            try: headers.update(json.loads(played['header']))
            except ValueError: pass
        if played.get('UA') or played.get('ua'): headers['User-Agent'] = played.get('UA') or played['ua']
        url = played.get('url')
        if isinstance(url, list):
            record['qualities'] = url[::2]
            url = url[1] if len(url) >= 2 else None
        if not isinstance(url, str) or not url.startswith('http'):
            detail = played.get('errMsg') or played.get('msg')
            raise Failure('no single http url: %r%s' % (str(url)[:100], ('; plugin: ' + str(detail)) if detail else ''))
        parsed = urllib.parse.urlparse(url)
        if parsed.hostname in ('127.0.0.1', 'localhost') and parsed.path == '/proxy':
            query = urllib.parse.parse_qs(parsed.query)
            record['proxy'] = 'plugin local proxy do=%s' % query.get('do', ['?'])[0]
            kind = query.get('do', [''])[0]
            if kind == 'm3u8' and query.get('url'):
                url = query['url'][0]
            elif kind == 'bili':
                params = {'avid': query['aid'][0], 'cid': query['cid'][0], 'qn': query.get('qn', ['16'])[0], 'fnval': '0', 'fnver': '0'}
                headers.setdefault('Referer', 'https://www.bilibili.com/')
                raw, _ = http_get('https://api.bilibili.com/x/player/playurl?' + urllib.parse.urlencode(params), headers)
                response = json.loads(raw)
                media = response.get('data') or {}; files = media.get('durl') or []
                if response.get('code') != 0: raise Failure('Bilibili: ' + str(response.get('message')))
                if len(files) != 1 or 'mp4' not in media.get('format', '').lower(): raise Failure('Bilibili has no single progressive MP4 stream')
                url = files[0]['url']
                record['stages']['bili'] = 'Progressive MP4, quality %s' % media.get('quality')
            else:
                raise Failure('plugin local proxy (%s) that cannot be unwrapped: %s' % (query.get('do'), url[:100]))
        record['stages']['play'] = url[:110]
        stage = 'media'
        try:
            data, status = http_get(url, {k: str(v) for k, v in headers.items()}, timeout=25, limit=4096)
        except urllib.error.HTTPError as e:
            raise Failure('media URL returned HTTP %d' % e.code)
        except Exception as e:
            raise Failure('media URL failed: %s: %s' % (type(e).__name__, e))
        record['stages']['media'] = 'HTTP %d, starts with %r' % (status, data[:12])
        record.update(ok=True)
    except Failure as f:
        record.update(ok=False, failed=stage, error=str(f), diag=f.diag)
    except Exception as e:
        record.update(ok=False, failed=stage, error='harness: %s: %s' % (type(e).__name__, e))
    finally:
        if session is not None: session.close()
    record['seconds'] = round(time.time() - started, 1)
    return record


def main():
    os.makedirs(OUT + '/jobs', exist_ok=True)
    raw, _ = http_get(SUB)
    config = json.loads(raw)
    with open(OUT + '/subscription.json', 'wb') as stream: stream.write(raw)
    spider = (config.get('spider') or '').split(';md5;')[0]
    jar = OUT + '/plugin.jar'
    if spider:
        data, _ = http_get(urllib.parse.urljoin(SUB, spider), timeout=60)
        open(jar, 'wb').write(data)
    sites = [s for s in config.get('sites', []) if not only or any(text in json.dumps(s, ensure_ascii=False) for text in only)]
    print('%d sites, %d workers, jar %s' % (len(sites), workers, jar), flush=True)
    results = []
    with cf.ThreadPoolExecutor(workers) as pool:
        futures = {pool.submit(test_site, s, SUB, jar): s for s in sites}
        for future in cf.as_completed(futures):
            r = future.result(); results.append(r)
            print('%s %-26s %-18s %s' % ('OK  ' if r['ok'] else 'FAIL', str(r['name'])[:24], str(r['api'])[:18], '' if r['ok'] else '[%s] %s' % (r['failed'], r['error'][:110])), flush=True)
    order = {s.get('key'): i for i, s in enumerate(sites)}
    results.sort(key=lambda r: order.get(r['key'], 0))
    json.dump(results, open(OUT + '/results.json', 'w'), ensure_ascii=False, indent=1)
    print('\n%d/%d sources passed the full pipeline' % (sum(r['ok'] for r in results), len(results)))


if __name__ == "__main__":
    main()
