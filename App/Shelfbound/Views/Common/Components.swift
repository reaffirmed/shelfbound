import LibraryKit
import ShelfCore
import SwiftUI

/// A cover: the real one when the source has it, otherwise a typographic one like the
/// mockup's (fics never have covers).
@MainActor
struct CoverView: View {
    let title: String
    var author: String = ""
    let format: WorkFormat
    var url: URL? = nil
    var words: Int? = nil
    var chapters: String? = nil
    var compact = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                if format.isText {
                    textCover(w)
                } else {
                    RemoteImage(url: url, width: w) { artCover(w) }
                }
            }
            .frame(width: w, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: max(4, w * 0.05), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: max(4, w * 0.05), style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var hue: Double { Hue.of(title) }

    private func textCover(_ w: CGFloat) -> some View {
        let bg = Color(hue: hue, saturation: 0.32, brightness: 0.93)
        let ink = Color(hue: hue, saturation: 0.55, brightness: 0.28)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(format.label.uppercased()).font(.system(size: max(6, w * 0.075), weight: .bold)).tracking(1)
                Spacer()
                Text("¶").font(.system(size: max(8, w * 0.12), design: .serif))
            }
            Spacer(minLength: 2)
            Text(title)
                .font(.system(size: max(8, w * (compact ? 0.13 : 0.115)), weight: .semibold, design: .serif))
                .lineLimit(compact ? 3 : 5)
                .minimumScaleFactor(0.7)
            if !author.isEmpty && !compact {
                Text(author).font(.system(size: max(6, w * 0.075))).opacity(0.75).lineLimit(1).padding(.top, 2)
            }
            Spacer(minLength: 2)
            if !compact {
                HStack {
                    if let words { Text(words >= 1000 ? "\(words / 1000)k" : "\(words)") }
                    Spacer()
                    if let chapters { Text(chapters) }
                }
                .font(.system(size: max(6, w * 0.07), weight: .medium).monospacedDigit())
                .opacity(0.7)
            }
        }
        .foregroundStyle(ink)
        .padding(w * 0.09)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(bg)
    }

    private func artCover(_ w: CGFloat) -> some View {
        let a = Color(hue: hue, saturation: 0.55, brightness: 0.62)
        let b = Color(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.24)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.18)).frame(width: w * 0.42).offset(x: w * 0.45, y: -w * 0.9)
            VStack(alignment: .leading, spacing: 2) {
                Text(format.label.uppercased()).font(.system(size: max(6, w * 0.07), weight: .bold)).tracking(1).opacity(0.8)
                Text(title).font(.system(size: max(8, w * 0.12), weight: .heavy)).lineLimit(3).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(w * 0.08)
        }
    }
}

/// Cover plus the red "new chapters" badge and the downloaded check, as in the mockup.
@MainActor
struct BadgedCover: View {
    let record: WorkRecord
    var showBadge = true
    var downloaded = false
    var compact = false

    var body: some View {
        CoverView(
            title: record.title, author: record.authors.first ?? "", format: record.format, url: record.coverURL,
            words: record.work?.wordCount ?? record.summary.wordCount,
            chapters: record.work?.chapterCount ?? record.summary.chapterCount, compact: compact)
            .overlay(alignment: .topTrailing) {
                if showBadge, record.unreadNewCount > 0 {
                    Text("\(record.unreadNewCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Color.shelfBadge))
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("\(record.unreadNewCount) new")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if downloaded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.shelfAccent))
                        .padding(4)
                        .accessibilityLabel("Downloaded")
                }
            }
    }
}

enum ChipStyle {
    case plain, rating, warning, category, ship, outline, free

    var background: Color {
        switch self {
        case .plain: Color(.tertiarySystemFill)
        case .rating: Color.shelfRating.opacity(0.22)
        case .warning: Color.shelfWarning.opacity(0.18)
        case .category: Color.shelfCategory.opacity(0.16)
        case .ship: Color.shelfAccent.opacity(0.15)
        case .outline, .free: .clear
        }
    }

    var foreground: Color {
        switch self {
        case .warning: .shelfWarning
        case .ship: .shelfAccent
        case .free: .secondary
        default: .primary
        }
    }
}

@MainActor
struct Chip: View {
    let text: String
    var style: ChipStyle = .plain
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
            Text(text)
        }
        .font(.footnote.weight(style == .warning || style == .ship ? .semibold : .regular))
        .foregroundStyle(style.foreground)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(style.background))
        .overlay {
            if style == .outline || style == .free { Capsule().strokeBorder(Color(.separator)) }
        }
    }
}

/// Lays children out left to right, wrapping to new lines (tag chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            width = max(width, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (origins, width, y + lineHeight)
    }
}

/// The coloured two-letter square used for sources.
@MainActor
struct SourceIcon: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Text(name.monogram)
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(hue: Hue.of(name), saturation: 0.55, brightness: 0.62)))
    }
}

/// Settings-style icon tile.
@MainActor
struct RowIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
    }
}

@MainActor
struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(Color.shelfAccent).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

extension WorkRecord {
    /// "Ch. 85 of 87" for images, "Chapter 9 of 20" for text.
    var progressLine: String? {
        guard let position else { return nil }
        let order = readingOrder
        let index = order.firstIndex { $0.id == position.chapterID }.map { $0 + 1 }
        let total = work?.chapterCount?.split(separator: "/").last.map(String.init) ?? (order.isEmpty ? "?" : "\(order.count)")
        guard let index else { return position.chapterTitle }
        return format.isText ? "Chapter \(index) of \(total)" : "Ch. \(index) of \(total)"
    }
}
