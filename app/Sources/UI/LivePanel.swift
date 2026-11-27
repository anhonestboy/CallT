import SwiftUI
import AppKit
import Combine

/// Pannello galleggiante della sessione live. Due forme:
/// - compatta: una barra con timer e azioni rapide (screenshot, clip, segna);
/// - espansa: note live, trascrizione, catture e una chat per fare domande o
///   aggiungere note tue.
/// Si nasconde (⌃⌥N o dal menu) senza fermare nulla, e si nasconde da solo
/// quando condividi lo schermo. È esclusa dalle catture di Recap stessa.
@MainActor
final class LivePanelController: ObservableObject {
    static let shared = LivePanelController()

    @Published private(set) var isVisible = false
    @Published var expanded = AppSettings.livePanelExpanded {
        didSet {
            AppSettings.defaults.set(expanded, forKey: SettingsKey.livePanelExpanded)
            layout(animated: true)
        }
    }
    @Published var tab: LivePanelTab = .notes

    private var panel: LivePanelWindow?
    private var hiddenForSharing = false
    private var cancellables: Set<AnyCancellable> = []

    private let expandedDefault = NSSize(width: 440, height: 640)

    init() {
        ScreenShareWatcher.shared.$isSharing
            .removeDuplicates()
            .sink { sharing in
                Task { @MainActor in LivePanelController.shared.sharingChanged(sharing) }
            }
            .store(in: &cancellables)
    }

    func sessionStarted() {
        if AppSettings.liveShowPanel { show() }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        hiddenForSharing = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(animated: false)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func close() {
        hide()
        panel = nil
        LiveSession.shared.dismissResult()
    }

    func showTab(_ tab: LivePanelTab) {
        self.tab = tab
        if !expanded { expanded = true }
        show()
    }

    private func sharingChanged(_ sharing: Bool) {
        if sharing, isVisible {
            hiddenForSharing = true
            panel?.orderOut(nil)
            isVisible = false
        } else if !sharing, hiddenForSharing {
            show()
        }
    }

    private func makePanel() -> LivePanelWindow {
        let host = NSHostingView(rootView: LivePanelView()
            .environmentObject(LiveSession.shared)
            .environmentObject(self))
        host.sizingOptions = []
        let panel = LivePanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        panel.contentView = host
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Non leggibile da altri processi (vecchie API di cattura). Le app che
        // usano ScreenCaptureKit possono comunque vederla: per questo il
        // pannello si nasconde da solo quando condividi lo schermo.
        panel.sharingType = .none
        panel.delegate = panel
        return panel
    }

    /// Dimensiona il pannello sul contenuto (compatto) o sulla misura salvata
    /// (espanso), tenendo fermo l'angolo in alto a destra.
    func layout(animated: Bool) {
        guard let panel, let host = panel.contentView else { return }
        let size: NSSize
        if expanded {
            let w = AppSettings.defaults.double(forKey: "livePanelWidth")
            let h = AppSettings.defaults.double(forKey: "livePanelHeight")
            size = NSSize(width: w > 300 ? w : expandedDefault.width, height: h > 300 ? h : expandedDefault.height)
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 360, height: 360)
            panel.maxSize = NSSize(width: 1200, height: 2000)
        } else {
            // La barra compatta si adatta al contenuto: niente bordi da
            // trascinare né cursore di ridimensionamento.
            panel.styleMask.remove(.resizable)
            let fitting = host.fittingSize
            size = NSSize(width: max(fitting.width, 300), height: max(fitting.height, 52))
            panel.minSize = size
            panel.maxSize = size
        }
        var frame = panel.frame
        let screen = panel.screen ?? NSScreen.main
        if !panel.hasBeenPlaced, let visible = screen?.visibleFrame {
            let savedX = AppSettings.defaults.object(forKey: "livePanelTopRightX") as? Double
            let savedY = AppSettings.defaults.object(forKey: "livePanelTopRightY") as? Double
            let topRight = NSPoint(x: savedX ?? Double(visible.maxX - 16), y: savedY ?? Double(visible.maxY - 12))
            frame.origin = NSPoint(x: topRight.x - size.width, y: topRight.y - size.height)
            panel.hasBeenPlaced = true
        } else {
            frame.origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        }
        frame.size = size
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }

    /// Il contenuto compatto è cambiato (es. testo di stato): riadatta.
    func refit() {
        guard !expanded else { return }
        layout(animated: false)
    }
}

enum LivePanelTab: String, CaseIterable, Identifiable {
    case notes, transcript, captures, chat
    var id: String { rawValue }
    var label: String {
        switch self {
        case .notes: return String(localized: "Notes")
        case .transcript: return String(localized: "Transcript")
        case .captures: return String(localized: "Captures")
        case .chat: return String(localized: "Ask")
        }
    }
    var symbol: String {
        switch self {
        case .notes: return "note.text"
        case .transcript: return "text.quote"
        case .captures: return "photo.on.rectangle"
        case .chat: return "bubble.left.and.text.bubble.right"
        }
    }
}

