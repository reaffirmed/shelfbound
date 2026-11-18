import Foundation

public enum ReaderTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case paper, sepia, dusk, night
    public var id: String { rawValue }

    public var label: String { rawValue.capitalized }
    public var isDark: Bool { self == .dusk || self == .night }

    /// Hex colours: background, text, muted text, link and accent.
    public var colors: (background: String, text: String, muted: String, accent: String) {
        switch self {
        case .paper: ("#FBFAF6", "#1F1E1B", "#6F6A60", "#17755F")
        case .sepia: ("#F3E7CF", "#3D2F20", "#7A6A55", "#8A5A1C")
        case .dusk: ("#24272C", "#D8D4CA", "#9A968D", "#7FD8C0")
        case .night: ("#000000", "#A8A69F", "#6E6C66", "#5FB8A2")
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "light": self = .paper   // names from the first build
        case "dark": self = .night
        default: self = ReaderTheme(rawValue: raw) ?? .paper
        }
    }
}

public enum ReaderFont: String, Codable, Sendable, CaseIterable, Identifiable {
    /// New York, Apple's system serif.
    case serif
    case charter
    case georgia
    case system
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .serif: "New York"
        case .charter: "Charter"
        case .georgia: "Georgia"
        case .system: "System"
        }
    }

    public var css: String {
        switch self {
        case .serif: "ui-serif, \"New York\", Georgia, serif"
        case .charter: "Charter, \"Iowan Old Style\", Georgia, serif"
        case .georgia: "Georgia, \"Times New Roman\", serif"
        case .system: "-apple-system, system-ui, sans-serif"
        }
    }
}

public enum LineSpacing: String, Codable, Sendable, CaseIterable, Identifiable {
    case compact, normal, airy
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var value: Double {
        switch self {
        case .compact: 1.45
        case .normal: 1.65
        case .airy: 1.9
        }
    }
}

public struct ReaderStyle: Codable, Sendable, Hashable {
    public var theme: ReaderTheme
    public var fontSize: Double
    public var lineSpacing: LineSpacing
    public var margin: Double
    public var font: ReaderFont
    public var justify: Bool

    public init(
        theme: ReaderTheme = .paper, fontSize: Double = 19, lineSpacing: LineSpacing = .normal,
        margin: Double = 22, font: ReaderFont = .serif, justify: Bool = false
    ) {
        self.theme = theme
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.margin = margin
        self.font = font
        self.justify = justify
    }

    private enum CodingKeys: String, CodingKey { case theme, fontSize, lineSpacing, margin, font, justify }

    // Tolerates settings saved by older builds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderStyle()
        theme = (try? c.decodeIfPresent(ReaderTheme.self, forKey: .theme)) ?? d.theme
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        lineSpacing = (try? c.decodeIfPresent(LineSpacing.self, forKey: .lineSpacing)) ?? d.lineSpacing
        margin = (try? c.decodeIfPresent(Double.self, forKey: .margin)) ?? d.margin
        font = (try? c.decodeIfPresent(ReaderFont.self, forKey: .font)) ?? d.font
        justify = (try? c.decodeIfPresent(Bool.self, forKey: .justify)) ?? d.justify
    }
}

/// Builds the HTML page the text reader shows. Source HTML is placed inside our own
/// shell; scripts are blocked by a Content-Security-Policy so a source cannot run code
/// in the reader.
public enum ReaderDocument {
    /// Links with this scheme are handled by the app (next chapter, open glossary).
    public static let actionScheme = "shelfbound-reader"

    public struct EndOfChapter: Sendable, Hashable {
        public var message: String
        /// Title of the next chapter, if there is one. Shown as a link to `shelfbound-reader://next`.
        public var nextTitle: String?

        public init(message: String, nextTitle: String?) {
            self.message = message
            self.nextTitle = nextTitle
        }
    }

