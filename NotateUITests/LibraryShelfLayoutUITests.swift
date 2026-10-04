import XCTest

@MainActor
final class LibraryShelfLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStableArtworkAcrossRotationSidebarAndScopes() throws {
        let app = launchFixture()
        defer { XCUIDevice.shared.orientation = .portrait }
        let card = items(in: app).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let identifier = card.identifier
        XCTAssertEqual(card.frame.width, 168, accuracy: 1)
        capture("library-portrait", app: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height })
        let sameCard = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(sameCard.exists)
        XCTAssertEqual(sameCard.frame.width, 168, accuracy: 1)
        capture("library-landscape", app: app)

        let toggle = app.buttons["library.sidebar-toggle"]
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertTrue(wait { sameCard.frame.width == 168 })
        capture("library-landscape-collapsed-sidebar", app: app)
        toggle.tap()

        for scope in ["favorites", "recent", "trash"] {
            let button = app.buttons["library.sidebar.\(scope)"]
            XCTAssertTrue(button.exists)
            button.tap()
            XCTAssertTrue(items(in: app).firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(items(in: app).firstMatch.frame.width, 168, accuracy: 1)
            capture("library-\(scope)", app: app)
        }
        let tag = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.sidebar.tag.")).matching(NSPredicate(format: "label == %@", "Studio")).firstMatch
        XCTAssertTrue(tag.exists)
        tag.tap()
        XCTAssertTrue(items(in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(items(in: app).firstMatch.frame.width, 168, accuracy: 1)
        capture("library-tag", app: app)
        app.buttons["library.sidebar.home"].tap()
        let folder = items(in: app).matching(NSPredicate(format: "label BEGINSWITH %@", "Courses")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap()
        XCTAssertTrue(wait { app.staticTexts["library.header.title"].label == "Courses" })
        XCTAssertEqual(items(in: app).firstMatch.frame.width, 168, accuracy: 1)
        capture("library-folder", app: app)
        let child = items(in: app).matching(NSPredicate(format: "label BEGINSWITH %@", "Level 2")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        child.tap()
        XCTAssertTrue(wait { app.staticTexts["library.header.title"].label == "Level 2" })
        app.buttons["library.folder.back"].tap()
        XCTAssertTrue(wait { app.staticTexts["library.header.title"].label == "Courses" })
        capture("library-folder-return", app: app)
    }

    func testTileSizesAndSelectionKeepCardGeometry() {
        let app = launchFixture()
        defer { XCUIDevice.shared.orientation = .portrait }
        for (label, width) in [("Small", 144.0), ("Large", 200.0), ("Comfortable", 168.0)] {
            app.buttons["library.view-style"].tap()
            let option = app.buttons[label]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            capture("library-tile-menu-\(label.lowercased())", app: app)
            option.tap()
            XCTAssertTrue(wait { abs(self.items(in: app).firstMatch.frame.width - width) < 1 })
            capture("library-tiles-\(label.lowercased())", app: app)
        }
        app.buttons["library.selection-toggle"].tap()
        XCTAssertEqual(items(in: app).firstMatch.frame.width, 168, accuracy: 1)
        capture("library-selection", app: app)
    }

    func testCompactPortraitAndLandscape() {
        let app = launchFixture()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["library.tab.home"].exists)
        let card = items(in: app).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let identifier = card.identifier
        XCTAssertEqual(card.frame.width, 168, accuracy: 1)
        capture("library-phone-portrait", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height })
        let same = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(same.exists)
        XCTAssertEqual(same.frame.width, 168, accuracy: 1)
        capture("library-phone-landscape", app: app)
    }

    func testAccessibilityUsesListFallback() {
        let app = launchFixture(arguments: ["-UIPreferredContentSizeCategoryName",
                                           "UICTContentSizeCategoryAccessibilityXXXL"])
        let item = items(in: app).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(item.frame.width, 168)
        capture("library-accessibility-list", app: app)
    }

    func testScrolledItemStaysVisibleAfterRotation() throws {
        let app = launchFixture()
        defer { XCUIDevice.shared.orientation = .portrait }
        let browser = app.scrollViews["library-browser"]
        browser.swipeUp()
        browser.swipeUp()
        let visible = try XCTUnwrap(items(in: app).allElementsBoundByIndex.first { $0.isHittable })
        let identifier = visible.identifier
        capture("library-scrolled-portrait", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height })
        let same = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(wait { same.exists && same.frame.intersects(browser.frame) })
        XCTAssertEqual(same.frame.width, 168, accuracy: 1)
        capture("library-scrolled-landscape", app: app)
    }

    func testCompactHeaderStaysStableWhileScrolling() {
        let app = launchFixture()
        let header = app.descendants(matching: .any)["library.compact.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let initialFrame = header.frame
        let browser = app.scrollViews["library-browser"]
        browser.swipeUp()
        browser.swipeUp()
        XCTAssertEqual(header.frame.minY, initialFrame.minY, accuracy: 1)
        XCTAssertEqual(header.frame.height, initialFrame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(header.frame.height, 44)
        XCTAssertTrue(app.staticTexts["library.compact.title"].isHittable)
        app.buttons["library.tools"].tap()
        XCTAssertTrue(app.buttons["library.view-style"].waitForExistence(timeout: 5))
        capture("library-compact-header-tools", app: app)
    }

    func testDarkTileSizeMenu() {
        let app = launchFixture(environment: ["NOTATE_UI_TEST_APPEARANCE": "dark"])
        app.buttons["library.view-style"].tap()
        XCTAssertTrue(app.buttons["Comfortable"].waitForExistence(timeout: 5))
        capture("library-tile-menu-dark", app: app)
    }

    private func launchFixture(arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["NOTATE_UI_TESTING": "1", "NOTATE_UI_TEST_SEED": "fixture",
                                 "NOTATE_UI_TEST_SUPPRESS_AUTOFOCUS": "1",
                                 "NOTATE_UI_TEST_LAYOUT_FIXTURE": "1"]
        app.launchEnvironment.merge(environment) { _, value in value }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-browser")
            .firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func items(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.item."))
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func capture(_ name: String, app: XCUIApplication) {
        // Device rotation can update AX frames before the screenshot surface.
        let rendered = expectation(description: "Display settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { rendered.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 3), .completed)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
