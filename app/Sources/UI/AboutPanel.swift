import AppKit

/// Pannello "Informazioni su CallT" standard con crediti.
@MainActor
enum AboutPanel {
    static func show() {
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
        line(String(localized: "Recording: ScreenCaptureKit · Transcription: Apple Speech, whisper.cpp"))
        line(String(localized: "Speakers: FluidAudio · Notes: Apple Intelligence, Claude, OpenRouter, DeepSeek, Ollama"))
        line("")
        line(String(localized: "MIT license"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
