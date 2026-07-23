import Foundation
import AppIntents
import UniformTypeIdentifiers

/// Azione esposta all'app Comandi Rapidi: trascrive un file su richiesta
/// e restituisce il .txt, componibile in qualsiasi automazione.
struct TranscribeVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Trascrivi video"
    static let description = IntentDescription(
        "Trascrive on-device l'audio di un file video o audio e restituisce il testo.",
        categoryName: "Trascrizione")
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "File",
        description: "Il file video o audio da trascrivere.",
        supportedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .audio, .mpeg4Audio, .wav])
    var media: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Trascrivi \(\.$media)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("callt-intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL: URL
        if let url = media.fileURL {
            inputURL = url
        } else {
            inputURL = tempDir.appendingPathComponent(media.filename)
            try media.data.write(to: inputURL)
        }

        // File audio puri passano diretti; dai video si estrae la traccia.
        let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aif", "aiff", "caf", "flac"]
        let isAudio = audioExtensions.contains(inputURL.pathExtension.lowercased())

        let engine: TranscriptionEngine
        var audioURL = inputURL
        if AppSettings.engine == .whisper, let whisper = WhisperTranscriber.detect() {
            engine = whisper
            if !isAudio || inputURL.pathExtension.lowercased() != "wav" {
                let wav = tempDir.appendingPathComponent("audio.wav")
                try await AudioExtractor.extractWAV(from: inputURL, to: wav)
                audioURL = wav
            }
        } else {
            engine = AppleTranscriber()
            if !isAudio {
                let m4a = tempDir.appendingPathComponent("audio.m4a")
                try await AudioExtractor.exportM4A(from: inputURL, to: m4a)
                audioURL = m4a
            }
        }

        let transcript = try await engine.transcribe(
            audioURL: audioURL, language: AppSettings.language, progress: { _ in })

        let outName = (media.filename as NSString).deletingPathExtension + "_trascrizione.txt"
        let outFile = IntentFile(
            data: Data(transcript.text.utf8), filename: outName, type: .plainText)
        return .result(value: outFile, dialog: "Trascrizione completata: \(media.filename)")
    }
}

struct CallTShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranscribeVideoIntent(),
            phrases: [
                "Trascrivi un video con \(.applicationName)",
                "\(.applicationName) trascrivi",
            ],
            shortTitle: "Trascrivi video",
            systemImageName: "waveform")
    }
}
