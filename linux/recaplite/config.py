"""Configurazione di Recap Lite: ~/.config/recap-lite/config.json (tutto facoltativo)."""
from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "recap-lite"
CONFIG_FILE = CONFIG_DIR / "config.json"
RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
STATE_FILE = RUNTIME_DIR / "recap-lite.json"
PORT = int(os.environ.get("RECAP_LITE_PORT", "47321"))


@dataclass
class Config:
    # Lingua della call (whisper). "auto" per il riconoscimento automatico.
    language: str = "it"
    # Modello whisper.cpp: tiny, base, small, medium, large-v3-turbo… (scaricato al primo uso).
    whisper_model: str = "small"
    whisper_models_dir: str | None = None
    whisper_threads: int = 0  # 0 = tutti i core
    # Dove finiscono le cartelle delle call (stesso formato di Recap per Mac).
    output_dir: str = str(Path.home() / "Recap")
    # Motore delle note: "claude-cli" (account di Claude Code), "api" (ANTHROPIC_API_KEY), "off".
    engine: str = "claude-cli"
    claude_path: str = ""
    live_model: str = "sonnet"     # haiku | sonnet | opus
    final_model: str = "opus"
    notes_interval: int = 45       # secondi tra un aggiornamento e l'altro
    # Tieni anche l'audio completo (due tracce: tu e gli altri) nella cartella della call.
    keep_audio: bool = True
    # Comandi di cattura: PCM s16le 16 kHz mono su stdout. Modificabili se il sistema è diverso.
    mic_command: list[str] = field(default_factory=lambda: [
        "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", "--raw", "-"])
    system_command: list[str] = field(default_factory=lambda: [
        "pw-record", "-P", "{ stream.capture.sink = true }",
        "--rate", "16000", "--channels", "1", "--format", "s16", "--raw", "-"])
    # Vista all'avvio della call: "mini" (pillola sotto la barra; il pannello grande si apre da lì)
    # oppure "panel" (subito il pannello grande).
    start_view: str = "mini"
    # Pannello: browser in modalità app.
    panel_command: list[str] = field(default_factory=lambda: [
        "chromium-browser", "--app={url}", "--user-data-dir={profile}",
        "--ozone-platform=wayland", "--no-first-run", "--no-default-browser-check",
        "--window-size=480,760"])

    @classmethod
    def load(cls) -> "Config":
        cfg = cls()
        if CONFIG_FILE.exists():
            try:
                data = json.loads(CONFIG_FILE.read_text())
                for key, value in data.items():
                    if hasattr(cfg, key):
                        setattr(cfg, key, value)
            except (OSError, json.JSONDecodeError) as error:
                print(f"recap-lite: config ignorata ({error})", file=sys.stderr)
        return cfg

    def save_default(self) -> None:
        if not CONFIG_FILE.exists():
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            CONFIG_FILE.write_text(json.dumps(asdict(self), indent=2, ensure_ascii=False) + "\n")
