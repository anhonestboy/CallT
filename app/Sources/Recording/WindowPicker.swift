import Foundation
import AppKit
import ScreenCaptureKit

/// Picker di sistema per registrare una singola finestra o area:
/// alla scelta, avvia la registrazione con quel filtro.
@MainActor
final class WindowPicker: NSObject, ObservableObject {
    static let shared = WindowPicker()

    func pick() {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
    }
}

extension WindowPicker: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        nonisolated(unsafe) let chosen = filter
        Task { @MainActor in
            SCContentSharingPicker.shared.isActive = false
            await CallRecorder.shared.start(mode: .videoAudio, filter: chosen)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            SCContentSharingPicker.shared.isActive = false
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        appLog("⚠️ Content picker failed: \(error.localizedDescription)")
    }
}
