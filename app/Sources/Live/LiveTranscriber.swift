import Foundation
import AVFoundation
import Speech
import CoreMedia

/// Trascrizione in streaming di una sorgente audio (la tua voce o quella degli
/// altri) con SpeechAnalyzer: risultati "volatili" mentre si parla, poi finali.
/// I tempi sono in secondi dall'inizio della sessione.
final class LiveTranscriber: @unchecked Sendable {
    struct Update: Sendable {
        let speaker: Speaker
        let text: String
        let start: Double
        let end: Double
        let isFinal: Bool
    }

    let speaker: Speaker
    private let onUpdate: @Sendable (Update) -> Void
    private let queue = DispatchQueue(label: "com.werootbox.callt.live.transcriber")

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: StreamingConverter?
    private var resultsTask: Task<Void, Never>?
    private var started = false

    init(speaker: Speaker, onUpdate: @escaping @Sendable (Update) -> Void) {
        self.speaker = speaker
        self.onUpdate = onUpdate
    }

    func start(language: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language))
        else {
            throw TranscriptionError(message: "language “\(language)” is not supported by the Apple engine")
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        try await AppleTranscriber.ensureModelInstalled(for: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError(message: "no audio format available for live transcription")
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        try await analyzer.start(inputSequence: stream)

        let speaker = self.speaker
        let onUpdate = self.onUpdate
        let results = transcriber.results
        resultsTask = Task.detached {
            do {
                for try await result in results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    guard start.isFinite else { continue }
                    onUpdate(Update(
                        speaker: speaker, text: text,
                        start: start, end: end.isFinite ? end : start,
                        isFinal: result.isFinal))
                }
            } catch {
                appLog("⚠️ Live transcription (\(speaker.rawValue)) stopped: \(error.localizedDescription)")
            }
        }

        queue.sync {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.continuation = continuation
            self.converter = StreamingConverter(outputFormat: format)
            self.started = true
        }
    }

    private var nextStart: Double?

    /// Accoda un buffer audio; `time` = secondi dall'inizio sessione.
    ///
    /// SpeechAnalyzer rifiuta timestamp che si sovrappongono anche di un
    /// campione, e il ricampionamento non produce esattamente la durata dei
    /// PTS: il tempo avanza quindi per campioni contati, e salta in avanti
    /// solo se nei PTS c'è un vero buco (silenzio non consegnato).
    func append(_ buffer: AVAudioPCMBuffer, at time: Double) {
        queue.async { [self] in
            guard started, let converter, let continuation,
                  let converted = converter.convert(buffer) else { return }
            let rate = converted.format.sampleRate
            var start = nextStart ?? max(0, time)
            if time - start > 0.25 { start = time }
            nextStart = start + Double(converted.frameLength) / rate
            continuation.yield(AnalyzerInput(
                buffer: converted,
                bufferStartTime: CMTime(value: CMTimeValue((start * rate).rounded()),
                                        timescale: CMTimeScale(rate))))
        }
    }

    /// Chiude l'ingresso e attende i risultati finali di quanto già detto.
    func finish() async {
        let analyzer: SpeechAnalyzer? = queue.sync {
            started = false
            continuation?.finish()
            continuation = nil
            return self.analyzer
        }
        guard let analyzer else { return }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        _ = await resultsTask?.value
    }
}
