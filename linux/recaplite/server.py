"""Server HTTP locale (solo 127.0.0.1): il pannello web e i comandi della CLI."""
from __future__ import annotations

import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .session import Session

WEB = Path(__file__).parent / "web"


def serve(session: Session, port: int, on_quit) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        server_version = "RecapLite"

        def log_message(self, *args):  # silenzioso
            pass

        def _json(self, payload, status: int = 200) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if not length:
                return {}
            try:
                return json.loads(self.rfile.read(length))
            except json.JSONDecodeError:
                return {}

        def do_GET(self) -> None:
            url = urlparse(self.path)
            query = parse_qs(url.query)
            since = int((query.get("since") or ["0"])[0])
            if url.path in ("/", "/index.html"):
                data = (WEB / "index.html").read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif url.path == "/api/state":
                self._json(session.snapshot(since))
            elif url.path == "/events":
                self._events(since)
            else:
                self._json({"error": "not found"}, 404)

        def _events(self, since: int) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            seen = -1
            lines = since
            try:
                while True:
                    with session.changed:
                        if session.version == seen:
                            session.changed.wait(timeout=15)
                    if session.version == seen:
                        self.wfile.write(b": keepalive\n\n")
                    else:
                        # Rimanda le ultime righe: possono essere state unite o corrette.
                        snap = session.snapshot(max(0, lines - 3))
                        seen = snap["version"]
                        lines = snap["lineCount"]
                        self.wfile.write(b"data: " + json.dumps(snap, ensure_ascii=False).encode() + b"\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return

        def do_POST(self) -> None:
            url = urlparse(self.path)
            body = self._body()
            action = url.path.removeprefix("/api/")
            if action == "stop":
                session.stop()
            elif action == "mark":
                session.mark(body.get("note", ""))
            elif action == "note":
                session.add_note(body.get("text", ""))
            elif action == "ask":
                session.ask(body.get("text", ""))
            elif action == "refresh":
                session.refresh_notes()
            elif action == "open":
                target = session.notes_path if body.get("what") == "notes" else session.folder
                if target.exists():
                    subprocess.Popen(["xdg-open", str(target)], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
            elif action == "quit":
                threading.Thread(target=on_quit, daemon=True).start()
            else:
                self._json({"error": "unknown action"}, 404)
                return
            self._json({"ok": True, "phase": session.phase})

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, name="http", daemon=True).start()
    return server
