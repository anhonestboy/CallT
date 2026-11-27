import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pannello principale della menu bar: avvio della sessione live (o il suo
/// stato se è in corso), coda di elaborazione, recenti, drag & drop di file.
struct PopoverView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var session = LiveSession.shared
    @ObservedObject private var panel = LivePanelController.shared
    @State private var dropTargeted = false
    @State private var detectedTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sessionCard
            if let job = state.currentJob {
                jobCard(job)
            }
            if state.queuedCount > 0 {
                Label(String(localized: "Queued: \(state.queuedCount)"), systemImage: "tray.full")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            recentsSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
        .background(dropOverlay)
        .dropDestination(for: URL.self) { urls, _ in
            let media = urls.filter { FolderWatcher.isVideo($0) }
            guard !media.isEmpty else { return false }
            for url in media { state.enqueue(url, force: true) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .task { await detectTarget() }
    }

    // MARK: - Intestazione

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(verbatim: "CallT").font(.title3.weight(.semibold))
            Spacer()
            Toggle(isOn: Binding(
                get: { state.isMonitoring },
                set: { _ in state.toggleMonitoring() })
            ) {
                Text(state.isMonitoring
                    ? String(localized: "Watching folder")
                    : String(localized: "Folder off"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(state.isMonitoring
                ? String(localized: "Watching: \(AppSettings.watchFolder.lastPathComponent)")
                : String(localized: "Monitoring off"))
        }
    }

    // MARK: - Sessione

    @ViewBuilder
    private var sessionCard: some View {
        switch session.phase {
        case .live, .starting:
            liveCard
        case .finishing(let message):
            HStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text(message).font(.body.weight(.medium))
                Spacer()
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        case .done(let folder):
            VStack(alignment: .leading, spacing: 10) {
                Label(String(localized: "Notes ready"), systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.green)
                HStack(spacing: 8) {
                    if let notes = session.notesFileURL {
                        BigButton(String(localized: "Open notes"), symbol: "note.text", prominent: true) {
                            NSWorkspace.shared.open(notes)
                        }
                    }
                    BigButton(String(localized: "Folder"), symbol: "folder") {
                        NSWorkspace.shared.open(folder)
                    }
                }
                startButtons(compact: true)
            }
            .padding(14)
            .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        default:
            startButtons(compact: false)
        }
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(verbatim: LiveTime.format(session.elapsed))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                Spacer()
                if session.notesBusy {
                    ProgressView().controlSize(.small)
                }
            }
            Text(session.targetDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                BigButton(panel.isVisible ? String(localized: "Hide panel") : String(localized: "Show panel"),
                          symbol: panel.isVisible ? "eye.slash" : "rectangle.inset.topright.filled") {
                    panel.toggle()
                }
                BigButton(String(localized: "Notes"), symbol: "note.text") {
                    panel.showTab(.notes)
                }
            }
            HStack(spacing: 8) {
                if session.hasVideo {
                    BigButton(String(localized: "Screenshot"), symbol: "camera") {
                        Task { await session.snapshot() }
                    }
                }
                BigButton(String(localized: "Mark"), symbol: "star") {
                    Task { await session.markMoment() }
                }
            }
            BigButton(String(localized: "Stop and write the notes"), symbol: "stop.fill", prominent: true, tint: .red) {
                Task { await session.stop() }
            }
        }
        .padding(14)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func startButtons(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BigButton(String(localized: "Start live session"), symbol: "record.circle", prominent: true) {
                Task { await session.start(mode: .video) }
            }
            .help(String(localized: "Global shortcut: ⌥⌘R"))
            HStack(spacing: 8) {
                BigButton(String(localized: "Audio only"), symbol: "waveform") {
                    Task { await session.start(mode: .audioOnly) }
                }
                BigButton(String(localized: "Choose window…"), symbol: "macwindow.badge.plus") {
                    WindowPicker.shared.pick()
                }
            }
            if !compact, let detectedTarget {
                Label(detectedTarget, systemImage: "viewfinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func detectTarget() async {
        guard !session.isActive, CGPreflightScreenCaptureAccess(),
              let target = try? await CaptureTargetResolver.resolve(AppSettings.liveCaptureTarget) else { return }
        detectedTarget = String(localized: "It will capture: \(target.description)")
    }

    // MARK: - Coda

    private func jobCard(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(job.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(verbatim: "\(job.stage.label) \(Int(job.progress * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Recenti

    @ViewBuilder
    private var recentsSection: some View {
        if !state.recents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(state.recents, id: \.sourcePath) { item in
                    recentRow(item)
                }
            }
        } else {
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Drop a video or audio file here to transcribe it")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.vertical, 16)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.quaternary))
        }
    }

    private func recentRow(_ item: ProcessedRegistry.RecentItem) -> some View {
        let notesPath = item.transcriptPath.map(AppState.notesPath(forTranscript:))
        let hasNotes = notesPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let title = Self.recentTitle(item)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.processedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasNotes, let notesPath {
                RowIconButton("note.text", help: String(localized: "Open notes")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: notesPath))
                }
            }
            if let transcript = item.transcriptPath {
                RowIconButton("doc.text", help: String(localized: "Open transcript")) {
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
                if FolderWatcher.isVideo(URL(fileURLWithPath: item.sourcePath)) {
                    Button(String(localized: "Process again")) {
                        state.enqueue(URL(fileURLWithPath: item.sourcePath), force: true)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Per le sessioni live il file sorgente è dentro la cartella della call:
    /// il nome della cartella è più parlante.
    private static func recentTitle(_ item: ProcessedRegistry.RecentItem) -> String {
        let url = URL(fileURLWithPath: item.sourcePath)
        let folder = url.deletingLastPathComponent()
        if item.transcriptPath.map({ URL(fileURLWithPath: $0).deletingLastPathComponent() == folder }) ?? false,
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path) {
            return folder.lastPathComponent
        }
        return item.displayName
    }

    // MARK: - Piè di pagina

    private var footer: some View {
        HStack(spacing: 6) {
            RowIconButton("folder", help: String(localized: "Open recordings folder")) {
                state.openWatchFolder()
            }
            RowIconButton("folder.badge.gearshape", help: String(localized: "Open transcripts folder")) {
                state.openOutputFolder()
            }
            RowIconButton("square.and.arrow.down", help: String(localized: "Transcribe files…")) {
                state.enqueueManually()
            }
            RowIconButton("clock.arrow.circlepath", help: String(localized: "History")) {
                HistoryWindow.show()
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Settings…"))
            RowIconButton("info.circle", help: String(localized: "About CallT")) {
                AboutPanel.show()
            }
            RowIconButton("power", help: String(localized: "Quit CallT")) {
                state.quit()
            }
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .background(Color.accentColor.opacity(0.06))
        }
    }
}

/// Pulsante grande a tutta larghezza (alto 36 pt).
struct BigButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var tint: Color?
    let action: () -> Void

    init(_ title: String, symbol: String, prominent: Bool = false, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.prominent = prominent
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(prominent ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .controlSize(.large)
        .modifier(ProminentStyle(prominent: prominent, tint: tint))
    }

    private struct ProminentStyle: ViewModifier {
        let prominent: Bool
        let tint: Color?
        func body(content: Content) -> some View {
            if prominent {
                content.buttonStyle(.borderedProminent).tint(tint ?? .accentColor)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

/// Icona cliccabile da 32×32 pt (prima erano icone .caption, difficili da colpire).
struct RowIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
