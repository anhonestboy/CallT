Recap — Automatic call recording, transcription and notes
==========================================================

WHAT IT IS
Recap lives in the menu bar (waveform icon). It records your calls
(system audio + microphone, with or without screen video) and watches a
folder: every video or audio file that lands there is automatically
transcribed, summarized into organized Markdown notes and, for videos,
compressed. Everything runs on your Mac: no data leaves the computer
unless you explicitly pick a cloud notes engine in the settings.

REQUIREMENTS
- macOS 26 (Tahoe) or later. Nothing else to install.

INSTALL
1. Open Recap.dmg.
2. Drag Recap into the Applications folder.
3. Eject the disk and launch Recap from Applications.

FIRST LAUNCH (important)
The app does not come from the App Store, so macOS blocks it at first:
1. Open Recap: a warning appears — press "Done".
2. Go to System Settings → Privacy & Security, scroll down and press
   "Open Anyway" next to Recap, then confirm.
This is needed only once. To record calls, also allow Recap under
"Screen & System Audio Recording" and "Microphone" when asked.

USE
- Click the waveform icon in the menu bar.
- "Record call" → video and audio, or audio only.
- "Start monitoring" to watch the recordings folder
  (default: ~/CallRecordings — change it in Settings).
- Transcripts (.txt), notes (.md) and compressed videos appear in the
  "output" subfolder. The first transcription in a language downloads
  the speech model once (internet required that one time).

SHORTCUTS (AUTOMATION)
- Settings → Automation: pick an Apple Shortcut to run after every
  transcription, receiving the .txt file as input (mail it, Slack it…).
- The Shortcuts app also gets a "Transcribe video" action from Recap.

© 2026 werootbox — hello@werootbox.com — MIT license
