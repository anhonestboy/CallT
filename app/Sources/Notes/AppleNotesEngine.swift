import Foundation
import FoundationModels

/// Motore note on-device (Apple Intelligence, FoundationModels).
/// Gratuito e privato; contesto piccolo (~4k token) → il generatore
/// spezza automaticamente le trascrizioni lunghe.
struct AppleNotesEngine: NotesEngine {
    let maxPromptChars = 8_000

    static func ifAvailable() -> AppleNotesEngine? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return AppleNotesEngine()
    }

    /// Availability description for the Settings UI.
    static func availabilityDescription() -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return String(localized: "Apple Intelligence available ✓")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Apple Intelligence is not enabled (System Settings → Apple Intelligence)")
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac does not support Apple Intelligence")
        case .unavailable(.modelNotReady):
            return String(localized: "Model is being prepared (try again shortly)")
        case .unavailable:
            return String(localized: "Apple Intelligence unavailable")
        }
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        // Fresh session per call: no accumulated context.
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw TranscriptionError(message: "Apple model: \(error.localizedDescription)")
        }
    }
}