    public static func html(
        title: String, kicker: String? = nil, body: String, notesBefore: String? = nil, notesAfter: String? = nil,
        style: ReaderStyle, end: EndOfChapter? = nil
    ) -> String {
        let c = style.theme.colors
        let notes: (String?, String) -> String = { notes, label in
            guard let notes, !notes.isEmpty else { return "" }
            return "<details class=\"notes\"><summary>\(label)</summary>\(notes)</details>"
        }
        let endBlock: String = {
            guard let end else { return "" }
            var out = "<div class=\"r-end\"><p>\(escape(end.message))</p>"
            if let next = end.nextTitle {
                out += "<a class=\"next\" href=\"\(actionScheme)://next\">Next: \(escape(next))</a>"
            }
            return out + "</div>"
        }()
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: \(style.theme.isDark ? "dark" : "light"); }
        body { background: \(c.background); color: \(c.text); font-family: \(style.font.css);
               font-size: \(Int(style.fontSize))px; line-height: \(style.lineSpacing.value);
               margin: 0; padding: 28px \(Int(style.margin))px 96px; word-wrap: break-word;
               -webkit-text-size-adjust: 100%; text-align: \(style.justify ? "justify" : "left");
               -webkit-hyphens: \(style.justify ? "auto" : "manual"); }
        .kicker { font: 600 12px -apple-system, system-ui, sans-serif; letter-spacing: .12em;
                  text-transform: uppercase; color: \(c.muted); margin: 0 0 6px; }
        h1.chapter-title { font-size: 1.45em; line-height: 1.2; margin: 0 0 1.1em; text-align: left; }
        p { margin: 0 0 1em; }
        img { max-width: 100%; height: auto; }
        a { color: \(c.accent); }
        hr { border: 0; text-align: center; margin: 1.6em 0; }
        hr::after { content: "* * *"; color: \(c.muted); letter-spacing: .4em; }
        blockquote { margin: 1em 0; padding-left: 1em; border-left: 2px solid \(c.muted); }
        .notes { color: \(c.muted); border-left: 3px solid \(c.muted); padding-left: 12px; margin: 1em 0 1.5em; font-size: .92em; }
        .notes summary { cursor: pointer; font-weight: 600; }
        .gl { border-bottom: 1px dotted \(c.accent); }
        mark.hl { background: rgba(255, 204, 0, \(style.theme.isDark ? "0.32" : "0.38")); color: inherit; border-radius: 2px; }
        .r-end { margin-top: 3em; padding-top: 1.5em; border-top: 1px solid \(c.muted)55; text-align: center;
                 color: \(c.muted); font: 15px/1.5 -apple-system, system-ui, sans-serif; }
        .r-end a.next { display: inline-block; margin-top: .6em; padding: .7em 1.2em; border-radius: 12px;
                        background: \(c.accent); color: \(c.background); text-decoration: none; font-weight: 600; }
        </style></head>
        <body>
        \(kicker.map { "<div class=\"kicker\">\(escape($0))</div>" } ?? "")
        <h1 class="chapter-title">\(escape(title))</h1>
        \(notes(notesBefore, "Notes"))
        <article>\(body)</article>
        \(notes(notesAfter, "End notes"))
        \(endBlock)
        </body></html>
        """
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Script the text reader injects (page scripts stay off). It reports scroll
    /// progress, underlines glossary terms (tapping one posts its index), and reads and
    /// marks highlights (tapping one posts its id).
    public static let readerScript = #"""
    (function () {
      let last = -1;
      function report() {
        const max = document.documentElement.scrollHeight - window.innerHeight;
        const p = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 1;
        if (Math.abs(p - last) > 0.005) { last = p; window.webkit.messageHandlers.progress.postMessage(p); }
      }
      window.addEventListener("scroll", report, { passive: true });
      window.addEventListener("load", report);

      window.__shelfGlossary = function (terms) {
        const root = document.querySelector("article");
        if (!root || !terms.length) return;
        const escaped = terms.map((t, i) => ({ i, t })).filter((x) => x.t.length > 1)
          .sort((a, b) => b.t.length - a.t.length);
        if (!escaped.length) return;
        const re = new RegExp("(" + escaped.map((x) => x.t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|") + ")", "g");
        const index = {};
        escaped.forEach((x) => { index[x.t] = x.i; });
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const nodes = [];
        while (walker.nextNode()) nodes.push(walker.currentNode);
        nodes.forEach((node) => {
          const text = node.nodeValue;
          re.lastIndex = 0;
          if (!re.test(text)) return;
          re.lastIndex = 0;
          const frag = document.createDocumentFragment();
          let pos = 0, m;
          while ((m = re.exec(text))) {
            frag.appendChild(document.createTextNode(text.slice(pos, m.index)));
            const span = document.createElement("span");
            span.className = "gl";
            span.textContent = m[0];
            span.dataset.i = String(index[m[0]]);
            frag.appendChild(span);
            pos = m.index + m[0].length;
          }
          frag.appendChild(document.createTextNode(text.slice(pos)));
          node.parentNode.replaceChild(frag, node);
        });
      };
      document.addEventListener("click", function (e) {
        const el = e.target.closest && e.target.closest(".gl");
        if (el) { window.webkit.messageHandlers.glossary.postMessage(Number(el.dataset.i)); return; }
        const mark = e.target.closest && e.target.closest("mark.hl");
        if (mark && window.getSelection().isCollapsed) { window.webkit.messageHandlers.highlight.postMessage(mark.dataset.h); }
      });

      // Highlights are stored as the quote plus a little text either side, measured in
      // the article's text, so they survive changes to the chapter's markup.
      const CONTEXT = 32;
      window.__shelfSelection = function () {
        const root = document.querySelector("article");
        const sel = window.getSelection();
        if (!root || !sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
        const range = sel.getRangeAt(0);
        if (!root.contains(range.commonAncestorContainer)) return null;
        const before = document.createRange();
        before.setStart(root, 0);
        before.setEnd(range.startContainer, range.startOffset);
        const text = root.textContent;
        const start = before.toString().length;
        const exact = range.toString();
        if (!exact.trim()) return null;
        const end = start + exact.length;
        return JSON.stringify({
          exact: exact,
          prefix: text.slice(Math.max(0, start - CONTEXT), start),
          suffix: text.slice(end, end + CONTEXT),
        });
      };

      function locate(text, h) {
        const tries = [[h.prefix + h.exact + h.suffix, h.prefix.length], [h.prefix + h.exact, h.prefix.length],
                       [h.exact + h.suffix, 0], [h.exact, 0]];
        for (const [needle, shift] of tries) {
          const at = text.indexOf(needle);
          if (at >= 0) return at + shift;
        }
        return -1;
      }

      const applied = {};
      window.__shelfHighlights = function (list) {
        const root = document.querySelector("article");
        if (!root) return;
        list.forEach((h) => {
          if (applied[h.id] || !h.exact) return;
          const start = locate(root.textContent, h);
          if (start < 0) return;
          const end = start + h.exact.length;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          const parts = [];
          let pos = 0;
          while (walker.nextNode()) {
            const node = walker.currentNode, len = node.nodeValue.length;
            const from = Math.max(start, pos), to = Math.min(end, pos + len);
            if (from < to) parts.push([node, from - pos, to - pos]);
            pos += len;
            if (pos >= end) break;
          }
          parts.forEach(([node, a, b]) => {
            if (!node.nodeValue.slice(a, b).trim()) return;
            let target = node;
            if (a > 0) target = target.splitText(a);
            if (b - a < target.nodeValue.length) target.splitText(b - a);
            const mark = document.createElement("mark");
            mark.className = "hl";
            mark.dataset.h = h.id;
            target.parentNode.replaceChild(mark, target);
            mark.appendChild(target);
          });
          applied[h.id] = true;
        });
        const sel = window.getSelection();
        if (sel) sel.removeAllRanges();
      };

      window.__shelfUnhighlight = function (id) {
        document.querySelectorAll('mark.hl[data-h="' + id + '"]').forEach((mark) => {
          const parent = mark.parentNode;
          while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
          parent.removeChild(mark);
          parent.normalize();
        });
        delete applied[id];
      };
    })();
    """#
}
