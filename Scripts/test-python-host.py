#!/usr/bin/env python3
"""Exercise the bundled Python spider host protocol without external network access."""
import json
import pathlib
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root = pathlib.Path(__file__).resolve().parents[1]
host = root / 'build/PythonHost'
with tempfile.TemporaryDirectory() as folder:
    job = pathlib.Path(folder)
    source = job / 'fixture.py'
    source.write_text('''
import sys
sys.path.append('..')
from base.spider import Spider
from Crypto.Cipher import AES
from pyquery import PyQuery
from bs4 import BeautifulSoup

class Spider(Spider):
    def init(self, extend=''):
        self.ext = extend
        self.setCache('runs', int(self.getCache('runs') or 0) + 1)
    def homeContent(self, filter):
        title = PyQuery('<b>title</b>')('b').text()
        return {'class': [{'type_id': self.getCache('runs'), 'type_name': title}], 'list': []}
    def homeVideoContent(self):
        return {'list': [{'vod_id': 'recommended', 'vod_name': self.ext}]}
    def categoryContent(self, tid, pg, filter, extend):
        return {'list': [{'vod_id': tid + '-' + pg}], 'pagecount': 3}
    def detailContent(self, ids):
        self.selected = ids[0]
        return {'list': [{'vod_id': ids[0], 'vod_name': self.html('<p>x</p>').xpath('//p/text()')[0]}]}
    def searchContent(self, key, quick):
        soup = BeautifulSoup('<a href="/one">One</a>', 'html.parser')
        return {'list': [{'vod_id': soup.a['href'], 'vod_name': key + str(AES.block_size)}]}
    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': self.getProxyUrl() + '&id=' + self.selected + '&flag=' + flag}
    def localProxy(self, param):
        self.proxied = getattr(self, 'proxied', 0) + 1
        if param.get('kind') == 'count':
            return [200, 'text/plain', str(self.proxied)]
        return [200, 'application/vnd.apple.mpegurl', '#EXTM3U\\n# ' + param['id'] + ' ' + param['flag']]
''')
    request = job / 'request.json'
    request.write_text(json.dumps(dict(script=str(source), cache=str(job), api='https://fixture.example/spider.py?extend=from-url', key='fixture')))

    def wait(file):
        until = time.monotonic() + 15
        while time.monotonic() < until:
            if file.exists(): return json.loads(file.read_text())
            time.sleep(.02)
        raise AssertionError('Host timed out: ' + str(file) + '\n' + (job / 'log').read_text())

    for run in (1, 2):
        (job / 'ready.json').unlink(missing_ok=True)
        with open(job / 'log', 'w') as log:
            started = time.monotonic()
            process = subprocess.Popen([str(host / 'python/bin/python3'), '-I', '-B', '-u', str(host / 'host.py'), '--serve', str(request)],
                                       stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
            try:
                assert wait(job / 'ready.json') == {'ready': True}
                startup = time.monotonic() - started
                counter = 0

                def call(params):
                    global counter
                    counter += 1
                    ident = f'{run}-{counter}'
                    process.stdin.write(json.dumps(dict(id=ident, params=params)) + '\n'); process.stdin.flush()
                    result = wait(job / 'responses' / (ident + '.json'))
                    assert 'error' not in result, result
                    return json.loads(result['result'])
                home = call({})
                assert home['class'][0] == {'type_id': str(run), 'type_name': 'title'}, home
                assert home['list'] == [{'vod_id': 'recommended', 'vod_name': 'from-url'}], home
                assert call({'t': 'movie', 'pg': '2'})['list'] == [{'vod_id': 'movie-2'}]
                assert call({'ids': 'chosen'})['list'] == [{'vod_id': 'chosen', 'vod_name': 'x'}]
                assert call({'wd': 'key', 'pg': '1'})['list'] == [{'vod_id': '/one', 'vod_name': 'key16'}]
                url = call({'play': 'opaque', 'flag': 'line'})['url']
                assert '/py-proxy?do=py' in url and url.startswith('http://127.0.0.1:'), url
                with urllib.request.urlopen(url, timeout=5) as response:
                    assert response.headers['Content-Type'] == 'application/vnd.apple.mpegurl'
                    assert response.read().decode() == '#EXTM3U\n# chosen line'
                assert (job / 'proxy-active').exists()
                # AVPlayer reads progressive media in ranges; repeated ranges reuse one spider response.
                ranged = urllib.request.Request(url, headers={'Range': 'bytes=0-1'})
                with urllib.request.urlopen(ranged, timeout=5) as response:
                    assert response.status == 206 and response.headers['Content-Range'] == 'bytes 0-1/21', response.headers
                    assert response.read() == b'#E'
                with urllib.request.urlopen(urllib.request.Request(url, headers={'Range': 'bytes=-5'}), timeout=5) as response:
                    assert response.status == 206 and response.read() == b' line'
                try:
                    urllib.request.urlopen(urllib.request.Request(url, headers={'Range': 'bytes=99-'}), timeout=5)
                    raise AssertionError('unsatisfiable range accepted')
                except urllib.error.HTTPError as error:
                    assert error.code == 416 and error.headers['Content-Range'] == 'bytes */21'
                counter_url = url.split('&')[0] + '&kind=count'
                with urllib.request.urlopen(counter_url, timeout=5) as response:
                    proxied = int(response.read())
                assert proxied == 2, f'spider localProxy ran {proxied} times; ranges must reuse the cached response'
                process.stdin.close()
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None: process.kill(); process.wait()
        print(f'run {run}: ready in {startup:.2f}s')
print('Python host checks passed: base.spider, bundled libraries, persistent cache, search arity, proxy with byte ranges, response protocol.')
