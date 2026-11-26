import RepoKit
import ShelfCore
import SwiftUI
import WebKit

/// Settings > Accounts: sources the person can sign in to, such as AO3.
@MainActor
struct AccountsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.accountSources) { source in
                NavigationLink {
                    AccountDetailView(source: source)
                } label: {
                    HStack {
                        Text(source.manifest.name)
                        Spacer()
                        Text(model.accounts[source.id].map { $0.username } ?? "Sign in")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("account.source")
            }
        }
        .overlay {
            if model.accountSources.isEmpty {
                ContentUnavailableView(
                    "No accounts", systemImage: "person.crop.circle",
                    description: Text("Install a source that supports signing in to see it here."))
            }
        }
        .navigationTitle("Accounts")
    }
}

/// One site: sign in or out, browse the person's lists, and import them into the library.
@MainActor
struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    let source: InstalledSource

    @State private var signingIn = false
    @State private var lists: [AccountList] = []
    @State private var error: String?
    @State private var checking = false
    @State private var confirmSignOut = false
    @State private var importer = AccountImport()

    private var account: SavedAccount? { model.accounts[source.id] }

    var body: some View {
        List {
            if let account {
                Section {
                    LabeledContent("Signed in as", value: account.username)
                    Button(checking ? "Checking..." : "Check sign-in") { Task { await check() } }
                        .disabled(checking)
                } footer: {
                    Text("Shelfbound keeps \(source.manifest.name)'s sign-in cookie in your Keychain. It never sees or stores your password. Chapters you read while signed in count in your \(source.manifest.name) history.")
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.shelfWarning) }
                }

                Section("Your lists") {
                    ForEach(lists) { list in
                        NavigationLink {
                            AccountListView(source: source, list: list)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.title)
                                if let subtitle = list.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if lists.isEmpty && error == nil { ProgressView() }
                }

                let importable = lists.filter { $0.importable == true }
                if !importable.isEmpty {
                    Section {
                        ForEach(importable) { list in
                            importRow(list)
                        }
                    } header: {
                        Text("Add to your library")
                    } footer: {
                        Text("Import adds every work in the list to your library, grouped by fandom. Keep in sync adds new ones each time Shelfbound checks for updates. Shelfbound only ever adds: it never removes anything from your account or your library.")
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Signing out here forgets the session on this phone. Your library stays as it is.")
                }
            } else {
                Section {
                    Button {
                        signingIn = true
                    } label: {
                        Label("Sign in to \(source.manifest.name)", systemImage: "person.crop.circle.badge.plus")
                    }
                } footer: {
                    Text("You sign in on \(source.manifest.name)'s own page. Then you can import your bookmarks and reading list, read works only for signed-in users, and mark, subscribe and leave kudos from a work's page.")
                }
            }
        }
        .navigationTitle(source.manifest.name)
        .task(id: account?.username) { await loadLists() }
        .sheet(isPresented: $signingIn) {
            if let login = source.manifest.account?.loginURL {
                SignInSheet(source: source, loginURL: login)
            }
        }
        .confirmationDialog("Sign out of \(source.manifest.name)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                model.signOut(sourceID: source.id)
                Task { await SignInSheet.clearWebSession(for: source.manifest.domains) }
            }
        }
    }

    @ViewBuilder
    private func importRow(_ list: AccountList) -> some View {
        let running = importer.running && importer.listID == list.id
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(list.title)
                Spacer()
                if running {
                    Button("Stop") { importer.stop() }
                } else {
                    Button("Import") { importer.start(sourceID: source.id, list: list, model: model) }
                        .disabled(importer.running)
                }
            }
            if importer.listID == list.id, let status = importer.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Keep in sync", isOn: Binding(
                get: { account?.syncedLists.contains(list.id) ?? false },
                set: { model.setSynced(list.id, $0, for: source.id) }))
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func loadLists() async {
        guard account != nil else { return }
        do {
            lists = try await model.accountLists(sourceID: source.id)
            error = nil
        } catch {
            self.error = error.readable
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            let ok = try await model.checkSignIn(sourceID: source.id)
            error = ok ? nil : "\(source.manifest.name) signed you out. Sign in again."
        } catch {
            self.error = error.readable
        }
    }
}

/// Copies one of the person's lists into the library, page by page.
@MainActor
@Observable
final class AccountImport {
    private(set) var listID: String?
    private(set) var running = false
    private(set) var status: String?
    private var task: Task<Void, Never>?

