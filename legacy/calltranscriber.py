#!/usr/bin/env python3
"""
CallTranscriber — macOS menu bar app (rumps) + watchdog.
Drop video → auto extract audio + transcribe with whisper-cpp.
"""
import os, sys, subprocess, time, json, signal
from pathlib import Path
from datetime import datetime
from threading import Thread, Lock

import rumps
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# ── CONFIG ─────────────────────────────────────────
WATCH_FOLDER = os.path.expanduser("~/CallRecordings")
OUTPUT_FOLDER = None  # set to WATCH_FOLDER/output by default
WHISPER_MODEL = "large-v3-turbo"  # italiano ottimo, veloce su Apple Silicon
WHISPER_LANG = "it"
FFMPEG_BIN = "/opt/homebrew/bin/ffmpeg"
WHISPER_BIN = "/opt/homebrew/bin/whisper-cpp"
COMPRESS_VIDEO = True
DELETE_ORIGINAL = False
# ────────────────────────────────────────────────────

VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".m4v"}
QUEUE: list[Path] = []
QUEUE_LOCK = Lock()
PROCESSING = False
LOG_LINES: list[str] = []


def log(msg: str):
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    LOG_LINES.append(line)
    print(line)
    if len(LOG_LINES) > 200:
        del LOG_LINES[: len(LOG_LINES) - 200]


def output_dir() -> Path:
    global OUTPUT_FOLDER
    if OUTPUT_FOLDER is None:
        OUTPUT_FOLDER = Path(WATCH_FOLDER) / "output"
    p = Path(OUTPUT_FOLDER)
    p.mkdir(parents=True, exist_ok=True)
    return p


def find_binary(names: list[str]) -> str:
    """Cerca binario per nome. Prima prova brew --prefix, poi which."""
    import shutil
    # Prova brew --prefix per trovare il path corretto (Apple Silicon vs Intel)
    for name in names:
        r = subprocess.run(["brew", "--prefix", name], capture_output=True, text=True)
        if r.returncode == 0:
            prefix = r.stdout.strip()
            # whisper-cpp installa in bin/; ffmpeg anche
            candidates = [
                os.path.join(prefix, "bin", name),
                os.path.join(prefix, "bin", name.replace("-cpp", "")),  # whisper-cpp → whisper
            ]
            for c in candidates:
                if os.path.isfile(c):
                    return c
    # Fallback: shutil.which
    for name in names:
        p = shutil.which(name)
        if p:
            return p
    return names[0]  # ultima spiaggia


def ffmpeg_path() -> str:
    return find_binary(["ffmpeg"])


def whisper_path() -> str:
    return find_binary(["whisper-cli", "whisper-cpp", "whisper"])


