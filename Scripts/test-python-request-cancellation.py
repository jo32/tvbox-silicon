#!/usr/bin/env python3
"""Actual Python calls, loops, sleeps and socket reads must relinquish their runtime slot."""
import importlib.util
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('python_cancellation_host', ROOT / 'Runtime/PythonHost/host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)

SOURCE = '''from pathlib import Path
import json, time, requests, urllib.request
from base.spider import Spider as Base
class Spider(Base):
    def init(self, extend=''): self.origin = json.loads(extend)['origin']
    def searchContent(self, key, quick, page='1'):
        if key == 'fast': return {'list':[{'vod_id':'fast'}]}
        Path(__file__ + '.started').write_text(key)
        if key == 'loop':
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    for i in range(100): value = i * i
                except Exception:
                    pass
        elif key == 'sleep':
            time.sleep(2)
        elif key == 'requests':
            with requests.get(self.origin + '/hold', stream=True, timeout=5) as response:
                response.content
        elif key == 'urllib':
            with urllib.request.urlopen(self.origin + '/hold', timeout=5) as response:
                response.read()
        elif key == 'child':
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(1) as pool:
                pool.submit(time.sleep, 2).result()
        elif key == 'native':
            import cancellation
            cancellation._sleep(1.2)  # Simulate an uninterruptible native call.
        elif key == 'fail':
            raise ValueError('fixture-script-failure')
        return {'list':[{'vod_id':'late'}]}
'''


class PythonCancellationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name)
        self.entry = self.path / 'entry.py'
        self.entry.write_text(SOURCE)
        self.release = threading.Event()
        self.received = threading.Event()
        self.threads = []
        test = self

        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Length', '1048576')
                self.end_headers()
                self.wfile.write(b'first')
                self.wfile.flush()
                test.received.set()
                test.release.wait(3)
        self.origin = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        self.origin.daemon_threads = True
        self.origin_thread = threading.Thread(target=self.origin.serve_forever, daemon=True)
        self.origin_thread.start()

    def tearDown(self):
        self.release.set()
        for thread in self.threads:
            thread.join(4)
        for slot in tuple(host._slots.values()):
            if slot.session:
                slot.session.close()
        host._slots.clear()
        self.origin.shutdown()
        self.origin.server_close()
        self.origin_thread.join()
        self.folder.cleanup()

    def input(self, request, keyword, timeout=4):
        return {'request': request, 'session': str(self.entry), 'script': str(self.entry),
            'sourceDirectory': str(self.path), 'cache': str(self.path / 'cache'),
            'profile': str(self.path / 'profile'), 'api': self.entry.as_uri(),
            'ext': json.dumps({'origin': f'http://127.0.0.1:{self.origin.server_port}'}),
            'timeoutSeconds': timeout, 'params': {'wd': keyword}}

    def start(self, request='fixture-request', keyword='loop', timeout=4):
        result, done = {}, threading.Event()
        def run():
            result.update(json.loads(host.handle(json.dumps(self.input(request, keyword, timeout)))))
            done.set()
        thread = threading.Thread(target=run, daemon=True)
        self.threads.append(thread)
        thread.start()
        return result, done

    def wait_started(self):
        end = time.monotonic() + 2
        while time.monotonic() < end:
            if Path(str(self.entry) + '.started').exists(): return
            time.sleep(.01)
        self.fail('the fixture never entered its real Python call')

    def cancel(self, request='fixture-request'):
        return json.loads(host.handle(json.dumps({'command':'cancel', 'request':request})))

    def assert_stopped(self, result, done, code='request_cancelled'):
        self.assertTrue(done.wait(.7), 'the caller stopped waiting but real Python execution kept its slot')
        self.assertEqual(result.get('errorCode'), code, result)
        self.assertNotIn('result', result)

    def test_running_python_loop_exits_even_when_source_catches_exception(self):
        result, done = self.start()
        self.wait_started()
        self.cancel()
        self.assert_stopped(result, done)

    def test_request_deadline_bounds_the_whole_python_call(self):
        result, done = self.start(timeout=.18)
        self.assert_stopped(result, done, 'request_timeout')

    def test_source_sleep_is_interrupted_without_waiting_for_its_delay(self):
        result, done = self.start(keyword='sleep')
        self.wait_started()
        self.cancel()
        self.assert_stopped(result, done)

    def test_cancel_shuts_down_a_requests_body_read(self):
        result, done = self.start(keyword='requests')
        self.assertTrue(self.received.wait(2))
        self.cancel()
        self.assert_stopped(result, done)

    def test_cancel_shuts_down_an_urllib_body_read(self):
        result, done = self.start(keyword='urllib')
        self.assertTrue(self.received.wait(2))
        self.cancel()
        self.assert_stopped(result, done)

    def test_cancellation_arriving_before_native_execution_skips_source_initialization(self):
        self.cancel('not-started')
        result = json.loads(host.handle(json.dumps(self.input('not-started', 'loop'))))
        self.assertEqual(result.get('errorCode'), 'request_cancelled')
        self.assertFalse(Path(str(self.entry) + '.started').exists())

    def test_a_cancelled_source_can_answer_the_next_request(self):
        result, done = self.start()
        self.wait_started()
        self.cancel()
        self.assert_stopped(result, done)
        fast = json.loads(host.handle(json.dumps(self.input('second-request', 'fast'))))
        self.assertEqual(json.loads(fast['result'])['list'], [{'vod_id':'fast'}])

    def test_child_executor_work_exits_before_request_releases_its_slot(self):
        result, done = self.start(keyword='child')
        self.wait_started()
        self.cancel()
        self.assert_stopped(result, done)
        fast = json.loads(host.handle(json.dumps(self.input('after-child', 'fast'))))
        self.assertIn('result', fast)

    def test_cancelled_native_wait_keeps_its_slot_until_it_really_returns(self):
        result, done = self.start(keyword='native')
        self.wait_started()
        time.sleep(.05)
        self.cancel()
        self.assertFalse(done.wait(.15), 'claimed to force-stop a native blocking call')
        second, finished = self.start(request='behind-native', keyword='fast')
        self.assertFalse(finished.wait(.15), 'same-source lock released before native return')
        self.assertTrue(done.wait(2))
        self.assertTrue(finished.wait(1))
        self.assertEqual(result.get('errorCode'), 'request_cancelled')
        self.assertIn('result', second)

    def test_cancel_while_waiting_for_same_source_does_not_cancel_its_owner(self):
        first, owner = self.start(request='owner', keyword='sleep')
        self.wait_started()
        second, waiter = self.start(request='waiter', keyword='fast')
        time.sleep(.05)
        self.cancel('waiter')
        self.assert_stopped(second, waiter)
        self.assertFalse(owner.is_set())
        self.cancel('owner')
        self.assert_stopped(first, owner)

    def test_session_limit_never_evicts_an_active_source(self):
        maximum = host.MAX_SESSIONS
        host.MAX_SESSIONS = 1
        try:
            first, done = self.start(request='busy-owner', keyword='sleep')
            self.wait_started()
            request = self.input('new-source', 'fast')
            request.update(session='other', cache=str(self.path / 'other'))
            rejected = json.loads(host.handle(json.dumps(request)))
            self.assertIn('busy', rejected.get('error', ''))
            self.assertEqual(len(host._slots), 1)
            self.assertFalse(done.is_set())
            self.cancel('busy-owner')
            self.assert_stopped(first, done)
            answer = json.loads(host.handle(json.dumps(request)))
            self.assertIn('result', answer)
            self.assertEqual(len(host._slots), 1)
        finally:
            host.MAX_SESSIONS = maximum

    def test_other_source_and_unscoped_thread_keep_their_own_lifetime(self):
        first, done = self.start(request='first', keyword='sleep')
        self.wait_started()
        another = self.path / 'another.py'
        another.write_text(SOURCE)
        request = self.input('other', 'fast')
        request.update(session='other', script=str(another), cache=str(self.path / 'other'))
        self.cancel('first')
        answer = json.loads(host.handle(json.dumps(request)))
        self.assertIn('result', answer)
        self.assert_stopped(first, done)
        import sys
        previous = sys.gettrace()
        def trace(frame, event, arg): return trace
        sys.settrace(trace)
        try:
            host.handle(json.dumps(self.input('trace-restore', 'fast')))
            self.assertIs(sys.gettrace(), trace)
        finally:
            sys.settrace(previous)

    def test_script_error_keeps_its_reason_and_next_call_has_a_fresh_deadline(self):
        failed = json.loads(host.handle(json.dumps(self.input('failure', 'fail'))))
        self.assertEqual(failed.get('errorCode'), 'script_error')
        self.assertIn('fixture-script-failure', failed.get('error', ''))
        fast = json.loads(host.handle(json.dumps(self.input('after-error', 'fast'))))
        self.assertEqual(json.loads(fast['result'])['list'], [{'vod_id':'fast'}])


if __name__ == '__main__':
    unittest.main(verbosity=2)
