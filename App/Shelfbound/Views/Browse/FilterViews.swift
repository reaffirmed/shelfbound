import RepoKit
import ShelfCore
import SwiftUI

/// A search in one source that starts with some filters set, such as a tag tapped on a
/// work's page.
struct TagSearchRoute: Hashable {
    let source: InstalledSource
    let values: [String: [String]]
    /// The tag, shown as the screen's title.
    let title: String
}

/// Every filter a source offers, in one screen. Edits a copy and hands it back on Apply,
/// so typing in a field doesn't start a search on every letter.
@MainActor
struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sourceID: String
    let filters: [SearchFilter]
    let values: [String: [String]]
    let apply: ([String: [String]]) -> Void

    @State private var draft: [String: [String]] = [:]

    private var groups: [(String?, [SearchFilter])] {
        var order: [String?] = []
        var byGroup: [String?: [SearchFilter]] = [:]
        for filter in filters {
            if byGroup[filter.group] == nil { order.append(filter.group) }
            byGroup[filter.group, default: []].append(filter)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(groups, id: \.0) { group in
                    Section(group.0 ?? "") {
                        ForEach(group.1) { filter in
                            FilterField(sourceID: sourceID, filter: filter, values: $draft)
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(cleaned(draft))
                        dismiss()
                    }
                    .accessibilityIdentifier("filters.apply")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset all", role: .destructive) {
                        var reset: [String: [String]] = [:]
                        for filter in filters { reset[filter.id] = filter.defaultValue ?? [] }
                        draft = reset
                    }
                }
            }
        }
        .onAppear { draft = values }
    }

    /// Drops empty text and ranges with nothing in them.
    private func cleaned(_ values: [String: [String]]) -> [String: [String]] {
        var out = values
        for filter in filters {
            switch filter.type {
            case .text:
                let text = (values[filter.id]?.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                out[filter.id] = text.isEmpty ? [] : [text]
            case .range, .date:
                let pair = values[filter.id] ?? []
                let min = pair.first ?? "", max = pair.count > 1 ? pair[1] : ""
                out[filter.id] = min.isEmpty && max.isEmpty ? [] : [min, max]
            default:
                break
            }
        }
        return out
    }
}

/// One filter as a form row, or a few rows for tags.
@MainActor
struct FilterField: View {
    let sourceID: String
    let filter: SearchFilter
    @Binding var values: [String: [String]]

    private var selected: [String] { values[filter.id] ?? [] }

