import Foundation
import AVFoundation

/// Cattura del microfono via AVCapture, non via ScreenCaptureKit.
///
/// SCK si prende il dispositivo di ingresso e ne forza la configurazione:
/// durante una call questo rompe la Voice Processing dell'app di WebRTC
/// (l'echo cancellation smette di funzionare) e la qualità della call crolla.
/// AVCapture legge lo stesso dispositivo senza riconfigurarlo, quindi la call
/// mantiene il suo percorso, e segue da solo il microfono predefinito quando
/// cambia (cuffie collegate o scollegate).
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.werootbox.callt.recording.mic")
    private var onBuffer: ((CMSampleBuffer) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    /// Avvia la cattura. Ritorna false se non c'è un microfono usabile: in quel
    /// caso si registra solo l'audio di sistema, senza far fallire la call.
    func start(onBuffer: @escaping (CMSampleBuffer) -> Void) -> Bool {
        var ok = false
        queue.sync {
            self.onBuffer = onBuffer
            ok = self.configure()
            if ok {
                if !self.session.isRunning { self.session.startRunning() }
                self.isRunning = self.session.isRunning
            }
        }
        if ok { observeDevices() }
        return ok
    }

    func stop() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        queue.sync {
            if session.isRunning { session.stopRunning() }
            isRunning = false
            onBuffer = nil
        }
    }

    /// Cambio del dispositivo predefinito: ricostruisce l'input e riparte.
    private func observeDevices() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification,
                     AVCaptureDevice.wasDisconnectedNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.rebuildAfterDeviceChange() }
            }
            observers.append(token)
        }
    }

    private func rebuildAfterDeviceChange() {
        guard isRunning else { return }
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        guard configure() else { return }
        if !session.isRunning { session.startRunning() }
        appLog("🎙️ Dispositivo di ingresso cambiato: microfono riagganciato")
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }

        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            appLog("⚠️ Nessun microfono disponibile: registro solo l'audio di sistema")
            return false
        }
        session.addInput(input)

        if session.outputs.isEmpty {
            // PCM 48 kHz stereo interleaved: il formato che il writer AAC si
            // aspetta, così non c'è conversione a valle.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                appLog("⚠️ Uscita audio del microfono non disponibile")
                return false
            }
            session.addOutput(output)
        }

        session.commitConfiguration()
        appLog("🎙️ Microfono agganciato: \(device.localizedName)")
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onBuffer?(sampleBuffer)
    }
}
