#!/usr/bin/env python3
"""Read-only mpv JSON IPC fixture. No network, media decoding, or account access."""
import json
import os
from pathlib import Path
import signal
import socket
import sys

executable = Path(sys.argv[0]).resolve()
journal = executable.with_suffix(".journal.jsonl")
stubborn = "stubborn" in executable.name
disconnected = "disconnected" in executable.name


def record(event):
    with journal.open("a", encoding="utf-8") as output:
        output.write(json.dumps(event, ensure_ascii=False) + "\n")


record({"event": "start", "pid": os.getpid(), "argv": sys.argv[1:]})
if stubborn or disconnected:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    def terminate(_signal, _frame):
        record({"event": "terminated"})
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)

path = next((arg.split("=", 1)[1] for arg in sys.argv[1:]
             if arg.startswith("--input-ipc-server=")), None)
if not path:
    raise SystemExit(2)

properties = {
    "time-pos": 0.0, "duration": 0.0, "pause": False, "idle-active": True,
    "eof-reached": False, "speed": 1.5, "volume": 42.0,
    "chapter-list": [{"title": "开始", "time": 0.0}, {"title": "第二章", "time": 25.0}],
}
observed = set()

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(1)
    with server.accept()[0] as connection:
        def send(event):
            data = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
            # Split a JSON message across writes to exercise framing, including UTF-8.
            midpoint = len(data) // 2
            connection.sendall(data[:midpoint])
            connection.sendall(data[midpoint:])

        def property_change(name):
            if name in observed:
                send({"event": "property-change", "name": name, "data": properties.get(name)})

        for line in connection.makefile("rb"):
            if len(line) > 1048576:
                raise SystemExit(3)
            message = json.loads(line)
            command = message.get("command", [])
            if not command:
                raise SystemExit(4)
            record({"event": "command", "command": command})
            name = command[0]
            if name == "observe_property":
                observed.add(command[2])
                property_change(command[2])
            elif name == "loadfile":
                properties.update({"time-pos": 3.25, "duration": 99.0, "idle-active": False,
                                   "eof-reached": False})
                send({"event": "file-loaded"})
                for key in properties:
                    property_change(key)
                if disconnected:
                    record({"event": "disconnected"})
                    connection.shutdown(socket.SHUT_RDWR)
                    connection.close()
                    # Stay alive with no IPC endpoint, and ignore SIGTERM. The
                    # production driver must retain this child and enforce SIGKILL.
                    while True:
                        signal.pause()
            elif name == "seek":
                properties["time-pos"] = float(command[1])
                property_change("time-pos")
            elif name == "set_property":
                key, value = command[1:3]
                if key == "pause":
                    properties[key] = value in (True, "yes", "true")
                elif key in ("volume", "speed"):
                    properties[key] = float(value)
                else:
                    properties[key] = value
                property_change(key)
            elif name == "get_property":
                send({"request_id": message.get("request_id"), "error": "success",
                      "data": properties.get(command[1])})
                continue
            elif name == "quit":
                record({"event": "quit", "stubborn": stubborn})
                if not stubborn:
                    send({"request_id": message.get("request_id"), "error": "success"})
                    raise SystemExit(0)
            send({"request_id": message.get("request_id"), "error": "success"})