final class LivePanelWindow: NSPanel, NSWindowDelegate {
    var hasBeenPlaced = false
    // Serve per scrivere nel campo di testo senza attivare l'app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowDidEndLiveResize(_ notification: Notification) {
        if LivePanelController.shared.expanded {
            AppSettings.defaults.set(Double(frame.width), forKey: "livePanelWidth")
            AppSettings.defaults.set(Double(frame.height), forKey: "livePanelHeight")
        }
        saveFrame()
    }

    private func saveFrame() {
        AppSettings.defaults.set(Double(frame.maxX), forKey: "livePanelTopRightX")
        AppSettings.defaults.set(Double(frame.maxY), forKey: "livePanelTopRightY")
    }
}

// MARK: - Vista

/// Scala tipografica del pannello: poche taglie, pesi netti, cifre fisse.
enum PanelType {
    static let timer = Font.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit()
    static let status = Font.system(size: 11.5, weight: .regular)
    static let body = Font.system(size: 13.5)
    static let label = Font.system(size: 10.5, weight: .semibold)
    static let meta = Font.system(size: 11).monospacedDigit()
    static let tab = Font.system(size: 12, weight: .medium)
}

struct LivePanelView: View {
    @EnvironmentObject private var session: LiveSession
    @EnvironmentObject private var controller: LivePanelController

    private let radius: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            if controller.expanded { Grabber() }
            LivePanelHeader()
            if controller.expanded {
                LivePanelBody()
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .allowsWindowActivationEvents(true)
        .onChange(of: session.phase) { _, _ in controller.refit() }
        .onChange(of: session.notesBusy) { _, _ in controller.refit() }
    }
}

/// Maniglia in alto: si trascina da qui (e da tutta la barra superiore).
private struct Grabber: View {
    var body: some View {
        Capsule()
            .fill(.secondary.opacity(0.45))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 7)
            .padding(.bottom, 1)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}

private struct LivePanelHeader: View {
    @EnvironmentObject private var session: LiveSession
    @EnvironmentObject private var controller: LivePanelController

    var body: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 10)
            actions
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, controller.expanded ? 8 : 10)
        .fixedSize(horizontal: !controller.expanded, vertical: true)
        .contentShape(Rectangle())
        // La barra intera sposta il pannello; i pulsanti restano cliccabili.
        .gesture(WindowDragGesture())
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .live, .starting:
            HStack(spacing: 10) {
                RecordingDot()
                VStack(alignment: .leading, spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(verbatim: LiveTime.format(session.elapsed))
                            .font(PanelType.timer)
                            .contentTransition(.numericText())
                    }
                    Text(statusLine)
                        .font(PanelType.status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        case .finishing(let message):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message).font(.system(size: 13, weight: .medium)).fixedSize()
            }
        case .done:
            Label(String(localized: "Notes ready"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.green)
                .fixedSize()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .idle:
            Text(String(localized: "No active session"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        if session.clipInProgress { return String(localized: "Saving clip…") }
        if session.notesBusy { return String(localized: "Updating notes…") }
        if session.notesError != nil { return String(localized: "AI notes: error (see the Notes tab)") }
        let shots = session.captures.filter { $0.file != nil }.count
        return shots > 0
            ? String(localized: "\(shots) captures · \(session.engineLabel)")
            : session.engineLabel
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch session.phase {
            case .live:
                if session.hasVideo {
                    PanelButton("camera", help: String(localized: "Screenshot (⌃⌥S)")) {
                        Task { await session.snapshot() }
                    }
                    PanelButton("film", help: String(localized: "Clip of the last seconds (⌃⌥C)"),
                                busy: session.clipInProgress) {
                        Task { await session.clip() }
                    }
                }
                PanelButton("star", help: String(localized: "Mark this moment (⌃⌥M)")) {
                    Task { await session.markMoment() }
                }
                Rectangle().fill(.separator).frame(width: 1, height: 18).padding(.horizontal, 5)
                expandButton
                PanelButton("eye.slash", help: String(localized: "Hide the panel (⌃⌥N) — the session continues")) {
                    controller.hide()
                }
                StopButton {
                    Task { await session.stop() }
                }
                .padding(.leading, 4)
            case .done(let folder):
                if let notes = session.notesFileURL {
                    PanelButton("note.text", help: String(localized: "Open notes")) {
                        NSWorkspace.shared.open(notes)
                    }
                }
                PanelButton("folder", help: String(localized: "Show the session folder")) {
                    NSWorkspace.shared.open(folder)
                }
                expandButton
                PanelButton("xmark", help: String(localized: "Close")) { controller.close() }
            case .failed, .idle:
                PanelButton("xmark", help: String(localized: "Close")) { controller.close() }
            default:
                expandButton
            }
        }
        .fixedSize()
    }

    private var expandButton: some View {
        PanelButton(controller.expanded ? "chevron.up" : "chevron.down",
                    help: controller.expanded ? String(localized: "Collapse") : String(localized: "Expand: notes, transcript, chat")) {
            withAnimation(.smooth(duration: 0.25)) { controller.expanded.toggle() }
        }
    }
}

