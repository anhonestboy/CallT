"""Finestra del pannello (Chromium in modalità app) e parti Quickshell (menu, pillola ridotta).

Su Hyprland la finestra si trova con `hyprctl clients -j` (classe o PID), così si può
renderla flottante e chiuderla anche se la regola della config non l'ha presa o se Chromium
ha passato la finestra a un processo già aperto.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .config import PORT, RUNTIME_DIR, Config

URL = f"http://127.0.0.1:{PORT}"
PANEL_PID = RUNTIME_DIR / "recap-lite-panel.pid"
APP_CLASS = "recap-lite"
WIDTH, HEIGHT, MARGIN, TOP = 480, 760, 12, 48


def alive() -> int | None:
    try:
        pid = int(PANEL_PID.read_text())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


# ── Hyprland ─────────────────────────────────────────────────

def _hyprctl(*args: str) -> str | None:
    if not shutil.which("hyprctl") or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return None
    try:
        result = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def _dispatch(lua: str) -> None:
    _hyprctl("dispatch", lua)


def windows(pid: int | None = None) -> list[dict]:
    """Le finestre del pannello aperte (vuoto se non siamo su Hyprland)."""
    try:
        clients = json.loads(_hyprctl("clients", "-j") or "[]")
    except json.JSONDecodeError:
        return []
    found = []
    for client in clients:
        classes = (client.get("class", ""), client.get("initialClass", ""))
        # Mai solo per titolo: una scheda "Recap Lite" del browser normale non va toccata.
        if (APP_CLASS in classes
                or any(c.startswith("chrome-127.0.0.1__") for c in classes)
                or (pid and client.get("pid") == pid)):
            found.append(client)
    return found


def _place(client: dict) -> None:
    """Flottante, 480×760, in alto a destra sotto la barra, su tutti i workspace."""
    window = f'"address:{client["address"]}"'
    if not client.get("floating"):
        _dispatch(f'hl.dsp.window.float({{ action = "enable", window = {window} }})')
    _dispatch(f"hl.dsp.window.resize({{ x = {WIDTH}, y = {HEIGHT}, window = {window} }})")
    try:
        monitors = json.loads(_hyprctl("monitors", "-j") or "[]")
        mon = next(m for m in monitors if m.get("id") == client.get("monitor"))
        scale = mon.get("scale") or 1
        x = int(mon["x"] + mon["width"] / scale - WIDTH - MARGIN)
        y = int(mon["y"] + TOP)
        _dispatch(f"hl.dsp.focus({{ window = {window} }})")
        _dispatch(f"hl.dsp.window.move({{ x = {x}, y = {y} }})")
    except (json.JSONDecodeError, StopIteration, KeyError, TypeError):
        _dispatch(f"hl.dsp.window.center({{ window = {window} }})")
    if not client.get("pinned"):
        _dispatch(f"hl.dsp.window.pin({{ window = {window} }})")


# ── pannello ─────────────────────────────────────────────────

def open_panel(cfg: Config) -> None:
    qs_call("mini", "close", start=False)
    on_hyprland = _hyprctl("version") is not None
    existing = windows(alive())
    if existing:
        _dispatch(f'hl.dsp.focus({{ window = "address:{existing[0]["address"]}" }})')
        return
    if alive() and not on_hyprland:
        return  # fuori da Hyprland ci si fida del PID
    profile = Path.home() / ".local/share/recap-lite/panel-profile"
    profile.mkdir(parents=True, exist_ok=True)
    command = [part.format(url=URL, profile=profile) for part in cfg.panel_command]
    if not shutil.which(command[0]):
        command = ["xdg-open", URL]
    elif "chrom" in Path(command[0]).name and not any(p.startswith("--class") for p in command):
        command.append(f"--class={APP_CLASS}")
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    PANEL_PID.write_text(str(process.pid))
    if not on_hyprland:
        return
    # La regola di recap.lua di solito basta; se non ha preso, la finestra si sistema qui.
    for _ in range(40):
        time.sleep(0.25)
        found = windows(process.pid)
        if found:
            client = found[0]
            if not (client.get("floating") and client.get("pinned")):
                _place(client)
            return


def open_default(cfg: Config) -> None:
    """Vista all'avvio: la pillola (default) o il pannello grande. Senza Quickshell, il pannello."""
    if cfg.start_view != "panel" and qs_call("mini", "open")[0]:
        return
    open_panel(cfg)


def close_panel() -> bool:
    closed = False
    for client in windows(alive()):
        pid = client.get("pid")
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
                closed = True
            except OSError:
                pass
    pid = alive()
    if pid:
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        closed = True
    PANEL_PID.unlink(missing_ok=True)
    return closed


def minimize() -> tuple[bool, str]:
    """Mostra la pillola compatta sotto la barra e chiude la finestra.
    Se la pillola non compare (Quickshell assente o in errore) la finestra resta aperta:
    non si resta mai senza un modo per tornare al pannello. Ritorna (riuscito, errore)."""
    ok, error = qs_call("mini", "open")
    if not ok:
        return False, error
    close_panel()
    return True, ""


def hide() -> None:
    """Chiude la finestra: resta la voce nella barra (e Super+Alt+N) per riaprirla."""
    close_panel()
    qs_call("mini", "close", start=False)


def qs_call(target: str, function: str, *args: str, start: bool = True) -> tuple[bool, str]:
    """Chiama una funzione IPC della config Quickshell `recap`, avviandola se serve.
    Ritorna (riuscito, messaggio d'errore)."""
    if not shutil.which("qs"):
        return False, "comando qs (Quickshell) non trovato"
    call = ["qs", "ipc", "-c", "recap", "call", target, function, *args]

    def attempt() -> tuple[bool, str]:
        try:
            result = subprocess.run(call, capture_output=True, text=True, timeout=5)
        except subprocess.TimeoutExpired:
            return False, "qs ipc non risponde"
        output = (result.stderr or result.stdout).strip()
        lines = output.splitlines()
        # Se qs non riconosce la chiamata stampa l'elenco delle funzioni ed esce con 0.
        if result.returncode == 0 and "function " in output:
            return False, f"qs ipc non ha eseguito {target}.{function}"
        return result.returncode == 0, (lines[-1] if lines else f"qs ipc: codice {result.returncode}")

    ok, error = attempt()
    if ok or not start:
        return ok, error
    subprocess.Popen(["qs", "-c", "recap", "-d"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    for _ in range(20):
        time.sleep(0.25)
        ok, error = attempt()
        if ok:
            return True, ""
    return False, error
