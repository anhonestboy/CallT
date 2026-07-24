import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProcessingTab()
                .tabItem { Label("Processing", systemImage: "waveform") }
            NotesTab()
                .tabItem { Label("Notes", systemImage: "note.text") }
            AutomationTab()
                .tabItem { Label("Automation", systemImage: "sparkles") }
            LogTab()
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .frame(width: 580)
        .onAppear {
            // No Dock icon: without activate the window would stay behind others.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SettingsKey.watchFolder) private var watchFolder = ""
    @AppStorage(SettingsKey.outputFolder) private var outputFolder = ""
    @AppStorage(SettingsKey.language) private var language = "it-IT"
    @AppStorage(SettingsKey.notifyOnComplete) private var notifyOnComplete = true
    @AppStorage("uiLanguage") private var uiLanguage = "system"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var languages: [(id: String, label: String)] = []
    @State private var needsRelaunch = false
    @StateObject private var permissions = PermissionsModel()

    var body: some View {
        Form {
            Section("Folders") {
                folderRow(
                    title: String(localized: "Recordings"), path: $watchFolder,
                    prompt: String(localized: "Choose the folder to watch")
                ) { state.watchFolderChanged() }
                folderRow(
                    title: String(localized: "Transcripts"), path: $outputFolder,
                    prompt: String(localized: "Choose the output folder"), allowReset: true)
                if !outputFolder.isEmpty && outputFolder == watchFolder {
                    Text("Not recommended: the output folder is the same as the watched folder.")
                        .font(.footnote).foregroundStyle(.orange)
                } else if outputFolder.isEmpty {
                    Text("Default output: an “output” subfolder of the watched folder.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Language") {
                Picker("Transcription language", selection: $language) {
                    ForEach(languages, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("App language", selection: $uiLanguage) {
                    Text("System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Italiano").tag("it")
                }
                .onChange(of: uiLanguage) { _, value in
                    switch value {
                    case "system":
                        AppSettings.defaults.removeObject(forKey: "AppleLanguages")
                    default:
                        AppSettings.defaults.set([value], forKey: "AppleLanguages")
                    }
                    needsRelaunch = true
                }
                if needsRelaunch {
                    HStack {
                        Text("Takes effect after relaunching CallT.")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Relaunch now") { relaunch() }
                    }
                }
            }
            Section("Permissions") {
                PermissionsRows(model: permissions)
            }
            Section("Startup & alerts") {
                Toggle("Notify when each transcription finishes", isOn: $notifyOnComplete)
                LabeledContent(String(localized: "Version")) {
                    HStack {
                        Text(verbatim: UpdateChecker.currentVersion).foregroundStyle(.secondary)
                        Button(String(localized: "Check for updates")) {
                            Task { await UpdateChecker.checkInteractively() }
                        }
                    }
                }
                Toggle("Open CallT at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            appLog("⚠️ Launch at login: \(error.localizedDescription)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .task { languages = await AppleTranscriber.availableLanguages() }
        .onAppear { permissions.refresh() }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func folderRow(
        title: String, path: Binding<String>, prompt: String,
        allowReset: Bool = false, onChange: @escaping () -> Void = {}
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(path.wrappedValue.isEmpty
                    ? String(localized: "Default")
                    : (path.wrappedValue as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                if allowReset && !path.wrappedValue.isEmpty {
                    Button {
                        path.wrappedValue = ""
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Restore the default folder"))
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.message = prompt
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                        onChange()
                    }
                }
            }
        }
    }
}

// MARK: - Processing

struct ProcessingTab: View {
    @AppStorage(SettingsKey.engine) private var engine = TranscriptionEngineKind.apple.rawValue
    @AppStorage(SettingsKey.whisperModelPath) private var whisperModelPath = ""
    @AppStorage(SettingsKey.compressVideo) private var compressVideo = true
    @AppStorage(SettingsKey.compressionQuality) private var quality = CompressionQuality.media.rawValue
    @AppStorage(SettingsKey.downscaleTo1080) private var downscale = true
    @AppStorage(SettingsKey.deleteOriginal) private var deleteOriginal = false
    @AppStorage(SettingsKey.keepAudio) private var keepAudio = false
    @AppStorage(SettingsKey.generateSRT) private var generateSRT = false
    @AppStorage(SettingsKey.diarizeSpeakers) private var diarize = true
    @AppStorage("micDeviceID") private var micDeviceID = ""

    private var whisperAvailable: Bool { WhisperTranscriber.detectBinary() != nil }
    private var microphones: [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices.map { ($0.uniqueID, $0.localizedName) }
    }

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Engine", selection: $engine) {
                    ForEach(TranscriptionEngineKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                if engine == TranscriptionEngineKind.whisper.rawValue {
                    if !whisperAvailable {
                        Text("whisper-cli not found: install it with “brew install whisper-cpp”. The Apple engine will be used instead.")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if !FileManager.default.fileExists(atPath: whisperModelPath) {
                        Text(String(localized: "Model not found at \(whisperModelPath)"))
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Toggle("Identify speakers (diarization)", isOn: $diarize)
                if diarize {
                    Text("Speaker turns are detected on-device (CoreML). The model (~100 MB) is downloaded once on first use.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Also generate subtitles (.srt)", isOn: $generateSRT)
                Toggle("Keep the extracted audio (.wav)", isOn: $keepAudio)
            }
            Section("Recording") {
                Picker(String(localized: "Microphone"), selection: $micDeviceID) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.id) { mic in
                        Text(verbatim: mic.name).tag(mic.id)
                    }
                }
                Text("Global shortcut to start/stop recording: ⌥⌘R")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Compress the video after transcription", isOn: $compressVideo)
                Group {
                    Picker("Quality", selection: $quality) {
                        ForEach(CompressionQuality.allCases) { q in
                            Text(q.label).tag(q.rawValue)
                        }
                    }
                    Toggle("Downscale to 1080p when larger", isOn: $downscale)
                    Toggle("Move the original to the Trash after compression", isOn: $deleteOriginal)
                }
                .disabled(!compressVideo)
            } header: {
                Text("Compression")
            } footer: {
                Text("The compressed video is kept only when it is genuinely smaller than the original. Audio-only files are never compressed.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notes

struct NotesTab: View {
    @AppStorage(SettingsKey.notesEnabled) private var enabled = true
    @AppStorage(SettingsKey.notesEngine) private var engine = "apple"
    @AppStorage(SettingsKey.notesBaseURL) private var baseURL = ""
    @AppStorage(SettingsKey.notesDetail) private var detail = "normal"
    @AppStorage(SettingsKey.notesTimestamps) private var timestamps = true
    @State private var model = ""
    @State private var apiKey = ""

    private static var engines: [(id: String, label: String)] {
        [
            ("apple", String(localized: "Apple Intelligence (local, free)")),
            ("claude", String(localized: "Claude API")),
            ("openrouter", "OpenRouter"),
            ("deepseek", "DeepSeek"),
            ("ollama", String(localized: "Ollama (local)")),
            ("custom", String(localized: "OpenAI-compatible…")),
        ]
    }

    private var needsKey: Bool {
        if engine == "apple" { return false }
        if engine == "claude" { return true }
        return OpenAICompatEngine.provider(engine)?.needsKey ?? true
    }

    var body: some View {
        Form {
            Section {
                Toggle("Generate organized call notes (.md)", isOn: $enabled)
                Picker("Detail level", selection: $detail) {
                    Text("Normal").tag("normal")
                    Text("Detailed").tag("detailed")
                    Text("Very detailed").tag("verydetailed")
                }
                Toggle("Include timestamps", isOn: $timestamps)
            } footer: {
                Text("After each transcription a “name_notes.md” file is created: summary, topics with details, decisions, action items and open questions. Higher detail levels produce longer, more thorough notes.")
            }
            Section("Engine") {
                Picker("Engine", selection: $engine) {
                    ForEach(Self.engines, id: \.id) { Text($0.label).tag($0.id) }
                }
                .onChange(of: engine) { _, _ in loadFields() }

                if engine == "apple" {
                    Text(AppleNotesEngine.availabilityDescription())
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    if engine == "claude" {
                        Picker("Model", selection: $model) {
                            ForEach(ClaudeNotesEngine.models, id: \.0) { id, label in
                                Text(label).tag(id)
                            }
                        }
                        .onChange(of: model) { _, value in
                            AppSettings.setNotesModel(value, for: engine)
                        }
                    } else {
                        TextField("Model", text: $model, prompt: Text(verbatim:
                            OpenAICompatEngine.provider(engine)?.defaultModel.isEmpty == false
                                ? OpenAICompatEngine.provider(engine)!.defaultModel
                                : "e.g. gpt-4o"))
                            .onChange(of: model) { _, value in
                                AppSettings.setNotesModel(value, for: engine)
                            }
                    }
                    if engine == "custom" {
                        TextField("Base URL", text: $baseURL, prompt: Text(verbatim: "https://api.openai.com/v1"))
                    }
                    if needsKey {
                        SecureField("API key", text: $apiKey)
                            .onChange(of: apiKey) { _, value in
                                KeychainStore.write(value, account: "apikey-\(engine)")
                            }
                        Text("The key is stored in the Keychain. The transcript is sent to the selected provider.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if engine == "ollama" {
                        Text("Requires Ollama running on this Mac (localhost:11434).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .task { loadFields() }
    }

    private func loadFields() {
        model = AppSettings.notesModel(for: engine)
        apiKey = KeychainStore.read("apikey-\(engine)") ?? ""
    }
}

// MARK: - Automation

struct AutomationTab: View {
    @AppStorage(SettingsKey.deliveryShortcut) private var deliveryShortcut = ""
    @State private var shortcuts: [String] = []
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                Picker("Shortcut to run", selection: $deliveryShortcut) {
                    Text("None").tag("")
                    ForEach(shortcuts, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                HStack {
                    Button("Refresh list") { Task { await reload() } }
                    Button("Try with a sample file") { Task { await runTest() } }
                        .disabled(deliveryShortcut.isEmpty)
                    Button("Open Shortcuts") {
                        NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                    }
                }
                if let testResult {
                    Text(verbatim: testResult).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Automatic delivery")
            } footer: {
                Text("When each transcription finishes, CallT runs the chosen Apple Shortcut with the .txt file as input: useful to send it via mail, Slack, Notes, and so on.")
            }
            Section {
            } footer: {
                Text("CallT also exposes a “Transcribe video” action in the Shortcuts app, so you can build automations that transcribe a file on demand.")
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        shortcuts = await ShortcutRunner.list()
        if !deliveryShortcut.isEmpty && !shortcuts.contains(deliveryShortcut) {
            shortcuts.append(deliveryShortcut)
        }
    }

    private func runTest() async {
        testResult = String(localized: "Running…")
        let sample = FileManager.default.temporaryDirectory
            .appendingPathComponent("callt-sample-transcript.txt")
        try? String(localized: "This is a sample transcript generated by CallT.").write(
            to: sample, atomically: true, encoding: .utf8)
        if let error = await ShortcutRunner.run(shortcut: deliveryShortcut, input: sample) {
            testResult = String(localized: "Error: \(error)")
        } else {
            testResult = String(localized: "Shortcut ran successfully ✓")
        }
    }
}

// MARK: - Log

struct LogTab: View {
    @ObservedObject private var logStore = LogStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logStore.lines) { line in
                            Text(verbatim: line.text)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .onChange(of: logStore.lines.last?.id) { _, _ in
                    proxy.scrollTo("bottom")
                }
            }
            .frame(height: 300)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Open log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([logStore.logFileURL])
                }
                Spacer()
            }
        }
        .padding(20)
    }
}
