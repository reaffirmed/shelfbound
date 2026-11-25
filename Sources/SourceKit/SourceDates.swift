import Foundation

/// Dates from sources: ISO 8601 with or without fractional seconds (what JavaScript's
/// `toISOString()` writes), a plain "2024-05-01" day, or milliseconds since 1970.
enum SourceDates {
    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let ms = try? container.decode(Double.self) { return Date(timeIntervalSince1970: ms / 1000) }
        let text = try container.decode(String.self)
        if let date = parse(text) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(text)")
    }

    static func parse(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withFullDate]
        return full.date(from: text)
    }
}
