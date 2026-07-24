import Foundation
import AppKit
import AVFoundation

/// Orchestratore dell'elaborazione di un singolo video:
/// audio → transcription → notes → (compression) → (trash original) → (Apple Shortcut).
enum Pipeline {
    struct UpdateInfo: Sendable {
        var error: String?
        var transcriptURL: URL?
        var notesURL: URL?
    }

    typealias Update = @Sendable (JobStage, Double, UpdateInfo?) -> Void

    static func run(videoURL: URL, update: @escaping Update) async {
        let outDir = AppSettings.outputFolder
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            await fail(videoURL, update: update, message: "Could not create the output folder: \(error.localizedDescription)")
            return
        }

        // Base name: reuse the one already assigned to this source, otherwise
        // the first free one (so call.mp4 and call.mov never overwrite each other).
        let baseName = await resolveBaseName(for: videoURL, outDir: outDir)
        let transcriptURL = outDir.appendingPathComponent("\(baseName)_transcript.txt")
        let notesURL = outDir.appendingPathComponent("\(baseName)_notes.md")
        let srtURL = outDir.appendingPathComponent("\(baseName)_transcript.srt")
        let compressedURL = outDir.appendingPathComponent("\(baseName)_compressed.mp4")
        let keptAudioURL = outDir.appendingPathComponent("\(baseName)_audio.wav")
        let ext = videoURL.pathExtension.lowercased()
        let isMKV = ext == "mkv"
        let isAudioFile = FolderWatcher.audioExtensions.contains(ext)

