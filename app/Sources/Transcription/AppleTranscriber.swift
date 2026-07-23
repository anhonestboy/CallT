import Foundation
import AVFoundation
import Speech
import CoreMedia

/// Motore di trascrizione integrato di macOS 26 (SpeechAnalyzer/SpeechTranscriber):
/// on-device, nessuna dipendenza esterna. Il modello linguistico viene
/// scaricato dal sistema alla prima trascrizione in quella lingua.
struct AppleTranscriber: TranscriptionEngine {
    /// Lingue supportate dal sistema, per il picker delle impostazioni.
    static func availableLanguages() async -> [(id: String, label: String)] {
        let locales = await SpeechTranscriber.supportedLocales
        var seen = Set<String>()
        var result: [(id: String, label: String)] = []
        for locale in locales {
            let id = locale.identifier(.bcp47)
            guard seen.insert(id).inserted else { continue }
            let label = Locale.current.localizedString(forIdentifier: id) ?? id
            result.append((id: id, label: "\(label) (\(id))"))
        }
        // Current system language first, then alphabetical.
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        result.sort { a, b in
            if a.id.hasPrefix(preferred) != b.id.hasPrefix(preferred) {
                return a.id.hasPrefix(preferred)
            }
            return a.label < b.label
        }
        if result.isEmpty {
            result = [(id: "en-US", label: "English (en-US)"), (id: "it-IT", label: "Italiano (it-IT)")]
        }
        return result
    }

    func transcribe(
        audioURL: URL,
        language: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        guard let resolved = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language))
        else {
            throw TranscriptionError(message: "language “\(language)” is not supported by the Apple engine")
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])

        try await Self.ensureModelInstalled(for: transcriber, locale: resolved)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = audioFile.fileFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.fileFormat.sampleRate
            : 0

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let resultsTask = Task {
            var segments: [Transcript.Segment] = []
            var fine: [Transcript.Segment] = []
            var pendingPrefix = ""
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                segments.append(.init(
                    start: start.isFinite ? start : nil,
                    end: end.isFinite ? end : nil,
                    text: text))
                // Run temporizzati a livello di parola, per sottotitoli a grana fine.
                for run in result.text.runs {
                    let runText = String(result.text[run.range].characters)
                    if let tr = run.audioTimeRange,
                       tr.start.seconds.isFinite, tr.end.seconds.isFinite {
                        fine.append(.init(
                            start: tr.start.seconds, end: tr.end.seconds,
                            text: pendingPrefix + runText))
                        pendingPrefix = ""
                    } else if fine.isEmpty {
                        pendingPrefix += runText
                    } else {
                        fine[fine.count - 1].text += runText
                    }
                }
                if duration > 0, end.isFinite {
                    progress(min(end / duration, 1.0))
                }
            }
            return (segments, fine)
        }

        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            throw TranscriptionError(message: "audio analysis failed: \(error.localizedDescription)")
        }

        let (segments, fine) = try await resultsTask.value
        guard !segments.isEmpty else {
            throw TranscriptionError(message: "no speech recognized in the file")
        }
        return Transcript(segments: segments, fineSegments: fine)
    }

    /// Scarica il modello per la lingua se non è già installato (una tantum).
    private static func ensureModelInstalled(
        for transcriber: SpeechTranscriber, locale: Locale
    ) async throws {
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        guard !installed.contains(locale.identifier(.bcp47)) else { return }

        appLog("⬇️ Downloading the transcription model for \(locale.identifier(.bcp47)) (one-time)…")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            // Possibile limite di lingue riservate: provo a riservare esplicitamente.
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        appLog("✅ Transcription model ready")
    }
}