    var body: some View {
        switch filter.type {
        case .toggle:
            Toggle(filter.label, isOn: Binding(
                get: { !selected.isEmpty },
                set: { values[filter.id] = $0 ? ["true"] : [] }))
        case .select:
            Picker(filter.label, selection: Binding(
                get: { selected.first ?? "" },
                set: { values[filter.id] = $0.isEmpty ? [] : [$0] }
            )) {
                ForEach(filter.options ?? []) { Text($0.label).tag($0.id) }
            }
        case .multi:
            NavigationLink {
                MultiPicker(filter: filter, values: $values)
            } label: {
                LabeledContent(filter.label, value: summary(of: selected))
            }
        case .text:
            TextField(filter.label, text: Binding(
                get: { selected.first ?? "" },
                set: { values[filter.id] = [$0] }
            ), prompt: Text(filter.placeholder ?? filter.label))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        case .range:
            RangeField(filter: filter, values: $values)
        case .date:
            DateRangeField(filter: filter, values: $values)
        case .tags:
            if let options = filter.options, !options.isEmpty {
                // A fixed list (a site's genres): tap them, the same as on the site, and
                // they go to the site as its genre filter, not as typed search words.
                VStack(alignment: .leading, spacing: 6) {
                    GenreGrid(filter: filter, values: $values)
                    if filter.excludable == true {
                        Text("Tap once to include, twice to exclude, three times to clear.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                TagField(sourceID: sourceID, filter: filter, values: $values)
            }
        }
    }

    private func summary(of ids: [String]) -> String {
        let labels = ids.compactMap { id in filter.options?.first { $0.id == id }?.label }
        switch labels.count {
        case 0: return "Any"
        case 1: return labels[0]
        default: return "\(labels.count) chosen"
        }
    }
}

@MainActor
private struct MultiPicker: View {
    let filter: SearchFilter
    @Binding var values: [String: [String]]

    var body: some View {
        List(filter.options ?? []) { option in
            let on = (values[filter.id] ?? []).contains(option.id)
            Button {
                var next = values[filter.id] ?? []
                if let i = next.firstIndex(of: option.id) { next.remove(at: i) } else { next.append(option.id) }
                values[filter.id] = next
            } label: {
                HStack {
                    Text(option.label).foregroundStyle(.primary)
                    Spacer()
                    if on { Image(systemName: "checkmark").foregroundStyle(Color.shelfAccent) }
                }
            }
        }
        .navigationTitle(filter.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// From and to, as whole numbers.
@MainActor
private struct RangeField: View {
    let filter: SearchFilter
    @Binding var values: [String: [String]]

    private func part(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let pair = values[filter.id] ?? []
                return index < pair.count ? pair[index] : ""
            },
            set: { text in
                var pair = values[filter.id] ?? []
                while pair.count < 2 { pair.append("") }
                pair[index] = text.filter(\.isNumber)
                values[filter.id] = pair
            })
    }

    var body: some View {
        HStack {
            Text(filter.label)
            Spacer()
            TextField("Min", text: part(0))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
            Text("to").foregroundStyle(.secondary)
            TextField("Max", text: part(1))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
            if let unit = filter.placeholder { Text(unit).foregroundStyle(.secondary).font(.footnote) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.range.\(filter.id)")
    }
}

/// From and to dates, each one optional: switch one on to pick it.
@MainActor
private struct DateRangeField: View {
    let filter: SearchFilter
    @Binding var values: [String: [String]]

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func stored(_ index: Int) -> String {
        let pair = values[filter.id] ?? []
        return index < pair.count ? pair[index] : ""
    }

    private func store(_ text: String, at index: Int) {
        var pair = values[filter.id] ?? []
        while pair.count < 2 { pair.append("") }
        pair[index] = text
        values[filter.id] = pair.allSatisfy(\.isEmpty) ? [] : pair
    }

    private func isOn(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { !stored(index).isEmpty },
            set: { on in
                if on {
                    // From starts a month back, to starts today.
                    let start = index == 0 ? Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() : Date()
                    store(Self.format.string(from: start), at: index)
                } else {
                    store("", at: index)
                }
            })
    }

    private func day(_ index: Int) -> Binding<Date> {
        Binding(
            get: { Self.format.date(from: stored(index)) ?? Date() },
            set: { store(Self.format.string(from: $0), at: index) })
    }

    var body: some View {
        Group {
            Toggle(isOn: isOn(0)) {
                Text(filter.label + " from")
            }
            if !stored(0).isEmpty {
                DatePicker("From", selection: day(0), in: ...Date(), displayedComponents: .date)
            }
            Toggle(isOn: isOn(1)) {
                Text(filter.label + " until")
            }
            if !stored(1).isEmpty {
                DatePicker("Until", selection: day(1), in: ...Date(), displayedComponents: .date)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.date.\(filter.id)")
    }

    /// "12 Jan 2024", for chips.
    static func display(_ text: String) -> String {
        guard let date = format.date(from: text) else { return text }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Chosen names as chips (tap one to switch it between include and leave out), a field to
/// type in, and suggestions from the filter's options or the source as you type.
@MainActor
private struct TagField: View {
    @Environment(AppModel.self) private var model
    let sourceID: String
    let filter: SearchFilter
    @Binding var values: [String: [String]]

    @State private var text = ""
    @State private var suggestions: [SearchFilter.Option] = []

    private var included: [String] { values[filter.id] ?? [] }
    private var excluded: [String] { values[filter.excludeKey] ?? [] }
    private var canExclude: Bool { filter.excludable == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(filter.label).font(.subheadline.weight(.semibold))
            if !included.isEmpty || !excluded.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(included, id: \.self) { name in chosen(name, excluded: false) }
                    ForEach(excluded, id: \.self) { name in chosen(name, excluded: true) }
                }
            }
            HStack {
                TextField(filter.placeholder ?? "Add \(filter.label.lowercased())", text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { add(text, exclude: false) }
                    .accessibilityIdentifier("filter.tags.\(filter.id)")
                if !text.isEmpty {
                    Button("Add") { add(text, exclude: false) }.buttonStyle(.borderless)
                }
            }
            ForEach(suggestions.prefix(8)) { option in
                HStack {
                    Button { add(option.id, exclude: false) } label: {
                        Label(option.label, systemImage: "plus.circle").foregroundStyle(.primary)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if canExclude {
                        Button { add(option.id, exclude: true) } label: {
                            Image(systemName: "minus.circle").foregroundStyle(Color.shelfWarning)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Leave out \(option.label)")
                    }
                }
                .font(.subheadline)
            }
            if canExclude && (!included.isEmpty || !excluded.isEmpty) {
                Text("Tap a tag to switch between including it and leaving it out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task(id: text) { await suggest() }
    }

    private func chosen(_ name: String, excluded isExcluded: Bool) -> some View {
        let label = filter.options?.first { $0.id == name }?.label ?? name
        return HStack(spacing: 4) {
            Button {
                guard canExclude else { return }
                remove(name)
                add(name, exclude: !isExcluded)
            } label: {
                Text(isExcluded ? "− \(label)" : label)
                    .strikethrough(isExcluded)
            }
            .buttonStyle(.borderless)
            Button { remove(name) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(label)")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(isExcluded ? Color.shelfWarning : Color.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(isExcluded ? Color.shelfWarning.opacity(0.15) : Color.shelfAccent))
    }

    private func add(_ raw: String, exclude: Bool) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        remove(name)
        values[exclude ? filter.excludeKey : filter.id, default: []].append(name)
        text = ""
        suggestions = []
    }

    private func remove(_ name: String) {
        values[filter.id] = included.filter { $0 != name }
        values[filter.excludeKey] = excluded.filter { $0 != name }
    }

    private func suggest() async {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { suggestions = []; return }
        let chosen = Set(included + excluded)
        if let options = filter.options, !options.isEmpty {
            let lower = typed.lowercased()
            suggestions = options.filter { $0.label.lowercased().contains(lower) && !chosen.contains($0.id) }
            return
        }
        guard filter.suggests == true else { return }
        // Wait for a pause in typing before asking the site.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, let runtime = try? model.runtime(for: sourceID) else { return }
        let found = (try? await runtime.suggest(filterID: filter.id, text: typed)) ?? []
        guard !Task.isCancelled else { return }
        suggestions = found.filter { !chosen.contains($0.id) }
    }
}

/// A chip for a text, range or tags filter in the chip bar. It shows what's set, and a
/// tap opens the full filter screen.
@MainActor
struct FilterSummaryChip: View {
    let filter: SearchFilter
    let values: [String: [String]]
    let open: () -> Void

    var body: some View {
        Button(action: open) { FilterChipLabel(text: text, on: true) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("filter.chip")
    }

    private var text: String {
        let current = values[filter.id] ?? []
        switch filter.type {
        case .text:
            return "\(filter.label): \(current.first ?? "")"
        case .range:
            let min = current.first ?? "", max = current.count > 1 ? current[1] : ""
            let range = min.isEmpty ? "up to \(max)" : max.isEmpty ? "\(min)+" : "\(min)–\(max)"
            return "\(filter.label): \(range)"
        case .date:
            let from = (current.first ?? "").isEmpty ? "" : DateRangeField.display(current[0])
            let to = current.count > 1 && !current[1].isEmpty ? DateRangeField.display(current[1]) : ""
            let range = from.isEmpty ? "until \(to)" : to.isEmpty ? "since \(from)" : "\(from)–\(to)"
            return "\(filter.label): \(range)"
        default:
            let names = current + (values[filter.excludeKey] ?? []).map { "−\($0)" }
            if names.count == 1 {
                let name = names[0]
                return filter.options?.first { $0.id == name }?.label ?? name
            }
            return "\(filter.label) · \(names.count)"
        }
    }
}

/// The capsule every filter chip uses. The same weight on and off, and no animation when
/// the text changes, so a new value replaces the old one at once.
struct FilterChipLabel: View {
    let text: String
    let on: Bool
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .contentTransition(.identity)
        .foregroundStyle(on ? Color.white : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(on ? Color.shelfAccent : Color(.tertiarySystemFill)))
        .transaction { $0.animation = nil }
    }
}

/// One button beside the results that flips between the list and big covers. It sits in
/// the results, not the toolbar, because the toolbar hides while the search field is active.
struct SearchLayoutToggle: View {
    @Binding var layout: SearchLayout

    var body: some View {
        Button {
            layout = layout == .list ? .covers : .list
        } label: {
            Image(systemName: layout == .list ? SearchLayout.covers.systemImage : SearchLayout.list.systemImage)
                .font(.body.weight(.medium))
                .frame(width: 36, height: 32)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout == .list ? "Show results as covers" : "Show results as a list")
        .accessibilityIdentifier("search.layout")
    }
}

/// How search results show: a list with details, or a grid of big covers like Discover.
enum SearchLayout: String, CaseIterable, Identifiable {
    case list, covers

    static let key = "search.layout"

    var id: String { rawValue }
    var label: String { self == .list ? "List" : "Covers" }
    var systemImage: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// The toolbar button that switches search results between the list and big covers.
struct SearchLayoutMenu: View {
    @Binding var layout: SearchLayout

    var body: some View {
        Menu {
            Picker("Show results as", selection: $layout) {
                ForEach(SearchLayout.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
            }
        } label: {
            Image(systemName: layout.systemImage)
        }
        .accessibilityLabel("Show results as")
    }
}

/// One cover with the title under it, for the cover grids. Its height depends only on
/// the column width (a 2:3 cover and two title lines kept even for a short title), so
/// every tile in a grid is the same size and rows never resize as covers load.
@MainActor
struct CoverTile: View {
    let item: CoverGrid.Item
    let open: (WorkRoute) -> Void

    var body: some View {
        Button { open(item.route) } label: {
            let work = item.route.summary
            VStack(alignment: .leading, spacing: 3) {
                CoverView(
                    title: work.title, author: work.authors.first ?? "", format: item.format, url: work.coverURL,
                    words: work.wordCount, chapters: work.chapterCount)
                TileText(title: work.title, caption: item.caption ?? work.authors.first ?? work.fandoms?.first ?? item.format.label)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("work.result")
        .contextMenu {
            if !item.alternatives.isEmpty {
                ForEach(Array(item.alternatives.enumerated()), id: \.offset) { _, alternative in
                    Button("Open on \(alternative.0)") { open(alternative.1) }
                }
            }
        }
    }
}

/// Search results as big covers with the title under them, the way Discover shows its
/// rows. Sits in one list row so it works inside the same List as the other results.
/// For a short, fixed set of results only: a list that loads more pages uses
/// `PagedCoverGrid`, since one list row that keeps growing makes the list jump.
@MainActor
struct CoverGrid: View {
    struct Item: Identifiable {
        let route: WorkRoute
        let format: WorkFormat
        /// A line under the tile in place of its usual meta, like the source's name.
        var caption: String? = nil
        /// The same work on other sources, offered on touch and hold.
        var alternatives: [(String, WorkRoute)] = []
        var id: String { route.key.id }
    }

    let items: [Item]
    /// Opens a work. A button rather than a NavigationLink, which in a List row would add
    /// a disclosure chevron beside every tile.
    let open: (WorkRoute) -> Void

    /// Three across on a phone, more on wider screens, each cover as wide as its column.
    static let columns = [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
            ForEach(items) { CoverTile(item: $0, open: open) }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .listRowBackground(Color.clear)
    }
}

/// A grid of covers that loads more as you scroll, in its own scroll view rather than a
/// List row. Each tile is laid out lazily and keeps its size, so a new page only adds
/// rows below and nothing above it moves. The next page is asked for while about two
/// screens of covers are still left, so it's usually there before you reach the end.
@MainActor
struct PagedCoverGrid<Header: View>: View {
    let items: [CoverGrid.Item]
    /// The last page loaded, passed on to the footer.
    let page: Int
    let hasMore: Bool
    /// The last page failed, so the end shows Try again instead of a spinner.
    let failed: Bool
    let loadMore: (_ retry: Bool) -> Void
    let open: (WorkRoute) -> Void
    @ViewBuilder var header: () -> Header

    /// How many tiles from the end the next page is fetched.
    static var prefetchDistance: Int { 24 }

    var body: some View {
        // The trigger is a set of IDs worked out once per update, not an index lookup per tile.
        let trigger = Set(items.suffix(Self.prefetchDistance).map(\.id))
        ScrollView {
            header()
            LazyVGrid(columns: CoverGrid.columns, alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    CoverTile(item: item, open: open)
                        .onAppear { if hasMore, trigger.contains(item.id) { loadMore(false) } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            PageFooter(hasMore: hasMore, failed: failed, page: page, loadMore: loadMore)
                .padding(.horizontal, 16)
        }
    }
}

extension PagedCoverGrid where Header == EmptyView {
    init(items: [CoverGrid.Item], page: Int, hasMore: Bool, failed: Bool,
         loadMore: @escaping (_ retry: Bool) -> Void, open: @escaping (WorkRoute) -> Void) {
        self.init(items: items, page: page, hasMore: hasMore, failed: failed, loadMore: loadMore, open: open) { EmptyView() }
    }
}

/// The end of a list that loads more: a spinner while there's more to come, or Try again
/// after a failed page. It keeps one fixed height, so swapping between the two never
/// nudges the rows above it. Reaching it also asks for the next page, as a fallback for
/// when the prefetch didn't fire (a short page, or a failed one).
struct PageFooter: View {
    let hasMore: Bool
    let failed: Bool
    /// The page shown last. The footer asks again whenever it changes while still on
    /// screen, as after a page that brought only works already shown.
    var page = 0
    let loadMore: (_ retry: Bool) -> Void

    var body: some View {
        if hasMore {
            ZStack {
                if failed {
                    Button("Try again") { loadMore(true) }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            // Load in a Task of its own (inside loadMore), since this one is cancelled as
            // soon as the footer scrolls away.
            .task(id: page) { if !failed { loadMore(false) } }
        } else {
            Color.clear.frame(height: 24)
        }
    }
}
