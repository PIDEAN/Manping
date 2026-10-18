#!/usr/bin/env python3
"""Loopback-only streaming AI protocol fixture; no upstream or paid calls."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import time

folder = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def record(self, body):
        with (folder / "requests.jsonl").open("a", encoding="utf-8") as output:
            output.write(json.dumps({"path": self.path, "method": self.command,
                                     "headers": dict(self.headers), "body": body}, ensure_ascii=False) + "\n")

    def fixed(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.record(None)
        if self.path.startswith("/iam"):
            self.fixed(200, {"token": "fixture-bearer", "expireTime": "2099-01-01T00:00:00Z"})
        else:
            self.fixed(404, {"error": "fixture not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        self.record(body)
        if "/redirect/" in self.path:
            self.send_response(302)
            self.send_header("Location", "/redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if "/unauthorized/" in self.path:
            self.fixed(401, {"error": "fixture-key-must-never-be-echoed"})
            return
        if "/limited/" in self.path:
            self.fixed(429, {"error": "fixture limit"})
            return
        if self.path.endswith("/messages"):
            events = [{"type": "content_block_delta", "delta": {"type": "text_delta", "text": "你好"}},
                      {"type": "message_stop"}]
            streaming = body.get("stream", False)
            complete = {"content": [{"type": "text", "text": "你好"}], "stop_reason": "end_turn"}
        elif "GenerateContent" in self.path or ":generateContent" in self.path:
            events = [{"candidates": [{"content": {"parts": [{"text": "你好"}]}, "finishReason": "STOP"}]}]
            streaming = "streamGenerateContent" in self.path
            complete = events[0]
        elif self.path.endswith("/api/chat"):
            events = [{"message": {"role": "assistant", "content": "你好"}, "done": False},
                      {"message": {"content": ""}, "done": True, "done_reason": "stop"}]
            streaming = body.get("stream", True)
            complete = {"message": {"content": "你好"}, "done": True, "done_reason": "stop"}
        else:
            events = [{"choices": [{"delta": {"content": "你好"}, "finish_reason": None}]},
                      {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
            streaming = body.get("stream", False)
            complete = {"choices": [{"message": {"role": "assistant", "content": "你好"}, "finish_reason": "stop"}]}
        if not streaming:
            self.fixed(200, complete)
            return
        ndjson = self.path.endswith("/api/chat")
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson" if ndjson else "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for event in events:
                encoded = json.dumps(event, ensure_ascii=False).encode("utf-8")
                payload = encoded + b"\n" if ndjson else b"data: " + encoded + b"\r\n\r\n"
                # Two-byte HTTP chunks deliberately split UTF-8 and SSE CRLF.
                for index in range(0, len(payload), 2):
                    chunk = payload[index:index + 2]
                    self.wfile.write(('%x\r\n' % len(chunk)).encode() + chunk + b"\r\n")
                    self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
ready = folder / "port.ready"
ready.write_text(str(server.server_port), encoding="ascii")
ready.replace(folder / "port")
server.serve_forever()
