import Foundation
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// La sessione live: registra la call, la trascrive mentre parlate, salva
/// screenshot e clip, tiene note aggiornate con l'AI e a fine call scrive
/// tutto in una cartella (note .md con immagini, trascrizione, materiali).
@MainActor
final class LiveSession: ObservableObject {
    static let shared = LiveSession()

    enum Phase: Equatable {
        case idle
        case starting
        case live
        case finishing(String)
        case done(URL)
        case failed(String)
    }

    enum Mode: String {
        case video, audioOnly
    }

    // MARK: Stato pubblicato (UI)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode = .video
    @Published private(set) var startedAt: Date?
    @Published private(set) var targetDescription = ""
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var volatile: [Speaker: String] = [:]
    @Published private(set) var notes = ""
    @Published private(set) var notesUpdatedAt: Date?
    @Published private(set) var notesBusy = false
    @Published private(set) var notesError: String?
    @Published private(set) var captures: [Capture] = []
    @Published private(set) var chat: [ChatItem] = []
    @Published private(set) var askBusy = false
    @Published private(set) var engineLabel = ""
    @Published private(set) var sessionFolder: URL?
    @Published private(set) var notesFileURL: URL?
    @Published private(set) var clipInProgress = false

    var isActive: Bool { phase == .starting || phase == .live }
    var isDoneOrFailed: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }
    var isRecording: Bool { isActive }
    var hasVideo: Bool { source?.producesVideo ?? false }

    // MARK: Interni

    private var source: LiveMediaSource?
    private var router: MediaRouter?
    private var meTranscriber: LiveTranscriber?
    private var othersTranscriber: LiveTranscriber?
    private var frameAnalyzer: FrameAnalyzer?
    private var clipBuffer: ClipRingBuffer?
    private var recordingWriter: MediaFileWriter?
    private var othersWAV: URL?
    private var llm: LiveLLM?
    private var notesLoop: Task<Void, Never>?
    private var sentLineCount = 0
    private var pendingUserNotes: [(time: Double, text: String)] = []
    private var nextCaptureID = 1
    private var baseName = ""
    private var restartAttempted = false
    private var stopping = false

    private var assetsDir: URL? { sessionFolder?.appendingPathComponent("assets", isDirectory: true) }

    // MARK: - Avvio

    /// Avvia una sessione. `picked` = finestra/schermo scelti con il picker di
    /// sistema; `replay` = file da rileggere come se fosse una call (collaudo).
    func start(mode: Mode, picked: SCContentFilter? = nil, replay: URL? = nil, replaySpeed: Double = 1) async {
        guard !isActive, !stopping else { return }
        if replay == nil {
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                showPermissionAlert()
                return
            }
        }
        reset()
        phase = .starting
        self.mode = mode
        AppSettings.defaults.set(mode == .audioOnly ? "audioOnly" : "video", forKey: "lastRecordMode")

        let stamp = Self.nameFormatter.string(from: Date())
        baseName = String(localized: "Call \(stamp)")
        let folder = AppSettings.outputFolder.appendingPathComponent(baseName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        } catch {
            fail(String(localized: "Could not create the session folder: \(error.localizedDescription)"))
            return
        }
        sessionFolder = folder
        notesFileURL = folder.appendingPathComponent("\(baseName)_notes.md")

        llm = LiveLLMFactory.make()
        engineLabel = llm?.label ?? String(localized: "no AI engine")
        if llm == nil, AppSettings.liveEngine != "off" {
            notesError = String(localized: "No AI engine available: set one in Settings → Live.")
        }

        let router = MediaRouter()
        self.router = router
        let wantsVideo = mode == .video
        let fps = 10

        do {
            // Trascrizione: io (microfono) e gli altri (audio di sistema).
            let language = AppSettings.language
            let me = LiveTranscriber(speaker: .me) { update in
                Task { @MainActor in LiveSession.shared.handle(update) }
            }
            let others = LiveTranscriber(speaker: .others) { update in
                Task { @MainActor in LiveSession.shared.handle(update) }
            }
            try await others.start(language: language)
            try await me.start(language: language)
            meTranscriber = me
            othersTranscriber = others
            router.me = me
            router.others = others

            if AppSettings.liveDiarize && SpeakerLabeler.available {
                let wav = folder.appendingPathComponent(".others-16k.wav")
                router.othersTap = try? WAVTap(url: wav)
                othersWAV = router.othersTap == nil ? nil : wav
            }

            let handlers = router.handlers { error in
                Task { @MainActor in await LiveSession.shared.sourceStopped(error) }
            }
            let source: LiveMediaSource
            if let replay {
                source = FileReplaySource(url: replay, speed: replaySpeed, handlers: handlers)
            } else {
                let target: ResolvedCaptureTarget
                if let picked {
                    target = CaptureTargetResolver.fromPicked(picked)
                } else {
                    target = try await CaptureTargetResolver.resolve(AppSettings.liveCaptureTarget)
                }
                source = ScreenCaptureSource(
                    target: target, wantsVideo: wantsVideo,
                    wantsMic: AppSettings.captureMic != "never", fps: fps, handlers: handlers)
            }
            try await source.start()
            self.source = source
            router.origin = source.origin
            targetDescription = source.targetDescription

            if source.producesVideo, wantsVideo {
                let analyzer = FrameAnalyzer(
                    autoEnabled: AppSettings.liveAutoShots,
                    sensitivity: AppSettings.liveShotSensitivity
                ) { shot in
                    Task { @MainActor in LiveSession.shared.addShot(shot, kind: .auto) }
                }
                frameAnalyzer = analyzer
                router.frames = analyzer
                let clips = ClipRingBuffer(
                    dir: FileManager.default.temporaryDirectory
                        .appendingPathComponent("recap-clips-\(UUID().uuidString)"),
                    videoSize: source.videoSize, withMic: true, fps: fps,
                    maxPreRoll: Double(AppSettings.liveClipBefore))
                clipBuffer = clips
                router.clips = clips
            }

            let keep = AppSettings.liveKeepRecording
            if keep != "none" {
                let withVideo = keep == "video" && source.producesVideo
                let url = folder.appendingPathComponent("\(baseName).\(withVideo ? "mp4" : "m4a")")
                recordingWriter = try? MediaFileWriter(
                    url: url, videoSize: withVideo ? source.videoSize : nil, withMic: true, fps: fps)
                router.recording = recordingWriter
            }
        } catch {
            await teardownMedia()
            fail(String(localized: "Live session could not start: \(error.localizedDescription)"))
            return
        }

        startedAt = Date()
        phase = .live
        appLog("🔴 Live session started — \(targetDescription) — AI: \(engineLabel)")
        LivePanelController.shared.sessionStarted()
        ScreenShareWatcher.shared.start()
        startNotesLoop()
    }

    private func reset() {
        lines = []
        volatile = [:]
        notes = ""
        notesUpdatedAt = nil
        notesError = nil
        captures = []
        chat = []
        sentLineCount = 0
        pendingUserNotes = []
        nextCaptureID = 1
        restartAttempted = false
        targetDescription = ""
        sessionFolder = nil
        notesFileURL = nil
        othersWAV = nil
    }

    private func fail(_ message: String) {
        appLog("❌ \(message)")
        phase = .failed(message)
        startedAt = nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Recording could not start")
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Screen recording permission required")
        alert.informativeText = String(localized: "To record calls, Recap needs permission to capture the screen and system audio. Enable Recap in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// La sorgente si è fermata: fine del file in replay, oppure la finestra
    /// della call è stata chiusa. In quel caso riprova sullo schermo intero.
    private func sourceStopped(_ error: Error?) async {
        guard phase == .live, !stopping else { return }
        guard error != nil, source is ScreenCaptureSource, !restartAttempted, let router else {
            await stop()
            return
        }
        restartAttempted = true
        appLog("↻ Capture interrupted, switching to the whole screen")
        await source?.stop()
        do {
            let target = try await CaptureTargetResolver.resolve(.pointerDisplay)
            let handlers = router.handlers { error in
                Task { @MainActor in await LiveSession.shared.sourceStopped(error) }
            }
            let replacement = ScreenCaptureSource(
                target: target, wantsVideo: mode == .video,
                wantsMic: AppSettings.captureMic != "never", fps: 10, handlers: handlers)
            try await replacement.start()
            source = replacement
            targetDescription = replacement.targetDescription
        } catch {
            appLog("❌ Capture could not restart: \(error.localizedDescription)")
            await stop()
        }
    }

    // MARK: - Trascrizione

    private func handle(_ update: LiveTranscriber.Update) {
        guard isActive || stopping else { return }
        if !update.isFinal {
            volatile[update.speaker] = update.text
            return
        }
        volatile[update.speaker] = nil
        guard !update.text.isEmpty else { return }
        let line = TranscriptLine(speaker: update.speaker, start: update.start, end: update.end, text: update.text)
        if isEcho(line) { return }
        // Unisce frasi consecutive della stessa persona.
        if let last = lines.indices.last, lines.count > sentLineCount,
           lines[last].speaker == line.speaker,
           line.start - lines[last].end < 1.2, lines[last].text.count < 400 {
            lines[last].text += " " + line.text
            lines[last].end = max(lines[last].end, line.end)
        } else {
            insertSorted(line)
        }
    }

    private func insertSorted(_ line: TranscriptLine) {
        // Le due sorgenti arrivano con ritardi diversi: tiene l'ordine temporale
        // ma non tocca le righe già passate all'AI.
        var index = lines.count
        while index > sentLineCount, lines[index - 1].start > line.start { index -= 1 }
        lines.insert(line, at: index)
    }

    /// Senza cuffie il microfono riprende anche le voci degli altri dagli
    /// altoparlanti: una riga "mia" quasi identica a una "degli altri" nello
    /// stesso momento è un'eco, e si scarta.
    private func isEcho(_ line: TranscriptLine) -> Bool {
        let words = FrameAnalyzer.words(line.text)
        guard words.count >= 3 else { return false }
        let window = (line.start - 4)...(line.end + 4)
        for (index, other) in lines.enumerated().reversed() {
            if other.end < line.start - 30 { break }
            guard other.speaker != line.speaker,
                  window.overlaps((other.start)...(max(other.start, other.end))) else { continue }
            let otherWords = FrameAnalyzer.words(other.text)
            let shared = Double(words.intersection(otherWords).count)
            if line.speaker == .me, shared / Double(words.count) >= 0.6 { return true }
            if line.speaker == .others, other.speaker == .me,
               shared / Double(max(1, otherWords.count)) >= 0.6, index >= sentLineCount {
                lines.remove(at: index)
                return false
            }
        }
        return false
    }

    var elapsed: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Istante corrente sul tempo della sessione (secondi).
    private var now: Double { router?.lastTime ?? elapsed }

    // MARK: - Materiale visivo

    func snapshot(note: String = "") async {
        guard phase == .live, let frameAnalyzer else { return }
        guard let shot = await frameAnalyzer.captureNow() else { return }
        addShot(shot, kind: .manual, note: note)
    }

    func markMoment(note: String = "") async {
        guard phase == .live else { return }
        let time = now
        var shot: FrameAnalyzer.Shot?
        if let frameAnalyzer { shot = await frameAnalyzer.captureNow() }
        if let shot {
            addShot(shot, kind: .mark, note: note)
        } else {
            captures.append(Capture(id: nextCaptureID, kind: .mark, time: time, file: nil, note: note))
            nextCaptureID += 1
        }
        let text = note.isEmpty ? String(localized: "⭐ Moment marked") : "⭐ \(note)"
        pendingUserNotes.append((time, text))
        chat.append(ChatItem(role: .note, text: text, time: time))
        scheduleSoonUpdate()
    }

    func clip() async {
        guard phase == .live, let clipBuffer, let router, let assetsDir, !clipInProgress else { return }
        let before = Double(AppSettings.liveClipBefore)
        let after = Double(AppSettings.liveClipAfter)
        let centerPTS = router.lastVideoPTS
        let time = now
        let id = nextCaptureID
        nextCaptureID += 1
        let name = String(format: "%03d-clip-%@.mp4", id, LiveTime.stamp(time).replacingOccurrences(of: ":", with: "."))
        clipInProgress = true
        appLog("🎬 Clip: last \(Int(before)) s + next \(Int(after)) s…")
        let shot = await frameAnalyzer?.captureNow()
        do {
            _ = try await clipBuffer.makeClip(
                center: centerPTS, before: before, after: after,
                to: assetsDir.appendingPathComponent(name))
            captures.append(Capture(id: id, kind: .clip, time: time, file: "assets/\(name)",
                                    ocrText: shot?.ocrText ?? ""))
            appLog("   → \(name)")
        } catch {
            appLog("⚠️ Clip failed: \(error.localizedDescription)")
        }
        clipInProgress = false
    }

    private func addShot(_ shot: FrameAnalyzer.Shot, kind: Capture.Kind, note: String = "") {
        guard let assetsDir else { return }
        let id = nextCaptureID
        nextCaptureID += 1
        let suffix = kind == .auto ? "slide" : (kind == .mark ? "mark" : "shot")
        let name = String(format: "%03d-%@-%@.jpg", id, suffix,
                          LiveTime.stamp(shot.time).replacingOccurrences(of: ":", with: "."))
        do {
            try shot.jpeg.write(to: assetsDir.appendingPathComponent(name))
        } catch {
            appLog("⚠️ Screenshot not saved: \(error.localizedDescription)")
            return
        }
        captures.append(Capture(id: id, kind: kind, time: shot.time, file: "assets/\(name)",
                                ocrText: shot.ocrText, note: note))
        if kind != .auto { scheduleSoonUpdate() }
    }

    // MARK: - Interazione

    func addUserNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let time = now
        pendingUserNotes.append((time, trimmed))
        chat.append(ChatItem(role: .note, text: trimmed, time: time))
        scheduleSoonUpdate()
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.append(ChatItem(role: .question, text: trimmed, time: now))
        guard let llm = llm ?? LiveLLMFactory.make() else {
            chat.append(ChatItem(role: .error, text: String(localized: "No AI engine available."), time: now))
            return
        }
        askBusy = true
        var material = "NOTES SO FAR:\n\(notes.isEmpty ? "(none yet)" : notes)\n\n"
        material += "TRANSCRIPT:\n\(LivePrompts.transcriptText(lines))\n"
        for (speaker, text) in volatile where !text.isEmpty {
            material += "[now] \(speaker.label) (still speaking): \(text)\n"
        }
        let visuals = captures.map(LivePrompts.visualCaption).joined(separator: "\n\n")
        if !visuals.isEmpty { material += "\nVISUALS:\n\(visuals)\n" }
        var blocks: [LLMBlock] = [.text(material)]
        if llm.supportsImages, let latest = captures.last(where: \.isImage), let data = imageData(latest) {
            blocks.append(.jpeg(data, caption: "Most recent screenshot: " + LivePrompts.visualCaption(latest)))
        }
        blocks.append(.text("QUESTION: \(trimmed)"))
        do {
            let answer = try await llm.complete(system: LivePrompts.askSystem, blocks: blocks, tier: .ask)
            chat.append(ChatItem(role: .answer, text: LivePrompts.clean(answer), time: now))
        } catch {
            chat.append(ChatItem(role: .error, text: error.localizedDescription, time: now))
        }
        askBusy = false
    }

    // MARK: - Note live

    private func startNotesLoop() {
        notesLoop?.cancel()
        notesLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = max(20, AppSettings.liveInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard let self, self.phase == .live else { return }
                await self.updateNotes(force: false)
            }
        }
    }

    private var soonUpdate: Task<Void, Never>?
    private func scheduleSoonUpdate() {
        soonUpdate?.cancel()
        soonUpdate = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.updateNotes(force: true)
        }
    }

    func refreshNotesNow() {
        Task { await updateNotes(force: true) }
    }

    private func updateNotes(force: Bool) async {
        guard let llm, !notesBusy, phase == .live || stopping else { return }
        let newLines = Array(lines[min(sentLineCount, lines.count)...])
        let newCaptures = captures.filter { !$0.sentToAI }
        let userNotes = pendingUserNotes
        let words = newLines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        // All'inizio aspetta un minimo di materiale per non scrivere note vuote.
        let enough = words >= (notes.isEmpty ? 40 : 15) || !newCaptures.isEmpty || !userNotes.isEmpty
        guard enough || (force && words > 0) else { return }

        notesBusy = true
        defer { notesBusy = false }
        var blocks: [LLMBlock] = [
            .text("CURRENT NOTES:\n\(notes.isEmpty ? "(empty — first update)" : notes)"),
            .text("NEW TRANSCRIPT:\n\(newLines.isEmpty ? "(nothing new)" : LivePrompts.transcriptText(newLines))"),
        ]
        if !newCaptures.isEmpty {
            blocks.append(.text("NEW VISUALS:"))
            // Al massimo 4 immagini per aggiornamento; le altre viaggiano come testo OCR.
            let withImage = Set(newCaptures.filter(\.isImage).suffix(4).map(\.id))
            for capture in newCaptures {
                let caption = LivePrompts.visualCaption(capture)
                if llm.supportsImages, withImage.contains(capture.id), let data = imageData(capture) {
                    blocks.append(.jpeg(data, caption: caption))
                } else {
                    blocks.append(.text(caption))
                }
            }
        }
        if !userNotes.isEmpty {
            blocks.append(.text("USER NOTES:\n" + userNotes.map { "[\(LiveTime.stamp($0.time))] \($0.text)" }
                .joined(separator: "\n")))
        }
        let lineCountAtSend = lines.count
        let captureIDs = Set(newCaptures.map(\.id))
        do {
            let updated = try await llm.complete(system: LivePrompts.liveSystem, blocks: blocks, tier: .live)
            let cleaned = LivePrompts.clean(updated)
            guard !cleaned.isEmpty else { return }
            notes = cleaned
            notesUpdatedAt = Date()
            notesError = nil
            sentLineCount = min(lineCountAtSend, lines.count)
            for index in captures.indices where captureIDs.contains(captures[index].id) {
                captures[index].sentToAI = true
            }
            pendingUserNotes.removeFirst(min(userNotes.count, pendingUserNotes.count))
            saveLiveNotes()
        } catch {
            notesError = error.localizedDescription
            appLog("⚠️ Live notes: \(error.localizedDescription)")
        }
    }

    /// Le note live vengono salvate a ogni aggiornamento: si possono aprire
    /// (es. in Obsidian) durante la call e sopravvivono a un crash.
    private func saveLiveNotes() {
        guard let notesFileURL else { return }
        try? notes.write(to: notesFileURL, atomically: true, encoding: .utf8)
    }

    private func imageData(_ capture: Capture) -> Data? {
        guard let file = capture.file, let folder = sessionFolder else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(file))
    }

    // MARK: - Fine sessione

    func stop() async {
        guard phase == .live, !stopping else { return }
        stopping = true
        defer { stopping = false }
        notesLoop?.cancel()
        soonUpdate?.cancel()
        ScreenShareWatcher.shared.stop()
        let duration = elapsed
        phase = .finishing(String(localized: "Closing the recording…"))
        appLog("⏹️ Live session stopped (\(LiveTime.format(duration)))")

        await teardownMedia()
        // Ciò che era ancora "in corso di riconoscimento" diventa definitivo.
        volatile = [:]

        guard let folder = sessionFolder else { phase = .idle; return }

        // Chi sono "gli altri": diarizzazione dell'audio di sistema (on-device).
        if let wav = othersWAV, lines.contains(where: { $0.speaker == .others }) {
            phase = .finishing(String(localized: "Identifying speakers…"))
            do {
                let turns = try await SpeakerLabeler.diarize(wav: wav)
                applyDiarization(turns)
            } catch {
                appLog("⚠️ Speaker identification failed (non-blocking): \(error.localizedDescription)")
            }
        }
        if let wav = othersWAV { try? FileManager.default.removeItem(at: wav) }

        let transcriptURL = folder.appendingPathComponent("\(baseName)_transcript.txt")
        try? LivePrompts.transcriptText(lines).write(to: transcriptURL, atomically: true, encoding: .utf8)
        writeSidecars(folder: folder)

        phase = .finishing(String(localized: "Writing the final notes…"))
        let finalNotes = await composeFinalNotes(duration: duration)
        let notesURL = folder.appendingPathComponent("\(baseName)_notes.md")
        try? finalNotes.write(to: notesURL, atomically: true, encoding: .utf8)
        notes = finalNotes
        notesFileURL = notesURL

        let recording = recordingWriter?.url
        recordingWriter = nil
        let registrySource = recording.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? transcriptURL
        await ProcessedRegistry.shared.markDone(registrySource, transcript: transcriptURL)
        AppState.shared.refreshRecents()

        phase = .done(folder)
        startedAt = nil
        appLog("✅ Session saved: \(folder.path)")
        Notifier.notifyDone(
            title: String(localized: "Call notes ready"), body: baseName,
            transcript: transcriptURL, notes: notesURL)
        AppState.shared.resumeQueueAfterRecording()
    }

    private func teardownMedia() async {
        await source?.stop()
        source = nil
        router?.detach()
        async let me: Void = meTranscriber?.finish() ?? ()
        async let others: Void = othersTranscriber?.finish() ?? ()
        _ = await (me, others)
        meTranscriber = nil
        othersTranscriber = nil
        router?.othersTap = nil
        router?.flushTap()
        if let writer = recordingWriter, await !writer.finish() {
            appLog("⚠️ The recording file could not be finalized")
        }
        await clipBuffer?.shutdown()
        clipBuffer = nil
        frameAnalyzer = nil
        router = nil
    }

    /// Divide "Others" in persone distinte usando i turni della diarizzazione.
    private func applyDiarization(_ turns: [SpeakerLabeler.DiarSegment]) {
        guard !turns.isEmpty else { return }
        let speakers = Set(turns.map(\.speaker))
        guard speakers.count >= 1 else { return }
        var names: [String: String] = [:]
        for (index, id) in speakers.sorted().enumerated() {
            names[id] = String(localized: "Participant \(index + 1)")
        }
        for index in lines.indices where lines[index].speaker == .others {
            let mid = (lines[index].start + lines[index].end) / 2
            let turn = turns.first { mid >= $0.start && mid <= $0.end }
                ?? turns.min { abs($0.start - mid) < abs($1.start - mid) }
            if let turn, speakers.count > 1 { lines[index].speakerName = names[turn.speaker] }
        }
        appLog("   \(speakers.count) other participant(s) identified")
    }

    private func composeFinalNotes(duration: Double) async -> String {
        var body = notes
        let llm = self.llm
        if let llm, !lines.isEmpty || !captures.isEmpty {
            do {
                if llm.supportsImages {
                    var blocks: [LLMBlock] = [
                        .text("FULL TRANSCRIPT:\n\(lines.isEmpty ? "(no speech recognized)" : LivePrompts.transcriptText(lines))"),
                        .text("NOTES TAKEN LIVE:\n\(notes.isEmpty ? "(none)" : notes)"),
                    ]
                    let notesFromUser = chat.filter { $0.role == .note }
                    if !notesFromUser.isEmpty {
                        blocks.append(.text("USER NOTES:\n" + notesFromUser
                            .map { "[\(LiveTime.stamp($0.time))] \($0.text)" }.joined(separator: "\n")))
                    }
                    if !captures.isEmpty {
                        blocks.append(.text("VISUALS:"))
                        let chosen = Set(Self.pickImages(captures, limit: 20).map(\.id))
                        for capture in captures {
                            let caption = LivePrompts.visualCaption(capture)
                            if chosen.contains(capture.id), let data = imageData(capture) {
                                blocks.append(.jpeg(data, caption: caption))
                            } else {
                                blocks.append(.text(caption))
                            }
                        }
                    }
                    body = LivePrompts.clean(try await llm.complete(
                        system: LivePrompts.finalSystem(detail: .current), blocks: blocks, tier: .final))
                } else if !lines.isEmpty {
                    // Motori solo-testo: la pipeline classica con map/reduce.
                    body = try await CallNotesGenerator.generateNotes(
                        transcript: sidecarTranscript(), callName: baseName) { _ in }
                }
            } catch {
                appLog("⚠️ Final notes failed, keeping the live notes: \(error.localizedDescription)")
            }
        }
        if body.isEmpty { body = "# \(baseName)" }
        return body + materialsAppendix(duration: duration)
    }

    /// Prima le catture scelte da te, poi quelle automatiche distribuite nel tempo.
    private static func pickImages(_ captures: [Capture], limit: Int) -> [Capture] {
        let images = captures.filter(\.isImage)
        let manual = images.filter { $0.kind != .auto }
        let auto = images.filter { $0.kind == .auto }
        var chosen = Array(manual.suffix(limit))
        let room = limit - chosen.count
        if room > 0, !auto.isEmpty {
            let step = max(1, Double(auto.count) / Double(room))
            var position = 0.0
            while Int(position) < auto.count, chosen.count < limit {
                chosen.append(auto[Int(position)])
                position += step
            }
        }
        return chosen
    }

    private func materialsAppendix(duration: Double) -> String {
        var out = "\n\n---\n\n"
        let date = Self.dateFormatter.string(from: startedAt ?? Date().addingTimeInterval(-duration))
        out += "_\(date) · \(LiveTime.format(duration)) · \(targetDescription) · \(engineLabel)_\n"
        let visuals = captures.filter { $0.file != nil }
        guard !visuals.isEmpty else { return out }
        out += "\n## " + String(localized: "Materials") + "\n\n"
        for capture in visuals {
            guard let file = capture.file else { continue }
            let stamp = LiveTime.stamp(capture.time)
            let label: String
            switch capture.kind {
            case .auto: label = String(localized: "Screen")
            case .manual: label = String(localized: "Screenshot")
            case .clip: label = String(localized: "Clip")
            case .mark: label = String(localized: "⭐ Marked moment")
            }
            let note = capture.note.isEmpty ? "" : " — \(capture.note)"
            let target = file.replacingOccurrences(of: " ", with: "%20")
            if capture.kind == .clip {
                out += "- [🎬 \(label) \(stamp)\(note)](\(target))\n"
            } else {
                out += "\n**\(label) \(stamp)**\(note)\n\n![\(label) \(stamp)](\(target))\n"
            }
        }
        return out
    }

    private func sidecarTranscript() -> Transcript {
        Transcript(segments: lines.map {
            Transcript.Segment(start: $0.start, end: $0.end, text: "\($0.displaySpeaker): \($0.text)")
        })
    }

    private func writeSidecars(folder: URL) {
        // Stesso sidecar della pipeline: "Rigenera note" funziona anche qui.
        if let data = try? JSONEncoder().encode(sidecarTranscript()) {
            try? data.write(to: folder.appendingPathComponent(".\(baseName).segments.json"))
        }
        struct SessionFile: Codable {
            var name: String
            var target: String
            var lines: [TranscriptLine]
            var captures: [Capture]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(SessionFile(
            name: baseName, target: targetDescription, lines: lines, captures: captures)) {
            try? data.write(to: folder.appendingPathComponent("session.json"))
        }
    }

    func dismissResult() {
        if case .done = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()
}

/// Smista i buffer dalle code di cattura verso trascrizione, analisi frame,
/// clip e registrazione, senza passare dal main thread.
final class MediaRouter: @unchecked Sendable {
    private let lock = NSLock()
    var me: LiveTranscriber?
    var others: LiveTranscriber?
    var othersTap: WAVTap?
    var frames: FrameAnalyzer?
    var clips: ClipRingBuffer?
    var recording: MediaFileWriter?
    var origin: CMTime = .zero
    private let tapQueue = DispatchQueue(label: "com.werootbox.recap.live.tap")
    private var detached = false
    private var _lastTime: Double = 0
    private var _lastVideoPTS: Double = 0

    var lastTime: Double { lock.withLock { _lastTime } }
    var lastVideoPTS: Double { lock.withLock { _lastVideoPTS } }

    func detach() {
        lock.withLock { detached = true }
    }

    /// Attende che le scritture del WAV in coda siano su disco.
    func flushTap() {
        tapQueue.sync {}
    }

    private func time(of buffer: CMSampleBuffer) -> Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid else { return nil }
        return CMTimeSubtract(pts, origin).seconds
    }

    func handlers(stopped: @escaping @Sendable (Error?) -> Void) -> MediaHandlers {
        MediaHandlers(
            systemAudio: { [weak self] buffer in self?.system(buffer) },
            micAudio: { [weak self] buffer in self?.mic(buffer) },
            video: { [weak self] buffer in self?.video(buffer) },
            stopped: stopped)
    }

    private func system(_ buffer: CMSampleBuffer) {
        guard !lock.withLock({ detached }), let t = time(of: buffer) else { return }
        lock.withLock { _lastTime = max(_lastTime, t) }
        if let recording { recording.queue.async { recording.appendSystem(buffer) } }
        clips?.appendSystem(buffer)
        guard let pcm = AudioTools.pcmBuffer(from: buffer) else { return }
        others?.append(pcm, at: t)
        if let tap = othersTap { tapQueue.async { tap.write(pcm, at: t) } }
    }

    private func mic(_ buffer: CMSampleBuffer) {
        guard !lock.withLock({ detached }), let t = time(of: buffer) else { return }
        if let recording { recording.queue.async { recording.appendMic(buffer) } }
        clips?.appendMic(buffer)
        guard let pcm = AudioTools.pcmBuffer(from: buffer) else { return }
        me?.append(pcm, at: t)
    }

    private func video(_ buffer: CMSampleBuffer) {
        guard !lock.withLock({ detached }), let t = time(of: buffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        lock.withLock { _lastVideoPTS = pts; _lastTime = max(_lastTime, t) }
        frames?.ingest(buffer, time: t)
        clips?.appendVideo(buffer)
        if let recording, recording.hasVideo { recording.queue.async { recording.appendVideo(buffer) } }
    }
}
