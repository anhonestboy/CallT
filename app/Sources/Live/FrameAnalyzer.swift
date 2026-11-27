import Foundation
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Guarda il video della call ~2 volte al secondo e decide quando salvare uno
/// screenshot: lo schermo è cambiato in modo netto rispetto all'ultimo salvato,
/// poi è rimasto fermo per un attimo (niente transizioni a metà), e contiene
/// testo leggibile (slide, documenti, codice — non i volti in galleria).
/// Il testo viene estratto con l'OCR on-device di Vision.
final class FrameAnalyzer: @unchecked Sendable {
    struct Shot: Sendable {
        let time: Double
        let jpeg: Data
        let ocrText: String
        let automatic: Bool
    }

    enum Sensitivity: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String {
            switch self {
            case .low: return String(localized: "Low (only big changes)")
            case .medium: return String(localized: "Medium")
            case .high: return String(localized: "High (every slide)")
            }
        }
        /// Quota di pixel cambiati (0…1) che conta come "nuova schermata".
        /// Due slide con lo stesso modello differiscono solo nel testo: la
        /// luminanza media cambia poco, ma una buona parte dei pixel sì.
        var changeThreshold: Float {
            switch self {
            case .low: return 0.05
            case .medium: return 0.03
            case .high: return 0.012
            }
        }
    }

    private let queue = DispatchQueue(label: "com.werootbox.callt.live.frames", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onShot: @Sendable (Shot) -> Void
    var autoEnabled: Bool
    var sensitivity: Sensitivity

    private var lastSample: Double = -10
    private var previousThumb: [Float]?
    private var savedThumb: [Float]?
    private var stableSince: Double?
    private var lastAutoShot: Double = -1000
    private var lastAutoText: Set<String> = []
    private var latest: (buffer: CVPixelBuffer, time: Double)?
    private var busy = false

    private let thumbW = 128
    private let thumbH = 72
    private let minGapBetweenAutoShots: Double = 8
    private let stableFor: Double = 1.5
    private let minTextChars = 40

    init(autoEnabled: Bool, sensitivity: Sensitivity, onShot: @escaping @Sendable (Shot) -> Void) {
        self.autoEnabled = autoEnabled
        self.sensitivity = sensitivity
        self.onShot = onShot
    }

    /// Frame dal flusso video; `time` = secondi dall'inizio sessione.
    func ingest(_ sampleBuffer: CMSampleBuffer, time: Double) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        queue.async { [self] in
            latest = (pixels, time)
            guard time - lastSample >= 0.5, !busy else { return }
            lastSample = time
            analyze(pixels, time: time)
        }
    }

    /// Screenshot immediato dell'ultimo frame (pulsante o scorciatoia).
    func captureNow() async -> Shot? {
        await withCheckedContinuation { (cont: CheckedContinuation<Shot?, Never>) in
            queue.async { [self] in
                guard let latest else { cont.resume(returning: nil); return }
                cont.resume(returning: makeShot(latest.buffer, time: latest.time, automatic: false))
            }
        }
    }

    // MARK: - Rilevamento cambi scena (sulla coda)

    private func analyze(_ pixels: CVPixelBuffer, time: Double) {
        guard autoEnabled, let thumb = thumbnail(pixels) else { return }
        defer { previousThumb = thumb }
        guard let saved = savedThumb else {
            // Primo frame: riferimento iniziale, poi si valuta come gli altri.
            savedThumb = thumb.map { _ in -1 }
            return
        }
        let motion = previousThumb.map { Self.changedFraction($0, thumb) } ?? 1
        let change = Self.changedFraction(saved, thumb)

        guard change >= sensitivity.changeThreshold else {
            stableSince = nil
            return
        }
        // Cambiato: aspetta che smetta di muoversi.
        if motion > 0.006 {
            stableSince = nil
            return
        }
        if stableSince == nil { stableSince = time }
        guard let since = stableSince, time - since >= stableFor,
              time - lastAutoShot >= minGapBetweenAutoShots else { return }
        stableSince = nil

        busy = true
        defer { busy = false }
        guard let shot = makeShot(pixels, time: time, automatic: true) else { return }
        // Niente testo → probabilmente volti/video: aggiorna il riferimento e basta.
        savedThumb = thumb
        let words = Self.words(shot.ocrText)
        guard shot.ocrText.count >= minTextChars else { return }
        // Stessa slide (es. cambia solo la miniatura di chi parla): salta.
        if Self.jaccard(words, lastAutoText) > 0.8 { return }
        lastAutoShot = time
        lastAutoText = words
        onShot(shot)
    }

    private func thumbnail(_ pixels: CVPixelBuffer) -> [Float]? {
        let image = CIImage(cvPixelBuffer: pixels)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(thumbW) / extent.width, y: CGFloat(thumbH) / extent.height))
        var bytes = [UInt8](repeating: 0, count: thumbW * thumbH * 4)
        context.render(scaled, toBitmap: &bytes, rowBytes: thumbW * 4,
                       bounds: CGRect(x: 0, y: 0, width: thumbW, height: thumbH),
                       format: .RGBA8, colorSpace: nil)
        var luma = [Float](repeating: 0, count: thumbW * thumbH)
        for i in 0..<(thumbW * thumbH) {
            let r = Float(bytes[i * 4]), g = Float(bytes[i * 4 + 1]), b = Float(bytes[i * 4 + 2])
            luma[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        return luma
    }

    /// Quota di pixel la cui luminanza è cambiata in modo percepibile.
    private static func changedFraction(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in 0..<a.count where abs(a[i] - b[i]) > 0.08 { changed += 1 }
        return Float(changed) / Float(a.count)
    }

    // MARK: - Salvataggio + OCR

    private func makeShot(_ pixels: CVPixelBuffer, time: Double, automatic: Bool) -> Shot? {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let text = Self.recognizeText(cg)
        guard let jpeg = Self.jpeg(cg, maxSide: 1920, quality: 0.8) else { return nil }
        return Shot(time: time, jpeg: jpeg, ocrText: text, automatic: automatic)
    }

    static func recognizeText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    static func jpeg(_ image: CGImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let longest = CGFloat(max(image.width, image.height))
        var source = image
        if longest > maxSide {
            let k = maxSide / longest
            let w = Int(CGFloat(image.width) * k), h = Int(CGFloat(image.height) * k)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let resized = ctx.makeImage() { source = resized }
            }
        }
        CGImageDestinationAddImage(dest, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
