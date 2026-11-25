import Foundation
import ShelfCore

/// Compares titles across sources, which spell the same work differently
/// ("The Beginning After the End" vs "Beginning After The End, The" vs "the beginning after the end!").
/// Used by import, merged search and migration.
public enum TitleMatcher {
    /// Lowercased, accents and punctuation removed, a leading or trailing "the/a/an" dropped,
    /// whitespace collapsed.
    public static func normalize(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let spaced = String(folded.map { (c: Character) -> Character in c.isLetter || c.isNumber ? c : " " })
        var words = spaced.split(separator: " ").map(String.init)
        if let first = words.first, ["the", "a", "an"].contains(first), words.count > 1 { words.removeFirst() }
        if let last = words.last, ["the", "a", "an"].contains(last), words.count > 1 { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// 0...1: 1 for the same normalized title, otherwise word overlap (Dice coefficient).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 1 }
        let wx = Set(x.split(separator: " ")), wy = Set(y.split(separator: " "))
        let shared = wx.intersection(wy).count
        return 2 * Double(shared) / Double(wx.count + wy.count) * 0.95
    }

    /// The candidate that best matches `title` (and `authors`, when both sides have them), if
    /// it's close enough to be the same work.
    public static func best(
        for title: String, authors: [String] = [], among candidates: [WorkSummary], threshold: Double = 0.85
    ) -> WorkSummary? {
        var best: (WorkSummary, Double)?
        for candidate in candidates {
            var score = similarity(title, candidate.title)
            if !authors.isEmpty, !candidate.authors.isEmpty {
                let mine = Set(authors.map(normalize)), theirs = Set(candidate.authors.map(normalize))
                score += mine.isDisjoint(with: theirs) ? -0.1 : 0.05
            }
            if score >= threshold, score > (best?.1 ?? 0) { best = (candidate, score) }
        }
        return best?.0
    }
}

/// Matches read chapters across sources by chapter number, which survives a change of
/// source when chapter IDs don't.
public enum ChapterMatcher {
    /// "Chapter 12.5", "Ch. 12.5: Title", "Episode 40", "c12" → the number.
    public static func number(of chapter: Chapter) -> Double? {
        if let number = chapter.number { return number }
        let title = chapter.title.lowercased()
        let patterns = [#"(?:chapter|chap|ch|episode|ep|c)\.?\s*(\d+(?:\.\d+)?)"#, #"(\d+(?:\.\d+)?)"#]
        for pattern in patterns {
            if let range = title.range(of: pattern, options: .regularExpression) {
                let digits = title[range].drop { !$0.isNumber }
                if let value = Double(digits) { return value }
            }
        }
        return nil
    }

    /// IDs of `chapters` whose numbers are in `readNumbers`.
    public static func ids(in chapters: [Chapter], numbered readNumbers: Set<Double>) -> Set<String> {
        Set(chapters.filter { number(of: $0).map(readNumbers.contains) ?? false }.map(\.id))
    }

    /// Everything up to and including `number` (for imports that only keep "last read").
    public static func ids(in chapters: [Chapter], through number: Double) -> Set<String> {
        Set(chapters.filter { (Self.number(of: $0) ?? .infinity) <= number }.map(\.id))
    }
}
