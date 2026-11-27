# Recap Lite (Linux)

Note in tempo reale delle call su Linux, sullo stile di [Recap per Mac](../app/README.it.md). Prima fase: solo audio.

- **Trascrive mentre parlate**, tutto in locale con whisper.cpp. La tua voce ("Io", dal microfono) resta separata da quella degli altri ("Altri", dall'audio di sistema). Funziona con qualunque app di call: legge l'audio da PipeWire, nessun bot entra in riunione.
- **Scrive le note durante la call** con la CLI `claude` (il tuo account di Claude Code, nessuna chiave API), oppure con l'API Anthropic se c'è `ANTHROPIC_API_KEY`. A fine call le riscrive per intero (Opus).
- **Pannello** in una finestra Chromium: note, trascrizione, chat per fare domande o aggiungere note tue, ⭐ per segnare un momento.
- **Stessa cartella di Recap per Mac**: `…_notes.md`, `…_transcript.txt`, `session.json` e l'audio (`.m4a` con due tracce se c'è ffmpeg). Si può spostare sul Mac e consultare come le altre.

Screenshot automatici e clip dello schermo sono la fase 2.

## Requisiti (Fedora)

```sh
sudo dnf install pipewire-utils python3-pywhispercpp chromium
```

Facoltativi: `ffmpeg` (audio compresso invece che WAV), `claude` (Claude Code, già collegato al tuo account).
Il modello whisper (`small` di default) viene scaricato al primo uso, se non c'è già.

## Installazione

```sh
./install.sh          # comando recap-lite in ~/.local/bin + voce nel launcher
./install.sh --hypr   # anche scorciatoie e regola del pannello per Hyprland
recap-lite check      # controlla che ci sia tutto
```

Con `--hypr`:
- copia `hypr/recap.lua` in `~/.config/hypr/` e aggiunge `pcall(require, "recap")` a `hyprland.lua` (con backup);
- installa il **menu flottante** (Quickshell, `~/.config/quickshell/recap`) e aggiunge la **voce nella barra** di waybar (`custom/recap`, primo dei moduli di destra; backup `config.jsonc.bak-recap`).

Come la barra dei menu del Mac: l'icona dell'onda è sempre visibile e durante la call diventa rossa con il timer. **Clic** apre il menu sotto l'icona (avvia/ferma, pannello, segna il momento, call recenti, cartella, impostazioni). Si chiude cliccando fuori o con Esc. **Clic destro** avvia o ferma, **clic centrale** mostra il pannello. Colori dallo sfondo (matugen) e suoni degli extras, come il resto del desktop.

| Scorciatoia | Azione |
|---|---|
| Super+Alt+C | avvia / ferma la sessione |
| Super+Alt+N | mostra / nasconde il pannello (la sessione continua) |
| Super+Alt+M | segna il momento ⭐ |

Il pannello è flottante, fissato su tutti i workspace e leggermente trasparente.

Se usi un'altra barra, la voce si aggiunge a mano (`waybar_patch.py` mostra il modulo): `recap-lite status --waybar` per il testo, `recap-lite menu` al clic.

## Uso

```sh
recap-lite start [--title "Kickoff Orione"]   # avvia e apre il pannello
recap-lite mark ["decisione sul CRM"]         # ⭐
recap-lite note "chiedere i costi a Marco"
recap-lite ask "cosa hanno detto sul budget?"
recap-lite stop                               # note finali; stampa la cartella
```

Le call finiscono in `~/Recap/<Call data ora>/`.

## Configurazione

`~/.config/recap-lite/config.json`, creato al primo avvio:

| Chiave | Default | |
|---|---|---|
| `language` | `it` | lingua della call (`auto` per il riconoscimento automatico) |
| `whisper_model` | `small` | `base` più veloce, `medium` più preciso ma pesante |
| `output_dir` | `~/Recap` | dove finiscono le call |
| `engine` | `claude-cli` | `claude-cli`, `api` (ANTHROPIC_API_KEY) oppure `off` |
| `live_model` / `final_model` | `sonnet` / `opus` | modelli Claude per note live e finali |
| `notes_interval` | `45` | secondi tra un aggiornamento delle note e l'altro |
| `keep_audio` | `true` | tiene l'audio della call |
| `mic_command`, `system_command` | `pw-record …` | comandi di cattura (PCM 16 kHz mono su stdout) |

Su Apple Silicon (Asahi) whisper gira sulla CPU: `small` regge una call in tempo reale; se nel pannello compare "Trascrizione in ritardo", passa a `base`.

## Collaudo senza call

```sh
recap-lite start --replay altri.wav io.wav --speed 2   # WAV 16 kHz mono
```

Log del demone: `~/.cache/recap-lite/recap-lite.log`.
