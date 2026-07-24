import SwiftUI
import AppKit

/// Finestra Storico: tutte le call elaborate, con ricerca sia nei nomi
/// sia nel CONTENUTO di trascrizioni e note.
@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: HistoryView())
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 460)
        let w = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.title = String(localized: "History")
        w.contentView = host
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private struct HistoryView: View {
    @State private var items: [ProcessedRegistry.RecentItem] = []
    @State private var query = ""
    @State private var contentMatches: Set<String> = []   // sourcePath che matchano nel contenuto
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    private var filtered: [ProcessedRegistry.RecentItem] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        return items.filter {
            $0.displayName.lowercased().contains(q) || contentMatches.contains($0.sourcePath)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search by name or inside transcripts and notes"), text: $query)
                    .textFieldStyle(.plain)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35))

            if filtered.isEmpty {
                Spacer()
                Text(query.isEmpty
                    ? String(localized: "No processed calls yet.")
                    : String(localized: "No results for “\(query)”."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered, id: \.sourcePath) { item in
                    row(item)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { reload() }
        .onChange(of: query) { _, newValue in
            scheduleContentSearch(newValue)
        }
    }

    private func row(_ item: ProcessedRegistry.RecentItem) -> some View {
        let notesPath = item.transcriptPath.map(AppState.notesPath(forTranscript:))
        let hasNotes = notesPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        return HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(item.processedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hasNotes, let notesPath {
                Button(String(localized: "Notes")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: notesPath))
                }
                .controlSize(.small)
            }
            if let transcript = item.transcriptPath {
                Button(String(localized: "Transcript")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: transcript))
                }
                .controlSize(.small)
            }
            Menu {
                if let transcript = item.transcriptPath {
                    Button(String(localized: "Regenerate notes")) {
                        AppState.shared.regenerateNotes(transcriptPath: transcript)
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
                    AppState.shared.enqueue(URL(fileURLWithPath: item.sourcePath), force: true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        Task {
            items = await ProcessedRegistry.shared.recentDone(limit: 1000)
        }
    }

    /// Ricerca full-text (con debounce) dentro trascrizioni e note.
    private func scheduleContentSearch(_ text: String) {
        searchTask?.cancel()
        contentMatches = []
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return }
        let snapshot = items
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let needle = trimmed.lowercased()
            var matches: Set<String> = []
            for item in snapshot {
                guard !Task.isCancelled else { return }
                var paths: [String] = []
                if let t = item.transcriptPath {
                    paths.append(t)
                    paths.append(AppState.notesPath(forTranscript: t))
                }
                for path in paths {
                    if let text = try? String(contentsOfFile: path, encoding: .utf8),
                       text.lowercased().contains(needle) {
                        matches.insert(item.sourcePath)
                        break
                    }
                }
            }
            let found = matches
            await MainActor.run {
                contentMatches = found
                searching = false
            }
        }
    }
}
