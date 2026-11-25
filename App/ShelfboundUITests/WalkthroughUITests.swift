import XCTest

/// Walks the main flows on a fresh install against the live sources repo and saves a
/// screenshot after every step. Steps keep going after a failure, so one broken screen
/// still leaves screenshots of the rest. CI exports the screenshots as an artifact.
final class WalkthroughUITests: XCTestCase {
    static let repoURL = "https://reaffirmed.github.io/shelfbound-sources/"

    private var app: XCUIApplication!
    private var shot = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    func testWalkthrough() {
        step("Library on first launch") {
            dismissSystemAlerts()
            XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20), "No Library tab")
            app.tabBars.buttons["Library"].tap()
        }

        step("Browse") {
            app.tabBars.buttons["Browse"].tap()
            XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 10))
        }

        step("Add repository: check") {
            tapFirst([app.navigationBars["Browse"].buttons["Add repository"], app.buttons["Add Repository…"]])
            let field = app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "No URL field")
            field.tap()
            field.typeText(Self.repoURL)
            tapFirst([app.buttons["Check repository"]])
            XCTAssertTrue(app.staticTexts["About this repository"].waitForExistence(timeout: 30)
                          || app.staticTexts["ABOUT THIS REPOSITORY"].exists,
                          "Repository preview didn't load")
        }

        step("Add repository: added") {
            let add = app.collectionViews.buttons["Add repository"]
            if !add.exists { app.swipeUp() }
            tapFirst([add])
            XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 10))
        }

        step("Repository sources") {
            let row = app.buttons.matching(identifier: "browse.repo").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "Repository not listed in Browse")
            row.tap()
            XCTAssertTrue(app.buttons["Install"].waitForExistence(timeout: 30), "No installable sources")
        }

        step("Install WeebCentral") { install(matching: "weeb") }
        step("Install AO3") { install(matching: "ao3", or: "archive of our own") }

        // AO3 is rated Explicit, and explicit sources stay hidden until allowed in Settings.
        step("Settings: allow explicit sources") {
            app.tabBars.buttons["Settings"].tap()
            let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Show sources rated up to'")).firstMatch
            for _ in 0..<5 where !(picker.exists && picker.isHittable) { app.swipeUp(); sleep(1) }
            guard picker.waitForExistence(timeout: 5) else { return XCTFail("No content rating setting") }
            picker.tap()
            let explicit = app.buttons["Explicit"]
            if explicit.waitForExistence(timeout: 5) { explicit.tap() } else { XCTFail("No Explicit option") }
            sleep(1)
        }

        step("Search all sources") {
            app.tabBars.buttons["Browse"].tap()
            popToRoot()
            XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 10))
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            search.typeText("solo leveling\n")
            XCTAssertTrue(firstResult().waitForExistence(timeout: 45), "No search results")
            sleep(3)
        }

        step("Search results by source") {
            let bySource = app.segmentedControls.buttons["By source"]
            if bySource.waitForExistence(timeout: 5) { bySource.tap(); sleep(2) }
        }

        step("Search results merged") {
            let merged = app.segmentedControls.buttons["Merged"]
            if merged.exists { merged.tap(); sleep(1) }
            endSearch()
        }

        sourceFlow(name: "WeebCentral", matching: "weeb", query: "solo leveling", prefix: "Manga")
        // CI sets AO3_REACHABLE=0 when AO3 refuses the runner (it often sends 429 to cloud
        // machines). Then AO3's source page and chips are still checked, but not its network steps.
        let ao3Reachable = ProcessInfo.processInfo.environment["AO3_REACHABLE"] != "0"
        sourceFlow(name: "AO3", matching: "ao3", or: "archive", query: "coffee shop", prefix: "Fic", network: ao3Reachable)

        step("Library after reading") {
            app.tabBars.buttons["Library"].tap()
            sleep(2)
        }
    }

    // MARK: Flows

    private func sourceFlow(name: String, matching: String, or other: String? = nil, query: String, prefix: String, network: Bool = true) {
        step("\(name): source search") {
            app.tabBars.buttons["Browse"].tap()
            popToRoot()
            let row = app.buttons.matching(identifier: "browse.source").matching(sourceRow(matching, other)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "\(name) not in installed sources")
            row.tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
            sleep(3) // filters load from the source
        }

        step("\(name): filter chip menu") {
            let chip = app.buttons.matching(identifier: "filter.chip").firstMatch
            guard chip.waitForExistence(timeout: 5) else { return XCTFail("\(name) has no filter chips") }
            chip.tap()
            sleep(1)
        }

        step("\(name): filter chip chosen") {
            // A menu shows its options as buttons; pick the second if there is one, else close it.
            let options = app.collectionViews.buttons
            if options.count > 1 { options.element(boundBy: 1).tap() } else { app.tap() }
            sleep(1)
        }

        step("\(name): multi-select menu after one tap") {
            let multi = app.buttons.matching(identifier: "filter.chip")
                .matching(NSPredicate(format: "label CONTAINS[c] 'warning' OR label CONTAINS[c] 'genre' OR label CONTAINS[c] 'type'")).firstMatch
            guard multi.exists else { return }
            if !multi.isHittable { app.scrollViews.firstMatch.swipeLeft() }
            multi.tap()
            sleep(1)
            let options = app.collectionViews.buttons
            if options.count > 0 { options.element(boundBy: 0).tap() }
            sleep(1) // the screenshot shows whether the menu stayed open
        }

        step("\(name): multi-select menu closed") {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            sleep(1)
        }

        guard network else {
            step("\(name): search (site unreachable from CI, not checked)") {
                let search = app.searchFields.firstMatch
                search.tap()
                search.typeText("\(query)\n")
                sleep(8)
            }
            return
        }

        step("\(name): search results") {
            let search = app.searchFields.firstMatch
            search.tap()
            search.typeText("\(query)\n")
            if !firstResult().waitForExistence(timeout: 45) {
                // One retry, for a slow site: submit the same search again.
                search.tap()
                search.typeText("\n")
                XCTAssertTrue(firstResult().waitForExistence(timeout: 45), "No \(name) results for \(query)")
            }
            sleep(2)
        }

        step("\(name): results while re-sorting") {
            let chip = app.buttons.matching(identifier: "filter.chip").firstMatch
            guard chip.exists else { return }
            chip.tap()
            let options = app.collectionViews.buttons
            if options.waitForExistence(timeout: 3), options.count > 2 { options.element(boundBy: 2).tap() }
            // No wait: this screenshot should catch the old results dimmed while new ones load.
        }

        step("\(name): results after re-sorting") {
            XCTAssertTrue(firstResult().waitForExistence(timeout: 45), "No \(name) results after re-sorting")
            sleep(2)
        }

        step("\(name): series page") {
            firstResult().tap()
            let read = readButton()
            XCTAssertTrue(read.waitForExistence(timeout: 45), "\(name) series page has no read button")
            sleep(2)
        }

        step("\(name): series chapters") {
            app.swipeUp()
            sleep(1)
        }

        step("\(name): reader") {
            app.swipeDown()
            let read = readButton()
            if read.waitForExistence(timeout: 5) { read.tap() } else { XCTFail("No read button") }
            sleep(12) // pages or text load from the network
        }

        step("\(name): reader controls") {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
        }

        step("\(name): reader scrolled") {
            app.swipeUp()
            sleep(3)
            closeReader()
        }
    }

    // MARK: Helpers

    /// Runs one step and screenshots the screen afterwards, whatever happened.
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in
            body()
            shot += 1
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = String(format: "%02d %@", shot, name)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func install(matching text: String, or other: String? = nil) {
        let cell = app.cells.containing(sourceRow(text, other)).firstMatch
        guard cell.waitForExistence(timeout: 15) else { return XCTFail("No \(text) source in the repository") }
        let install = cell.buttons["Install"]
        if install.exists { install.tap() }
        let done = cell.staticTexts["Installed"].waitForExistence(timeout: 45) || cell.buttons["Installed"].exists
        XCTAssertTrue(done, "\(text) didn't install")
    }

    private func sourceRow(_ text: String, _ other: String?) -> NSPredicate {
        if let other {
            return NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", text, other)
        }
        return NSPredicate(format: "label CONTAINS[c] %@", text)
    }

    private func firstResult() -> XCUIElement {
        app.buttons.matching(identifier: "work.result").firstMatch
    }

    private func readButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start reading' OR label BEGINSWITH 'Read ch.'")).firstMatch
    }

    private func tapFirst(_ elements: [XCUIElement]) {
        for element in elements where element.waitForExistence(timeout: 5) {
            element.tap()
            return
        }
        XCTFail("None of \(elements.map(\.description)) appeared")
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        sleep(1)
    }

    private func popToRoot() {
        for _ in 0..<5 where !app.navigationBars["Browse"].exists { goBack() }
        if app.searchFields.firstMatch.exists, (app.searchFields.firstMatch.value as? String)?.isEmpty == false { endSearch() }
    }

    private func closeReader() {
        for label in ["Close reader", "Close", "Done"] where app.buttons[label].exists {
            app.buttons[label].tap()
            sleep(1)
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        for label in ["Close reader", "Close", "Done"] where app.buttons[label].waitForExistence(timeout: 2) {
            app.buttons[label].tap()
            return
        }
    }

    /// Clears and closes the search field ("Cancel" before iOS 26, "Close" after).
    private func endSearch() {
        let clear = app.searchFields.firstMatch.buttons["Clear text"]
        if clear.exists { clear.tap() }
        for label in ["Cancel", "Close"] {
            let button = app.navigationBars.buttons[label]
            if button.exists { button.tap(); break }
        }
        sleep(1)
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            guard springboard.alerts.firstMatch.waitForExistence(timeout: 3) else { return }
            for label in ["Allow", "OK"] where springboard.alerts.buttons[label].exists {
                springboard.alerts.buttons[label].tap()
            }
        }
    }
}
