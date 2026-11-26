"""Cooperative request cancellation for the embedded Python host.

Hooks are installed once, and only act on the calling thread's request scope. They do not kill
threads, interrupt arbitrary native extensions, or change network calls made outside a request.
"""
import http.client
import os
import re
import socket
import sys
import threading
import time
import urllib.request
import weakref
from concurrent.futures import ThreadPoolExecutor

_local = threading.local()
_lock = threading.Lock()
_active = {}
_cancelled = {}
_sleep = time.sleep
_begin = http.client.HTTPResponse.begin
_open = urllib.request.OpenerDirector.open
_submit = ThreadPoolExecutor.submit


class RequestStopped(BaseException):
    """Pass through a spider's `except Exception: retry` handler."""
    def __init__(self, code):
        self.code = code
        super().__init__('The source took too long to respond.' if code == 'request_timeout'
                         else 'The source request was cancelled.')


def current_request():
    return getattr(_local, 'scope', None)


def interrupt_body(body):
    # Buffered reads hold a file lock, so close alone may block the cancel sender.
    try:
        body.fp.raw._sock.shutdown(socket.SHUT_RDWR)
    except (AttributeError, OSError):
        pass


class RequestScope:
    def __init__(self, request):
        self.id = str(request.get('request') or '')
        try:
            timeout = min(140, max(.05, float(request.get('timeoutSeconds', 140))))
        except (TypeError, ValueError):
            timeout = 140
        self.deadline = time.monotonic() + timeout
        self.event = threading.Event()
        self.lock = threading.Lock()
        self.code = None
        self.bodies = weakref.WeakSet()
        self.children = set()
        self.condition = threading.Condition()
        self.timer = threading.Timer(timeout, self.stop, args=('request_timeout',))
        self.timer.daemon = True
        source = os.path.abspath(os.path.dirname(request.get('script') or __file__))
        modules = os.path.abspath(os.path.join(request.get('profile') or source, 'modules'))
        self.folders = (source + os.sep, os.path.realpath(source) + os.sep, modules + os.sep)

    def __enter__(self):
        self.previous, self.previous_trace = current_request(), sys.gettrace()
        _local.scope = self
        with _lock:
            early = _cancelled.pop(self.id, 0)
            if self.id:
                _active[self.id] = self
        if early > time.monotonic():
            self.stop('request_cancelled')
        self.timer.start()
        sys.settrace(self.trace)
        return self

    def __exit__(self, *_):
        sys.settrace(self.previous_trace)
        _local.scope = self.previous
        self.finish_children()
        self.timer.cancel()
        with _lock:
            if _active.get(self.id) is self:
                _active.pop(self.id, None)
        if self.event.is_set():
            for body in tuple(self.bodies):
                try:
                    body.close()
                except (OSError, ValueError):
                    pass

    def finish_children(self):
        # Child executor work keeps the same native execution fence. Never release a slot while
        # a cancelled child can still touch the spider. Native extensions may delay this cleanup.
        with self.condition:
            if self.children:
                self.stop(self.code or 'request_cancelled')
                for future in tuple(self.children):
                    future.cancel()
                while self.children:
                    self.condition.wait(.05)

    def trace(self, frame, event, arg):
        if frame.f_code.co_filename.startswith(self.folders):
            self.check()
            return self.trace
        return None

    def check(self):
        if self.event.is_set():
            raise RequestStopped(self.code)
        if time.monotonic() >= self.deadline:
            self.stop('request_timeout')
            raise RequestStopped(self.code)

    def stop(self, code):
        with self.lock:
            if self.code is not None:
                return
            self.code = code
            self.event.set()
            bodies = tuple(self.bodies)
        for body in bodies:
            interrupt_body(body)

    def track(self, body):
        with self.lock:
            self.bodies.add(body)
            stopped = self.code is not None
        if stopped:
            interrupt_body(body)
            self.check()

    def timeout(self, value=None):
        self.check()
        remaining = max(.001, self.deadline - time.monotonic())
        if isinstance(value, tuple):
            return tuple(min(float(part), remaining) if part is not None else remaining for part in value)
        if value is None or value is socket._GLOBAL_DEFAULT_TIMEOUT:
            return remaining
        try:
            return min(float(value), remaining)
        except (TypeError, ValueError):
            # requests also accepts urllib3 Timeout objects.
            import urllib3
            return urllib3.util.Timeout(total=remaining, connect=remaining, read=remaining)


def cancel_request(ident):
    if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', ident):
        return
    with _lock:
        scope = _active.get(ident)
        if scope is None:
            now = time.monotonic()
            for key, deadline in tuple(_cancelled.items()):
                if deadline < now:
                    _cancelled.pop(key, None)
            _cancelled[ident] = now + 60
            while len(_cancelled) > 256:
                _cancelled.pop(next(iter(_cancelled)))
    if scope:
        scope.stop('request_cancelled')


def sleep(seconds):
    scope = current_request()
    if scope is None or seconds < 0:
        return _sleep(seconds)
    scope.check()
    scope.event.wait(min(seconds, max(0, scope.deadline - time.monotonic())))
    scope.check()


def response_begin(response):
    scope = current_request()
    if scope:
        scope.track(response)
    try:
        result = _begin(response)
    except BaseException:
        if scope:
            scope.check()
        raise
    if scope:
        scope.check()
    return result


def urlopen(opener, url, data=None, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):
    scope = current_request()
    if scope:
        timeout = scope.timeout(timeout)
    try:
        return _open(opener, url, data, timeout)
    except BaseException:
        if scope:
            scope.check()
        raise


def executor_submit(executor, function, /, *args, **kwargs):
    scope = current_request()
    if scope is None:
        return _submit(executor, function, *args, **kwargs)
    scope.check()

    def run():
        previous, previous_trace = current_request(), sys.gettrace()
        _local.scope = scope
        sys.settrace(scope.trace)
        try:
            scope.check()
            result = function(*args, **kwargs)
            scope.check()
            return result
        finally:
            sys.settrace(previous_trace)
            _local.scope = previous

    def done(future):
        with scope.condition:
            scope.children.discard(future)
            scope.condition.notify_all()

    with scope.condition:
        future = _submit(executor, run)
        scope.children.add(future)
        future.add_done_callback(done)
    return future


time.sleep = sleep
http.client.HTTPResponse.begin = response_begin
urllib.request.OpenerDirector.open = urlopen
ThreadPoolExecutor.submit = executor_submit
