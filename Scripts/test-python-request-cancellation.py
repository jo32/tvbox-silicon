#!/usr/bin/env python3
"""Cancelling embedded Python requests (Runtime/PythonHost/cancellation.py) through host.handle.

Runs with build/PythonHost's interpreter (Scripts/build-python-host.sh), whose site-packages has requests.
"""
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYTHON = ROOT / 'build/PythonHost/python/bin/python3'
if PYTHON.exists() and Path(sys.executable).resolve() != PYTHON.resolve() and not os.environ.get('CANCEL_TEST_ANY_PYTHON'):
    os.execv(str(PYTHON), [str(PYTHON), '-I', __file__, *sys.argv[1:]])
sys.path[:0] = [str(ROOT / 'Runtime/PythonHost'), str(ROOT / 'build/PythonHost/site-packages')]
spec = importlib.util.spec_from_file_location('cancellation_host', ROOT / 'Runtime/PythonHost/host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)

SOURCE = '''import json, time, requests
from time import sleep
from pathlib import Path
from base.spider import Spider as Base
class Spider(Base):
    def init(self, extend=''): self.origin = json.loads(extend)['origin']
    def searchContent(self, key, quick, page='1'):
        Path(__file__ + '.started').write_text(key)
        if key == 'sleep':
            while True:  # a retry loop that swallows errors must still end
                try:
                    time.sleep(30)
                except Exception:
                    pass
        if key == 'bare-sleep': sleep(30)
        if key == 'http': requests.get(self.origin + '/hold').content
        if key == 'clock': return {'list': [{'vod_id': str(time.time() > 0 and time.monotonic() > 0)}]}
        return {'list': [{'vod_id': key}]}
'''


class CancellationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name)
        self.entry = self.path / 'entry.py'
        self.entry.write_text(SOURCE)
        self.release = threading.Event()
        test = self

        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                test.release.wait(30)
                self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'ok')
        self.origin = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        self.origin.daemon_threads = True
        threading.Thread(target=self.origin.serve_forever, daemon=True).start()

    def tearDown(self):
        self.release.set()
        for slot in tuple(host._slots.values()):
            if slot.session:
                slot.session.close()
        host._slots.clear()
        self.origin.shutdown(); self.origin.server_close()
        self.folder.cleanup()

    def request(self, ident, keyword, timeout=60):
        return {'request': ident, 'session': str(self.entry), 'script': str(self.entry), 'sourceDirectory': str(self.path),
                'cache': str(self.path / 'cache'), 'profile': str(self.path / 'profile'), 'api': self.entry.as_uri(),
                'ext': json.dumps({'origin': 'http://127.0.0.1:%d' % self.origin.server_address[1]}),
                'timeoutSeconds': timeout, 'params': {'wd': keyword}}

    def start(self, ident, keyword, timeout=60):
        result, done = {}, threading.Event()
        def run():
            result.update(json.loads(host.handle(json.dumps(self.request(ident, keyword, timeout)))))
            done.set()
        threading.Thread(target=run, daemon=True).start()
        return result, done

    def started(self, keyword):
        marker = Path(str(self.entry) + '.started')
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if marker.exists() and marker.read_text() == keyword:
                marker.unlink(); return
            time.sleep(.01)
        self.fail('the source never started ' + keyword)

    def cancel(self, ident):
        self.assertEqual(host.handle(json.dumps({'command': 'cancel', 'request': ident})), '{}')

    def assert_stops(self, result, done, code='request_cancelled', within=.5):
        began = time.monotonic()
        self.assertTrue(done.wait(within + 2), 'the request kept its source busy')
        self.assertLess(time.monotonic() - began, within)
        self.assertEqual(result.get('errorCode'), code, result)

    def call(self, ident, keyword):
        answer = json.loads(host.handle(json.dumps(self.request(ident, keyword))))
        return json.loads(answer['result']) if 'result' in answer else answer

    def test_cancel_ends_a_sleep_even_in_a_loop_that_swallows_errors(self):
        result, done = self.start('r1', 'sleep')
        self.started('sleep')
        self.cancel('r1')
        self.assert_stops(result, done)
        self.assertEqual(self.call('r2', 'after')['list'][0]['vod_id'], 'after', 'the source stayed unusable')

    def test_cancel_ends_from_time_import_sleep(self):
        result, done = self.start('r1', 'bare-sleep')
        self.started('bare-sleep')
        self.cancel('r1')
        self.assert_stops(result, done)

    def test_cancel_ends_an_http_wait(self):
        result, done = self.start('r1', 'http')
        self.started('http')
        time.sleep(.1)  # in the request now
        self.cancel('r1')
        self.assert_stops(result, done)

    def test_deadline_ends_a_sleep(self):
        result, done = self.start('r1', 'sleep', timeout=.5)
        self.started('sleep')
        self.assert_stops(result, done, 'source_timeout', within=1)

    def test_cancel_before_start_stops_the_request(self):
        self.cancel('early')
        self.assertEqual(self.call('early', 'fast').get('errorCode'), 'request_cancelled')
        self.assertEqual(self.call('later', 'fast')['list'][0]['vod_id'], 'fast')

    def test_cancel_ends_a_caller_waiting_for_the_busy_source(self):
        first, first_done = self.start('r1', 'sleep')
        self.started('sleep')
        second, second_done = self.start('r2', 'fast')
        time.sleep(.2)
        self.cancel('r2')
        self.assert_stops(second, second_done)
        self.assertFalse(first_done.is_set())
        self.cancel('r1')
        self.assert_stops(first, first_done)

    def test_http_timeout_defaults_to_20_seconds_within_the_deadline(self):
        seen = []
        original = host._send
        def probe(session, prepared, **options):
            seen.append(options['timeout'])
            return original(session, prepared, **options)
        host._send = probe
        try:
            self.release.set()
            self.assertNotIn('error', self.call('r1', 'http'))
            result, done = self.start('r2', 'http', timeout=5)
            self.assertTrue(done.wait(10))
        finally:
            host._send = original
        self.assertEqual(seen[0], 20)
        self.assertLessEqual(seen[1], 5)

    def test_source_keeps_the_rest_of_time(self):
        self.assertEqual(self.call('r1', 'clock')['list'][0]['vod_id'], 'True')

    def test_outside_a_request_sleep_is_time_sleep(self):
        began = time.monotonic()
        host.cancellation.sleep(.05)
        self.assertGreaterEqual(time.monotonic() - began, .05)


if __name__ == '__main__':
    unittest.main(verbosity=2)
