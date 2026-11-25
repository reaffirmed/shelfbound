import LibraryKit
import ShelfCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Translates a chapter's paragraphs on the device with Apple's Translation framework
/// (iOS 18 and later). Nothing is sent to a server: the system downloads the language
/// pair once, asking first. Results are cached on disk per chapter.
@MainActor
struct ChapterTranslation: ViewModifier {
    let workID: String
    let chapterID: String
    let paragraphs: [String]
    let source: String?
    let target: String?
    @Binding var translated: [String]?
    @Binding var state: TranslationState

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.modifier(Runner(
                workID: workID, chapterID: chapterID, paragraphs: paragraphs, source: source, target: target,
                translated: $translated, state: $state))
        } else {
            content
        }
        #else
        content
        #endif
    }

    static var isAvailable: Bool {
        #if canImport(Translation)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }
}

enum TranslationState: Equatable {
    case idle, translating, done, failed(String)
}

#if canImport(Translation)
@available(iOS 18.0, *)
@MainActor
private struct Runner: ViewModifier {
    let workID: String
    let chapterID: String
    let paragraphs: [String]
    let source: String?
    let target: String?
    @Binding var translated: [String]?
    @Binding var state: TranslationState
    @State private var configuration: TranslationSession.Configuration?

    private var cacheKey: String? {
        guard let target, !paragraphs.isEmpty else { return nil }
        return TranslationCache.key(work: workID, chapter: chapterID, source: source, target: target, paragraphs: paragraphs)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: cacheKey, initial: true) { _, key in start(key) }
            .translationTask(configuration) { session in
                await run(session)
            }
    }

    private func start(_ key: String?) {
        guard let key, let target else {
            translated = nil
            state = .idle
            configuration = nil
            return
        }
        if let cached = TranslationCache.default().load(key, count: paragraphs.count) {
            translated = cached
            state = .done
            return
        }
        state = .translating
        let next = TranslationSession.Configuration(
            source: source.map { Locale.Language(identifier: $0) }, target: Locale.Language(identifier: target))
        if configuration?.source == next.source, configuration?.target == next.target {
            configuration?.invalidate()
        } else {
            configuration = next
        }
    }

    private func run(_ session: TranslationSession) async {
        let input = paragraphs
        guard let key = cacheKey, !input.isEmpty else { return }
        let requests = input.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        do {
            var output = input
            for response in try await session.translations(from: requests) {
                if let index = response.clientIdentifier.flatMap(Int.init), output.indices.contains(index) {
                    output[index] = response.targetText
                }
            }
            // The chapter may have changed while this ran.
            guard key == cacheKey else { return }
            TranslationCache.default().save(key, output)
            translated = output
            state = .done
        } catch {
            guard key == cacheKey else { return }
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if TranslationError.unsupportedSourceLanguage ~= error { return "This chapter's language can't be translated on this device yet." }
        if TranslationError.unsupportedLanguagePairing ~= error { return "Those two languages can't be translated between on this device." }
        if TranslationError.unableToIdentifyLanguage ~= error { return "Couldn't tell what language this chapter is in. Pick it in Translate." }
        return error.localizedDescription
    }
}
#endif

/// Choose the language to translate a work into, and the one it's written in.
@MainActor
struct TranslationSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    @State private var languages: [String] = []

    var body: some View {
        let settings = model.record(key)?.settings ?? WorkSettings()
        Form {
            Section {
                Picker("Translate into", selection: Binding(
                    get: { settings.translateTo },
                    set: { value in model.updateRecord(key) { $0.settings.translateTo = value } }
                )) {
                    Text("Off (read the original)").tag(String?.none)
                    ForEach(targets, id: \.self) { Text(Self.name($0)).tag(String?.some($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Translate into")
            } footer: {
                Text("Chapters are translated on this iPhone by Apple's translation models, and nothing is sent to a server. The first time you pick a language, iOS asks to download it. Formatting such as italics is lost in translated paragraphs.")
            }
            if settings.translateTo != nil {
                Section("Written in") {
                    Picker("Written in", selection: Binding(
                        get: { settings.translateFrom },
                        set: { value in model.updateRecord(key) { $0.settings.translateFrom = value } }
                    )) {
                        Text("Detect automatically").tag(String?.none)
                        ForEach(languages, id: \.self) { Text(Self.name($0)).tag(String?.some($0)) }
                    }
                }
            }
        }
        .navigationTitle("Translate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { languages = await Self.supportedLanguages() }
    }

    /// The device's own languages first, then the rest.
    private var targets: [String] {
        let preferred = Locale.preferredLanguages.compactMap { Locale.Language(identifier: $0).languageCode?.identifier }
        let known = Set(languages)
        var out: [String] = []
        for code in preferred where (known.isEmpty || known.contains(code)) && !out.contains(code) { out.append(code) }
        for code in languages where !out.contains(code) { out.append(code) }
        return out
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    private static func supportedLanguages() async -> [String] {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            let all = await LanguageAvailability().supportedLanguages
            let codes = Set(all.compactMap { language -> String? in
                guard let code = language.languageCode?.identifier else { return nil }
                // Keep scripts apart where they matter, such as Chinese.
                if let script = language.script?.identifier, code == "zh" { return "\(code)-\(script)" }
                return code
            })
            return codes.sorted { name($0) < name($1) }
        }
        #endif
        return []
    }
}

/// The system translation sheet over a piece of text (iOS 17.4 and later), for summaries.
@MainActor
struct SystemTranslation: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    static var isAvailable: Bool {
        #if canImport(Translation)
        if #available(iOS 17.4, *) { return true }
        #endif
        return false
    }

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
