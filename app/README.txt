Recap — Live notes for your calls
=================================

WHAT IT IS
Recap lives in the menu bar (waveform icon). During a call it
transcribes what is said, saves screenshots of what gets shared, keeps
short clips on demand and writes notes with AI while the meeting goes
on. It also watches a folder: every video or audio file that lands there
is transcribed, summarized into Markdown notes and, for videos,
compressed. Transcription and OCR run on your Mac; text and screenshots
reach only the AI engine you pick in the settings (or none).
Recap was previously called CallT: its settings are imported on first
launch.

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
- "Start live session" (⌥⌘R) when the call begins; the floating panel
  shows notes, transcript and captures. ⌃⌥N hides/shows it, ⌃⌥S takes
  a screenshot, ⌃⌥C saves a clip, ⌃⌥M marks the moment.
- When you stop, the call folder holds notes (.md) with images,
  transcript and clips.
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
