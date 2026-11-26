"""Cancelling a request of the embedded Python host (iOS and tvOS).

The app gives up on a request it no longer waits for (`{"command": "cancel"}`), and each request has a
deadline. Running Python can't be stopped from outside, so a request stops where it waits on the host: an
HTTP call through requests (host.py's `send`) and the source module's own `time.sleep`. Both return at once
with `RequestStopped`. Anything else runs to its end. Nothing is traced and no library is patched: a request's
scope is local to its thread, and the Mac's one-source processes never open one.
"""
import threading
import time
import types

_local = threading.local()
_lock = threading.Lock()
_active = {}
_early = {}  # cancels that came before their request started: id -> when to forget it


class RequestStopped(BaseException):
    """A BaseException, so a source's `except Exception:` retry loop doesn't swallow it. `source_timeout` is the
    app's (localized) "took too long" error, as the Java host's; nobody waits for a cancelled request's answer."""
    def __init__(self, code):
        self.code = code
        super().__init__('The source took too long to respond.' if code == 'source_timeout'
                         else 'The source request was cancelled.')


def current():
    return getattr(_local, 'scope', None)


class RequestScope:
    """One request on its thread: `id` is the app's request id (empty: not cancellable), `timeout` in seconds."""

    def __init__(self, ident, timeout):
        self.id = ident
        self.deadline = time.monotonic() + timeout
        self.code = None
        self.changed = threading.Condition()

    def __enter__(self):
        self.previous = current()
        _local.scope = self
        with _lock:
            if self.id:
                if _early.pop(self.id, 0) > time.monotonic():
                    self.code = 'request_cancelled'
                _active[self.id] = self
        return self

    def __exit__(self, *_):
        _local.scope = self.previous
        with _lock:
            if _active.get(self.id) is self:
                del _active[self.id]

    def remaining(self):
        return self.deadline - time.monotonic()

    def check(self):
        if self.code is None and self.remaining() <= 0:
            self.code = 'source_timeout'
        if self.code:
            raise RequestStopped(self.code)

    def stop(self, code='request_cancelled'):
        with self.changed:
            if self.code is None:
                self.code = code
            self.changed.notify_all()

    def timeout(self, value):
        """An HTTP call's timeout: the source's, or 20 s as outside a request, never past the deadline."""
        remaining = max(0.001, self.remaining())
        if value is None:
            return min(20, remaining)
        if isinstance(value, tuple):
            return tuple(remaining if part is None else min(part, remaining) for part in value)
        if isinstance(value, (int, float)):
            return min(value, remaining)
        return value  # urllib3's Timeout: the source's own

    def sleep(self, seconds):
        self.check()
        with self.changed:
            self.changed.wait_for(lambda: self.code is not None, max(0, min(seconds, self.remaining())))
        self.check()

    def run(self, function, *args, **kwargs):
        """Calls a blocking function on its own thread and waits for it, or for a cancel or the deadline. A call
        given up on finishes by itself (its timeout bounds it) and its answer is dropped."""
        self.check()
        outcome = {}

        def call():
            try:
                outcome['value'] = function(*args, **kwargs)
            except BaseException as error:
                outcome['error'] = error
            with self.changed:
                outcome['done'] = True
                self.changed.notify_all()

        threading.Thread(target=call, daemon=True, name='Python source request').start()
        with self.changed:
            while 'done' not in outcome and self.code is None and self.remaining() > 0:
                self.changed.wait(self.remaining())
        if 'done' not in outcome:
            self.check()
        if 'error' in outcome:
            raise outcome['error']
        return outcome['value']


def cancel(ident):
    """Stops the request `ident` at its next wait, also when its cancel comes before it starts."""
    with _lock:
        scope = _active.get(ident)
        if scope is None and ident:
            now = time.monotonic()
            for key in [key for key, expiry in _early.items() if expiry < now]:
                del _early[key]
            _early[ident] = now + 60
            while len(_early) > 256:
                del _early[next(iter(_early))]
    if scope:
        scope.stop()


def sleep(seconds):
    """`time.sleep` for a source module: a request's wait ends when it is cancelled."""
    scope = current()
    if scope is None:
        return time.sleep(seconds)
    scope.sleep(seconds)


class _SourceTime(types.ModuleType):
    """The `time` module as a source module sees it: everything is time's, except `sleep`."""
    sleep = staticmethod(sleep)

    def __getattr__(self, name):
        return getattr(time, name)


_source_time = _SourceTime('time')


def bind(module):
    """Gives a source module the cancellable sleep: its `import time` and `from time import sleep`."""
    if getattr(module, 'time', None) is time:
        module.time = _source_time
    if getattr(module, 'sleep', None) is time.sleep:
        module.sleep = sleep
    return module
