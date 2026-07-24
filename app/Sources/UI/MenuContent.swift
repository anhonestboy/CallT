import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var recorder = CallRecorder.shared

    var body: some View {
        Group {
            statusSection
            Divider()
            recordingSection
            Divider()
            Button(state.isMonitoring ? "Stop monitoring" : "Start monitoring") {
                state.toggleMonitoring()
            }
            Button("Transcribe files…") { state.enqueueManually() }
            Button("Process existing files") { state.processExistingFiles() }
            Divider()
            recentSection
            Button("Open recordings folder") { state.openWatchFolder() }
            Button("Open transcripts folder") { state.openOutputFolder() }
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("About CallT") { showAbout() }
            Button("Quit CallT") { state.quit() }
                .keyboardShortcut("q")
        }
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        func line(_ text: String, bold: Bool = false, link: String? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11),
                .paragraphStyle: center,
            ]
            if let link { attrs[.link] = link }
            credits.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        line(String(localized: "Created by Maurizio Palumbo — werootbox"), bold: true)
        line("github.com/anhonestboy/CallT", link: "https://github.com/anhonestboy/CallT")
        line("")
        line(String(localized: "Built with Claude Code (Anthropic)"))
        line(String(localized: "Recording: ScreenCaptureKit · Transcription: Apple Speech, whisper.cpp"))
        line(String(localized: "Notes: Apple Intelligence, Claude, OpenRouter, DeepSeek, Ollama"))
        line("")
        line(String(localized: "MIT license"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @ViewBuilder
    private var recordingSection: some View {
        if recorder.isRecording {
            if let started = recorder.startedAt {
                Text(String(localized: "Recording (since \(started.formatted(date: .omitted, time: .shortened)))"))
            }
            Button("⏹ Stop and transcribe") {
                Task { await recorder.stop() }
            }
        } else {
            Menu("⏺ Record call") {
                Button("Video and audio") {
                    Task { await recorder.start(mode: .videoAudio) }
                }
                Button("Audio only") {
                    Task { await recorder.start(mode: .audioOnly) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let job = state.currentJob {
            Text(verbatim: "\(job.stage.label) \(Int(job.progress * 100))% — \(job.displayName)")
        } else if state.isMonitoring {
            Text(String(localized: "Watching: \(AppSettings.watchFolder.lastPathComponent)"))
        } else {
            Text("Monitoring off")
        }
        if state.queuedCount > 0 {
            Text(String(localized: "Queued: \(state.queuedCount)"))
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let finished = state.jobs.filter(\.isFinished).suffix(5).reversed()
        if !finished.isEmpty {
            Menu("Recent") {
                ForEach(Array(finished)) { job in
                    Button {
                        if let url = job.transcriptURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text(verbatim: "\(job.stage == .done ? "✓" : "✗") \(job.displayName)")
                    }
                    .disabled(job.transcriptURL == nil)
                }
            }
            Divider()
        }
    }
}
