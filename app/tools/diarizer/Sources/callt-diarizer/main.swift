import Foundation
import FluidAudio

// callt-diarizer <audio.wav>
// Stampa su stdout JSON: {"segments":[{"speaker":"1","start":0.0,"end":3.2},…]}
// I modelli CoreML (~100MB) vengono scaricati da HuggingFace alla prima
// esecuzione e restano in ~/Library/Application Support/FluidAudio/Models.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: callt-diarizer <audio.wav>\n".utf8))
    exit(2)
}
let audioPath = arguments[1]

Task {
    do {
        let config = OfflineDiarizerConfig()
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(URL(fileURLWithPath: audioPath))

        let segments: [[String: Any]] = result.segments.map { segment in
            [
                "speaker": "\(segment.speakerId)",
                "start": segment.startTimeSeconds,
                "end": segment.endTimeSeconds,
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["segments": segments])
        FileHandle.standardOutput.write(payload)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
