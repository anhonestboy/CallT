import Foundation

enum JobStage: String, Codable {
    case queued
    case extractingAudio
    case transcribing
    case summarizing
    case compressing
    case delivering
    case done
    case failed

    var label: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .extractingAudio: return String(localized: "Extracting audio")
        case .transcribing: return String(localized: "Transcribing")
        case .summarizing: return String(localized: "Notes")
        case .compressing: return String(localized: "Compressing")
        case .delivering: return String(localized: "Delivering")
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        }
    }
}

struct Job: Identifiable, Equatable {
    let id = UUID()
    let videoURL: URL
    var stage: JobStage = .queued
    /// 0…1 within the current stage (where available).
    var progress: Double = 0
    var error: String?
    var transcriptURL: URL?
    var startedAt: Date?
    var finishedAt: Date?

    var displayName: String { videoURL.lastPathComponent }
    var isFinished: Bool { stage == .done || stage == .failed }
}
