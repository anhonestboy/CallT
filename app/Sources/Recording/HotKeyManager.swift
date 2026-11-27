import Foundation
import AppKit
import Carbon.HIToolbox

/// Scorciatoie globali (RegisterEventHotKey non richiede permessi di accessibilità):
/// - ⌥⌘R  avvia/ferma la sessione (ultima modalità usata)
/// - ⌃⌥N  mostra/nasconde il pannello live
/// - ⌃⌥S  screenshot
/// - ⌃⌥C  clip (ultimi secondi + i prossimi)
/// - ⌃⌥M  segna il momento
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    enum Action: UInt32, CaseIterable {
        case toggleRecording = 1, togglePanel, snapshot, clip, mark

        var key: Int {
            switch self {
            case .toggleRecording: return kVK_ANSI_R
            case .togglePanel: return kVK_ANSI_N
            case .snapshot: return kVK_ANSI_S
            case .clip: return kVK_ANSI_C
            case .mark: return kVK_ANSI_M
            }
        }

        var modifiers: Int {
            self == .toggleRecording ? (optionKey | cmdKey) : (controlKey | optionKey)
        }

        var display: String {
            switch self {
            case .toggleRecording: return "⌥⌘R"
            case .togglePanel: return "⌃⌥N"
            case .snapshot: return "⌃⌥S"
            case .clip: return "⌃⌥C"
            case .mark: return "⌃⌥M"
            }
        }

        var label: String {
            switch self {
            case .toggleRecording: return String(localized: "Start/stop the session")
            case .togglePanel: return String(localized: "Show/hide the live panel")
            case .snapshot: return String(localized: "Screenshot")
            case .clip: return String(localized: "Clip of the last seconds")
            case .mark: return String(localized: "Mark this moment")
            }
        }
    }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    func register() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let id = hotKeyID.id
                Task { @MainActor in HotKeyManager.perform(id) }
                return noErr
            },
            1, &eventType, nil, &handlerRef)

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x434C_5452) /* CLTR */, id: action.rawValue)
            RegisterEventHotKey(
                UInt32(action.key), UInt32(action.modifiers), hotKeyID,
                GetEventDispatcherTarget(), 0, &ref)
            if let ref { hotKeyRefs.append(ref) }
        }
    }

    private static func perform(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        let session = LiveSession.shared
        switch action {
        case .toggleRecording:
            Task {
                if session.isActive {
                    await session.stop()
                } else {
                    let last = AppSettings.defaults.string(forKey: "lastRecordMode") ?? "video"
                    await session.start(mode: last == "audioOnly" ? .audioOnly : .video)
                }
            }
        case .togglePanel:
            LivePanelController.shared.toggle()
        case .snapshot:
            Task { await session.snapshot() }
        case .clip:
            Task { await session.clip() }
        case .mark:
            Task { await session.markMoment() }
        }
    }
}