    func start(sourceID: String, list: AccountList, model: AppModel) {
        guard !running else { return }
        listID = list.id
        running = true
        status = "Starting..."
        task = Task {
            var added: [WorkKey] = []
            var seen = 0
            var page = 1
            do {
                // AO3 shows 20 works a page; 250 pages is 5,000 works, more than enough.
                while page <= 250, !Task.isCancelled {
                    let result = try await model.accountList(sourceID: sourceID, listID: list.id, page: page)
                    for work in result.results {
                        seen += 1
                        let key = WorkKey(sourceID: sourceID, workID: work.id)
                        if model.addToLibrary(key, summary: work) { added.append(key) }
                    }
                    status = "Page \(page): \(added.count) added, \(seen - added.count) already in your library"
                    guard result.hasMore, !result.results.isEmpty else { break }
                    page += 1
                }
                status = Task.isCancelled
                    ? "Stopped. \(added.count) added."
                    : "Done. \(added.count) added, \(seen - added.count) were already in your library."
            } catch {
                status = "\(added.count) added, then: \(error.readable)"
            }
            running = false
            model.saveNow()
            // Fetch chapter lists for the new works in the background.
            if !added.isEmpty {
                let keys = Set(added)
                Task { await model.checkForUpdates(only: keys) }
            }
        }
    }

    func stop() {
        task?.cancel()
    }
}

/// The whole of one of the person's lists, loading more as you scroll.
@MainActor
struct AccountListView: View {
    @Environment(AppModel.self) private var model
    let source: InstalledSource
    let list: AccountList

    @State private var results: [WorkSummary] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(results) { work in
                NavigationLink(value: WorkRoute(key: WorkKey(sourceID: source.id, workID: work.id), summary: work)) {
                    WorkCard(work: work, format: work.format ?? source.manifest.defaultFormat)
                }
                .onAppear { if work.id == results.last?.id { Task { await load(page + 1) } } }
            }
            if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load(page + 1) } }
                }
            } else if loading && !results.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .overlay {
            if results.isEmpty && loading {
                ProgressView()
            } else if results.isEmpty && !hasMore && error == nil {
                ContentUnavailableView("Nothing here yet", systemImage: "tray")
            }
        }
        .navigationTitle(list.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(1) }
        .task { if results.isEmpty { await load(1) } }
    }

    private func load(_ next: Int) async {
        guard !loading, hasMore || next == 1 else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.accountList(sourceID: source.id, listID: list.id, page: next)
            if next == 1 {
                // AO3 repeats a work when a bookmark changes between pages; a repeated ID breaks the list.
                results = result.results.uniqued()
            } else {
                let seen = Set(results.map(\.id))
                results += result.results.uniqued().filter { !seen.contains($0.id) }
            }
            page = next
            hasMore = result.hasMore && !result.results.isEmpty
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.readable
        }
    }
}

/// The site's own sign-in page in a web view. The person signs in there; Shelfbound
/// watches for the page to move on, then asks the source who is signed in and keeps the
/// site's cookies. It never reads or fills in the form.
@MainActor
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: InstalledSource
    let loginURL: URL

    @State private var controller = SignInController()
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            SignInWebView(url: loginURL, controller: controller) { url in
                // Leaving the sign-in page usually means it worked.
                if url.path != loginURL.path { Task { await finish(quiet: true) } }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(message ?? "Sign in to \(source.manifest.name) below. Shelfbound keeps the sign-in cookie, not your password.")
                    .font(.footnote)
                    .foregroundStyle(message == nil ? Color.secondary : Color.shelfWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(checking ? "Checking..." : "Done") { Task { await finish(quiet: false) } }.disabled(checking)
                }
            }
        }
        .interactiveDismissDisabled(checking)
    }

    private func finish(quiet: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let cookies = await controller.cookies()
        await controller.keepBrowserIdentity(for: source.manifest.domains, cookies: cookies)
        do {
            if let account = try await model.finishSignIn(sourceID: source.id, cookies: cookies) {
                message = nil
                _ = account
                dismiss()
            } else if !quiet {
                message = "\(source.manifest.name) doesn't show you signed in yet. Finish signing in, then tap Done."
            }
        } catch {
            if !quiet { message = error.readable }
        }
    }

    /// Removes the site's cookies from the web view too, so the next sign-in starts fresh.
    static func clearWebSession(for domains: [String]) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all = await store.allCookies()
        for cookie in AccountKeychain.cookies(all, matching: domains) {
            await store.deleteCookie(cookie)
        }
    }
}

@MainActor
final class SignInController {
    weak var webView: WKWebView?

    func cookies() async -> [HTTPCookie] {
        guard let webView else { return [] }
        return await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    /// If the site set a bot-check clearance during sign-in, requests must carry the same
    /// User-Agent, as after "Verify in browser".
    func keepBrowserIdentity(for domains: [String], cookies: [HTTPCookie]) async {
        guard let webView,
              let clearance = AccountKeychain.cookies(cookies, matching: domains).first(where: { $0.name == "cf_clearance" }),
              let agent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String, !agent.isEmpty
        else { return }
        let domain = clearance.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        ClearanceStore.shared.record(host: domain, userAgent: agent)
    }
}

@MainActor
struct SignInWebView: UIViewRepresentable {
    let url: URL
    let controller: SignInController
    let onPage: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "signin.web"
        controller.webView = view
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPage: (URL) -> Void

        init(onPage: @escaping (URL) -> Void) { self.onPage = onPage }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { onPage(url) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let scheme = action.request.url?.scheme, scheme == "https" || scheme == "http" || scheme == "about" else { return .cancel }
            return .allow
        }
    }
}
