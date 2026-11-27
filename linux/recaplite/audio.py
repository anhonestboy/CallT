"""Cattura audio e segmentazione in frasi.

Due sorgenti indipendenti (microfono = "Me", audio di sistema = "Others"),
ognuna letta da un processo esterno che scrive PCM s16le 16 kHz mono su
stdout (pw-record di default). Un rilevatore di voce a energia, con soglia
che si adatta al rumore di fondo, taglia il flusso in frasi da passare a
whisper.
"""
from __future__ import annotations

import subprocess
import threading
import time
import wave
from pathlib import Path
from typing import Callable

import numpy as np

RATE = 16_000
FRAME = 480  # 30 ms


class Utterance:
    __slots__ = ("speaker", "start", "end", "samples")

    def __init__(self, speaker: str, start: float, end: float, samples: np.ndarray):
        self.speaker = speaker
        self.start = start
        self.end = end
        self.samples = samples  # float32 [-1, 1]


class Segmenter:
    """Rilevatore di voce: frasi tra 0,4 e 15 s, chiuse da ~0,7 s di silenzio."""

    def __init__(self, speaker: str, on_utterance: Callable[[Utterance], None],
                 on_speaking: Callable[[str, bool], None]):
        self.speaker = speaker
        self.on_utterance = on_utterance
        self.on_speaking = on_speaking
        self.noise = 0.003
        self.pre_roll: list[np.ndarray] = []
        self.current: list[np.ndarray] = []
        self.start_frame = 0
        self.frame_index = 0
        self.silent_frames = 0
        self.speaking = False
        self.min_frames = int(0.4 * RATE / FRAME)
        self.max_frames = int(15 * RATE / FRAME)
        self.hang_frames = int(0.7 * RATE / FRAME)
        self.pre_frames = int(0.3 * RATE / FRAME)
        self._carry = np.zeros(0, dtype=np.float32)

    def feed(self, samples: np.ndarray) -> None:
        data = np.concatenate([self._carry, samples]) if self._carry.size else samples
        usable = (len(data) // FRAME) * FRAME
        self._carry = data[usable:]
        for offset in range(0, usable, FRAME):
            self._frame(data[offset:offset + FRAME])

    def _frame(self, frame: np.ndarray) -> None:
        rms = float(np.sqrt(np.mean(frame * frame)) + 1e-9)
        threshold = max(self.noise * 3.0, 0.006)
        voiced = rms > threshold
        if not voiced:
            # Il rumore di fondo si aggiorna solo sui frame non vocali.
            self.noise = 0.995 * self.noise + 0.005 * rms
        if self.speaking:
            self.current.append(frame)
            self.silent_frames = 0 if voiced else self.silent_frames + 1
            long_enough = len(self.current) >= self.max_frames
            if self.silent_frames >= self.hang_frames or long_enough:
                self._close()
        elif voiced:
            self.speaking = True
            self.silent_frames = 0
            self.current = list(self.pre_roll)
            self.start_frame = self.frame_index - len(self.pre_roll)
            self.current.append(frame)
            self.on_speaking(self.speaker, True)
        else:
            self.pre_roll.append(frame)
            if len(self.pre_roll) > self.pre_frames:
                self.pre_roll.pop(0)
        self.frame_index += 1

    def _close(self) -> None:
        frames = self.current
        self.speaking = False
        self.current = []
        self.pre_roll = []
        self.on_speaking(self.speaker, False)
        voiced = len(frames) - self.silent_frames
        if voiced < self.min_frames:
            return
        samples = np.concatenate(frames)
        start = max(0, self.start_frame) * FRAME / RATE
        end = start + len(samples) / RATE
        self.on_utterance(Utterance(self.speaker, start, end, samples))

    def flush(self) -> None:
        if self.speaking:
            self._close()


class Source:
    """Legge PCM da un processo (o da un file in replay) e lo passa al segmentatore."""

    def __init__(self, speaker: str, segmenter: Segmenter, command: list[str] | None = None,
                 replay: Path | None = None, speed: float = 1.0, keep: Path | None = None,
                 on_error: Callable[[str], None] | None = None):
        self.speaker = speaker
        self.segmenter = segmenter
        self.command = command
        self.replay = replay
        self.speed = max(0.1, speed)
        self.keep_path = keep
        self.on_error = on_error or (lambda message: None)
        self.process: subprocess.Popen | None = None
        self.thread: threading.Thread | None = None
        self.stopping = threading.Event()
        self.samples_read = 0
        self._wav: wave.Wave_write | None = None

    def start(self) -> None:
        if self.keep_path:
            self._wav = wave.open(str(self.keep_path), "wb")
            self._wav.setnchannels(1)
            self._wav.setsampwidth(2)
            self._wav.setframerate(RATE)
        if self.replay is None:
            try:
                self.process = subprocess.Popen(
                    self.command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            except FileNotFoundError as error:
                raise RuntimeError(f"comando di cattura non trovato: {self.command[0]}") from error
        self.thread = threading.Thread(target=self._run, name=f"audio-{self.speaker}", daemon=True)
        self.thread.start()

    def _run(self) -> None:
        try:
            if self.replay is not None:
                self._run_replay()
            else:
                self._run_process()
        finally:
            self.segmenter.flush()

    def _run_process(self) -> None:
        assert self.process and self.process.stdout
        chunk = FRAME * 2 * 10  # 300 ms
        while not self.stopping.is_set():
            data = self.process.stdout.read(chunk)
            if not data:
                break
            self._consume(data)
        if not self.stopping.is_set():
            err = b""
            if self.process.stderr:
                try:
                    err = self.process.stderr.read() or b""
                except OSError:
                    pass
            self.on_error(f"cattura {self.speaker} interrotta: {err.decode(errors='replace').strip()[:200]}")

    def _run_replay(self) -> None:
        with wave.open(str(self.replay), "rb") as wav:
            if wav.getframerate() != RATE or wav.getnchannels() != 1 or wav.getsampwidth() != 2:
                raise RuntimeError(f"{self.replay}: serve un WAV 16 kHz mono 16 bit")
            begin = time.monotonic()
            block = FRAME * 10
            while not self.stopping.is_set():
                data = wav.readframes(block)
                if not data:
                    break
                due = (self.samples_read / RATE) / self.speed - (time.monotonic() - begin)
                if due > 0:
                    time.sleep(due)
                self._consume(data)

    def _consume(self, data: bytes) -> None:
        if len(data) % 2:
            data = data[:-1]
        if self._wav:
            self._wav.writeframes(data)
        pcm = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
        self.samples_read += len(pcm)
        self.segmenter.feed(pcm)

    @property
    def finished(self) -> bool:
        return self.thread is not None and not self.thread.is_alive()

    def stop(self) -> None:
        self.stopping.set()
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
        if self.thread:
            self.thread.join(timeout=5)
        if self._wav:
            self._wav.close()
            self._wav = None
