"""Bounded, deduplicated access to the converter subprocess.

Three endpoints start a HyperDR process: ``/api/run`` through ``job.py``,
``/api/curve`` and ``/api/preview``. Only the first had any admission control.
The other two looked bounded because both keep a cache, but a cache bounds
*finished* work and says nothing about work in flight: N concurrent misses on
the same key were N separate processes, each doing the same thing. For preview
that meant N whole-file reads of a RAW, N embedded-JPEG scans, N temporary
files and N runs of a CLI with a 180-second timeout, all producing one answer.

Two mechanisms, deliberately separate because they solve different halves:

``Budget`` caps how many of these processes may run at once and refuses
immediately when full, so the panel answers "busy" instead of accepting
unbounded work.

``SingleFlight`` collapses concurrent callers asking for the *same* thing onto
one execution. Several browser tabs moving the same slider is the common case,
and it should cost one process, not one per tab.

Layer them by wrapping the budget inside the single-flight factory: only the
caller that actually runs the work needs a slot.
"""
from __future__ import annotations

import contextlib
import threading


class Busy(RuntimeError):
    """The request cannot be admitted right now.

    Carries the HTTP status the endpoint should report, so the distinction
    between "the queue is full" (503) and "you are asking too often" (429)
    survives the trip out of the worker.
    """

    def __init__(self, message: str, status: int = 503) -> None:
        super().__init__(message)
        self.status = status


class Budget:
    """At most `limit` concurrent holders, with no unbounded queue behind it."""

    def __init__(self, limit: int, message: str = "服务器繁忙，请稍后再试。") -> None:
        self._semaphore = threading.BoundedSemaphore(max(1, int(limit)))
        self._message = message
        self.limit = max(1, int(limit))

    @contextlib.contextmanager
    def hold(self, timeout: float = 0.0):
        """Acquire a slot or raise `Busy`.

        A zero timeout refuses immediately. A short positive one absorbs the
        burst of a page load without letting callers pile up: waiting longer
        than the work takes only moves the queue from the semaphore into the
        server's thread pool, which is the thing being protected.
        """
        if timeout > 0:
            acquired = self._semaphore.acquire(blocking=True, timeout=timeout)
        else:
            acquired = self._semaphore.acquire(blocking=False)
        if not acquired:
            raise Busy(self._message, status=503)
        try:
            yield
        finally:
            self._semaphore.release()


class _Call:
    __slots__ = ("done", "value", "error")

    def __init__(self) -> None:
        self.done = threading.Event()
        self.value = None
        self.error: BaseException | None = None


class SingleFlight:
    """One execution per key, shared by everyone who asks for it concurrently."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._calls: dict[object, _Call] = {}

    def run(self, key, factory, timeout: float = 300.0):
        """Run `factory()` for `key`, or wait for the call already running it.

        The leader's result -- value or exception -- is delivered to every
        follower, so a failure is reported once and identically rather than
        being retried by each waiter in turn.
        """
        with self._lock:
            call = self._calls.get(key)
            leader = call is None
            if leader:
                call = _Call()
                self._calls[key] = call

        if not leader:
            # Bounded: a leader that hangs must not hold its followers'
            # request threads for longer than the work itself could take.
            if not call.done.wait(timeout):
                raise Busy("相同请求仍在处理中，请稍后再试。", status=503)
            if call.error is not None:
                raise call.error
            return call.value

        try:
            call.value = factory()
        except BaseException as exc:  # noqa: BLE001 - re-raised below
            call.error = exc
            raise
        finally:
            with self._lock:
                self._calls.pop(key, None)
            call.done.set()
        return call.value

    def in_flight(self) -> int:
        with self._lock:
            return len(self._calls)
