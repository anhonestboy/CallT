"""Trascrizione delle frasi con whisper.cpp (pywhispercpp), su un thread dedicato.

Un solo modello per entrambe le sorgenti: le frasi vengono messe in coda e
trascritte in ordine. Se la CPU non tiene il passo la coda cresce e il
ritardo viene mostrato nel pannello.
"""
from __future__ import annotations

import os
import queue
import re
import threading
from typing import Callable

from .audio import Utterance

# Allucinazioni tipiche di whisper su rumore o silenzio.
_HALLUCINATIONS = re.compile(
    r"sottotitoli|sottotitolato|revisione a cura|grazie per (aver|la) (guardato|visione)|"
    r"video registrato|iscriviti al canale|amara\.org|thanks for watching|subtitles by",
    re.IGNORECASE)
_BRACKETS = re.compile(r"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*")


def clean(text: str) -> str:
    text = _BRACKETS.sub("", text)
    text = re.sub(r"\s+", " ", text).strip()
    if not text or _HALLUCINATIONS.search(text):
        return ""
    if len(text) < 2 or not re.search(r"\w", text):
        return ""
    return text


class Transcriber:
    def __init__(self, model: str, language: str, models_dir: str | None, threads: int,
                 on_text: Callable[[Utterance, str], None], on_backlog: Callable[[float], None]):
        self.model_name = model
        self.language = language
        self.models_dir = models_dir
        self.threads = threads or (os.cpu_count() or 4)
        self.on_text = on_text
        self.on_backlog = on_backlog
        self.queue: "queue.Queue[Utterance | None]" = queue.Queue()
        self.model = None
        self.thread = threading.Thread(target=self._run, name="whisper", daemon=True)
        self.ready = threading.Event()
        self.error: str | None = None

    def start(self) -> None:
        self.thread.start()

    def load(self) -> None:
        from pywhispercpp.model import Model  # import lento: solo quando serve

        kwargs = dict(print_progress=False, print_realtime=False, print_timestamps=False,
                      n_threads=self.threads, redirect_whispercpp_logs_to=None)
        if self.language and self.language != "auto":
            kwargs["language"] = self.language
        if self.models_dir:
            kwargs["models_dir"] = self.models_dir
        self.model = Model(self.model_name, **kwargs)

    def submit(self, utterance: Utterance) -> None:
        self.queue.put(utterance)
        self.on_backlog(self.backlog_seconds())

    def backlog_seconds(self) -> float:
        with self.queue.mutex:
            items = list(self.queue.queue)
        return sum(u.end - u.start for u in items if u is not None)

    def _run(self) -> None:
        try:
            self.load()
        except Exception as error:  # noqa: BLE001 — qualunque errore va mostrato nel pannello
            self.error = f"whisper non disponibile: {error}"
        self.ready.set()
        while True:
            item = self.queue.get()
            if item is None:
                break
            if self.model is None:
                continue
            try:
                segments = self.model.transcribe(item.samples, no_context=True)
                text = clean(" ".join(s.text.strip() for s in segments))
            except Exception as error:  # noqa: BLE001
                text = ""
                self.error = f"trascrizione: {error}"
            if text:
                self.on_text(item, text)
            self.on_backlog(self.backlog_seconds())

    def finish(self) -> None:
        """Trascrive ciò che resta in coda, poi si ferma."""
        self.queue.put(None)
        self.thread.join()
