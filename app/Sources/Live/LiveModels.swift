import Foundation

/// Chi parla, per come lo sappiamo in tempo reale: il microfono sei tu,
/// l'audio di sistema sono gli altri partecipanti. A fine call la
/// diarizzazione può dividere "gli altri" in persone distinte.
enum Speaker: String, Codable, Sendable {
    case me
    case others

    var label: String {
        switch self {
        case .me: return String(localized: "Me")
        case .others: return String(localized: "Others")
        }
    }
}

struct TranscriptLine: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var speaker: Speaker
    /// Etichetta più precisa dopo la diarizzazione ("Speaker 2"), se nota.
    var speakerName: String?
    var start: Double
    var end: Double
    var text: String

    var displaySpeaker: String { speakerName ?? speaker.label }
}

/// Materiale visivo salvato durante la call.
struct Capture: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case auto      // cambio di schermata rilevato
        case manual    // screenshot chiesto da te
        case clip      // mini registrazione video
        case mark      // momento segnato (con screenshot se c'è video)
    }

    var id: Int
    var kind: Kind
    var time: Double
    /// Percorso relativo alla cartella della sessione (es. "assets/007-shot.jpg").
    var file: String?
    var ocrText: String = ""
    var note: String = ""
    /// Già passato all'AI per le note live.
    var sentToAI = false

    var isImage: Bool { file.map { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") } ?? false }
}

struct ChatItem: Identifiable, Sendable, Equatable {
    enum Role: Sendable { case question, answer, note, error }
    let id = UUID()
    let role: Role
    var text: String
    let time: Double
}

enum LiveTime {
    /// 75 → "01:15", 3725 → "1:02:05".
    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Sempre hh:mm:ss, per il materiale passato all'AI e i file.
    static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
