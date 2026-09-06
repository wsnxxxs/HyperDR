"""One desktop-owned photo shared with the connected phone viewers.

The phone receives the desktop's completed native frame, so it never launches
a competing RAW render. A new phone upload is handed to the editor atomically.
"""
from __future__ import annotations

import json
import socket
import threading
import time

from . import session, renditions, job


class Workbench:
    def __init__(self):
        self.changed = threading.Condition(threading.RLock())
        self.enabled = False
        self.owner = ""
        self.revision = 0
        self.current = {}
        self.upload = None
        self.pending = ""
        self.frame = None
        self.incoming_frame = None
        self.original_frame = None
        self.frame_version = 0
        self.phone_seen = 0.0
        self.desktop_seen = 0.0
        self.completed = []

    def notify(self):
        self.revision += 1
        self.changed.notify_all()

    def snapshot(self):
        with self.changed:
            return {
                "enabled": self.enabled, "revision": self.revision,
                "computer": socket.gethostname(),
                "phoneConnected": time.monotonic() - self.phone_seen < 25,
                "desktopConnected": time.monotonic() - self.desktop_seen < 15,
                "current": dict(self.current), "upload": self.upload,
                "pending": self.pending, "frameVersion": self.frame_version,
                "frameReady": self.frame is not None and self.frame[:2] == self.frame_key(),
                "completed": list(self.completed),
            }

    def frame_key(self):
        return (self.current.get("sessionId"),
                json.dumps(self.current.get("options", {}), sort_keys=True))

    def publish_frame(self, session_id, options, data):
        with self.changed:
            original_key = (session_id, options.get("highlightRecovery", "blend"))
            if self.original_frame is None or self.original_frame[:2] != original_key:
                self.original_frame = (*original_key, data)
            key = (session_id, json.dumps(options, sort_keys=True))
            if self.enabled:
                if key != self.frame_key():
                    # A cached render can finish before its editor-state POST.
                    self.incoming_frame = (*key, data)
                    return
                self.frame = (*key, data)
                self.frame_version += 1
                self.notify()

    def publish(self, body):
        with self.changed:
            if not self.enabled or body.get("owner") != self.owner:
                raise ValueError("此工作台已由另一个桌面窗口接管，请重新连接手机。")
            self.desktop_seen = time.monotonic()
            current = body.get("current") or {}
            sid = current.get("sessionId")
            if self.pending and sid != self.pending:
                return self.snapshot()
            if self.upload and sid != self.current.get("sessionId"):
                raise ValueError("手机正在上传照片，请等待上传完成。")
            if sid:
                if not isinstance(current.get("options", {}), dict):
                    raise ValueError("调整参数无效。")
                source = session.input_path(sid)
                current = {"sessionId": sid,
                           "file": {"name": source.name, "size": source.stat().st_size},
                           "options": current.get("options", {}),
                           "busy": bool(current.get("busy")),
                           "status": str(current.get("status", ""))[:200]}
                for entry in reversed(renditions.list_for(sid)):
                    identity = (sid, entry["id"])
                    if not any((e["sessionId"], e["id"]) == identity for e in self.completed):
                        self.completed.insert(0, {"sessionId": sid, **{
                            k: entry[k] for k in ("id", "name", "bytes", "createdAt")}})
                self.completed = self.completed[:30]
            else:
                current = {}
            if self.pending == sid:
                self.pending = ""
            if current != self.current:
                self.current = current
                if self.incoming_frame and self.incoming_frame[:2] == self.frame_key():
                    self.frame = self.incoming_frame
                    self.incoming_frame = None
                    self.frame_version += 1
                self.notify()
            return self.snapshot()

    def begin_upload(self, name):
        with self.changed:
            if not self.enabled or time.monotonic() - self.desktop_seen >= 15:
                raise ValueError("电脑编辑器尚未连接，请在电脑上打开手机连接工作台。")
            if self.upload or self.pending or self.current.get("busy") or job.active_session_id():
                raise ValueError("正在处理照片，请完成后再换一张。")
            sid = session.create_session()
            self.upload = {"sessionId": sid, "name": str(name)[:255], "progress": 0}
            self.notify()
            return {"sessionId": sid}

    def update_upload(self, body):
        with self.changed:
            if not self.upload or self.upload["sessionId"] != body.get("sessionId"):
                raise ValueError("上传已结束，请重新选择照片。")
            if body.get("cancel"):
                self.upload = None
            elif body.get("complete"):
                sid = self.upload["sessionId"]
                source = session.input_path(sid)
                self.current = {"sessionId": sid,
                                "file": {"name": source.name, "size": source.stat().st_size},
                                "options": {}, "busy": False, "status": "waiting"}
                self.frame = None
                self.pending = sid
                self.upload = None
            else:
                self.upload = {**self.upload, "progress": max(0, min(1, float(body.get("progress", 0))))}
            self.notify()
            return self.snapshot()

    def disable(self):
        with self.changed:
            self.enabled = False
            self.owner = ""
            self.upload = None
            self.pending = ""
            self.frame = None
            self.incoming_frame = None
            self.phone_seen = 0
            self.notify()
