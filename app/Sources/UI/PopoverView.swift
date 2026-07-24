import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pannello principale della menu bar (stile finestra): stato live,
/// registrazione, coda con barra di avanzamento, recenti con azioni,
/// drag & drop di file da trascrivere.
struct PopoverView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var recorder = CallRecorder.shared
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordCard
            if let job = state.currentJob {
                jobCard(job)
            }
            if state.queuedCount > 0 {
                Label(String(localized: "Queued: \(state.queuedCount)"), systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            recentsSection
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(dropOverlay)
        .dropDestination(for: URL.self) { urls, _ in
            let media = urls.filter { FolderWatcher.isVideo($0) }
            guard !media.isEmpty else { return false }
            for url in media { state.enqueue(url, force: true) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Sezioni

    private var header: some View {
        HStack {
            Circle()
                .fill(state.isMonitoring ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(state.isMonitoring
                ? String(localized: "Watching: \(AppSettings.watchFolder.lastPathComponent)")
                : String(localized: "Monitoring off"))
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.isMonitoring },
                set: { _ in state.toggleMonitoring() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private var recordCard: some View {
        Group {
            if recorder.isRecording {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    if let started = recorder.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Self.elapsed(since: started))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    Spacer()
                    Button {
                        Task { await recorder.stop() }
                    } label: {
                        Label(String(localized: "Stop and transcribe"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 8) {
                    Button {
                        Task { await recorder.start(mode: .videoAudio) }
                    } label: {
                        Label(String(localized: "Record"), systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Button {
                        Task { await recorder.start(mode: .audioOnly) }
                    } label: {
                        Label(String(localized: "Audio only"), systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    Button {
                        WindowPicker.shared.pick()
                    } label: {
                        Image(systemName: "macwindow.badge.plus")
                    }
                    .controlSize(.regular)
                    .help(String(localized: "Record a single window…"))
                }
                .help(String(localized: "Global shortcut: ⌥⌘R"))
            }
        }
    }

    private func jobCard(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(job.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(verbatim: "\(job.stage.label) \(Int(job.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !state.recents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(state.recents, id: \.sourcePath) { item in
                    recentRow(item)
                }
            }
        } else {
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Drop a video or audio file here to transcribe it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.quaternary))
        }
    }

    private func recentRow(_ item: ProcessedRegistry.RecentItem) -> some View {
        let notesPath = item.transcriptPath.map(AppState.notesPath(forTranscript:))
        let hasNotes = notesPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.processedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasNotes, let notesPath {
                iconButton("note.text", help: String(localized: "Open notes")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: notesPath))
                }
            }
            if let transcript = item.transcriptPath {
                iconButton("doc.text", help: String(localized: "Open transcript")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: transcript))
                }
            }
            Menu {
                if let transcript = item.transcriptPath {
                    Button(String(localized: "Regenerate notes")) {
                        state.regenerateNotes(transcriptPath: transcript)
                    }
                    Button(String(localized: "Copy transcript")) {
                        if let text = try? String(contentsOfFile: transcript, encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                }
                Button(String(localized: "Show in Finder")) {
                    let target = item.transcriptPath ?? item.sourcePath
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
                }
                Button(String(localized: "Process again")) {
                    state.enqueue(URL(fileURLWithPath: item.sourcePath), force: true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.vertical, 3)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            iconButton("folder", help: String(localized: "Open recordings folder")) {
                state.openWatchFolder()
            }
            iconButton("folder.badge.gearshape", help: String(localized: "Open transcripts folder")) {
                state.openOutputFolder()
            }
            iconButton("square.and.arrow.down", help: String(localized: "Transcribe files…")) {
                state.enqueueManually()
            }
            iconButton("clock.arrow.circlepath", help: String(localized: "History")) {
                HistoryWindow.show()
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Settings…"))
            iconButton("info.circle", help: String(localized: "About CallT")) {
                AboutPanel.show()
            }
            iconButton("power", help: String(localized: "Quit CallT")) {
                state.quit()
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .background(Color.accentColor.opacity(0.06))
        }
    }

    private static func elapsed(since date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
