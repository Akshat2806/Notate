import XCTest

/// Opt-in physical-device coverage for the explicitly created profiling
/// notebook. Ordinary CI runs never select or mutate a person's library.
@MainActor
final class NativeViewportNavigationUITests: XCTestCase {
    private var deviceViewportTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["NOTATE_RUN_DEVICE_VIEWPORT_UI_TESTS"] == "1"
    }

    func testFixedZoomScrollingForwardAndBackInSavedNotebook() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and device fixture.")
        }
        continueAfterFailure = false
        for direction in ["vertical", "horizontal"] {
            for zoom in ["0.5", "0.6", "1"] {
                let app = XCUIApplication()
                app.launchArguments = ["--ink-viewport-notebook"]
                app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
                app.launchEnvironment["NOTATE_INK_SCROLL_ZOOM"] = zoom
                app.launchEnvironment["NOTATE_INK_SCROLL_DIRECTION"] = direction
                app.launch()
                let (back, canvas) = openPerformanceNotebook(in: app)
                capture("fixed-\(direction)-\(zoom)-start")
                let indicator = app.descendants(matching: .any).matching(identifier: "canvas.page.indicator").firstMatch
                let before = indicator.label
                // Above horizontal fit, a slow half-screen drag can remain
                // below half a page stride and correctly snap back. Cross the
                // existing paging threshold explicitly; keep zoom unchanged.
                let start = direction == "vertical" ? CGVector(dx: 0.6, dy: 0.8) : CGVector(dx: 0.9, dy: 0.6)
                let end = direction == "vertical" ? CGVector(dx: 0.6, dy: 0.3) : CGVector(dx: 0.1, dy: 0.6)
                for step in 0..<6 {
                    canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                        thenDragTo: canvas.coordinate(withNormalizedOffset: end))
                    if step == 2 || step == 5 { capture("fixed-\(direction)-\(zoom)-forward-\(step)") }
                }
                XCTAssertTrue(wait { indicator.label != before },
                    "Fixed-zoom \(direction) scrolling at \(zoom) did not advance: before=\(before), after=\(indicator.label)")
                let advanced = indicator.label
                for step in 0..<6 {
                    canvas.coordinate(withNormalizedOffset: end).press(forDuration: 0.05,
                        thenDragTo: canvas.coordinate(withNormalizedOffset: start))
                    if step == 2 || step == 5 { capture("fixed-\(direction)-\(zoom)-reverse-\(step)") }
                }
                XCTAssertTrue(wait { indicator.label != advanced }, "Reverse scrolling must move back through pages.")
                XCTAssertTrue(back.isHittable)
                back.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-browser")
                    .firstMatch.waitForExistence(timeout: 15))
                app.terminate()
            }
        }
    }

    func testManualScrollPinchAndBackInSavedNotebook() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local NOTATE_INK_PROFILING build and device fixture.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ink-viewport-notebook"]
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_INK_SCROLL_ZOOM"] = "1"
        app.launchEnvironment["NOTATE_INK_SCROLL_DIRECTION"] = "vertical"
        app.launch()
        let (back, canvas) = openPerformanceNotebook(in: app)
        // Go from a writing zoom to the minimum fit range using real gestures.
        canvas.pinch(withScale: 0.1, velocity: -2)
        capture("native-fit-before-scroll")
        let indicator = app.descendants(matching: .any).matching(identifier: "canvas.page.indicator").firstMatch
        let before = indicator.label
        for index in 0..<4 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)))
            capture("native-page-transition-\(index)")
        }
        XCTAssertTrue(wait { indicator.label != before }, "Finger scrolling must advance the notebook.")
        canvas.pinch(withScale: 4, velocity: 2)
        capture("native-writing-zoom")
        canvas.pinch(withScale: 0.25, velocity: -2)
        for cycle in 0..<3 {
            if cycle == 1 {
                // Back remains available even while Reader is awaiting a
                // pending native snapshot or rendering handoff.
                app.buttons["Enter Reader Mode"].tap()
                XCTAssertTrue(app.buttons["Exit Reader Mode"].waitForExistence(timeout: 30),
                    "Reader mode must finish before testing Back during its session.")
            }
            XCTAssertTrue(back.isHittable)
            back.tap()
            let library = app.descendants(matching: .any).matching(identifier: "library-browser").firstMatch
            XCTAssertTrue(library.waitForExistence(timeout: 15), "Back must leave the editor immediately.")
            capture("native-library-return-\(cycle)")
            let notebook = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                    "library.item.", "Viewport Performance · 1,000 pages")).firstMatch
            XCTAssertTrue(notebook.waitForExistence(timeout: 15))
            notebook.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 30))
            XCTAssertTrue(canvas.waitForExistence(timeout: 60))
            XCTAssertTrue(wait { back.isHittable && !app.progressIndicators["Opening paper"].exists })
        }
    }

    func testRotationInSavedNotebook() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and device fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ink-viewport-notebook"]
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_INK_SCROLL_ZOOM"] = "0.6"
        app.launchEnvironment["NOTATE_INK_SCROLL_DIRECTION"] = "vertical"
        app.launch()
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        let (_, canvas) = openPerformanceNotebook(in: app)
        XCUIDevice.shared.orientation = .portrait
        let portraitPresented = wait { canvas.frame.height > canvas.frame.width }
        capture("native-portrait")
        XCTAssertTrue(portraitPresented, "The actual canvas must present portrait bounds; physical orientation or Rotation Lock can override automation.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapePresented = wait { canvas.frame.width > canvas.frame.height }
        capture("native-landscape")
        XCTAssertTrue(landscapePresented, "The actual canvas must present landscape bounds.")
    }

    private func openPerformanceNotebook(in app: XCUIApplication) -> (back: XCUIElement, canvas: XCUIElement) {
        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any).matching(identifier: "canvas.workspace").firstMatch
        if !canvas.waitForExistence(timeout: 2) {
            let notebook = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                    "library.item.", "Viewport Performance · 1,000 pages")
            ).firstMatch
            XCTAssertTrue(notebook.waitForExistence(timeout: 30), "The dedicated 1,000-page test copy must be in the library.")
            XCTAssertTrue(wait { notebook.isHittable })
            notebook.tap()
        }
        XCTAssertTrue(canvas.waitForExistence(timeout: 60), "The test notebook must open into the canvas.")
        XCTAssertTrue(wait { !app.progressIndicators["Opening paper"].exists && back.isHittable })
        return (back, canvas)
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    private func capture(_ name: String) {
        let displayed = expectation(description: "Presented frames settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { displayed.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [displayed], timeout: 3), .completed)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureImmediately(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