        appLog("▶️ Processing: \(videoURL.lastPathComponent)")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("callt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // MKV files need ffmpeg for any operation.
        if isMKV && !FFmpegHelper.available {
            await fail(videoURL, update: update, message: ".mkv files require ffmpeg (brew install ffmpeg)")
            return
        }

        let hasAudio: Bool
        if isAudioFile {
            hasAudio = true
        } else {
            hasAudio = await detectAudio(videoURL, isMKV: isMKV)
        }

        // 1+2. Audio extraction and transcription (skipped for silent videos)
        var writtenTranscript: URL?
        var writtenNotes: URL?
        if hasAudio {
            update(.extractingAudio, 0, nil)
            let engineKind = AppSettings.engine
            // Whisper wants 16k mono WAV; the Apple engine reads M4A.
            // If the user keeps the extracted audio, WAV is needed anyway.
            let needsWAV = engineKind == .whisper || AppSettings.keepAudio
            let audioForEngine: URL
            do {
                if isAudioFile {
                    // The file IS audio already: use it directly
                    // (WAV only when whisper needs it and the format differs).
                    if engineKind == .whisper && ext != "wav" {
                        audioForEngine = try await extractWAVResiliently(
                            from: videoURL, to: tempDir.appendingPathComponent("audio.wav"))
                    } else {
                        audioForEngine = videoURL
                    }
                } else if isMKV {
                    let wav = tempDir.appendingPathComponent("audio.wav")
                    try await FFmpegHelper.extractWAV(from: videoURL, to: wav)
                    audioForEngine = wav
                } else if needsWAV {
                    audioForEngine = try await extractWAVResiliently(
                        from: videoURL, to: tempDir.appendingPathComponent("audio.wav"))
                } else {
                    do {
                        let m4a = tempDir.appendingPathComponent("audio.m4a")
                        try await AudioExtractor.exportM4A(from: videoURL, to: m4a)
                        audioForEngine = m4a
                    } catch where FFmpegHelper.available {
                        // Some files (e.g. certain Teams recordings) trip
                        // AVFoundation's decoder mid-stream; ffmpeg is tolerant.
                        appLog("⚠️ AVFoundation could not extract the audio, retrying with ffmpeg…")
                        let wav = tempDir.appendingPathComponent("audio.wav")
                        try await FFmpegHelper.extractWAV(from: videoURL, to: wav)
                        audioForEngine = wav
                    }
                }
            } catch {
                let ns = error as NSError
                let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
                    .map { " — \($0.domain) \($0.code) \($0.localizedDescription)" } ?? ""
                await fail(videoURL, update: update,
                           message: "Audio extraction failed: \(error.localizedDescription) [\(ns.domain) \(ns.code)\(underlying)]")
                return
            }

            if AppSettings.keepAudio, !isAudioFile, audioForEngine.pathExtension == "wav" {
                try? FileManager.default.removeItem(at: keptAudioURL)
                try? FileManager.default.copyItem(at: audioForEngine, to: keptAudioURL)
                appLog("   → \(keptAudioURL.lastPathComponent)")
            }

            update(.transcribing, 0, nil)
            let engine: TranscriptionEngine
            if engineKind == .whisper, let whisper = WhisperTranscriber.detect() {
                engine = whisper
            } else {
                if engineKind == .whisper {
                    appLog("⚠️ Whisper not available, falling back to the Apple engine")
                }
                engine = AppleTranscriber()
            }

            var transcript: Transcript
            do {
                transcript = try await engine.transcribe(
                    audioURL: audioForEngine,
                    language: AppSettings.language
                ) { p in update(.transcribing, p, nil) }
            } catch {
                await fail(videoURL, update: update, message: "Transcription failed: \(error.localizedDescription)")
                return
            }

            // 2a. Chi parla (diarizzazione) — non bloccante
            if AppSettings.diarizeSpeakers && SpeakerLabeler.available {
                do {
                    let wavForDiarization: URL
                    if audioForEngine.pathExtension.lowercased() == "wav" {
                        wavForDiarization = audioForEngine
                    } else {
                        wavForDiarization = try await extractWAVResiliently(
                            from: videoURL, to: tempDir.appendingPathComponent("diar.wav"))
                    }
                    appLog("🗣️ Identifying speakers…")
                    let turns = try await SpeakerLabeler.diarize(wav: wavForDiarization)
                    let speakers = Set(turns.map(\.speaker)).count
                    transcript = SpeakerLabeler.apply(turns, to: transcript)
                    appLog("   \(speakers) speaker\(speakers == 1 ? "" : "s") identified")
                } catch {
                    appLog("⚠️ Speaker identification failed (non-blocking): \(error.localizedDescription)")
                }
            }

            do {
                try transcript.text.write(to: transcriptURL, atomically: true, encoding: .utf8)
                appLog("   → \(transcriptURL.lastPathComponent)")
                if AppSettings.generateSRT {
                    let srt = transcript.srt()
                    if !srt.isEmpty {
                        try srt.write(to: srtURL, atomically: true, encoding: .utf8)
                        appLog("   → \(srtURL.lastPathComponent)")
                    }
                }
            } catch {
                await fail(videoURL, update: update, message: "Writing the transcript failed: \(error.localizedDescription)")
                return
            }
            writtenTranscript = transcriptURL
            // Sidecar nascosto con i segmenti: permette di rigenerare le note
            // (anche con un altro livello di dettaglio) senza ritrascrivere.
            let sidecarURL = outDir.appendingPathComponent(".\(baseName).segments.json")
            if let data = try? JSONEncoder().encode(transcript) {
                try? data.write(to: sidecarURL)
            }
            update(.transcribing, 1, UpdateInfo(transcriptURL: transcriptURL))

            // 2b. Organized notes (.md) — non-blocking
            if AppSettings.notesEnabled {
                update(.summarizing, 0, nil)
                do {
                    let notes = try await CallNotesGenerator.generateNotes(
                        transcript: transcript, callName: baseName
                    ) { p in update(.summarizing, p, nil) }
                    try notes.write(to: notesURL, atomically: true, encoding: .utf8)
                    writtenNotes = notesURL
                    appLog("   → \(notesURL.lastPathComponent)")
                } catch {
                    appLog("⚠️ Notes not generated (non-blocking): \(error.localizedDescription)")
                }
            }
        } else {
            appLog("ℹ️ No audio track: skipping transcription")
        }

        // 3. Compression (non-blocking: a failure does not invalidate the transcript)
        // Audio-only files are never compressed.
        var compressionSucceeded = false
        if AppSettings.compressVideo && !isAudioFile {
            update(.compressing, 0, nil)
            do {
                let result: VideoCompressor.Result
                if isMKV {
                    result = try await FFmpegHelper.compress(
                        source: videoURL, destination: compressedURL,
                        quality: AppSettings.compressionQuality,
                        downscale: AppSettings.downscaleTo1080
                    ) { p in update(.compressing, p, nil) }
                } else {
                    do {
                        result = try await VideoCompressor.compress(
                            source: videoURL, destination: compressedURL,
                            quality: AppSettings.compressionQuality,
                            downscale: AppSettings.downscaleTo1080
                        ) { p in update(.compressing, p, nil) }
                    } catch where FFmpegHelper.available {
                        appLog("⚠️ AVFoundation could not compress the video, retrying with ffmpeg…")
                        result = try await FFmpegHelper.compress(
                            source: videoURL, destination: compressedURL,
                            quality: AppSettings.compressionQuality,
                            downscale: AppSettings.downscaleTo1080
                        ) { p in update(.compressing, p, nil) }
                    }
                }
                switch result {
                case .compressed(let saved):
                    compressionSucceeded = true
                    appLog("   → \(compressedURL.lastPathComponent) (−\(saved)%)")
                case .skippedAlreadyEfficient:
                    appLog("   ℹ️ Video already efficient, compression skipped")
                case .skippedNotSmaller:
                    appLog("   ℹ️ Compressed file was not smaller: keeping the original")
                }
            } catch {
                appLog("⚠️ Compression failed (non-blocking): \(error.localizedDescription)")
            }
        }

        // 4. Registry BEFORE trashing (afterwards the file stats are gone)
        await ProcessedRegistry.shared.markDone(videoURL, transcript: writtenTranscript)

        // 5. Original to the Trash (only when a compressed copy exists)
        if AppSettings.deleteOriginal && compressionSucceeded {
            do {
                try FileManager.default.trashItem(at: videoURL, resultingItemURL: nil)
                appLog("🗑️ Original moved to the Trash")
            } catch {
                appLog("⚠️ Could not trash the original: \(error.localizedDescription)")
            }
        }

        update(.done, 1, UpdateInfo(transcriptURL: writtenTranscript, notesURL: writtenNotes))
        appLog("✅ Finished: \(videoURL.lastPathComponent)")
        Notifier.notifyDone(
            title: String(localized: "Transcription finished"),
            body: videoURL.lastPathComponent,
            transcript: writtenTranscript, notes: writtenNotes)

        // 6. Delivery via Apple Shortcuts — off the serial queue: a slow or
        // stuck shortcut must not hold up the next files.
        let shortcut = AppSettings.deliveryShortcut
        if !shortcut.isEmpty, let transcript = writtenTranscript {
            Task.detached {
                if let error = await ShortcutRunner.run(shortcut: shortcut, input: transcript) {
                    appLog("⚠️ Shortcut “\(shortcut)” failed: \(error)")
                } else {
                    appLog("📤 Shortcut “\(shortcut)” ran with the transcript")
                }
            }
        }
    }

