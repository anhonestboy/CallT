import Foundation

/// Chiavi e accesso alle impostazioni persistenti (UserDefaults).
/// Le view usano @AppStorage con le stesse chiavi; il motore legge da qui.
enum SettingsKey {
    static let watchFolder = "watchFolder"
    static let outputFolder = "outputFolder"
    static let language = "language"
    static let engine = "engine"
    static let whisperModelPath = "whisperModelPath"
    static let compressVideo = "compressVideo"
    static let compressionQuality = "compressionQuality"
    static let downscaleTo1080 = "downscaleTo1080"
    static let deleteOriginal = "deleteOriginal"
    static let keepAudio = "keepAudio"
    static let generateSRT = "generateSRT"
    static let deliveryShortcut = "deliveryShortcut"
    static let monitoringEnabled = "monitoringEnabled"
    static let notifyOnComplete = "notifyOnComplete"
    /// Cartelle già inizializzate: i loro file preesistenti sono stati sigillati
    /// una tantum; ai riavvii successivi i file non elaborati vengono ripresi.
    static let initializedFolders = "initializedFolders"
    static let notesEnabled = "notesEnabled"
    /// "apple" | "claude" | "openrouter" | "deepseek" | "ollama" | "custom"
    static let notesEngine = "notesEngine"
    static let notesBaseURL = "notesBaseURL"
    /// "normal" | "detailed" | "verydetailed"
    static let notesDetail = "notesDetail"
    static let notesTimestamps = "notesTimestamps"
}

enum TranscriptionEngineKind: String, CaseIterable, Identifiable {
    case apple
    case whisper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return String(localized: "Apple (built-in, recommended)")
        case .whisper: return String(localized: "Whisper (requires whisper-cli)")
        }
    }
}

enum CompressionQuality: String, CaseIterable, Identifiable {
    case alta, media, bassa
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alta: return String(localized: "High (larger files)")
        case .media: return String(localized: "Medium (recommended)")
        case .bassa: return String(localized: "Low (smaller files)")
        }
    }
    /// Bit per pixel·frame target per HEVC: determina il bitrate in base a risoluzione e fps.
    var bitsPerPixel: Double {
        switch self {
        case .alta: return 0.085
        case .media: return 0.055
        case .bassa: return 0.035
        }
    }
}

struct AppSettings {
    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.watchFolder: NSString("~/CallRecordings").expandingTildeInPath,
            SettingsKey.outputFolder: "",
            SettingsKey.language: Locale.current.identifier(.bcp47),
            SettingsKey.engine: TranscriptionEngineKind.apple.rawValue,
            SettingsKey.whisperModelPath: NSString("~/.calltranscriber/models/ggml-large-v3-turbo.bin").expandingTildeInPath,
            SettingsKey.compressVideo: true,
            SettingsKey.compressionQuality: CompressionQuality.media.rawValue,
            SettingsKey.downscaleTo1080: true,
            SettingsKey.deleteOriginal: false,
            SettingsKey.keepAudio: false,
            SettingsKey.generateSRT: false,
            SettingsKey.deliveryShortcut: "",
            SettingsKey.monitoringEnabled: false,
            SettingsKey.notifyOnComplete: true,
            SettingsKey.notesEnabled: true,
            SettingsKey.notesEngine: "apple",
            SettingsKey.notesBaseURL: "",
            SettingsKey.notesDetail: "normal",
            SettingsKey.notesTimestamps: true,
        ])
    }

    static var watchFolder: URL {
        URL(fileURLWithPath: defaults.string(forKey: SettingsKey.watchFolder) ?? NSString("~/CallRecordings").expandingTildeInPath)
    }
    static var outputFolder: URL {
        let raw = defaults.string(forKey: SettingsKey.outputFolder) ?? ""
        return raw.isEmpty ? watchFolder.appendingPathComponent("output") : URL(fileURLWithPath: raw)
    }
    static var language: String { defaults.string(forKey: SettingsKey.language) ?? "it-IT" }
    static var engine: TranscriptionEngineKind {
        TranscriptionEngineKind(rawValue: defaults.string(forKey: SettingsKey.engine) ?? "") ?? .apple
    }
    static var whisperModelPath: String { defaults.string(forKey: SettingsKey.whisperModelPath) ?? "" }
    static var compressVideo: Bool { defaults.bool(forKey: SettingsKey.compressVideo) }
    static var compressionQuality: CompressionQuality {
        CompressionQuality(rawValue: defaults.string(forKey: SettingsKey.compressionQuality) ?? "") ?? .media
    }
    static var downscaleTo1080: Bool { defaults.bool(forKey: SettingsKey.downscaleTo1080) }
    static var deleteOriginal: Bool { defaults.bool(forKey: SettingsKey.deleteOriginal) }
    static var keepAudio: Bool { defaults.bool(forKey: SettingsKey.keepAudio) }
    static var generateSRT: Bool { defaults.bool(forKey: SettingsKey.generateSRT) }
    static var deliveryShortcut: String { defaults.string(forKey: SettingsKey.deliveryShortcut) ?? "" }
    static var monitoringEnabled: Bool { defaults.bool(forKey: SettingsKey.monitoringEnabled) }
    static var notifyOnComplete: Bool { defaults.bool(forKey: SettingsKey.notifyOnComplete) }

    static var notesEnabled: Bool { defaults.bool(forKey: SettingsKey.notesEnabled) }
    static var notesEngine: String { defaults.string(forKey: SettingsKey.notesEngine) ?? "apple" }
    static var notesBaseURL: String { defaults.string(forKey: SettingsKey.notesBaseURL) ?? "" }
    static var notesDetail: String { defaults.string(forKey: SettingsKey.notesDetail) ?? "normal" }
    static var notesTimestamps: Bool { defaults.bool(forKey: SettingsKey.notesTimestamps) }

    /// Modello per motore di note (chiave dedicata per motore, con default sensato).
    static func notesModel(for engine: String) -> String {
        if let stored = defaults.string(forKey: "notesModel-\(engine)"), !stored.isEmpty {
            return stored
        }
        if engine == "claude" { return "claude-opus-4-8" }
        return OpenAICompatEngine.provider(engine)?.defaultModel ?? ""
    }

    static func setNotesModel(_ model: String, for engine: String) {
        defaults.set(model, forKey: "notesModel-\(engine)")
    }

    /// Cartella dati dell'app (registro, log).
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallT", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
