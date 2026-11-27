import SwiftUI
import AppKit

/// Rendering leggero del Markdown delle note: titoli, elenchi, checkbox,
/// citazioni, separatori, immagini (miniature cliccabili) e link alle clip.
/// Il testo in linea (grassetto, corsivo, codice, link) usa AttributedString.
struct MarkdownView: View {
    let markdown: String
    /// Cartella rispetto a cui risolvere i percorsi relativi ("assets/…").
    let baseURL: URL?

    private enum Block {
        case heading(Int, String)
        case bullet(Int, String)
        case task(Int, Bool, String)
        case numbered(Int, String, String)
        case quote(String)
        case image(String, String)
        case rule
        case paragraph(String)
    }

    var body: some View {
        let blocks = Self.parse(markdown)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, first: index == 0)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block, first: Bool) -> some View {
        switch block {
        case .heading(1, let text):
            inline(text, font: .system(size: 19, weight: .bold))
                .tracking(-0.3)
                .padding(.bottom, 2)
        case .heading(2, let text):
            // Sezioni come etichette: maiuscolo spaziato, con filo sottile.
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.plain(text).uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
            .padding(.top, first ? 0 : 14)
            .padding(.bottom, 1)
        case .heading(_, let text):
            inline(text, font: .system(size: 14.5, weight: .semibold))
                .padding(.top, 8)
        case .bullet(let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(level == 0 ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.6))
                    .frame(width: level == 0 ? 5 : 4, height: level == 0 ? 5 : 4)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 3.5 }
                inline(text)
            }
            .padding(.leading, CGFloat(level) * 16 + 2)
        case .task(let level, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(done ? Color.green : Color.secondary)
                inline(text)
                    .strikethrough(done, color: .secondary)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .numbered(let level, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: number)
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .quote(let text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                }
        case .image(let alt, let path):
            ImageThumb(url: resolve(path), caption: alt)
                .padding(.vertical, 4)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.vertical, 8)
        case .paragraph(let text):
            inline(text)
        }
    }

    /// Testo senza marcatori Markdown, per le etichette di sezione.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    private func inline(_ text: String, font: Font = .system(size: 13.5)) -> some View {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var attributed = (try? AttributedString(markdown: text, options: options, baseURL: baseURL))
            ?? AttributedString(text)
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = .accentColor
        }
        return Text(attributed)
            .font(font)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    private func resolve(_ path: String) -> URL? {
        let clean = path.removingPercentEncoding ?? path
        if clean.hasPrefix("/") { return URL(fileURLWithPath: clean) }
        if let url = URL(string: path), url.scheme != nil { return url }
        return baseURL?.appendingPathComponent(clean)
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let level = min(3, indent / 2)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("```") { flush(); continue }
            if let heading = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                blocks.append(.heading(heading.1.count, String(heading.2)))
            } else if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.rule)
            } else if let image = line.firstMatch(of: /^!\[([^\]]*)\]\(([^)]+)\)\s*$/) {
                flush()
                blocks.append(.image(String(image.1), String(image.2)))
            } else if let task = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.*)$/) {
                flush()
                blocks.append(.task(level, task.1 != " ", String(task.2)))
            } else if let bullet = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
                flush()
                blocks.append(.bullet(level, String(bullet.1)))
            } else if let numbered = line.firstMatch(of: /^(\d+[.)])\s+(.*)$/) {
                flush()
                blocks.append(.numbered(level, String(numbered.1), String(numbered.2)))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

/// Miniatura di un'immagine locale: clic per aprirla in Anteprima.
struct ImageThumb: View {
    let url: URL?
    let caption: String
    var maxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url, let image = ImageCache.image(at: url) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: maxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1)))
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open the image"))
            } else {
                Label(caption.isEmpty ? (url?.lastPathComponent ?? "") : caption, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
            if !caption.isEmpty {
                Text(verbatim: caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Le view si ridisegnano spesso durante la call (testo volatile): le
/// miniature non vanno riletto dal disco ogni volta.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(at url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