    /// WAV extraction with an ffmpeg fallback: AVFoundation's decoder rejects
    /// mid-stream quirks (some Teams/OneDrive recordings) that ffmpeg tolerates.
    private static func extractWAVResiliently(from source: URL, to wav: URL) async throws -> URL {
        do {
            try await AudioExtractor.extractWAV(from: source, to: wav)
        } catch where FFmpegHelper.available {
            appLog("⚠️ AVFoundation could not extract the audio, retrying with ffmpeg…")
            try await FFmpegHelper.extractWAV(from: source, to: wav)
        }
        return wav
    }

    /// True when the file has at least one audio track (when in doubt, true:
    /// extraction will fail with a clear message).
    private static func detectAudio(_ url: URL, isMKV: Bool) async -> Bool {
        if isMKV {
            return (try? await FFmpegHelper.probe(url))?.hasAudio ?? true
        }
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio) else {
            return true
        }
        return !tracks.isEmpty
    }

    /// Reuse the base name already assigned to this source; otherwise the first
    /// free one among stem, stem_ext, stem_ext_2, …
    private static func resolveBaseName(for videoURL: URL, outDir: URL) async -> String {
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let suffix = "_transcript.txt"
        if let prior = await ProcessedRegistry.shared.knownTranscript(for: videoURL) {
            let priorURL = URL(fileURLWithPath: prior)
            if priorURL.deletingLastPathComponent().path == outDir.path,
               priorURL.lastPathComponent.hasSuffix(suffix) {
                return String(priorURL.lastPathComponent.dropLast(suffix.count))
            }
        }
        let ext = videoURL.pathExtension.lowercased()
        var candidates = [stem, "\(stem)_\(ext)"]
        candidates += (2...9).map { "\(stem)_\(ext)_\($0)" }
        for candidate in candidates {
            let txtBusy = FileManager.default.fileExists(
                atPath: outDir.appendingPathComponent(candidate + suffix).path)
            let mp4Busy = FileManager.default.fileExists(
                atPath: outDir.appendingPathComponent(candidate + "_compressed.mp4").path)
            if !txtBusy && !mp4Busy { return candidate }
        }
        return "\(stem)_\(Int(Date().timeIntervalSince1970))"
    }

    /// Rigenera solo le note (con le impostazioni correnti) a partire dal
    /// sidecar dei segmenti — senza ritrascrivere.
    static func regenerateNotes(transcriptPath: String, update: @escaping Update) async {
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        let outDir = transcriptURL.deletingLastPathComponent()
        var baseName = transcriptURL.lastPathComponent
        for suffix in ["_transcript.txt", "_trascrizione.txt"] where baseName.hasSuffix(suffix) {
            baseName = String(baseName.dropLast(suffix.count))
        }
        let notesURL = outDir.appendingPathComponent("\(baseName)_notes.md")
        let sidecarURL = outDir.appendingPathComponent(".\(baseName).segments.json")

        let transcript: Transcript
        if let data = try? Data(contentsOf: sidecarURL),
           let decoded = try? JSONDecoder().decode(Transcript.self, from: data) {
            transcript = decoded
        } else if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            // Vecchie trascrizioni senza sidecar: niente timestamp, solo testo.
            transcript = Transcript(segments: text.split(separator: "\n").map {
                .init(start: nil, end: nil, text: String($0))
            })
        } else {
            appLog("❌ Notes regeneration failed: transcript not readable")
            update(.failed, 0, UpdateInfo(error: "transcript not readable"))
            return
        }

        appLog("♻️ Regenerating notes: \(baseName)")
        update(.summarizing, 0, nil)
        do {
            let notes = try await CallNotesGenerator.generateNotes(
                transcript: transcript, callName: baseName
            ) { p in update(.summarizing, p, nil) }
            try notes.write(to: notesURL, atomically: true, encoding: .utf8)
            appLog("   → \(notesURL.lastPathComponent)")
            update(.done, 1, UpdateInfo(transcriptURL: transcriptURL, notesURL: notesURL))
            Notifier.notifyDone(
                title: String(localized: "Notes regenerated"),
                body: baseName, transcript: transcriptURL, notes: notesURL)
        } catch {
            appLog("❌ Notes regeneration failed: \(error.localizedDescription)")
            update(.failed, 0, UpdateInfo(error: error.localizedDescription))
        }
    }

    private static func fail(_ videoURL: URL, update: Update, message: String) async {
        appLog("❌ \(message)")
        await ProcessedRegistry.shared.markFailed(videoURL)
        update(.failed, 0, UpdateInfo(error: message))
        Notifier.notify(title: String(localized: "Processing failed"), body: videoURL.lastPathComponent)
    }
}
