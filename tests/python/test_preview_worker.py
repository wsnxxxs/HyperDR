"""Exercise pipe reuse and interrupted-worker recovery with a real child process."""
import json
import subprocess
import sys
import threading
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps/panel"))
from hyperdr_panel.preview_worker import PreviewWorker

SCRIPT = r'''
import json, sys, time
print(json.dumps({"schema":"hyperdr.preview-worker/v1"}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if "hang" in request: time.sleep(30)
    data = json.dumps(request).encode()
    sys.stdout.buffer.write((json.dumps({"size":len(data)}) + "\n").encode() + data)
    sys.stdout.buffer.flush()
'''


def test_worker_reuses_process_and_recovers_after_cancellation():
    worker = PreviewWorker()
    launch = subprocess.Popen
    calls = []

    def spawn(*args, **kwargs):
        process = launch([sys.executable, "-u", "-c", SCRIPT], **kwargs)
        calls.append(process)
        return process

    def request(value, call=None):
        call = call or SimpleNamespace(cancel=threading.Event(), process=None)
        return worker.request([sys.executable, "preview-frame", value], call, 5)

    try:
        with mock.patch("hyperdr_panel.preview_worker.subprocess.Popen", side_effect=spawn):
            assert json.loads(request("first")) == ["first"]
            assert json.loads(request("second")) == ["second"]
            assert len(calls) == 1
            call = SimpleNamespace(cancel=threading.Event(), process=None)
            timer = threading.Timer(.1, call.cancel.set)
            timer.start()
            try:
                request("hang", call)
                raise AssertionError("cancelled request returned a frame")
            except ValueError as error:
                assert "superseded" in str(error)
            finally:
                timer.cancel()
            assert calls[0].poll() is not None
            assert json.loads(request("recovered")) == ["recovered"]
            assert len(calls) == 2
    finally:
        worker.close()