/// Puntino di registrazione con alone pulsante.
private struct RecordingDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.red.opacity(0.25))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1 : 0.55)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .shadow(color: .red.opacity(0.6), radius: 4)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Pulsante rotondo da 30 pt: icona netta, alone al passaggio del mouse.
struct PanelButton: View {
    let symbol: String
    let help: String
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, busy: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13.5, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.11 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .frame(width: 10, height: 10)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.red.opacity(hovering ? 1 : 0.88)))
                .shadow(color: .red.opacity(0.35), radius: hovering ? 6 : 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(String(localized: "Stop and write the notes (⌥⌘R)"))
        .accessibilityLabel(String(localized: "Stop and write the notes (⌥⌘R)"))
    }
}

private struct LivePanelBody: View {
    @EnvironmentObject private var session: LiveSession
    @EnvironmentObject private var controller: LivePanelController

    var body: some View {
        VStack(spacing: 8) {
            TabBar(selection: $controller.tab)
                .padding(.horizontal, 10)

            // Foglio interno: il vetro resta tutto intorno, il testo su un
            // fondo più pieno per restare leggibile su qualunque sfondo.
            Group {
                switch controller.tab {
                case .notes: NotesTabView()
                case .transcript: TranscriptTabView()
                case .captures: CapturesTabView()
                case .chat: ChatTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 8)

            if session.phase == .live || controller.tab == .chat {
                ComposerView()
                    .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 8)
    }
}

/// Schede a pillola con selezione che scorre.
private struct TabBar: View {
    @Binding var selection: LivePanelTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LivePanelTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.smooth(duration: 0.22)) { selection = tab }
                } label: {
                    // Icona + testo se c'è spazio, altrimenti solo testo (mai a capo).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                            Text(tab.label).font(PanelType.tab)
                        }
                        Text(tab.label).font(PanelType.tab)
                    }
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.primary.opacity(0.10))
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
    }
}

