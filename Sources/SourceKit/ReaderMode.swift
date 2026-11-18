import Foundation
import ShelfCore
import SwiftSoup

/// Pulls the main text out of an ordinary web page, for chapter links that no installed
/// source handles. It keeps a small set of text tags and drops everything else,
/// including scripts, styles, forms, navigation and comments sections.
public enum ReaderMode {
    public struct Article: Sendable, Hashable {
        public var title: String?
        public var html: String
        public var wordCount: Int
    }

    static let allowedTags: Set<String> = [
        "p", "br", "em", "i", "strong", "b", "u", "s", "sub", "sup", "small", "span",
        "h2", "h3", "h4", "blockquote", "hr", "ul", "ol", "li", "img", "div",
    ]
    static let dropSelectors = [
        "script", "style", "noscript", "iframe", "form", "nav", "header", "footer", "aside", "button",
        "input", "select", "textarea", "svg", "video", "audio", "object", "embed",
        "[class*=comment]", "[id*=comment]", "[class*=share]", "[class*=related]", "[class*=sidebar]",
        "[class*=advert]", "[class*=navigation]", "[class*=menu]",
    ]

    public static func extract(html: String, url: URL) throws -> Article {
        let document = try SwiftSoup.parse(html, url.absoluteString)
        let title = try document.select("h1").first()?.text() ?? (try document.title())
        try document.select("h1").remove()
        for selector in dropSelectors {
            try document.select(selector).remove()
        }

        // Score blocks by the text in their direct <p> children, then take the best one.
        var best: Element?
        var bestScore = 0
        for candidate in try document.select("article, main, section, div").array() {
            var score = 0
            for child in candidate.children().array() where child.tagName() == "p" || child.tagName() == "br" {
                let text = try child.text()
                score += text.count
                if text.contains(",") || text.contains("。") || text.contains("，") { score += 20 }
            }
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        guard let root = best ?? document.body() else {
            return Article(title: title, html: "", wordCount: 0)
        }
        let cleaned = try clean(root, base: url)
        let words = try root.text().split(whereSeparator: { $0.isWhitespace }).count
        return Article(title: title.isEmpty ? nil : title, html: cleaned, wordCount: words)
    }

    /// Keeps allowed tags with no attributes, except https image sources.
    static func clean(_ root: Element, base: URL) throws -> String {
        var out = ""
        for node in root.getChildNodes() {
            out += try render(node, base: base)
        }
        return out
    }

    private static func render(_ node: Node, base: URL) throws -> String {
        if let text = node as? TextNode {
            return ReaderDocument.escape(text.text())
        }
        guard let element = node as? Element else { return "" }
        let tag = element.tagName().lowercased()
        let inner = try element.getChildNodes().map { try render($0, base: base) }.joined()
        guard allowedTags.contains(tag) else { return inner }
        switch tag {
        case "br", "hr":
            return "<\(tag)>"
        case "img":
            let src = try element.attr("src")
            guard let url = URL(string: src, relativeTo: base)?.absoluteURL, url.scheme == "https" else { return "" }
            return "<img src=\"\(ReaderDocument.escape(url.absoluteString))\">"
        case "div", "span":
            // Flatten wrappers; a div becomes a paragraph break.
            return tag == "div" ? inner + "\n" : inner
        default:
            return "<\(tag)>\(inner)</\(tag)>"
        }
    }
}
