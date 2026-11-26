#!/usr/bin/env python3
"""The Python host's media proxy (`ProxyHandler` in Runtime/PythonHost/host.py) against loopback servers.

Runs with build/PythonHost's interpreter (Scripts/build-python-host.sh), whose site-packages has requests.
"""
import gzip
import http.client
import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
PYTHON = ROOT / 'build/PythonHost/python/bin/python3'
if PYTHON.exists() and Path(sys.executable).resolve() != PYTHON.resolve() and not os.environ.get('PROXY_TEST_ANY_PYTHON'):
    os.execv(str(PYTHON), [str(PYTHON), '-I', __file__, *sys.argv[1:]])
sys.path[:0] = [str(ROOT / 'Runtime/PythonHost'), str(ROOT / 'build/PythonHost/site-packages')]
spec = importlib.util.spec_from_file_location('proxy_host', ROOT / 'Runtime/PythonHost/host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
import requests

MOVIE = bytes(range(256)) * (16 * 1024)  # 4 MB


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.gets = 0
        self.calls = []
        self.release = threading.Event()
        self.generator_closed = threading.Event()
        test = self

        class Origin(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_): pass
            def do_GET(self):
                test.gets += 1
                if self.path == '/missing':
                    self.send_response(404); self.send_header('Content-Length', '9'); self.end_headers()
                    self.wfile.write(b'not found'); return
                if self.path == '/slow':
                    test.release.wait(5); return
                if self.path == '/gzip':
                    data = gzip.compress(MOVIE[:100000], mtime=0)
                    self.send_response(200); self.send_header('Content-Encoding', 'gzip')
                    self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
                # Ignores Range, as most hosts behind a spider do for the spider's own request.
                self.send_response(200); self.send_header('Content-Length', str(len(MOVIE))); self.end_headers()
                if self.path == '/held':
                    self.wfile.write(MOVIE[:65536]); self.wfile.flush()
                    test.release.wait(5)
                    self.wfile.write(MOVIE[65536:]); return
                self.wfile.write(MOVIE)

        self.origin = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        self.origin.daemon_threads = True
        threading.Thread(target=self.origin.serve_forever, daemon=True).start()
        origin = 'http://127.0.0.1:%d' % self.origin.server_address[1]

        class Spider:
            def localProxy(self, params):
                test.calls.append(dict(params))
                kind = params.get('kind')
                if kind == 'response': return [200, 'video/mp4', requests.get(origin + '/movie')]
                if kind == 'bytes': return [200, 'video/mp4', requests.get(origin + '/movie').content]
                if kind == 'stream': return [200, 'video/mp4', requests.get(origin + '/movie', stream=True)]
                if kind == 'held': return [200, 'video/mp4', requests.get(origin + '/held', stream=True)]
                if kind == 'gzip': return [200, 'video/mp4', requests.get(origin + '/gzip', stream=True)]
                if kind == 'missing': return [200, 'video/mp4', requests.get(origin + '/missing', stream=True)]
                if kind == 'raises-missing':
                    response = requests.get(origin + '/missing'); response.raise_for_status()
                if kind == 'timeout': return [200, 'video/mp4', requests.get(origin + '/slow', timeout=0.3)]
                if kind == 'legacy-headers':
                    referer = json.loads(params['headers'])['Referer']
                    return [200, 'text/plain', referer]
                if kind == 'no-headers': return [200, 'text/plain', 'headers' in params and 'yes' or 'no']
                if kind == 'generator':
                    def endless():
                        try:
                            while True: yield b'x' * 1000
                        finally:
                            test.generator_closed.set()
                    return [200, 'video/mp2t', endless()]
                return [404, 'text/plain', 'unknown']

        session = host.Session.__new__(host.Session)
        session.spider = Spider()
        self.folder = tempfile.TemporaryDirectory()
        session.cache = self.folder.name
        session.cached_response = (None, None)
        session.cache_lock = threading.Lock()
        self.proxy = ThreadingHTTPServer(('127.0.0.1', 0), type('FixtureProxy', (host.ProxyHandler,), {'session': session}))
        self.proxy.daemon_threads = True
        threading.Thread(target=self.proxy.serve_forever, daemon=True).start()

    def tearDown(self):
        self.release.set()
        self.proxy.shutdown(); self.proxy.server_close()
        self.origin.shutdown(); self.origin.server_close()
        self.folder.cleanup()

    def connection(self):
        return http.client.HTTPConnection('127.0.0.1', self.proxy.server_address[1], timeout=10)

    def get(self, query, headers=None, method='GET', connection=None):
        client = connection or self.connection()
        client.request(method, '/py-proxy?do=py&' + query, headers=headers or {})
        response = client.getresponse()
        body = response.read()
        if connection is None:
            client.close()
        return response, body

    def assert_ranges(self, kind):
        for first, last in ((0, 1), (1000000, 1999999), (3000000, None)):
            response, body = self.get('kind=' + kind, {'Range': f'bytes={first}-{"" if last is None else last}'})
            end = len(MOVIE) - 1 if last is None else last
            self.assertEqual(response.status, 206)
            self.assertEqual(response.getheader('Content-Range'), f'bytes {first}-{end}/{len(MOVIE)}')
            self.assertEqual(body, MOVIE[first:end + 1])
        self.assertEqual((len(self.calls), self.gets), (1, 1), 'each range asked the spider and the origin again')

    def test_buffered_response_serves_three_ranges_from_one_download(self):
        self.assert_ranges('response')

    def test_bytes_body_serves_three_ranges_from_one_call(self):
        self.assert_ranges('bytes')

    def test_streamed_response_whose_upstream_ignores_range_still_answers_206(self):
        self.assert_ranges('stream')

    def test_streamed_response_without_range_arrives_before_the_upstream_finishes(self):
        client = self.connection()
        client.timeout = 2  # the origin holds back all but its first 64 KB for 5 s: buffering it all times out
        client.request('GET', '/py-proxy?do=py&kind=held')
        response = client.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader('Content-Length'), str(len(MOVIE)))
        self.assertEqual(response.read(65536), MOVIE[:65536])
        self.release.set()
        client.sock.settimeout(10)
        self.assertEqual(response.read(), MOVIE[65536:])
        # The same connection answers again: the framing held.
        _, body = self.get('kind=bytes', connection=client)
        self.assertEqual(body, MOVIE)

    def test_compressed_upstream_is_sent_decoded_in_chunks(self):
        response, body = self.get('kind=gzip')
        self.assertEqual(response.status, 200)
        self.assertIsNone(response.getheader('Content-Encoding'))
        self.assertEqual(response.getheader('Transfer-Encoding'), 'chunked')
        self.assertEqual(body, MOVIE[:100000])

    def test_endless_generator_streams_and_is_closed_when_the_player_leaves(self):
        client = self.connection()
        client.request('GET', '/py-proxy?do=py&kind=generator')
        response = client.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(50000), b'x' * 50000)
        client.close()
        self.assertTrue(self.generator_closed.wait(5), 'the generator kept running after the player left')

    def test_head_sends_headers_only(self):
        response, body = self.get('kind=stream', method='HEAD')
        self.assertEqual(response.status, 200)
        self.assertEqual(body, b'')

    def test_legacy_headers_query_parameter_reaches_the_spider_untouched(self):
        query = 'kind=legacy-headers&headers=' + quote(json.dumps({'Referer': 'https://example.invalid/page'}))
        response, body = self.get(query, {'Range': 'bytes=0-', 'Referer': 'http://127.0.0.1/'})
        self.assertEqual(response.status, 206)
        self.assertEqual(body, b'https://example.invalid/page')
        _, body = self.get('kind=no-headers', {'User-Agent': 'AppleCoreMedia'})
        self.assertEqual(body, b'no', 'the player request headers were put in params')

    def test_upstream_refusal_passes_through(self):
        for kind in ('missing', 'raises-missing'):
            for headers in ({}, {'Range': 'bytes=0-1'}):
                response, _ = self.get('kind=' + kind, headers)
                self.assertEqual(response.status, 404, (kind, headers))

    def test_upstream_timeout_answers_504(self):
        response, _ = self.get('kind=timeout')
        self.assertEqual(response.status, 504)


if __name__ == '__main__':
    unittest.main(verbosity=2)
