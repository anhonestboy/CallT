"""recap-lite — note in tempo reale delle tue call, su Linux.

  recap-lite start [--title "Nome"]   avvia una sessione e apre il pannello
  recap-lite stop                     ferma, scrive le note finali e stampa dove sono
  recap-lite toggle                   avvia o ferma (per una scorciatoia)
  recap-lite panel [--show|--hide|--mini]  pannello: mostra/nasconde o riduce a pillola
  recap-lite mark ["nota"]            segna il momento (⭐)
  recap-lite note "testo"             aggiunge una nota tua
  recap-lite ask "domanda"            chiede qualcosa sulla call (risposta nel pannello)
  recap-lite status [--waybar|--json] stato, anche per waybar o per il menu
  recap-lite menu                     apre il menu flottante (clic sulla voce in waybar)
  recap-lite recent [--json]          ultime call
  recap-lite check                    controlla che tutto il necessario ci sia

Collaudo senza call: recap-lite start --replay altri.wav [io.wav] [--speed 2]
(WAV 16 kHz mono).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from .config import CONFIG_FILE, PORT, STATE_FILE, Config

from .panel import URL, close_panel, minimize, open_panel, qs_call
from . import panel as panel_mod
LOG_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "recap-lite"


# ── comunicazione col demone ────────────────────────────────

def _request(path: str, body: dict | None = None, timeout: float = 3):
    data = json.dumps(body or {}).encode() if body is not None else None
    request = urllib.request.Request(URL + path, data=data,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def _state() -> dict | None:
    try:
        return _request("/api/state?since=999999999")
    except (urllib.error.URLError, OSError, ValueError):
        return None


def _post(action: str, **body) -> dict | None:
    try:
        return _request(f"/api/{action}", body)
    except (urllib.error.URLError, OSError, ValueError):
        return None


# ── comandi ─────────────────────────────────────────────────

def cmd_start(args, cfg: Config) -> int:
    state = _state()
    if state and state["phase"] in ("starting", "live", "finishing"):
        if not args.no_panel:
            open_panel(cfg)
        print(f"Sessione già attiva: {state['name']}")
        return 0
    if state:  # sessione precedente conclusa: chiude il vecchio demone
        _post("quit")
        time.sleep(0.5)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    serve_args = [sys.executable, "-m", "recaplite", "serve"]
    if args.title:
        serve_args += ["--title", args.title]
    if args.replay:
        serve_args += ["--replay", *args.replay, "--speed", str(args.speed)]
    log = open(LOG_DIR / "recap-lite.log", "ab")
    subprocess.Popen(serve_args, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                     start_new_session=True, cwd=str(Path(__file__).resolve().parent.parent))
    for _ in range(100):
        time.sleep(0.2)
        state = _state()
        if state:
            break
    else:
        print(f"Il demone non risponde: vedi {LOG_DIR / 'recap-lite.log'}", file=sys.stderr)
        return 1
    print(f"🔴 {state['name']} — note: {state['engine']}, trascrizione: whisper {state['model']}")
    if not args.no_panel:
        open_panel(cfg)
    return 0


def cmd_stop(args, cfg: Config) -> int:
    state = _state()
    if not state:
        print("Nessuna sessione attiva.")
        return 1
    if state["phase"] == "live":
        _post("stop")
    last = ""
    while True:
        state = _state()
        if not state:
            print("Il demone si è chiuso.", file=sys.stderr)
            return 1
        if state["phase"] in ("done", "failed"):
            break
        if state["phaseMessage"] != last:
            last = state["phaseMessage"]
            print(last)
        time.sleep(0.5)
    print(f"✅ {state['folder']}")
    return 0


def cmd_toggle(args, cfg: Config) -> int:
    state = _state()
    if state and state["phase"] == "live":
        # Non blocca la scorciatoia: il demone finisce da solo e notifica.
        _post("stop")
        return 0
    args.title, args.replay, args.speed, args.no_panel = None, None, 1.0, False
    return cmd_start(args, cfg)


def cmd_panel(args, cfg: Config) -> int:
    if args.hide:
        panel_mod.hide()
        return 0
    if args.mini:
        minimize()
        return 0
    if not args.show and close_panel():
        return 0
    if not _state():
        print("Nessuna sessione attiva: recap-lite start")
        return 1
    open_panel(cfg)
    return 0


ICON = "\U000F147D"  # onda (Nerd Font, md-waveform)


def cmd_status(args, cfg: Config) -> int:
    state = _state()
    if args.json:
        out = {k: v for k, v in (state or {"phase": "idle"}).items() if k not in ("lines", "notes", "chat")}
        out["outputDir"] = str(Path(cfg.output_dir).expanduser())
        out["configFile"] = str(CONFIG_FILE)
        out.setdefault("model", cfg.whisper_model)
        print(json.dumps(out, ensure_ascii=False))
        return 0
    if args.waybar:
        # Sempre visibile, come l'icona di Recap nella barra dei menu del Mac.
        if not state or state["phase"] == "done":
            print(json.dumps({"text": ICON, "class": "idle", "tooltip": "Recap — clic per il menu"},
                             ensure_ascii=False))
        else:
            minutes, seconds = divmod(int(state["elapsed"]), 60)
            text = {"live": f"{ICON} ● {minutes:02d}:{seconds:02d}", "finishing": f"{ICON} note…",
                    "starting": f"{ICON} …", "failed": f"{ICON} ⚠"}.get(state["phase"], ICON)
            tooltip = f"Recap — {state['name']}\n{state['lineCount']} frasi · {state['engine']}"
            print(json.dumps({"text": text, "class": state["phase"], "tooltip": tooltip}, ensure_ascii=False))
        return 0
    if not state:
        print("Nessuna sessione attiva.")
        return 1
    print(f"{state['name']}: {state['phase']} {state['phaseMessage']}".strip())
    print(f"  {int(state['elapsed'])} s · {state['lineCount']} frasi · ritardo trascrizione "
          f"{state['backlog']} s · note: {state['engine']}")
    if state.get("error"):
        print(f"  ⚠ {state['error']}")
    return 0


def cmd_stop_async(args, cfg: Config) -> int:
    """Ferma senza aspettare: il demone finisce da solo e manda una notifica."""
    return 0 if _post("stop") is not None else 1


def cmd_recent(args, cfg: Config) -> int:
    """Le ultime call (cartelle con le note), dalla più recente."""
    root = Path(cfg.output_dir).expanduser()
    items = []
    if root.is_dir():
        for folder in root.iterdir():
            if not folder.is_dir():
                continue
            notes = next(iter(sorted(folder.glob("*_notes.md"))), None)
            if not notes:
                continue
            items.append({"name": folder.name, "folder": str(folder), "notes": str(notes),
                          "mtime": notes.stat().st_mtime})
    items.sort(key=lambda item: item["mtime"], reverse=True)
    items = items[:args.limit]
    if args.json:
        print(json.dumps(items, ensure_ascii=False))
    else:
        for item in items:
            print(f"{time.strftime('%d/%m %H:%M', time.localtime(item['mtime']))}  {item['name']}")
    return 0


def cmd_menu(args, cfg: Config) -> int:
    """Apre/chiude il menu Quickshell sotto il puntatore (per il clic sulla voce in waybar)."""
    x, y = "-1", "-1"
    try:
        pos = subprocess.run(["hyprctl", "cursorpos"], capture_output=True, text=True, timeout=2).stdout
        x, y = [part.strip() for part in pos.split(",")[:2]]
        int(x), int(y)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        x, y = "-1", "-1"
    if qs_call("menu", "toggleAt", x, y):
        return 0
    print("Quickshell non risponde: prova `qs -c recap` per vedere l'errore.", file=sys.stderr)
    return 1


def cmd_simple(action: str):
    def run(args, cfg: Config) -> int:
        text = " ".join(args.text) if getattr(args, "text", None) else ""
        key = {"mark": "note", "note": "text", "ask": "text"}[action]
        if _post(action, **{key: text}) is None:
            print("Nessuna sessione attiva.")
            return 1
        return 0
    return run


def cmd_check(args, cfg: Config) -> int:
    from .llm import Engine

    ok = True

    def line(good: bool, label: str, detail: str = "") -> None:
        nonlocal ok
        ok &= good
        print(f"{'✓' if good else '✗'} {label}{(' — ' + detail) if detail else ''}")

    for name, command in (("microfono", cfg.mic_command), ("audio di sistema", cfg.system_command)):
        line(bool(shutil.which(command[0])), f"cattura {name}", " ".join(command[:2]))
    try:
        import pywhispercpp  # noqa: F401
        line(True, "whisper.cpp (pywhispercpp)", f"modello {cfg.whisper_model}")
    except ImportError:
        line(False, "whisper.cpp (pywhispercpp)", "sudo dnf install python3-pywhispercpp")
    engine = Engine(cfg)
    line(engine.available or cfg.engine == "off", "note AI", engine.label)
    line(bool(shutil.which(cfg.panel_command[0])), "pannello", cfg.panel_command[0])
    line(bool(shutil.which("ffmpeg")), "ffmpeg (facoltativo)", "audio salvato come .m4a invece che WAV")
    print(f"Output: {Path(cfg.output_dir).expanduser()}")
    return 0 if ok else 1


def cmd_serve(args, cfg: Config) -> int:
    from .server import serve
    from .session import Session

    replay = None
    if args.replay:
        files = [Path(p).expanduser() for p in args.replay]
        replay = (files[0], files[1] if len(files) > 1 else None)
    session = Session(cfg, title=args.title, replay=replay, speed=args.speed)
    quit_event = threading.Event()
    server = serve(session, PORT, quit_event.set)
    STATE_FILE.write_text(json.dumps({"pid": os.getpid(), "port": PORT}))
    signal.signal(signal.SIGTERM, lambda *_: (session.stop(), quit_event.set()))
    try:
        session.start()
    except Exception as error:  # noqa: BLE001
        session.phase, session.error = "failed", str(error)
        session._bump()
    # A sessione conclusa resta in ascolto ancora mezz'ora per il pannello.
    failed_at = None
    while not quit_event.wait(timeout=1):
        if session.phase == "failed":
            failed_at = failed_at or time.time()
        ended = session.finished_at or failed_at
        if ended and time.time() - ended > 1800:
            break
    if session.phase == "live":
        session.stop()
        while session.phase == "finishing":
            time.sleep(0.5)
    server.shutdown()
    STATE_FILE.unlink(missing_ok=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="recap-lite", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    for name in ("start", "serve"):
        p = sub.add_parser(name)
        p.add_argument("--title")
        p.add_argument("--replay", nargs="+", metavar="WAV")
        p.add_argument("--speed", type=float, default=1.0)
        if name == "start":
            p.add_argument("--no-panel", action="store_true")
    sub.add_parser("stop")
    sub.add_parser("toggle")
    panel_parser = sub.add_parser("panel")
    group = panel_parser.add_mutually_exclusive_group()
    group.add_argument("--show", action="store_true", help="apre (o porta in primo piano)")
    group.add_argument("--hide", action="store_true", help="nasconde; si riapre dalla barra o con Super+Alt+N")
    group.add_argument("--mini", action="store_true", help="riduce alla pillola sotto la barra")
    status = sub.add_parser("status")
    status.add_argument("--waybar", action="store_true")
    status.add_argument("--json", action="store_true")
    recent = sub.add_parser("recent")
    recent.add_argument("--json", action="store_true")
    recent.add_argument("--limit", type=int, default=5)
    sub.add_parser("stop-async")
    sub.add_parser("menu")
    sub.add_parser("check")
    for name in ("mark", "note", "ask"):
        p = sub.add_parser(name)
        p.add_argument("text", nargs="*")

    args = parser.parse_args(argv)
    cfg = Config.load()
    cfg.save_default()
    handlers = {
        "start": cmd_start, "serve": cmd_serve, "stop": cmd_stop, "toggle": cmd_toggle,
        "panel": cmd_panel, "status": cmd_status, "check": cmd_check, "recent": cmd_recent,
        "stop-async": cmd_stop_async, "menu": cmd_menu,
        "mark": cmd_simple("mark"), "note": cmd_simple("note"), "ask": cmd_simple("ask"),
    }
    return handlers[args.command](args, cfg)
