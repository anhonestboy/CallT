"""La sessione: audio → frasi → whisper → trascrizione; note aggiornate con l'AI;
a fine call la cartella con note, trascrizione e session.json (formato di Recap per Mac)."""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

from . import prompts
from .audio import Segmenter, Source, Utterance
from .config import Config
from .llm import Engine, LLMError
from .whisper import Transcriber


class Session:
    def __init__(self, cfg: Config, title: str | None = None,
                 replay: tuple[Path, Path | None] | None = None, speed: float = 1.0):
        self.cfg = cfg
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.version = 0
        self.replay = replay
        self.speed = speed

        now = datetime.now()
        self.base_name = title or f"Call {now:%Y-%m-%d %H.%M}"
        self.base_name = re.sub(r"[/\\:]", "-", self.base_name)
        self.folder = Path(cfg.output_dir).expanduser() / self.base_name
        self.started_at = time.time()
        self.started_label = now.strftime("%d/%m/%Y %H:%M")

        self.phase = "starting"          # starting | live | finishing | done | failed
        self.phase_message = ""
        self.error: str | None = None
        self.lines: list[dict] = []
        self.speaking = {"me": False, "others": False}
        self.backlog = 0.0
        self.notes = ""
        self.notes_updated: float | None = None
        self.notes_busy = False
        self.notes_error: str | None = None
        self.chat: list[dict] = []
        self.ask_busy = False
        self.sent_lines = 0
        self.pending_user_notes: list[tuple[float, str]] = []
        self.finished_at: float | None = None

        self.engine = Engine(cfg)
        self.transcriber = Transcriber(
            cfg.whisper_model, cfg.language, cfg.whisper_models_dir, cfg.whisper_threads,
            on_text=self._on_text, on_backlog=self._on_backlog)
        self.sources: list[Source] = []
        self._notes_thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._soon = threading.Event()

    # ── stato ───────────────────────────────────────────────

    def _bump(self) -> None:
        with self.lock:
            self.version += 1
            self.changed.notify_all()

    def elapsed(self) -> float:
        return time.time() - self.started_at

    def snapshot(self, since_line: int = 0) -> dict:
        with self.lock:
            return {
                "version": self.version, "phase": self.phase, "phaseMessage": self.phase_message,
                "error": self.error or self.transcriber.error, "name": self.base_name,
                "folder": str(self.folder), "startedAt": self.started_at, "elapsed": self.elapsed(),
                "engine": self.engine.label, "model": self.cfg.whisper_model,
                "speaking": dict(self.speaking), "backlog": round(self.backlog, 1),
                "notes": self.notes, "notesUpdated": self.notes_updated, "notesBusy": self.notes_busy,
                "notesError": self.notes_error, "chat": list(self.chat), "askBusy": self.ask_busy,
                "lineCount": len(self.lines), "linesFrom": min(since_line, len(self.lines)),
                "lines": [dict(l) for l in self.lines[since_line:]],
                "notesFile": str(self.notes_path) if self.notes_path.exists() else None,
            }

    @property
    def notes_path(self) -> Path:
        return self.folder / f"{self.base_name}_notes.md"

    # ── avvio ───────────────────────────────────────────────

    def start(self) -> None:
        self.folder.mkdir(parents=True, exist_ok=True)
        self.transcriber.start()
        keep = self.cfg.keep_audio and self.replay is None
        specs = [("others", self.cfg.system_command), ("me", self.cfg.mic_command)]
        for speaker, command in specs:
            replay_file = None
            if self.replay is not None:
                replay_file = self.replay[0] if speaker == "others" else self.replay[1]
                if replay_file is None:
                    continue
            segmenter = Segmenter(speaker, self._on_utterance, self._on_speaking)
            source = Source(speaker, segmenter, command=command, replay=replay_file, speed=self.speed,
                            keep=self.folder / f".{speaker}.wav" if keep else None,
                            on_error=self._on_capture_error)
            source.start()
            self.sources.append(source)
        with self.lock:
            self.phase = "live"
        self._bump()
        self._notes_thread = threading.Thread(target=self._notes_loop, name="notes", daemon=True)
        self._notes_thread.start()
        if self.replay is not None:
            threading.Thread(target=self._watch_replay, daemon=True).start()

    def _watch_replay(self) -> None:
        while not self._stop.is_set():
            if all(s.finished for s in self.sources):
                self.stop()
                return
            time.sleep(0.5)

    def _on_capture_error(self, message: str) -> None:
        with self.lock:
            if self.phase == "live":
                self.error = message
        self._bump()

    # ── audio → testo ───────────────────────────────────────

    def _on_speaking(self, speaker: str, speaking: bool) -> None:
        with self.lock:
            self.speaking[speaker] = speaking
        self._bump()

    def _on_utterance(self, utterance: Utterance) -> None:
        self.transcriber.submit(utterance)

    def _on_backlog(self, seconds: float) -> None:
        with self.lock:
            self.backlog = seconds
        self._bump()

    def _on_text(self, utterance: Utterance, text: str) -> None:
        line = {"id": str(uuid.uuid4()).upper(), "speaker": utterance.speaker, "speakerName": None,
                "start": round(utterance.start, 2), "end": round(utterance.end, 2), "text": text}
        with self.lock:
            if self._is_echo(line):
                return
            last = self.lines[-1] if len(self.lines) > self.sent_lines else None
            if (last and last["speaker"] == line["speaker"] and line["start"] - last["end"] < 1.2
                    and len(last["text"]) < 400):
                last["text"] += " " + line["text"]
                last["end"] = max(last["end"], line["end"])
            else:
                index = len(self.lines)
                while index > self.sent_lines and self.lines[index - 1]["start"] > line["start"]:
                    index -= 1
                self.lines.insert(index, line)
        self._bump()

    def _is_echo(self, line: dict) -> bool:
        """Senza cuffie il microfono riprende gli altri dagli altoparlanti: le righe "mie"
        quasi uguali a una riga degli altri nello stesso momento si scartano."""
        words = _words(line["text"])
        if len(words) < 3:
            return False
        for index in range(len(self.lines) - 1, -1, -1):
            other = self.lines[index]
            if other["end"] < line["start"] - 30:
                break
            if other["speaker"] == line["speaker"]:
                continue
            if other["end"] < line["start"] - 4 or other["start"] > line["end"] + 4:
                continue
            other_words = _words(other["text"])
            shared = len(words & other_words)
            if line["speaker"] == "me" and shared / len(words) >= 0.6:
                return True
            if (line["speaker"] == "others" and other["speaker"] == "me" and index >= self.sent_lines
                    and shared / max(1, len(other_words)) >= 0.6):
                del self.lines[index]
                return False
        return False

    # ── interazione ─────────────────────────────────────────

    def add_note(self, text: str) -> None:
        text = text.strip()
        if not text:
            return
        t = self.elapsed()
        with self.lock:
            self.pending_user_notes.append((t, text))
            self.chat.append({"role": "note", "text": text, "time": t})
        self._bump()
        self._soon.set()

    def mark(self, note: str = "") -> None:
        self.add_note(f"⭐ {note}" if note.strip() else "⭐ Momento segnato")

    def ask(self, question: str) -> None:
        question = question.strip()
        if not question:
            return
        with self.lock:
            self.chat.append({"role": "question", "text": question, "time": self.elapsed()})
            self.ask_busy = True
            material = (f"NOTES SO FAR:\n{self.notes or '(none yet)'}\n\n"
                        f"TRANSCRIPT:\n{prompts.transcript_text(self.lines, self.cfg.language)}\n\nQUESTION: {question}")
        self._bump()

        def work() -> None:
            try:
                answer = prompts.clean(self.engine.complete(prompts.ASK_SYSTEM, material, "ask"))
                item = {"role": "answer", "text": answer, "time": self.elapsed()}
            except LLMError as error:
                item = {"role": "error", "text": str(error), "time": self.elapsed()}
            with self.lock:
                self.chat.append(item)
                self.ask_busy = False
            self._bump()

        threading.Thread(target=work, daemon=True).start()

    # ── note live ───────────────────────────────────────────

    def _notes_loop(self) -> None:
        while not self._stop.is_set():
            woke = self._soon.wait(timeout=max(20, self.cfg.notes_interval))
            self._soon.clear()
            if self._stop.is_set():
                return
            if woke:
                time.sleep(3)  # raccoglie le note scritte in fila
            self.update_notes(force=woke)

    def refresh_notes(self) -> None:
        self._soon.set()

    def update_notes(self, force: bool = False) -> None:
        if not self.engine.available:
            return
        with self.lock:
            if self.notes_busy:
                return
            new_lines = self.lines[self.sent_lines:]
            user_notes = list(self.pending_user_notes)
            words = sum(len(l["text"].split()) for l in new_lines)
            enough = words >= (40 if not self.notes else 15) or bool(user_notes)
            if not (enough or (force and words > 0)):
                return
            self.notes_busy = True
            line_count = len(self.lines)
            prompt = (f"CURRENT NOTES:\n{self.notes or '(empty — first update)'}\n\n"
                      f"NEW TRANSCRIPT:\n{prompts.transcript_text(new_lines, self.cfg.language) or '(nothing new)'}")
            if user_notes:
                prompt += "\n\nUSER NOTES:\n" + "\n".join(
                    f"[{prompts.stamp(t)}] {text}" for t, text in user_notes)
        self._bump()
        try:
            updated = prompts.clean(self.engine.complete(
                prompts.live_system(self.cfg.language), prompt, "live"))
            with self.lock:
                if updated:
                    self.notes = updated
                    self.notes_updated = time.time()
                    self.notes_error = None
                    self.sent_lines = min(line_count, len(self.lines))
                    del self.pending_user_notes[:len(user_notes)]
                    self.notes_path.write_text(self.notes + "\n")
        except LLMError as error:
            with self.lock:
                self.notes_error = str(error)
        finally:
            with self.lock:
                self.notes_busy = False
            self._bump()

    # ── fine ────────────────────────────────────────────────

    def stop(self) -> None:
        with self.lock:
            if self.phase != "live":
                return
            self.phase = "finishing"
            self.phase_message = "Chiudo l'audio…"
        self._stop.set()
        self._soon.set()
        self._bump()
        threading.Thread(target=self._finish, name="finish", daemon=True).start()

    def _set_phase_message(self, message: str) -> None:
        with self.lock:
            self.phase_message = message
        self._bump()

    def _finish(self) -> None:
        duration = self.elapsed()
        for source in self.sources:
            source.stop()
        self._set_phase_message("Finisco la trascrizione…")
        self.transcriber.finish()
        with self.lock:
            self.speaking = {"me": False, "others": False}
        if self._notes_thread:
            self._notes_thread.join(timeout=600)

        self._set_phase_message("Scrivo le note finali…")
        transcript_path = self.folder / f"{self.base_name}_transcript.txt"
        with self.lock:
            lines = list(self.lines)
        transcript_path.write_text(prompts.transcript_text(lines, self.cfg.language) + "\n")
        final = self._final_notes(lines)
        self.notes_path.write_text(final + self._appendix(duration))
        self._write_sidecars(lines)
        self._save_audio()

        with self.lock:
            self.notes = final
            self.finished_at = time.time()
            self.phase = "done"
            self.phase_message = ""
        self._bump()
        _notify("Note della call pronte", self.base_name)

    def _final_notes(self, lines: list[dict]) -> str:
        if not self.engine.available or not lines:
            return self.notes or f"# {self.base_name}"
        with self.lock:
            user_notes = [c for c in self.chat if c["role"] == "note"]
        prompt = (f"FULL TRANSCRIPT:\n{prompts.transcript_text(lines, self.cfg.language)}\n\n"
                  f"NOTES TAKEN LIVE:\n{self.notes or '(none)'}")
        if user_notes:
            prompt += "\n\nUSER NOTES:\n" + "\n".join(
                f"[{prompts.stamp(c['time'])}] {c['text']}" for c in user_notes)
        try:
            return prompts.clean(self.engine.complete(
                prompts.final_system(self.cfg.language), prompt, "final")) or self.notes
        except LLMError as error:
            with self.lock:
                self.notes_error = f"note finali: {error}"
            return self.notes or f"# {self.base_name}"

    def _appendix(self, duration: float) -> str:
        m, s = divmod(int(duration), 60)
        h, m = divmod(m, 60)
        length = f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"
        return (f"\n\n---\n\n_{self.started_label} · {length} · Recap Lite (Linux) · "
                f"whisper {self.cfg.whisper_model} · {self.engine.label}_\n")

    def _write_sidecars(self, lines: list[dict]) -> None:
        # Stessi file di Recap per Mac: "Rigenera note" e la cronologia funzionano anche lì.
        segments = [{"start": l["start"], "end": l["end"],
                     "text": f"{l.get('speakerName') or prompts.label(l['speaker'], self.cfg.language)}: {l['text']}"}
                    for l in lines]
        (self.folder / f".{self.base_name}.segments.json").write_text(
            json.dumps({"segments": segments, "fineSegments": []}, ensure_ascii=False))
        session = {"name": self.base_name, "target": "Linux · audio", "lines": lines, "captures": []}
        (self.folder / "session.json").write_text(
            json.dumps(session, ensure_ascii=False, indent=2, sort_keys=True))

    def _save_audio(self) -> None:
        """Le due tracce (altri, io) diventano un .m4a se c'è ffmpeg, altrimenti restano WAV."""
        others = self.folder / ".others.wav"
        me = self.folder / ".me.wav"
        present = [p for p in (others, me) if p.exists() and p.stat().st_size > 44]
        if not present:
            return
        if shutil.which("ffmpeg"):
            out = self.folder / f"{self.base_name}.m4a"
            args = ["ffmpeg", "-loglevel", "error", "-y"]
            for path in present:
                args += ["-i", str(path)]
            for index in range(len(present)):
                args += ["-map", str(index)]
            args += ["-c:a", "aac", "-b:a", "64k", str(out)]
            if subprocess.run(args).returncode == 0:
                for path in present:
                    path.unlink()
                return
        for path in present:
            path.rename(self.folder / f"{self.base_name}-{path.stem.lstrip('.')}.wav")


def _words(text: str) -> set[str]:
    return {w for w in re.split(r"\W+", text.lower()) if len(w) >= 3}


def _notify(title: str, body: str) -> None:
    if shutil.which("notify-send"):
        subprocess.Popen(["notify-send", "-a", "Recap", title, body],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