private struct NotesTabView: View {
    @EnvironmentObject private var session: LiveSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if session.notesBusy {
                        ProgressView().controlSize(.mini)
                        Text("Updating…").font(PanelType.meta).foregroundStyle(.secondary)
                    } else if let at = session.notesUpdatedAt {
                        TimelineView(.periodic(from: .now, by: 10)) { _ in
                            Text(String(localized: "Updated \(at.formatted(.relative(presentation: .named)))"))
                                .font(PanelType.meta).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if session.phase == .live {
                        Button {
                            session.refreshNotesNow()
                        } label: {
                            Label(String(localized: "Update now"), systemImage: "arrow.clockwise")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(session.notesBusy)
                    }
                    if let url = session.notesFileURL, FileManager.default.fileExists(atPath: url.path) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label(String(localized: "Open"), systemImage: "arrow.up.forward")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                if let error = session.notesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                if session.notes.isEmpty {
                    EmptyHint(
                        symbol: "sparkles",
                        title: String(localized: "Notes will appear here"),
                        detail: String(localized: "After the first minute of conversation the AI starts writing notes, and updates them every \(AppSettings.liveInterval) seconds with what is said and shown on screen."))
                } else {
                    MarkdownView(markdown: session.notes, baseURL: session.sessionFolder)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.automatic)
    }
}

private struct TranscriptTabView: View {
    @EnvironmentObject private var session: LiveSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.lines.isEmpty && session.volatile.isEmpty {
                        EmptyHint(symbol: "waveform",
                                  title: String(localized: "Listening…"),
                                  detail: String(localized: "What you say is labelled “Me”, the other participants “Others”."))
                    }
                    ForEach(session.lines) { line in
                        TranscriptRow(time: line.start, speaker: line.displaySpeaker,
                                      isMe: line.speaker == .me, text: line.text, volatile: false)
                    }
                    ForEach([Speaker.others, .me], id: \.self) { speaker in
                        if let text = session.volatile[speaker], !text.isEmpty {
                            TranscriptRow(time: nil, speaker: speaker.label, isMe: speaker == .me,
                                          text: text, volatile: true)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: session.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
            .onAppear { proxy.scrollTo("bottom") }
        }
    }
}

private struct TranscriptRow: View {
    let time: Double?
    let speaker: String
    let isMe: Bool
    let text: String
    let volatile: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(isMe ? Color.accentColor : Color.purple)
                .opacity(volatile ? 0.35 : 0.8)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(speaker.uppercased())
                        .font(PanelType.label)
                        .tracking(0.6)
                        .foregroundStyle(isMe ? Color.accentColor : Color.purple)
                    if let time {
                        Text(verbatim: LiveTime.format(time)).font(PanelType.meta).foregroundStyle(.tertiary)
                    }
                }
                Text(text)
                    .font(PanelType.body)
                    .lineSpacing(2.5)
                    .foregroundStyle(volatile ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CapturesTabView: View {
    @EnvironmentObject private var session: LiveSession
    private let columns = [GridItem(.adaptive(minimum: 124), spacing: 12)]

    var body: some View {
        ScrollView {
            if session.captures.isEmpty {
                EmptyHint(symbol: "photo.on.rectangle",
                          title: String(localized: "No captures yet"),
                          detail: String(localized: "Screenshots are taken automatically when the shared screen changes. You can also take one (⌃⌥S), save a clip of the last seconds (⌃⌥C) or mark a moment (⌃⌥M)."))
                    .padding(14)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(session.captures.reversed()) { capture in
                        CaptureCell(capture: capture, folder: session.sessionFolder)
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct CaptureCell: View {
    let capture: Capture
    let folder: URL?
    @State private var hovering = false

    private var url: URL? { capture.file.flatMap { folder?.appendingPathComponent($0) } }

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                    if capture.isImage, let url, let image = ImageCache.image(at: url) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: capture.kind == .clip ? "play.rectangle.fill" : "star.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.25 : 0.08)))
                .scaleEffect(hovering ? 1.02 : 1)
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                    Text(verbatim: LiveTime.format(capture.time)).font(PanelType.meta)
                }
                .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(capture.ocrText.isEmpty ? (capture.file ?? "") : String(capture.ocrText.prefix(300)))
    }

    private var symbol: String {
        switch capture.kind {
        case .auto: return "rectangle.on.rectangle"
        case .manual: return "camera.fill"
        case .clip: return "film.fill"
        case .mark: return "star.fill"
        }
    }
}

private struct ChatTabView: View {
    @EnvironmentObject private var session: LiveSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.chat.isEmpty {
                        EmptyHint(symbol: "bubble.left.and.text.bubble.right",
                                  title: String(localized: "Ask about the call"),
                                  detail: String(localized: "“What did they say about the budget?”, “Summarize the last 5 minutes”. Or write a note of yours: it goes into the notes."))
                    }
                    ForEach(session.chat) { item in
                        ChatBubble(item: item)
                    }
                    if session.askBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Thinking…").font(PanelType.meta).foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: session.chat.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
        }
    }
}

private struct ChatBubble: View {
    let item: ChatItem

    var body: some View {
        HStack {
            if item.role == .question { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                if item.role == .note {
                    Label(String(localized: "Your note").uppercased(), systemImage: "pencil")
                        .font(PanelType.label).tracking(0.5)
                        .foregroundStyle(.secondary)
                }
                if item.role == .answer {
                    MarkdownView(markdown: item.text, baseURL: nil)
                } else {
                    Text(item.text)
                        .font(PanelType.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .foregroundStyle(item.role == .question ? Color.white
                                         : (item.role == .error ? Color.orange : Color.primary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if item.role != .question { Spacer(minLength: 24) }
        }
    }

    private var background: Color {
        switch item.role {
        case .question: return Color.accentColor
        case .note: return Color.yellow.opacity(0.18)
        case .error: return Color.orange.opacity(0.12)
        case .answer: return Color.primary.opacity(0.055)
        }
    }
}

/// Campo in fondo al pannello: domanda all'AI o nota personale.
private struct ComposerView: View {
    @EnvironmentObject private var session: LiveSession
    @EnvironmentObject private var controller: LivePanelController
    @State private var text = ""
    @State private var asNote = false
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.askBusy
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            HStack(spacing: 0) {
                modeButton(note: false, symbol: "sparkles", help: String(localized: "Ask the AI"))
                modeButton(note: true, symbol: "pencil", help: String(localized: "Add a note of yours"))
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))

            TextField(asNote ? String(localized: "Write a note (it goes into the notes)…")
                             : String(localized: "Ask something about the call…"),
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(PanelType.body)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func modeButton(note: Bool, symbol: String, help: String) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.18)) { asNote = note }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(asNote == note ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(asNote == note ? Color.primary.opacity(0.12) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func send() {
        let value = text
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        if asNote {
            session.addUserNote(value)
        } else {
            controller.tab = .chat
            Task { await session.ask(value) }
        }
    }
}

private struct EmptyHint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 12)
    }
}
