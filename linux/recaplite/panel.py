"""Finestra del pannello (Chromium in modalità app) e parti Quickshell (menu, pillola ridotta)."""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .config import PORT, RUNTIME_DIR, Config

URL = f"http://127.0.0.1:{PORT}"
PANEL_PID = RUNTIME_DIR / "recap-lite-panel.pid"


def alive() -> int | None:
    try:
        pid = int(PANEL_PID.read_text())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def open_panel(cfg: Config) -> None:
    qs_call("mini", "hide", start=False)
    if alive():
        return
    profile = Path.home() / ".local/share/recap-lite/panel-profile"
    profile.mkdir(parents=True, exist_ok=True)
    command = [part.format(url=URL, profile=profile) for part in cfg.panel_command]
    if not shutil.which(command[0]):
        command = ["xdg-open", URL]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    PANEL_PID.write_text(str(process.pid))


def close_panel() -> bool:
    pid = alive()
    if not pid:
        return False
    try:
        os.killpg(pid, signal.SIGTERM)
    except OSError:
        os.kill(pid, signal.SIGTERM)
    PANEL_PID.unlink(missing_ok=True)
    return True


def minimize() -> None:
    """Chiude la finestra e mostra la pillola compatta sotto la barra."""
    close_panel()
    qs_call("mini", "show")


def hide() -> None:
    """Chiude la finestra: resta la voce nella barra (e Super+Alt+N) per riaprirla."""
    close_panel()
    qs_call("mini", "hide", start=False)


def qs_call(target: str, function: str, *args: str, start: bool = True) -> bool:
    """Chiama una funzione IPC della config Quickshell `recap`, avviandola se serve."""
    if not shutil.which("qs"):
        return False
    call = ["qs", "ipc", "-c", "recap", "call", target, function, *args]
    if subprocess.run(call, capture_output=True).returncode == 0:
        return True
    if not start:
        return False
    subprocess.Popen(["qs", "-c", "recap", "-d"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    for _ in range(20):
        time.sleep(0.25)
        if subprocess.run(call, capture_output=True).returncode == 0:
            return True
    return False
