#!/usr/bin/env python3
"""Local protocol regressions for the embedded Python media proxy; no external services."""
import base64
import http.client
import importlib.util
import io
import json
import gzip
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit, quote

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('proxy_host', ROOT / 'Runtime/PythonHost/host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
import requests


class ProxyStreamingTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.release = threading.Event()
        self.disconnected = threading.Event()
        self.generator_closed = threading.Event()
        self.file_closed = threading.Event()
        self.audio_released = threading.Event()
        self.file_reads = 0
        self.calls = []
        test = self

        class Origin(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                if self.path == '/gzip':
                    data = gzip.compress(b'compressed media fixture', mtime=0)
                    self.send_response(200)
                    self.send_header('Content-Encoding', 'gzip')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if self.path == '/hold':
                    self.send_response(200)
                    self.send_header('Content-Length', str(8 * 1024 * 1024))
                    self.end_headers()
                    self.wfile.write(b'x' * 65536)
                    self.wfile.flush()
                    self.connection.settimeout(4)
                    try:
                        if not self.connection.recv(1):
                            test.disconnected.set()
                    except OSError:
                        pass
                    return
                if self.path == '/forbidden':
                    self.send_response(403)
                    self.send_header('Content-Length', '6')
                    self.end_headers()
                    self.wfile.write(b'denied')
                    return
                self.send_response(206)
                self.send_header('Content-Length', '5')
                self.send_header('Content-Range', 'bytes 3-7/16')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('ETag', '"fixture"')
                self.end_headers()
                self.wfile.write(b'34567')
            def log_message(self, *_): pass

        self.origin = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        self.origin.daemon_threads = True
        threading.Thread(target=self.origin.serve_forever, daemon=True).start()
        origin = 'http://127.0.0.1:' + str(self.origin.server_address[1])

        class Spider:
            def localProxy(self, params):
                test.calls.append(params)
                kind = params.get('kind')
                if kind == 'legacy':
                    referer = json.loads(params['headers'])['Referer']
                    return [200, 'text/plain', referer + '|' + params['range'] + '|' + params['Range']]
                if kind == 'range':
                    response = requests.get(origin + '/range', headers=params.get('headers', {}), stream=True)
                    return [200, 'video/mp4', response]
                if kind in ('forbidden', 'explicit-status'):
                    response = requests.get(origin + '/forbidden', stream=True)
                    return [418 if kind == 'explicit-status' else 200, 'text/plain', response]
                if kind == 'identity':
                    return [200, 'text/plain', params.get('headers', {}).get('Authorization', '')]
                if kind == 'hold':
                    response = requests.get(origin + '/hold', stream=True)
                    return [200, 'video/mp4', response]
                if kind in ('gzip-raw', 'gzip-decoded'):
                    response = requests.get(origin + '/gzip', stream=kind == 'gzip-raw')
                    return [200, 'video/mp4', response]
                if kind == 'generator':
                    def chunks():
                        try:
                            yield b'first'
                            test.release.wait(4)
                            yield b'last'
                        finally:
                            test.generator_closed.set()
                    return [200, 'video/mp4', chunks()]
                if kind == 'explicit':
                    return [206, 'video/mp4', b'34567', {'Content-Range': 'bytes 3-7/16', 'Content-Length': '5', 'Accept-Ranges': 'bytes'}]
                if kind == 'base64':
                    return [200, 'video/mp4', base64.b64encode(b'0123456789').decode(), {}, 1]
                if kind == 'file':
                    class Media(io.BytesIO):
                        def read(self, size=-1):
                            test.file_reads += 1
                            assert 0 < size <= 65536, 'unbounded file read'
                            return super().read(size)
                        def close(self):
                            test.file_closed.set()
                            super().close()
                    return [200, 'video/mp4', Media(b'file'), {'Content-Length': '4'}]
                if kind == 'large':
                    return [200, 'video/mp4', b'x' * (1024 * 1024 + 1)]
                return [200, 'text/plain', b'fast']

        self.session = host.Session.__new__(host.Session)
        self.session.spider = Spider()
        self.session.cache = self.folder.name
        self.session.cached_response = (None, None)
        self.session.cache_lock = threading.Lock()
        handler = type('FixtureProxy', (host.ProxyHandler,), {'session': self.session})
        self.proxy = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        self.proxy.daemon_threads = True
        threading.Thread(target=self.proxy.serve_forever, daemon=True).start()
        self.clients = []

    def client(self, kind, method='GET', headers=None, timeout=1):
        client = http.client.HTTPConnection('127.0.0.1', self.proxy.server_address[1], timeout=timeout)
        self.clients.append(client)
        client.request(method, '/py-proxy?do=py&kind=' + kind, headers=headers or {})
        return client, client.getresponse()

    def tearDown(self):
        self.release.set()
        for client in self.clients: client.close()
        self.proxy.shutdown(); self.proxy.server_close()
        self.origin.shutdown(); self.origin.server_close()
        self.folder.cleanup()

    def test_incoming_range_and_actual_upstream_206_metadata_survive(self):
        _, response = self.client('range', headers={'Range': 'bytes=3-7'})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.getheader('Content-Range'), 'bytes 3-7/16')
        self.assertEqual(response.getheader('Content-Length'), '5')
        self.assertEqual(response.getheader('ETag'), '"fixture"')
        self.assertEqual(response.read(), b'34567')
        self.assertEqual(self.calls[0].get('range'), 'bytes=3-7')
        self.assertEqual(self.calls[0].get('Range'), 'bytes=3-7')
        self.assertEqual(self.calls[0].get('headers', {}).get('Range'), 'bytes=3-7')

    def test_existing_query_headers_and_ranges_keep_their_plugin_contract(self):
        query = 'legacy&headers=' + quote('{"Referer":"https://example.invalid/source"}')
        query += '&range=legacy-lower&Range=legacy-upper'
        _, response = self.client(query, headers={'Range': 'bytes=0-'})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.read(), b'https://example.invalid/source|legacy-lower|legacy-upper')
        self.assertEqual(self.calls[0]['request_headers']['Range'], 'bytes=0-')

    def test_origin_failure_is_not_misreported_as_success(self):
        _, response = self.client('forbidden')
        self.assertEqual(response.status, 403)
        self.assertEqual(response.read(), b'denied')

    def test_explicit_plugin_failure_status_takes_precedence(self):
        _, response = self.client('explicit-status')
        self.assertEqual(response.status, 418)
        self.assertEqual(response.read(), b'denied')

    def test_cached_bytes_do_not_cross_request_credentials(self):
        for identity in ('Bearer first', 'Bearer second'):
            _, response = self.client('identity', headers={'Authorization': identity})
            self.assertEqual(response.read().decode(), identity)
        self.assertEqual(len(self.calls), 2)

    def test_explicit_content_range_is_not_removed(self):
        _, response = self.client('explicit', headers={'Range': 'bytes=3-7'})
        self.assertEqual(response.getheader('Content-Range'), 'bytes 3-7/16')
        self.assertEqual(response.read(), b'34567')

    def test_generator_delivers_first_bytes_without_waiting_for_end(self):
        _, response = self.client('generator')
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(5), b'first')
        self.assertFalse(self.release.is_set())
        self.release.set()
        self.assertEqual(response.read(), b'last')
        self.assertTrue(self.generator_closed.wait(1))

    def test_client_disconnect_closes_upstream_without_waiting_for_media_end(self):
        client, response = self.client('hold')
        self.assertEqual(response.read(65536), b'x' * 65536)
        # HTTPResponse holds the socket after HTTPConnection.close(). Close both.
        response.close(); client.close()
        self.assertTrue(self.disconnected.wait(2), 'upstream media connection remained open')


    def test_slow_media_does_not_serialize_other_proxy_requests(self):
        client, response = self.client('hold')
        self.assertEqual(response.read(65536), b'x' * 65536)
        _, fast = self.client('fast')
        self.assertEqual(fast.read(), b'fast')
        response.close(); client.close()

    def test_paused_reader_can_resume_without_truncating_a_companion_audio_response(self):
        # A DASH reader can leave its already-open AAC connection idle while it
        # consumes video. Scale finite wire timeouts only; all HTTP writes and
        # reads still use actual sockets. A media write deadline cuts this body
        # short and presents a false end of the programme when reading resumes.
        original = self.session.spider.localProxy
        movie = b'audio' * (1024 * 1024)
        def media(params):
            if params.get('kind') == 'paced-audio':
                return [200, 'audio/mp4', movie, {'Cache-Control': 'no-store'}]
            return original(params)
        self.session.spider.localProxy = media
        class PlaybackSocket:
            def __init__(self, wire): self.wire = wire
            def settimeout(self, seconds):
                self.wire.settimeout(min(seconds, .1) if seconds is not None else None)
            def __getattr__(self, name): return getattr(self.wire, name)
        class PacedHandler(host.ProxyHandler):
            session = self.session
            def setup(self):
                super().setup()
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
                self.connection = PlaybackSocket(self.connection)
        paced = ThreadingHTTPServer(('127.0.0.1', 0), PacedHandler)
        paced.daemon_threads = True
        threading.Thread(target=paced.serve_forever, daemon=True).start()
        client = http.client.HTTPConnection('127.0.0.1', paced.server_port, timeout=3)
        try:
            client.request('GET', '/py-proxy?do=py&kind=paced-audio')
            response = client.getresponse()
            prefix = response.read(65536)
            # Let the send window fill and exceed the accelerated finite timeout.
            self.assertFalse(threading.Event().wait(.4))
            _, other = self.client('fast')
            self.assertEqual(other.read(), b'fast')
            try:
                remaining = response.read()
            except http.client.IncompleteRead as error:
                remaining = error.partial
            self.assertEqual(len(prefix) + len(remaining), len(movie),
                'A healthy paused audio reader received EOF before the declared media length')
            self.assertEqual(prefix + remaining, movie)
        finally:
            client.close(); paced.shutdown(); paced.server_close()

    def test_disconnect_unblocks_a_backpressured_media_write_and_closes_its_generator(self):
        original = self.session.spider.localProxy
        test = self
        def media(params):
            if params.get('kind') != 'blocked-audio': return original(params)
            def chunks():
                try:
                    for _ in range(160): yield b'a' * 65536
                finally: test.audio_released.set()
            return [200, 'audio/mp4', chunks()]
        self.session.spider.localProxy = media
        class BlockedHandler(host.ProxyHandler):
            session = self.session
            def setup(self):
                super().setup()
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
        blocked = ThreadingHTTPServer(('127.0.0.1', 0), BlockedHandler)
        blocked.daemon_threads = True
        threading.Thread(target=blocked.serve_forever, daemon=True).start()
        client = http.client.HTTPConnection('127.0.0.1', blocked.server_port, timeout=3)
        try:
            client.request('GET', '/py-proxy?do=py&kind=blocked-audio')
            response = client.getresponse()
            self.assertEqual(len(response.read(65536)), 65536)
            self.assertFalse(test.audio_released.wait(.2))
            response.close(); client.close()
            self.assertTrue(test.audio_released.wait(1),
                'Closing playback left its media writer and generator blocked')
        finally:
            client.close(); blocked.shutdown(); blocked.server_close()

    def test_bytes_support_head_suffix_range_and_416(self):
        _, response = self.client('base64', 'HEAD')
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader('Content-Length'), '10')
        self.assertEqual(response.read(), b'')
        _, response = self.client('base64', headers={'Range': 'bytes=-3'})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.getheader('Content-Range'), 'bytes 7-9/10')
        self.assertEqual(response.read(), b'789')
        _, response = self.client('base64', headers={'Range': 'bytes=20-'})
        self.assertEqual(response.status, 416)
        self.assertEqual(response.getheader('Content-Range'), 'bytes */10')
        self.assertEqual(response.read(), b'')

    def test_head_closes_a_file_body_without_reading_it(self):
        _, response = self.client('file', 'HEAD')
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader('Content-Length'), '4')
        self.assertEqual(response.read(), b'')
        self.assertTrue(self.file_closed.wait(1))
        self.assertEqual(self.file_reads, 0)

    def test_large_source_bytes_are_not_retained_in_the_host_cache(self):
        for _ in range(2):
            _, response = self.client('large', headers={'Range': 'bytes=0-1'})
            self.assertEqual(response.read(), b'xx')
        self.assertEqual(len(self.calls), 2)
        self.assertIsNone(self.session.cached_response[1])

    def test_file_body_is_read_in_bounded_chunks(self):
        _, response = self.client('file')
        self.assertEqual(response.read(), b'file')
        self.assertTrue(self.file_closed.wait(1))
        self.assertEqual(self.file_reads, 1)

    def test_streaming_response_keeps_compressed_wire_length_and_encoding(self):
        _, response = self.client('gzip-raw')
        compressed = response.read()
        self.assertEqual(response.getheader('Content-Encoding'), 'gzip')
        self.assertEqual(int(response.getheader('Content-Length')), len(compressed))
        self.assertEqual(gzip.decompress(compressed), b'compressed media fixture')

    def test_already_decoded_response_does_not_claim_compressed_encoding_or_length(self):
        _, response = self.client('gzip-decoded')
        self.assertIsNone(response.getheader('Content-Encoding'))
        self.assertEqual(response.getheader('Content-Length'), '24')
        self.assertEqual(response.read(), b'compressed media fixture')


if __name__ == '__main__':
    unittest.main(verbosity=2)
