import XCTest

/// Opt-in physical-device coverage for the explicitly created profiling
/// notebook. Ordinary CI runs never select or mutate a person's library.
@MainActor
final class NativeViewportNavigationUITests: XCTestCase {
    private var deviceViewportTestsEnabled: Bool {
#if NOTATE_INK_PROFILING
        true
#else
        ProcessInfo.processInfo.environment["NOTATE_RUN_DEVICE_VIEWPORT_UI_TESTS"] == "1"
#endif
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

    func testNativeZoomControlScrollAndBackInSavedNotebook() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local NOTATE_INK_PROFILING build and device fixture.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ink-viewport-notebook"]
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_INK_SCROLL_ZOOM"] = "1"
        app.launchEnvironment["NOTATE_INK_SCROLL_DIRECTION"] = "vertical"
        app.launchEnvironment["NOTATE_UI_TESTING"] = "1"
        app.launch()
        let (back, canvas) = openPerformanceNotebook(in: app)
        let indicator = app.descendants(matching: .any).matching(identifier: "canvas.page.indicator").firstMatch
        let labelBeforeZoom = indicator.label
        let pageBeforeZoom = pageNumber(from: labelBeforeZoom)
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        XCTAssertTrue(zoomControl.waitForExistence(timeout: 10), "The zoom control should be exposed in the UI-test build.")
        captureImmediately("native-zoom-before-scrub")
        zoomControl.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: zoomControl.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        XCTAssertTrue(wait { (zoomControl.value as? String) == "50 percent" },
            "Dragging the native zoom control to its minimum should settle at 50%; value=\(String(describing: zoomControl.value))")
        let labelAfterZoom = indicator.label
        let pageAfterZoom = pageNumber(from: labelAfterZoom)
        if let pageBeforeZoom, let pageAfterZoom {
            XCTAssertLessThanOrEqual(abs(pageAfterZoom - pageBeforeZoom), 1,
                "Zoom-control scaling must keep the focused page anchored; before=\(labelBeforeZoom), after=\(labelAfterZoom).")
        }
        captureImmediately("native-zoom-after-scrub")
        capture("native-fit-before-scroll")
        let before = indicator.label
        for index in 0..<4 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)))
            capture("native-page-transition-\(index)")
        }
        XCTAssertTrue(wait { indicator.label != before }, "Finger scrolling must advance the notebook.")
        capture("native-fit-scrolled-page")
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

    func testPaperKitOwnedPinchMirrorsZoomAndMinimumBounce() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and physical iPad fixture.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_PAPERKIT_PINCH_OWNS_ZOOM"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()

        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30), "The separate handwritten Quick Note copy must be in the library.")
        XCTAssertTrue(wait { copy.isHittable })
        copy.tap()

        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "canvas.workspace").firstMatch
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        let indicator = app.descendants(matching: .any)
            .matching(identifier: "canvas.page.indicator").firstMatch
        let nativeDiagnostics = app.staticTexts["canvas.debug.nativeZoom"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        XCTAssertTrue(wait { back.isHittable && zoomControl.isHittable })
        XCTAssertTrue(zoomControl.waitForExistence(timeout: 10))
        XCTAssertTrue(nativeDiagnostics.waitForExistence(timeout: 10))
        if zoomPercent(from: zoomControl.value as? String) != 100 {
            setZoomPercent(100, using: zoomControl)
        }
        XCTAssertTrue(wait {
            guard let value = self.zoomPercent(from: zoomControl.value as? String) else { return false }
            return abs(value - 100) <= 2
        }, "The handwritten pinch comparison should begin near 100%.")
        captureImmediately("paperkit-quick-note-pinch-start")

        let initialPageNumber = pageNumber(from: indicator.label) ?? 1
        let initialPaperPage = self.paperPage(initialPageNumber, in: app)
        XCTAssertTrue(wait { initialPaperPage.isHittable },
            "The focused handwritten PaperKit page must be the native pinch target.")
        initialPaperPage.pinch(withScale: 1.5, velocity: 1)
        let pinchOutChangedZoom = wait {
            guard let value = self.zoomPercent(from: zoomControl.value as? String) else { return false }
            return value > 100 && value < 500
        }
        attachDiagnostics(nativeDiagnostics.label, named: "paperkit-quick-note-pinch-open-result")
        captureImmediately("paperkit-quick-note-pinch-open-result")
        XCTAssertTrue(pinchOutChangedZoom,
            "PaperKit-owned pinch should increase the handwritten page without overshooting the intended test range; value=\(String(describing: zoomControl.value)); diagnostics=\(nativeDiagnostics.label)")
        captureImmediately("paperkit-quick-note-pinch-out-settled")
        let afterOpenDiagnostics = XCTAttachment(string: nativeDiagnostics.label)
        afterOpenDiagnostics.name = "paperkit-quick-note-pinch-open-diagnostics"
        afterOpenDiagnostics.lifetime = .keepAlways
        add(afterOpenDiagnostics)
        let zoomedPercent = zoomPercent(from: zoomControl.value as? String) ?? 0

        let zoomedPageNumber = pageNumber(from: indicator.label) ?? initialPageNumber
        let zoomedPaperPage = self.paperPage(zoomedPageNumber, in: app)
        XCTAssertTrue(wait { zoomedPaperPage.isHittable },
            "Reacquire the visible handwritten page after zoom before pinching again.")
        zoomedPaperPage.pinch(withScale: 0.75, velocity: -1)
        let pinchInChangedZoom = wait {
            (self.zoomPercent(from: zoomControl.value as? String) ?? 0) < zoomedPercent
        }
        attachDiagnostics(nativeDiagnostics.label, named: "paperkit-quick-note-pinch-close-result")
        captureImmediately("paperkit-quick-note-pinch-close-result")
        XCTAssertTrue(pinchInChangedZoom,
            "PaperKit pinch-in must reduce zoom from \(zoomedPercent)%, rather than invoking the zoom control; diagnostics=\(nativeDiagnostics.label)")
        captureImmediately("paperkit-quick-note-pinch-in-settled")
        let afterCloseDiagnostics = XCTAttachment(string: nativeDiagnostics.label)
        afterCloseDiagnostics.name = "paperkit-quick-note-pinch-close-diagnostics"
        afterCloseDiagnostics.lifetime = .keepAlways
        add(afterCloseDiagnostics)
        if zoomPercent(from: zoomControl.value as? String) != 50 {
            setZoomPercent(50, using: zoomControl)
        }
        XCTAssertTrue(wait {
            guard let value = self.zoomPercent(from: zoomControl.value as? String) else { return false }
            return abs(value - 50) <= 2
        }, "The minimum-bounce check should begin at 50%.")
        let pageAtMinimum = self.paperPage(pageNumber(from: indicator.label) ?? 1, in: app)
        XCTAssertTrue(wait { pageAtMinimum.isHittable })
        pageAtMinimum.pinch(withScale: 0.5, velocity: -1)
        pauseForPresentedFrames(seconds: 10)
        let settledMinimum = zoomPercent(from: zoomControl.value as? String) ?? 0
        XCTAssertLessThanOrEqual(abs(settledMinimum - 50), 2,
            "Native PaperKit bounce must settle to 50% with paper and ink together; diagnostics=\(nativeDiagnostics.label)")
        captureImmediately("paperkit-quick-note-minimum-bounce-after-10s")
        XCTAssertTrue(back.isHittable)
    }

    func testQuickNoteHandwritingCopyZoomScrollAndBack() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and saved Quick Note copy.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()
        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30), "The separate Quick Note copy must be in the library.")
        XCTAssertTrue(wait { copy.isHittable })
        copy.tap()

        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any).matching(identifier: "canvas.workspace").firstMatch
        let indicator = app.descendants(matching: .any).matching(identifier: "canvas.page.indicator").firstMatch
        let viewportDiagnostics = app.staticTexts["canvas.debug.nativeZoom"]
        let hasViewportDiagnostics = viewportDiagnostics.waitForExistence(timeout: 2)
        func attachViewportDiagnostics(_ name: String) {
            attachDiagnostics(
                hasViewportDiagnostics ? viewportDiagnostics.label : "Geometry overlay is unavailable in this Release build.",
                named: name
            )
        }
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        // Capture before waiting for the editor's loading affordances to clear.
        // This is the window where the reported transient ink expansion appears.
        captureImmediately("quick-note-copy-open-immediate")
        XCTAssertTrue(wait { back.isHittable && !app.progressIndicators["Opening paper"].exists })
        captureImmediately("quick-note-copy-open-ready")
        attachViewportDiagnostics("quick-note-copy-open-geometry")
        pauseForPresentedFrames(seconds: 0.25)
        captureImmediately("quick-note-copy-open-250ms")
        pauseForPresentedFrames(seconds: 0.75)
        captureImmediately("quick-note-copy-open-1s")
        pauseForPresentedFrames(seconds: 9)
        captureImmediately("quick-note-copy-open-10s")
        attachViewportDiagnostics("quick-note-copy-open-10s-geometry")
        let initialPageLabel = indicator.label
        XCTAssertTrue(initialPageLabel.contains("of "), "The page indicator should report the copy's page count.")
        print("QUICK_NOTE_COPY_PAGE_COUNT \(initialPageLabel)")
        captureImmediately("quick-note-copy-start")

        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        XCTAssertTrue(zoomControl.waitForExistence(timeout: 10))
        XCTAssertTrue(wait { zoomControl.isHittable }, "The profiling zoom control must be visible before the test drags it.")
        let pageBeforeFirstZoom = pageNumber(from: indicator.label)
        if zoomPercent(from: zoomControl.value as? String) != 50 {
            var currentZoom = zoomPercent(from: zoomControl.value as? String) ?? 50
            var isFirstStep = true
            while currentZoom > 50 {
                let stepZoom = max(50, currentZoom / 2)
                setZoomPercent(stepZoom, using: zoomControl)
                if isFirstStep {
                    captureImmediately("quick-note-copy-first-zoom-step-immediate")
                    attachViewportDiagnostics("quick-note-copy-first-zoom-step-geometry")
                    pauseForPresentedFrames(seconds: 0.25)
                    captureImmediately("quick-note-copy-first-zoom-step-250ms")
                    isFirstStep = false
                }
                currentZoom = zoomPercent(from: zoomControl.value as? String) ?? stepZoom
            }
            captureImmediately("quick-note-copy-first-zoom-to-50-immediate")
            attachViewportDiagnostics("quick-note-copy-first-zoom-to-50-geometry")
            pauseForPresentedFrames(seconds: 0.25)
            captureImmediately("quick-note-copy-first-zoom-to-50-250ms")
            if let pageBeforeFirstZoom, let pageAfterFirstZoom = pageNumber(from: indicator.label) {
                XCTAssertLessThanOrEqual(abs(pageAfterFirstZoom - pageBeforeFirstZoom), 1,
                    "The first zoom-out must keep the focused handwritten page within one adjacent page; " +
                    "before=\(pageBeforeFirstZoom), after=\(pageAfterFirstZoom).")
            }
        }

        let pageBeforePreviewScroll = indicator.label
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.78))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                withNormalizedOffset: CGVector(dx: 0.55, dy: 0.43)
            ))
        XCTAssertTrue(wait { indicator.label != pageBeforePreviewScroll },
            "The handwritten copy must move to its next page at fit zoom.")
        captureImmediately("quick-note-copy-next-page-immediate")
        pauseForPresentedFrames(seconds: 0.25)
        captureImmediately("quick-note-copy-next-page-250ms")
        pauseForPresentedFrames(seconds: 0.75)
        captureImmediately("quick-note-copy-next-page-1s")
        pauseForPresentedFrames(seconds: 9)
        captureImmediately("quick-note-copy-next-page-10s")

        for zoom in [60, 100, 200, 400, 600, 800, 1_000] {
            setZoomPercent(zoom, using: zoomControl)
            capture("quick-note-copy-\(zoom)-percent")
        }
        pauseForPresentedFrames(seconds: 10)
        captureImmediately("quick-note-copy-1000-percent-after-10s")
        for zoom in [800, 600, 300, 150, 100, 60, 50] {
            setZoomPercent(zoom, using: zoomControl)
            capture("quick-note-copy-return-\(zoom)-percent")
        }
        pauseForPresentedFrames(seconds: 10)
        captureImmediately("quick-note-copy-50-percent-after-10s")
        XCTAssertTrue(wait { indicator.label.contains("of ") })

        let before = indicator.label
        for _ in 0..<4 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)))
        }
        XCTAssertTrue(wait { indicator.label != before }, "The copied Quick Note should scroll to another page.")
        capture("quick-note-copy-scroll-forward")
        let advanced = indicator.label
        for _ in 0..<4 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8)))
        }
        XCTAssertTrue(wait { indicator.label != advanced }, "Reverse scrolling should return through the copied Quick Note.")
        capture("quick-note-copy-scroll-reverse")

        back.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-browser")
            .firstMatch.waitForExistence(timeout: 15))
    }

    func testQuickNoteDenseCopiedPageZoomOutKeepsFullSurfaceRendered() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the local profiling build and a saved handwritten Quick Note copy.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()

        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        XCTAssertTrue(wait { copy.isHittable })
        copy.tap()

        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any).matching(identifier: "canvas.workspace").firstMatch
        let indicator = app.descendants(matching: .any).matching(identifier: "canvas.page.indicator").firstMatch
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        XCTAssertTrue(wait { back.isHittable && zoomControl.isHittable && indicator.label.contains("of ") })

        let pageCount = pageNumber(from: indicator.label.components(separatedBy: "of ").last ?? "") ?? 0
        XCTAssertGreaterThan(pageCount, 0, "The copied note must expose its page count.")
        if zoomPercent(from: zoomControl.value as? String) != 50 {
            setZoomPercent(50, using: zoomControl)
        }

        // Visit the copy at fit zoom and collect stroke counts from mounted
        // native hosts. This selects the user's duplicated dense page rather
        // than assuming a particular page number or using synthetic ink.
        var strokeCountsByPage: [Int: Int] = [:]
        var visitedFocusPages = Set<Int>()
        let paperPages = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "canvas.paper.page.")
        )
        for _ in 0..<(pageCount * 2 + 4) {
            for element in paperPages.allElementsBoundByIndex {
                let pageNumber = Int(element.identifier.replacingOccurrences(
                    of: "canvas.paper.page.", with: ""
                ))
                let strokeCount = Int(String(describing: element.value ?? ""))
                if let pageNumber, let strokeCount, strokeCountsByPage[pageNumber] == nil {
                    strokeCountsByPage[pageNumber] = strokeCount
                    print("QUICK_NOTE_COPY_PAGE_STROKES page=\(pageNumber) strokes=\(strokeCount)")
                }
            }
            guard let currentPage = pageNumber(from: indicator.label) else { break }
            visitedFocusPages.insert(currentPage)
            if currentPage >= pageCount { break }
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.82))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)
                ))
            if !wait({ (self.pageNumber(from: indicator.label) ?? currentPage) > currentPage }, timeout: 3) {
                // A short drag can land between pages at fit zoom. Advance
                // another half viewport while keeping the same direction.
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.82))
                    .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)
                    ))
                if !wait({ (self.pageNumber(from: indicator.label) ?? currentPage) > currentPage }, timeout: 3) { break }
            }
        }
        XCTAssertFalse(strokeCountsByPage.isEmpty,
            "The profiling build should expose mounted page stroke counts for the handwritten copy.")
        attachDiagnostics(
            "Quick Note Copy page count: \(pageCount)\n" +
                "Visited focus pages: \(visitedFocusPages.sorted())\n" +
                "Mounted page stroke counts: \(strokeCountsByPage.sorted { $0.key < $1.key })",
            named: "quick-note-dense-page-scan"
        )
        guard let maximumStrokeCount = strokeCountsByPage.values.max(),
              let densePage = strokeCountsByPage.first(where: { $0.value == maximumStrokeCount })?.key else {
            XCTFail("No handwritten page was found in the Quick Note copy.")
            return
        }
        print("QUICK_NOTE_COPY_DENSE_PAGE page=\(densePage) strokes=\(maximumStrokeCount)")

        var currentPage = pageNumber(from: indicator.label) ?? 1
        for _ in 0..<(pageCount + 4) where currentPage != densePage {
            let movesForward = densePage > currentPage
            let startY: CGFloat = movesForward ? 0.82 : 0.28
            let endY: CGFloat = movesForward ? 0.35 : 0.76
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: startY))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.55, dy: endY)
                ))
            _ = wait { self.pageNumber(from: indicator.label) != currentPage }
            currentPage = pageNumber(from: indicator.label) ?? currentPage
        }
        XCTAssertEqual(currentPage, densePage,
            "The recording sequence must focus the highest-stroke page in the copy.")

        captureImmediately("quick-note-dense-page-before-zoom")
        attachDiagnostics(app.staticTexts["canvas.debug.nativeZoom"].label,
            named: "quick-note-dense-page-before-zoom-geometry")
        setZoomPercent(100, using: zoomControl)
        setZoomPercent(1_000, using: zoomControl)
        captureImmediately("quick-note-dense-page-1000-immediate")
        pauseForPresentedFrames(seconds: 1)
        captureImmediately("quick-note-dense-page-1000-1s")
        setZoomPercent(600, using: zoomControl)
        captureImmediately("quick-note-dense-page-600-immediate")
        setZoomPercent(100, using: zoomControl)
        captureImmediately("quick-note-dense-page-100-immediate")
        setZoomPercent(50, using: zoomControl)
        captureImmediately("quick-note-dense-page-50-immediate")
        for (name, delay) in [("100ms", 0.1), ("250ms", 0.25), ("1s", 1.0), ("5s", 5.0), ("10s", 10.0)] {
            pauseForPresentedFrames(seconds: delay)
            captureImmediately("quick-note-dense-page-50-\(name)")
        }
        attachDiagnostics(app.staticTexts["canvas.debug.nativeZoom"].label,
            named: "quick-note-dense-page-after-zoom-geometry")

        // Cross between adjacent duplicated dense pages at fit zoom while
        // capturing the first presented frames after each scroll direction.
        let pageBeforeDenseTransition = pageNumber(from: indicator.label) ?? densePage
        for _ in 0..<3 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.82))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)
                ))
        }
        XCTAssertTrue(wait {
            (self.pageNumber(from: indicator.label) ?? pageBeforeDenseTransition) > pageBeforeDenseTransition
        }, "Scrolling forward should move between the duplicated dense pages.")
        captureImmediately("quick-note-dense-page-scroll-next-immediate")
        pauseForPresentedFrames(seconds: 0.1)
        captureImmediately("quick-note-dense-page-scroll-next-100ms")
        pauseForPresentedFrames(seconds: 0.25)
        captureImmediately("quick-note-dense-page-scroll-next-250ms")
        pauseForPresentedFrames(seconds: 0.75)
        captureImmediately("quick-note-dense-page-scroll-next-1s")

        let pageAfterDenseTransition = pageNumber(from: indicator.label) ?? densePage
        for _ in 0..<3 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.55, dy: 0.78)
                ))
        }
        XCTAssertTrue(wait {
            (self.pageNumber(from: indicator.label) ?? pageAfterDenseTransition) < pageAfterDenseTransition
        }, "Reverse scrolling should return across the dense page boundary.")
        captureImmediately("quick-note-dense-page-scroll-previous-immediate")
        pauseForPresentedFrames(seconds: 0.25)
        captureImmediately("quick-note-dense-page-scroll-previous-250ms")

        back.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-browser")
            .firstMatch.waitForExistence(timeout: 15))
    }

    func testQuickNoteCopyLastSevenPagesRenderAfterScroll() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the local profiling build and a saved handwritten Quick Note copy.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()

        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        XCTAssertTrue(wait { copy.isHittable })
        copy.tap()

        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any).matching(identifier: "canvas.workspace").firstMatch
        let indicator = app.descendants(matching: .any).matching(identifier: "canvas.page.indicator").firstMatch
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        XCTAssertTrue(wait { back.isHittable && zoomControl.isHittable && indicator.label.contains("of ") })

        let pageCount = pageNumber(from: indicator.label.components(separatedBy: "of ").last ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(pageCount, 7)
        if zoomPercent(from: zoomControl.value as? String) != 50 {
            setZoomPercent(50, using: zoomControl)
        }

        let firstTailPage = pageCount - 6
        var currentPage = pageNumber(from: indicator.label) ?? 1
        while currentPage < firstTailPage {
            let previousPage = currentPage
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50)
                ))
            if !wait({ (self.pageNumber(from: indicator.label) ?? previousPage) > previousPage }, timeout: 3) {
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.82))
                    .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)
                    ))
                XCTAssertTrue(wait {
                    (self.pageNumber(from: indicator.label) ?? previousPage) > previousPage
                }, "Could not advance toward the Quick Note tail from page \(previousPage).")
            }
            currentPage = pageNumber(from: indicator.label) ?? previousPage
        }
        XCTAssertEqual(currentPage, firstTailPage,
            "Tail-page inspection must start on page \(firstTailPage) without skipping it.")

        var strokeCounts: [Int: Int] = [:]
        for page in firstTailPage...pageCount {
            currentPage = pageNumber(from: indicator.label) ?? currentPage
            XCTAssertEqual(currentPage, page, "Expected to inspect tail page \(page) in order.")

            let paperPage = self.paperPage(page, in: app)
            XCTAssertTrue(wait { paperPage.exists }, "Page \(page) should have a mounted PaperKit host.")
            let strokeCount = Int(String(describing: paperPage.value ?? ""))
            XCTAssertNotNil(strokeCount, "Page \(page) should expose its loaded stroke count.")
            if let strokeCount {
                strokeCounts[page] = strokeCount
                print("QUICK_NOTE_COPY_TAIL_PAGE page=\(page) strokes=\(strokeCount)")
            }

            captureImmediately("quick-note-tail-page-\(page)-immediate")
            pauseForPresentedFrames(seconds: 1)
            captureImmediately("quick-note-tail-page-\(page)-1s")

            guard page < pageCount else { continue }
            let previousPage = page
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50)
                ))
            if !wait({ (self.pageNumber(from: indicator.label) ?? previousPage) > previousPage }, timeout: 3) {
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.82))
                    .press(forDuration: 0.05, thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)
                    ))
                XCTAssertTrue(wait {
                    (self.pageNumber(from: indicator.label) ?? previousPage) > previousPage
                }, "Could not scroll from Quick Note page \(previousPage) to the next page.")
            }
            currentPage = pageNumber(from: indicator.label) ?? previousPage
            XCTAssertEqual(currentPage, page + 1,
                "Slow tail-page scrolling should visit every consecutive page.")
        }

        attachDiagnostics(
            "Quick Note Copy tail pages: \(firstTailPage)...\(pageCount)\n" +
                "Mounted stroke counts: \(strokeCounts.sorted { $0.key < $1.key })",
            named: "quick-note-copy-last-seven-pages"
        )
        XCTAssertEqual(Set(strokeCounts.keys), Set(firstTailPage...pageCount))
        XCTAssertTrue((firstTailPage..<pageCount).allSatisfy { (strokeCounts[$0] ?? 0) > 0 },
            "The final handwritten pages should retain visible strokes.")

        // Exercise realistic fast reversals over the handwritten tail. These
        // system swipes launch momentum, unlike the slow page-by-page drags
        // above, and screenshots are captured as soon as each gesture ends so
        // an in-flight tile or mounting gap is not hidden by a later settle.
        let nativeDiagnostics = app.staticTexts["canvas.debug.nativeZoom"]
        XCTAssertTrue(nativeDiagnostics.waitForExistence(timeout: 10))
        if pageCount > firstTailPage + 1 {
            canvas.swipeDown()
            captureImmediately("quick-note-fast-scroll-prime-down")
            canvas.swipeDown()
            captureImmediately("quick-note-fast-scroll-prime-down-2")
        }
        for cycle in 0..<8 {
            if cycle.isMultiple(of: 2) {
                canvas.swipeUp()
            } else {
                canvas.swipeDown()
            }
            captureImmediately("quick-note-fast-scroll-reversal-\(cycle)")
            attachDiagnostics(nativeDiagnostics.label,
                named: "quick-note-fast-scroll-reversal-\(cycle)-viewport")
        }

        // Repeated zoom extremes expose stale crops that can look correct only
        // after PaperKit's asynchronous tile pass completes.
        setZoomPercent(1_000, using: zoomControl)
        captureImmediately("quick-note-fast-zoom-1000-immediate")
        for cycle in 0..<3 {
            setZoomPercent(50, using: zoomControl)
            captureImmediately("quick-note-fast-zoom-50-\(cycle)-immediate")
            attachDiagnostics(nativeDiagnostics.label,
                named: "quick-note-fast-zoom-50-\(cycle)-viewport")
            setZoomPercent(1_000, using: zoomControl)
            captureImmediately("quick-note-fast-zoom-1000-\(cycle)-immediate")
        }

        back.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-browser")
            .firstMatch.waitForExistence(timeout: 15))
    }

    func testQuickNoteCopyFirstZoomOutKeepsFocusedHandwritingAnchored() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and saved Quick Note copy.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()

        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        XCTAssertTrue(wait { copy.isHittable })
        print("QUICK_NOTE_COPY_SELECTED id=\(copy.identifier) label=\(copy.label)")
        copy.tap()

        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any).matching(identifier: "canvas.workspace").firstMatch
        let indicator = app.descendants(matching: .any).matching(identifier: "canvas.page.indicator").firstMatch
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        XCTAssertTrue(wait { back.isHittable && zoomControl.isHittable })
        XCTAssertTrue(indicator.label.contains("of "))
        print("QUICK_NOTE_COPY_PAGE_COUNT \(indicator.label)")

        setZoomPercent(100, using: zoomControl)
        XCTAssertTrue(wait { self.zoomPercent(from: zoomControl.value as? String) == 100 })
        let pageBeforeFirstZoomOut = pageNumber(from: indicator.label)
        captureImmediately("quick-note-first-zoom-out-start-100")

        setZoomPercent(50, using: zoomControl)
        XCTAssertTrue(wait { self.zoomPercent(from: zoomControl.value as? String) == 50 })
        captureImmediately("quick-note-first-zoom-out-immediate-50")
        pauseForPresentedFrames(seconds: 0.25)
        captureImmediately("quick-note-first-zoom-out-250ms-50")
        pauseForPresentedFrames(seconds: 0.75)
        captureImmediately("quick-note-first-zoom-out-1s-50")
        pauseForPresentedFrames(seconds: 9)
        captureImmediately("quick-note-first-zoom-out-10s-50")
        if let before = pageBeforeFirstZoomOut, let after = pageNumber(from: indicator.label) {
            XCTAssertLessThanOrEqual(abs(after - before), 1,
                "The first zoom-out should keep the handwritten page anchored; " +
                "before=\(before), after=\(after).")
        }

        back.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-browser")
            .firstMatch.waitForExistence(timeout: 15))
    }

    func testQuickNoteCopyPaperKitPinchInAndOutDiagnostics() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and saved Quick Note copy.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_PAPERKIT_PINCH_OWNS_ZOOM"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()

        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30), "The separate Quick Note copy must be in the library.")
        XCTAssertTrue(wait { copy.isHittable })
        copy.tap()

        let canvas = app.descendants(matching: .any).matching(identifier: "canvas.workspace").firstMatch
        let back = app.buttons["Back to Library"]
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        let diagnostics = app.staticTexts["canvas.debug.nativeZoom"]
        let paperPage = app.descendants(matching: .any)
            .matching(identifier: "canvas.paper.page.1").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        XCTAssertTrue(wait { back.isHittable && zoomControl.isHittable })
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(paperPage.waitForExistence(timeout: 10), "Expose the page bounds as the pinch gesture target.")
        XCTAssertTrue(wait { paperPage.isHittable })
        captureImmediately("quick-note-paperkit-pinch-start")

        let initialZoom = zoomPercent(from: zoomControl.value as? String) ?? 0
        paperPage.pinch(withScale: 4.0, velocity: 1)
        XCTAssertTrue(wait { (self.zoomPercent(from: zoomControl.value as? String) ?? 0) > initialZoom },
            "PaperKit pinch-out should increase the zoom from \(initialZoom)%; diagnostics=\(diagnostics.label)")
        captureImmediately("quick-note-paperkit-pinch-out-immediate")
        attachDiagnostics(diagnostics.label, named: "quick-note-paperkit-pinch-out-diagnostics")
        pauseForPresentedFrames(seconds: 10)
        captureImmediately("quick-note-paperkit-pinch-out-after-10s")

        let zoomedPercent = zoomPercent(from: zoomControl.value as? String) ?? 0
        paperPage.pinch(withScale: 0.5, velocity: -1)
        XCTAssertTrue(wait { (self.zoomPercent(from: zoomControl.value as? String) ?? 0) < zoomedPercent },
            "PaperKit pinch-in should reduce zoom from \(zoomedPercent)%; diagnostics=\(diagnostics.label)")
        captureImmediately("quick-note-paperkit-pinch-in-immediate")
        attachDiagnostics(diagnostics.label, named: "quick-note-paperkit-pinch-in-diagnostics")
        pauseForPresentedFrames(seconds: 10)
        captureImmediately("quick-note-paperkit-pinch-in-after-10s")
    }

    func testQuickNoteCopyPinchOutStaysAtItsSettledZoomWhileIdle() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and saved Quick Note copy.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()

        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        XCTAssertTrue(wait { copy.isHittable })
        copy.tap()

        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any).matching(identifier: "canvas.workspace").firstMatch
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        let diagnostics = app.staticTexts["canvas.debug.nativeZoom"]
        let paperPage = app.descendants(matching: .any)
            .matching(identifier: "canvas.paper.page.1").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        XCTAssertTrue(wait { back.isHittable && zoomControl.isHittable && paperPage.isHittable })
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        if self.zoomPercent(from: zoomControl.value as? String) != 50 {
            setZoomPercent(50, using: zoomControl)
        }
        XCTAssertTrue(wait { self.zoomPercent(from: zoomControl.value as? String) == 50 })
        captureImmediately("quick-note-copy-idle-pinch-start-50")

        paperPage.pinch(withScale: 4.0, velocity: 1)
        let pinchChangedZoom = wait {
            guard let value = self.zoomPercent(from: zoomControl.value as? String) else { return false }
            return value >= 100 && value <= 500
        }
        attachDiagnostics(diagnostics.label, named: "quick-note-copy-idle-pinch-out-result")
        captureImmediately("quick-note-copy-idle-pinch-out-result")
        XCTAssertTrue(pinchChangedZoom,
            "Pinch-out should raise zoom from 50% without reaching the 1000% cap; diagnostics=\(diagnostics.label)")
        let pinchSettledZoom = self.zoomPercent(from: zoomControl.value as? String) ?? 0
        captureImmediately("quick-note-copy-idle-pinch-out-settled")
        attachDiagnostics(diagnostics.label, named: "quick-note-copy-idle-pinch-out-geometry")

        pauseForPresentedFrames(seconds: 10)
        captureImmediately("quick-note-copy-idle-pinch-out-after-10s")
        let idleZoom = self.zoomPercent(from: zoomControl.value as? String) ?? 0
        attachDiagnostics(diagnostics.label, named: "quick-note-copy-idle-pinch-out-after-10s-geometry")
        XCTAssertLessThanOrEqual(abs(idleZoom - pinchSettledZoom), 2,
            "A settled notebook pinch must not be restored to a stale zoom while idle; " +
            "settled=\(pinchSettledZoom)%, after10s=\(idleZoom)%; diagnostics=\(diagnostics.label)")
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-browser")
            .firstMatch.waitForExistence(timeout: 15))
    }

    func testQuickNoteCopyNotebookOwnedPinchDiagnostics() throws {
        guard deviceViewportTestsEnabled else {
            throw XCTSkip("Requires the approved local profiling build and saved Quick Note copy.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTATE_NATIVE_PAGED_VIEWPORT"] = "1"
        app.launchEnvironment["NOTATE_NATIVE_PINCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["NOTATE_UI_TEST_KEEP_ZOOM_VISIBLE"] = "1"
        app.launch()

        let copy = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "library.item.", "Quick Note Copy")
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        XCTAssertTrue(wait { copy.isHittable })
        copy.tap()

        let back = app.buttons["Back to Library"]
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "canvas.workspace").firstMatch
        let zoomControl = app.descendants(matching: .any)
            .matching(identifier: "canvas.zoom.scrubber").firstMatch
        let indicator = app.descendants(matching: .any)
            .matching(identifier: "canvas.page.indicator").firstMatch
        let diagnostics = app.staticTexts["canvas.debug.nativeZoom"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 60))
        XCTAssertTrue(wait { back.isHittable && canvas.isHittable && zoomControl.isHittable })
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        if self.zoomPercent(from: zoomControl.value as? String) != 50 {
            setZoomPercent(50, using: zoomControl)
        }
        XCTAssertTrue(wait {
            guard let value = self.zoomPercent(from: zoomControl.value as? String) else { return false }
            return abs(value - 50) <= 2
        }, "Start the notebook pinch regression near the minimum supported zoom; " +
            "value=\(String(describing: zoomControl.value)); diagnostics=\(diagnostics.label)")
        let initialZoom = zoomPercent(from: zoomControl.value as? String) ?? 0
        // Pinch the active paper surface, then reacquire its accessibility
        // element after projection changes instead of reusing a stale frame.
        let initialPageNumber = pageNumber(from: indicator.label) ?? 1
        let initialPaperPage = self.paperPage(initialPageNumber, in: app)
        XCTAssertTrue(wait { initialPaperPage.isHittable })
        initialPaperPage.pinch(withScale: 4.0, velocity: 1)
        XCTAssertTrue(wait { (self.zoomPercent(from: zoomControl.value as? String) ?? 0) > initialZoom },
            "Notebook-owned pinch should increase from \(initialZoom)%; diagnostics=\(diagnostics.label)")
        let pinchOutPercent = zoomPercent(from: zoomControl.value as? String) ?? 0
        captureImmediately("quick-note-notebook-pinch-out-immediate")
        attachDiagnostics(diagnostics.label, named: "quick-note-notebook-pinch-out-diagnostics")
        pauseForPresentedFrames(seconds: 10)
        captureImmediately("quick-note-notebook-pinch-out-after-10s")

        let zoomedPercent = zoomPercent(from: zoomControl.value as? String) ?? 0
        XCTAssertLessThanOrEqual(abs(zoomedPercent - pinchOutPercent), 2,
            "The pinch-out result should remain stable for ten seconds; diagnostics=\(diagnostics.label)")
        let zoomedPageNumber = pageNumber(from: indicator.label) ?? 1
        let zoomedPaperPage = self.paperPage(zoomedPageNumber, in: app)
        XCTAssertTrue(wait { zoomedPaperPage.isHittable },
            "Reacquire the visible handwritten page after zoom before pinching back.")
        zoomedPaperPage.pinch(withScale: 0.5, velocity: -1)
        XCTAssertTrue(wait { (self.zoomPercent(from: zoomControl.value as? String) ?? 0) < zoomedPercent },
            "Notebook-owned pinch should decrease from \(zoomedPercent)%; diagnostics=\(diagnostics.label)")
        captureImmediately("quick-note-notebook-pinch-in-immediate")
        attachDiagnostics(diagnostics.label, named: "quick-note-notebook-pinch-in-diagnostics")
        pauseForPresentedFrames(seconds: 10)
        captureImmediately("quick-note-notebook-pinch-in-after-10s")
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

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func pageNumber(from label: String) -> Int? {
        label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
    }

    private func paperPage(_ pageNumber: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "canvas.paper.page.\(pageNumber)").firstMatch
    }

    private func setZoomPercent(_ targetPercent: Int, using zoomControl: XCUIElement) {
        guard var currentPercent = zoomPercent(from: zoomControl.value as? String),
              currentPercent > 0 else {
            XCTFail("The zoom control must expose a numeric current value.")
            return
        }
        // Keep each synthetic drag on the visible track. Beginning at the
        // scrubber's left edge can be intercepted by iPadOS edge gestures, and
        // a full octave in one XCUI drag is unreliable on a moving canvas.
        for _ in 0..<40 {
            if abs(currentPercent - targetPercent) <= 2 { return }
            let delta = 120 * log2(Double(targetPercent) / Double(currentPercent))
            if abs(delta) <= 0.5 { return }

            let width = Double(zoomControl.frame.width)
            let maximumTravel = min(45, width * 0.27)
            guard width > 0, maximumTravel > 0 else {
                XCTFail("The zoom control must have a nonzero on-screen frame.")
                return
            }
            let movement = min(abs(delta), maximumTravel) * (delta < 0 ? -1 : 1)
            let startingPercent = currentPercent
            let startX = movement >= 0 ? 0.5 : 0.9
            let endX = startX + movement / width
            XCTAssertTrue((0.45...0.92).contains(startX) && (0.45...0.92).contains(endX),
                "The scrubber drag must stay on its visible track; start=\(startX), end=\(endX).")
            zoomControl.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: zoomControl.coordinate(
                    withNormalizedOffset: CGVector(dx: endX, dy: 0.5)
                ))
            let isMovingTowardTarget = movement >= 0
            XCTAssertTrue(wait({
                guard let actual = self.zoomPercent(from: zoomControl.value as? String) else { return false }
                return isMovingTowardTarget ? actual > startingPercent : actual < startingPercent
            }, timeout: 3), "Zoom scrub should move toward \(targetPercent)%; " +
                "started=\(startingPercent) current=\(String(describing: zoomControl.value))")
            currentPercent = zoomPercent(from: zoomControl.value as? String) ?? startingPercent
        }
        XCTFail("Direct manipulation did not converge on \(targetPercent)%; current=\(String(describing: zoomControl.value))")
    }

    private func zoomPercent(from value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.filter(\.isNumber))
    }

    private func pauseForPresentedFrames(seconds: TimeInterval) {
        let presented = expectation(description: "Presented frames after zoom settlement")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { presented.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: seconds + 1), .completed)
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

    private func attachDiagnostics(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
