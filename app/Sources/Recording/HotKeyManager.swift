import Foundation
import AppKit
import Carbon.HIToolbox

/// Scorciatoia globale ⌥⌘R: avvia/ferma la registrazione con l'ultima
/// modalità usata. RegisterEventHotKey non richiede permessi di accessibilità.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in
                    let recorder = CallRecorder.shared
                    if recorder.isRecording {
                        await recorder.stop()
                    } else {
                        let last = AppSettings.defaults.string(forKey: "lastRecordMode") ?? "videoAudio"
                        await recorder.start(mode: last == "audioOnly" ? .audioOnly : .videoAudio)
                    }
                }
                return noErr
            },
            1, &eventType, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_5452) /* CLTR */, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0, &hotKeyRef)
    }
}