def extract_audio(video: Path, audio: Path) -> bool:
    log(f"🎵 Estrazione audio: {video.name}")
    cmd = [
        ffmpeg_path(), "-y", "-i", str(video),
        "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
        str(audio)
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        log(f"❌ ffmpeg: {r.stderr[-300:]}")
        return False
    return True


def transcribe(audio: Path, text: Path) -> bool:
    log(f"📝 Trascrizione in corso ({WHISPER_MODEL})...")
    cmd = [
        whisper_path(),
        "-m", f"models/ggml-{WHISPER_MODEL}.bin",
        "-f", str(audio),
        "-l", WHISPER_LANG,
        "-otxt",
        "-of", str(text.with_suffix("")),  # whisper-cpp aggiunge .txt
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
    if r.returncode != 0:
        log(f"❌ whisper-cpp: {r.stderr[-300:]}")
        return False
    # whisper-cpp output è audio.wav.txt, rinomina se necessario
    whisper_out = Path(str(text.with_suffix("")) + ".txt")
    if whisper_out.exists() and whisper_out != text:
        whisper_out.rename(text)
    return True


def compress_video(src: Path, dst: Path) -> bool:
    log(f"🎬 Compressione video...")
    cmd = [
        ffmpeg_path(), "-y", "-i", str(src),
        "-c:v", "hevc_videotoolbox", "-b:v", "2M",
        "-c:a", "aac", "-b:a", "64k",
        "-movflags", "+faststart",
        str(dst)
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0


def process_video(video: Path):
    global PROCESSING
    base = video.stem
    out = output_dir()
    audio_path = out / f"{base}_audio.wav"
    text_path = out / f"{base}_trascrizione.txt"
    compressed_path = out / f"{base}_compressed.mp4"

    # 1. Estrai audio
    if not extract_audio(video, audio_path):
        PROCESSING = False
        return
    log(f"   → {audio_path.name}")

    # 2. Trascrivi
    if not transcribe(audio_path, text_path):
        PROCESSING = False
        return
    log(f"   → {text_path.name}")

    # 3. Comprimi (opzionale)
    if COMPRESS_VIDEO:
        if compress_video(video, compressed_path):
            log(f"   → {compressed_path.name}")
        else:
            log("⚠️ Compressione fallita (non bloccante)")

    # 4. Cancella originale (opzionale)
    if DELETE_ORIGINAL and COMPRESS_VIDEO and compressed_path.exists():
        video.unlink()
        log("🗑️ Originale rimosso")

    log(f"✅ Completato: {video.name}")
    PROCESSING = False


def queue_worker():
    global PROCESSING
    while True:
        with QUEUE_LOCK:
            if QUEUE and not PROCESSING:
                path = QUEUE.pop(0)
                PROCESSING = True
            else:
                path = None
        if path:
            try:
                process_video(path)
            except Exception as e:
                log(f"💥 Errore: {e}")
                PROCESSING = False
        else:
            time.sleep(1)


class VideoHandler(FileSystemEventHandler):
    def on_created(self, event):
        if event.is_directory:
            return
        path = Path(event.src_path)
        if path.suffix.lower() not in VIDEO_EXTS:
            return
        if path.name.startswith("."):
            return
        # Aspetta 5s che il file sia completamente scritto
        Thread(target=self._delayed_enqueue, args=(path,), daemon=True).start()

    def _delayed_enqueue(self, path: Path, delay: float = 5.0):
        # Aspetta che la dimensione smetta di crescere
        if not path.exists():
            return
        time.sleep(delay)
        if not path.exists():
            return
        with QUEUE_LOCK:
            if path not in QUEUE:
                QUEUE.append(path)
                log(f"📥 Nuovo: {path.name}")


# ── rumps app ─────────────────────────────────────
class CallTranscriberApp(rumps.App):
    def __init__(self):
        super().__init__(
            "🎙️",
            title="CallTranscriber",
            quit_button=None,
        )
        # Nascondi dal dock — solo menu bar
        from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
        NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        self.folder_item = rumps.MenuItem("📂 Cartella: …")
        self.toggle_item = rumps.MenuItem("Avvia monitoraggio")
        self.status_item = rumps.MenuItem("Stato: ⏸️ fermo")
        self.folder_item.set_callback(self.choose_folder)
        self.toggle_item.set_callback(self.toggle_monitoring)

        self.menu = [
            self.folder_item,
            None,
            self.toggle_item,
            self.status_item,
            None,
            rumps.MenuItem("📋 Ultimi log", callback=self.show_logs),
            None,
            "⚙️ Opzioni",
            None,
            rumps.MenuItem("Esci", callback=self.quit_app),
        ]
        self.observer: Observer | None = None
        self._monitoring = False
        self._update_folder_display()

    def _update_folder_display(self):
        self.folder_item.title = f"📂 {WATCH_FOLDER}"

    def choose_folder(self, _):
        from AppKit import NSOpenPanel
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseDirectories_(True)
        panel.setCanChooseFiles_(False)
        panel.setCanCreateDirectories_(True)
        panel.setMessage_("Scegli la cartella per le registrazioni")
        if panel.runModal() == 1:  # NSModalResponseOK
            global WATCH_FOLDER
            WATCH_FOLDER = panel.URL().path()
            self._update_folder_display()
            if self._monitoring:
                self.stop_monitoring()
                self.start_monitoring()

    def toggle_monitoring(self, _):
        if self._monitoring:
            self.stop_monitoring()
        else:
            self.start_monitoring()

    def start_monitoring(self):
        log(f"🔍 Monitoraggio: {WATCH_FOLDER}")
        self.observer = Observer()
        self.observer.schedule(VideoHandler(), WATCH_FOLDER, recursive=False)
        self.observer.start()
        self._monitoring = True
        self.toggle_item.title = "Ferma monitoraggio"
        self.status_item.title = "Stato: ▶️ attivo"

    def stop_monitoring(self):
        if self.observer:
            self.observer.stop()
            self.observer.join(timeout=5)
            self.observer = None
        self._monitoring = False
        self.toggle_item.title = "Avvia monitoraggio"
        self.status_item.title = "Stato: ⏸️ fermo"
        log("⏸️ Monitoraggio fermato")

    @rumps.clicked("📋 Ultimi log")
    def show_logs(self, _):
        rumps.alert(
            title="Log (ultimi 20)",
            message="\n".join(LOG_LINES[-20:]) or "Nessun log.",
        )

    @rumps.clicked("⚙️ Opzioni")
    def options_menu(self, _):
        pass

    @rumps.clicked("Esci")
    def quit_app(self, _):
        self.stop_monitoring()
        rumps.quit_application()


def main():
    # Verifica dipendenze
    ffp = ffmpeg_path()
    whp = whisper_path()
    if not os.path.isfile(ffp):
        print(f"❌ ffmpeg non trovato. Installa: brew install ffmpeg")
        sys.exit(1)
    if not os.path.isfile(whp):
        print(f"❌ whisper-cpp non trovato. Installa: brew install whisper-cpp")
        sys.exit(1)
    log(f"Usando ffmpeg: {ffp}")
    log(f"Usando whisper: {whp}")

    # Avvia worker coda
    Thread(target=queue_worker, daemon=True).start()

    # Avvia app menu bar
    app = CallTranscriberApp()
    app.run()


if __name__ == "__main__":
    main()
