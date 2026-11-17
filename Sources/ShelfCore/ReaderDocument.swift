import Foundation

public enum ReaderTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case light, sepia, dark
    public var id: String { rawValue }

    var colors: (background: String, text: String, muted: String) {
        switch self {
        case .light: ("#ffffff", "#1d1d1f", "#6e6e73")
        case .sepia: ("#f6efe2", "#3b2f22", "#7a6a55")
        case .dark: ("#121212", "#e6e6e6", "#9a9a9a")
        }
    }
}

public struct ReaderStyle: Codable, Sendable, Hashable {
    public var theme: ReaderTheme
    public var fontSize: Double
    public var lineHeight: Double
    public var margin: Double
    public var fontFamily: String

    public init(
        theme: ReaderTheme = .light, fontSize: Double = 18, lineHeight: Double = 1.6,
        margin: Double = 20, fontFamily: String = "-apple-system, Georgia, serif"
    ) {
        self.theme = theme
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.margin = margin
        self.fontFamily = fontFamily
    }
}

/// Builds the HTML page the text reader shows. Source HTML is placed inside our own
/// shell; scripts are blocked by a Content-Security-Policy so a source cannot run code
/// in the reader.
public enum ReaderDocument {
    public static func html(
        title: String, body: String, notesBefore: String? = nil, notesAfter: String? = nil,
        style: ReaderStyle
    ) -> String {
        let c = style.theme.colors
        let notes: (String?, String) -> String = { notes, label in
            guard let notes, !notes.isEmpty else { return "" }
            return "<details class=\"notes\"><summary>\(label)</summary>\(notes)</details>"
        }
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: \(style.theme == .dark ? "dark" : "light"); }
        body { background: \(c.background); color: \(c.text); font-family: \(style.fontFamily);
               font-size: \(Int(style.fontSize))px; line-height: \(style.lineHeight);
               margin: 0; padding: 24px \(Int(style.margin))px 64px; word-wrap: break-word; }
        h1.chapter-title { font-size: 1.3em; margin: 0 0 1em; }
        p { margin: 0 0 1em; }
        img { max-width: 100%; height: auto; }
        a { color: inherit; }
        .notes { color: \(c.muted); border-left: 3px solid \(c.muted); padding-left: 12px; margin: 1em 0 1.5em; }
        .notes summary { cursor: pointer; font-weight: 600; }
        </style></head>
        <body>
        <h1 class="chapter-title">\(escape(title))</h1>
        \(notes(notesBefore, "Notes"))
        <article>\(body)</article>
        \(notes(notesAfter, "End notes"))
        </body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
