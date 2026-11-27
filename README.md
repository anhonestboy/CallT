<p align="center">
  <img src="docs/screenshots/banner.png" alt="Recap — live notes for your calls, on your Mac" width="720">
</p>

# Recap

**Live notes for your calls — on your Mac.** Recap sits in the menu bar and follows the call with you: it transcribes while you talk, grabs the slides and screens that get shared, saves short clips when something matters, and keeps a set of notes up to date while the meeting is still going. When you hang up, you get one folder with polished notes, the screenshots placed where they belong, and the full transcript.

No bot joins your meeting. Recap works with any call app — Zoom, Google Meet, Microsoft Teams, FaceTime, Webex — because it listens and looks from your Mac, not from inside the call.

<p align="center">
  <img src="docs/screenshots/live-panel.png" alt="Recap live panel: notes updated during the call, with the shared slide inline" width="440">
</p>

## What it does

- **Transcribes in real time**, on-device: your voice ("Me", from the microphone) is kept apart from everyone else ("Others", from the call audio). At the end, on-device diarization tells the other participants apart.
- **Sees what is shared.** Recap finds the call window and saves a screenshot whenever the shared screen changes — slides, documents, demos — reading the text with on-device OCR and skipping webcam faces.
- **Clips, not hours of video.** A rolling buffer means ⌃⌥C saves the last 30 seconds plus the next 10. Keeping the full recording is optional.
- **Notes that write themselves while you talk.** Claude reads the transcript and the screenshots and keeps the notes current every ~45 seconds: summary, topics, decisions, action items with owners and dates, open questions. A final pass writes the complete document when the call ends.
- **A panel you can talk to.** A translucent floating panel shows the notes, the transcript and the captures; ask it questions ("what did they say about the budget?") or add your own notes. Drag it anywhere, hide it with ⌃⌥N, and it gets out of the way by itself while you share your screen.
- **Everything in one place.** Each call gets its own folder: Markdown notes with images and clips, transcript, and session data — ready for Obsidian or any editor.

**AI, your way:** use Claude through the Claude Code login you already have (no API key), the Claude API, any text model you configure (e.g. DeepSeek, which receives the screenshots as OCR text), or no AI at all. Transcription and OCR never leave your Mac.

Recap still does what it always did: drop any recording into a watched folder and it is transcribed, summarized and compressed automatically.

<p align="center">
  <img src="docs/screenshots/menu.png" alt="Recap menu" width="320">
</p>

## Get it

- **Requirements:** macOS 26 (Tahoe) or later.
- **Download:** `Recap.dmg` from [Releases](https://github.com/anhonestboy/Recap/releases), or `brew install --cask anhonestboy/tap/recap` (versions up to 1.3.2 were published under the previous name, CallT).
- **Build from source:** `app/scripts/build.sh` · DMG: `app/scripts/package.sh` (Xcode 26).

Full documentation: [app/README.md](app/README.md) · [italiano](app/README.it.md)

## License

[MIT](LICENSE). `legacy/` contains the original Python prototype this app replaced.
