import SwiftUI
import UIKit

extension Color {
    /// Shelfbound green from the mockup, lighter in dark mode.
    static let shelfAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.239, green: 0.745, blue: 0.624, alpha: 1)
        : UIColor(red: 0.090, green: 0.459, blue: 0.373, alpha: 1) })
    static let shelfBadge = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.0, green: 0.353, blue: 0.376, alpha: 1)
        : UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1) })
    static let shelfWarning = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.910, green: 0.604, blue: 0.329, alpha: 1)
        : UIColor(red: 0.722, green: 0.384, blue: 0.106, alpha: 1) })
    static let shelfRating = Color(red: 0.886, green: 0.690, blue: 0.027)
    static let shelfCategory = Color(red: 0.761, green: 0.278, blue: 0.482)

    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

enum Hue {
    /// A stable hue (0...1) for a string, so generated covers keep their colour.
    static func of(_ text: String) -> Double {
        var hash: UInt64 = 5381
        for byte in text.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Double(hash % 360) / 360
    }
}

extension Error {
    var readable: String { (self as? LocalizedError)?.errorDescription ?? localizedDescription }
}

extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two-letter monogram for a source icon: "Kiosk Scans" -> "KS", "Lanternlight" -> "LA".
    var monogram: String {
        let words = split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 { return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased() }
        return String(prefix(2)).uppercased()
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Int {
    /// 84312 -> "84,312"
    var grouped: String { formatted(.number) }
}
