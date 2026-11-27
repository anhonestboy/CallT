import Foundation
import AVFoundation
import CoreMedia

/// Conversioni audio per la sessione live: CMSampleBuffer (ScreenCaptureKit,
/// AVCapture, AVAssetReader) → AVAudioPCMBuffer nel formato richiesto da chi
/// consuma (SpeechAnalyzer, file WAV per la diarizzazione).
enum AudioTools {
    /// Copia i campioni PCM di un CMSampleBuffer in un AVAudioPCMBuffer con il
    /// suo formato nativo. Nil se il buffer non è PCM o è vuoto.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferIsValid(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// Converte flussi PCM di formato arbitrario verso un formato fisso,
/// ricostruendo il convertitore se il formato d'ingresso cambia (es. cambio
/// di microfono a metà call). Non thread-safe: usarlo da una sola coda.
final class StreamingConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if inputFormat == nil || inputFormat! != input.format {
            inputFormat = input.format
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        if input.format == outputFormat { return input }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Scrive un WAV 16 kHz mono (formato atteso dal diarizzatore) a partire da
/// buffer PCM qualsiasi. Usato per l'audio "degli altri" durante la call.
final class WAVTap {
    private let file: AVAudioFile
    private let converter: StreamingConverter

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        converter = StreamingConverter(outputFormat: file.processingFormat)
    }

    private var framesWritten: AVAudioFramePosition = 0

    /// `time` è l'istante (secondi dall'inizio sessione) del primo campione:
    /// se l'audio ha buchi (silenzio non consegnato) li riempie di zeri, così
    /// i tempi del WAV restano allineati a quelli della trascrizione.
    func write(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard let converted = converter.convert(buffer) else { return }
        let rate = file.processingFormat.sampleRate
        let expected = AVAudioFramePosition(max(0, time) * rate)
        var gap = expected - framesWritten
        while gap > AVAudioFramePosition(rate / 10) {
            let chunk = AVAudioFrameCount(min(gap, AVAudioFramePosition(rate)))
            guard let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            silence.frameLength = chunk
            try? file.write(from: silence)
            framesWritten += AVAudioFramePosition(chunk)
            gap -= AVAudioFramePosition(chunk)
        }
        try? file.write(from: converted)
        framesWritten += AVAudioFramePosition(converted.frameLength)
    }
}
