"""One native preview worker; its decoded sources survive slider requests."""
from __future__ import annotations
import atexit
import json
import queue
import subprocess
import threading
import time
from pathlib import Path


class PreviewWorker:
    def __init__(self):
        self.lock = threading.Lock()
        self.process = None
        self.identity = None
        self.idle_timer = None
        self.last_used = 0.0

    def close(self):
        if self.idle_timer:
            self.idle_timer.cancel()
        process, self.process = self.process, None
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            for pipe in (process.stdin, process.stdout):
                pipe.close()

    def retire(self):
        with self.lock:
            if time.monotonic() - self.last_used >= 90:
                self.close()

    def request(self, argv, call, timeout):
        deadline = time.monotonic() + timeout
        while not self.lock.acquire(timeout=0.025):
            if call.cancel.is_set():
                raise ValueError("preview superseded")
            if time.monotonic() >= deadline:
                raise ValueError("native preview timed out")
        try:
            if self.idle_timer:
                self.idle_timer.cancel()
            if call.cancel.is_set():
                raise ValueError("preview superseded")
            executable = Path(argv[0])
            stat = executable.stat()
            identity = (str(executable), stat.st_mtime_ns, stat.st_size)
            if self.identity != identity or self.process is None or self.process.poll() is not None:
                self.close()
                self.process = subprocess.Popen([argv[0], "preview-worker"], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                self.identity = identity
                fresh = True
            else:
                fresh = False
            process = self.process
            call.process = process
            result = queue.Queue(maxsize=1)

            def exchange():
                try:
                    if fresh:
                        hello = json.loads(process.stdout.readline())
                        if hello.get("schema") != "hyperdr.preview-worker/v1":
                            raise ValueError("unsupported native preview worker")
                    process.stdin.write((json.dumps(argv[2:]) + "\n").encode("utf-8"))
                    process.stdin.flush()
                    header = json.loads(process.stdout.readline())
                    if header.get("error"):
                        raise ValueError(header["error"])
                    size = header["size"]
                    if not isinstance(size, int) or not 0 < size <= 512 * 1024 * 1024:
                        raise ValueError("invalid native preview size")
                    data = process.stdout.read(size)
                    if len(data) != size:
                        raise ValueError("native preview worker closed its output")
                    result.put(data)
                except Exception as error:
                    result.put(error)

            reader = threading.Thread(target=exchange, daemon=True)
            reader.start()
            while True:
                if call.cancel.is_set() or time.monotonic() >= deadline:
                    self.close()
                    reader.join(timeout=2)
                    raise ValueError("preview superseded" if call.cancel.is_set() else "native preview timed out")
                try:
                    value = result.get(timeout=0.025)
                    break
                except queue.Empty:
                    continue
            if isinstance(value, Exception):
                self.close()
                raise ValueError(str(value)) from value
            return value
        finally:
            call.process = None
            self.last_used = time.monotonic()
            if self.process is not None:
                self.idle_timer = threading.Timer(90, self.retire)
                self.idle_timer.daemon = True
                self.idle_timer.start()
            self.lock.release()


WORKER = PreviewWorker()
atexit.register(WORKER.close)
