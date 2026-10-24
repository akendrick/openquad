"""Background work for the app, on Python's own thread pool (not Qt's).

PySide's QThreadPool wraps Python functions in C++ tasks and releases them on the
worker thread, which made Python schedule deferred cleanups that could crash later.
Here the work is plain Python in plain threads; only results cross back to the
windows, as Qt signals (queued to the main thread).
"""

from __future__ import annotations

import concurrent.futures
import threading
from collections.abc import Callable

_executor = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="openquad")
_pending: set[concurrent.futures.Future[None]] = set()
_lock = threading.Lock()


def submit(job: Callable[[], None]) -> None:
    """Run `job` on a background thread."""
    future = _executor.submit(job)
    with _lock:
        _pending.add(future)

    def forget(done: concurrent.futures.Future[None]) -> None:
        with _lock:
            _pending.discard(done)

    future.add_done_callback(forget)


def wait(timeout: float = 60.0) -> None:
    """Block until all background work has finished (tests use this before teardown)."""
    with _lock:
        running = list(_pending)
    concurrent.futures.wait(running, timeout=timeout)
