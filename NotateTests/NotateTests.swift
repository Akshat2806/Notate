//
//  NotateTests.swift
//  NotateTests
//
//  Created by Akshat Srivastava on 21/09/26.
//

import XCTest
@testable import Notate
import UIKit
import PaperKit

@MainActor
private final class FailOnceCanvasMarkupCodec: CanvasCoreMarkupCoding {
    private var shouldFailEncoding = true

    func encode(_ markup: PaperMarkup) async throws -> Data {
        if shouldFailEncoding {
            shouldFailEncoding = false
            throw TestMarkupCodecError.injected
        }
        return try await PaperKitCanvasCoreCodec().encode(markup)
    }

    func decode(_ data: Data) async throws -> PaperMarkup {
        try await PaperKitCanvasCoreCodec().decode(data)
    }
}

private enum TestMarkupCodecError: Error, LocalizedError {
    case injected

    var errorDescription: String? { "injected PaperKit encode failure" }
}

final class NotateTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

    func testPaperSetupCatalogUsesTheIntendedCategoryOrderAndTemplates() {
        XCTAssertEqual(
            CanvasPaperTemplateCategory.allCases,
            [.essentials, .writing, .planner, .music, .literature]
        )
        XCTAssertEqual(
            CanvasPaperTemplateCategory.allCases.flatMap(\.styles),
            [
                .blank, .ruled, .grid, .dotted,
                .legal, .singleColumn, .cornell, .mixed, .twoColumnLeft, .threeColumn,
                .todo, .monthlyPlanner,
                .music, .guitarScore, .guitarTab,
                .manuscript,
            ]
        )
    }

    func testPaperSetupPaletteIsCuratedAndRepresentsLegacyTonesInPlace() {
        XCTAssertEqual(
            CanvasPaperTone.paperSetupPalette,
            [
                .paperWhite, .paperCream, .paperBeige, .paperBlueGray,
                .paperCharcoal, .trueBlack,
            ]
        )
        XCTAssertEqual(CanvasPaperTone.paperSetupPalette.count, 6)
        XCTAssertEqual(CanvasPaperTone.white.paperSetupPaletteChoice, .paperWhite)
        XCTAssertEqual(CanvasPaperTone.warmWhite.paperSetupPaletteChoice, .paperWhite)
        XCTAssertEqual(CanvasPaperTone.cream.paperSetupPaletteChoice, .paperCream)
        XCTAssertEqual(CanvasPaperTone.lightGray.paperSetupPaletteChoice, .paperBlueGray)
        XCTAssertEqual(CanvasPaperTone.beige.paperSetupPaletteChoice, .paperBeige)
        XCTAssertEqual(CanvasPaperTone.darkCream.paperSetupPaletteChoice, .paperBeige)
        XCTAssertEqual(CanvasPaperTone.blush.paperSetupPaletteChoice, .paperBeige)
        XCTAssertEqual(CanvasPaperTone.gray.paperSetupPaletteChoice, .paperBlueGray)
        XCTAssertEqual(CanvasPaperTone.sky.paperSetupPaletteChoice, .paperBlueGray)
        XCTAssertEqual(CanvasPaperTone.mint.paperSetupPaletteChoice, .paperBlueGray)
        XCTAssertEqual(CanvasPaperTone.charcoal.paperSetupPaletteChoice, .paperCharcoal)
        XCTAssertEqual(CanvasPaperTone.midnight.paperSetupPaletteChoice, .paperCharcoal)
        XCTAssertEqual(CanvasPaperTone.black.paperSetupPaletteChoice, .trueBlack)
        XCTAssertEqual(CanvasPaperTemplate.default.tone, .warmWhite)
        XCTAssertEqual(NotatePreferences.defaultPaperTemplate.tone, .paperWhite)
    }

    func testPaperSpacingSliderSnapsToExistingDensityValues() {
        XCTAssertEqual(CanvasPaperDensity.atSliderPosition(0), .narrow)
        XCTAssertEqual(CanvasPaperDensity.atSliderPosition(1), .standard)
        XCTAssertEqual(CanvasPaperDensity.atSliderPosition(2), .wide)
        XCTAssertEqual(CanvasPaperDensity.atSliderPosition(0.8), .standard)
        XCTAssertEqual(CanvasPaperDensity.narrow.sliderPosition, 0)
        XCTAssertEqual(CanvasPaperDensity.standard.sliderPosition, 1)
        XCTAssertEqual(CanvasPaperDensity.wide.sliderPosition, 2)
    }

    func testPaperTemplateArtworkBuildsAllNonblankLayoutsWithinPageBounds() {
        let pageSize = CGSize(width: 840, height: 1_188)
        for style in CanvasPaperStyle.allCases where style != .blank {
            let artwork = CanvasPaperTemplateArtwork.paths(
                for: CanvasPaperTemplate(style: style),
                pageSize: pageSize
            )
            XCTAssertFalse(artwork.pattern.isEmpty, "\(style.rawValue) should draw a preview")
            let bounds = artwork.pattern.boundingBoxOfPath
            XCTAssertGreaterThanOrEqual(bounds.minX, -0.01, "\(style.rawValue) min x")
            XCTAssertGreaterThanOrEqual(bounds.minY, -0.01, "\(style.rawValue) min y")
            XCTAssertLessThanOrEqual(bounds.maxX, pageSize.width + 0.01, "\(style.rawValue) max x")
            XCTAssertLessThanOrEqual(bounds.maxY, pageSize.height + 0.01, "\(style.rawValue) max y")
        }
    }

    @MainActor
    func testPaperTemplateAllPagesTargetsSkipImportedAndAlreadyMatchingPages() {
        let markup = PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 840, height: 1_188))
        let requested = CanvasPaperTemplate(style: .grid)
        let normalPage = CanvasPageSnapshot(markup: markup)
        let importedPage = CanvasPageSnapshot(
            markup: markup,
            background: .image(data: Data([0x01]), suggestedName: "Imported")
        )
        let matchingPage = CanvasPageSnapshot(markup: markup, paperTemplate: requested)

        XCTAssertEqual(
            CanvasEditorModel.paperTemplateTargetPageIDs(
                in: [normalPage, importedPage, matchingPage],
                template: requested
            ),
            [normalPage.id]
        )
    }

    func testPaperTemplateCodablePreservesOlderSavedValues() throws {
        let oldTemplateData = Data(
            #"{"style":"music","density":"narrow","tone":"midnight"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(CanvasPaperTemplate.self, from: oldTemplateData)
        XCTAssertEqual(
            decoded,
            CanvasPaperTemplate(style: .music, density: .narrow, tone: .midnight)
        )
    }

    @MainActor
    func testBulkPaperTemplateChangeUndoesAndRedoesAsOneAction() {
        let markup = PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 840, height: 1_188))
        let original = CanvasPaperTemplate(style: .ruled)
        let firstPage = CanvasPageSnapshot(markup: markup, paperTemplate: original)
        let secondPage = CanvasPageSnapshot(markup: markup, paperTemplate: original)
        let requested = CanvasPaperTemplate(style: .guitarTab, density: .wide, tone: .beige)
        var reportedChanges: [UUID: CanvasPaperTemplate] = [:]
        let callbacks = PaperCanvasCallbacks(
            markupChanged: { _, _ in },
            pageReplaced: { _ in },
            paperTemplatesChanged: { reportedChanges = $0 },
            interactionBegan: { _ in },
            undoAvailabilityChanged: { _, _, _ in },
            viewportChanged: { _, _ in },
            focusedPageChanged: { _ in }
        )
        let controller = PaperCanvasViewController(
            pages: [firstPage, secondPage],
            currentPageID: firstPage.id,
            viewport: CanvasViewportState(),
            inputMode: .pencilOnly,
            callbacks: callbacks
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 500, height: 800)
        controller.view.layoutIfNeeded()

        controller.setPaperTemplate(requested, forPageIDs: [firstPage.id, secondPage.id])
        XCTAssertEqual(controller.pageSnapshotsForTesting.map(\.paperTemplate), [requested, requested])
        XCTAssertEqual(Set(reportedChanges.keys), [firstPage.id, secondPage.id])

        reportedChanges = [:]
        controller.undo()
        XCTAssertEqual(controller.pageSnapshotsForTesting.map(\.paperTemplate), [original, original])
        XCTAssertEqual(Set(reportedChanges.keys), [firstPage.id, secondPage.id])

        reportedChanges = [:]
        controller.redo()
        XCTAssertEqual(controller.pageSnapshotsForTesting.map(\.paperTemplate), [requested, requested])
        XCTAssertEqual(Set(reportedChanges.keys), [firstPage.id, secondPage.id])
    }

    @MainActor
    func testBulkPaperTemplateStressKeepsLargeNotebookPageHostsVirtualized() {
        let pageCount = max(
            128,
            PaperCanvasViewController.maximumEagerPageHostCountForTesting * 4
        )
        let markup = PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 840, height: 1_188))
        let original = CanvasPaperTemplate(style: .ruled)
        let pages = (0..<pageCount).map { _ in
            CanvasPageSnapshot(markup: markup, paperTemplate: original)
        }
        let pageIDs = pages.map(\.id)
        let controller = PaperCanvasViewController(
            pages: pages,
            currentPageID: pageIDs[0],
            viewport: CanvasViewportState(),
            inputMode: .pencilOnly,
            callbacks: PaperCanvasCallbacks(
                markupChanged: { _, _ in },
                pageReplaced: { _ in },
                paperTemplatesChanged: { _ in },
                interactionBegan: { _ in },
                undoAvailabilityChanged: { _, _, _ in },
                viewportChanged: { _, _ in },
                focusedPageChanged: { _ in }
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 500, height: 800)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(controller.virtualizesPageHostsForTesting)
        let initiallyMountedIDs = Set(controller.mountedPageIDsForTesting)
        let initiallyMountedHostCount = controller.mountedPageHostCountForTesting
        XCTAssertLessThan(initiallyMountedHostCount, pageCount)

        let templates = [
            CanvasPaperTemplate(style: .grid, tone: .paperCream),
            CanvasPaperTemplate(style: .music, tone: .paperBlueGray),
            CanvasPaperTemplate(style: .todo, tone: .paperBeige),
            CanvasPaperTemplate(style: .guitarTab, tone: .paperCharcoal),
            CanvasPaperTemplate(style: .dotted, tone: .trueBlack),
        ]
        var currentTemplate = original

        // Repeat the all-page update and its full history round trip. This
        // exercises large page arrays while proving each operation touches
        // only the existing viewport/history hosts instead of mounting every
        // offscreen PaperKit controller.
        for iteration in 0..<15 {
            let requested = templates[iteration % templates.count]
            controller.setPaperTemplate(requested, forPageIDs: pageIDs)
            XCTAssertEqual(
                controller.pageSnapshotsForTesting.map(\.paperTemplate),
                Array(repeating: requested, count: pageCount)
            )
            XCTAssertEqual(controller.mountedPageHostCountForTesting, initiallyMountedHostCount)
            XCTAssertEqual(Set(controller.mountedPageIDsForTesting), initiallyMountedIDs)

            controller.undo()
            XCTAssertEqual(
                controller.pageSnapshotsForTesting.map(\.paperTemplate),
                Array(repeating: currentTemplate, count: pageCount)
            )
            XCTAssertEqual(controller.mountedPageHostCountForTesting, initiallyMountedHostCount)

            controller.redo()
            XCTAssertEqual(
                controller.pageSnapshotsForTesting.map(\.paperTemplate),
                Array(repeating: requested, count: pageCount)
            )
            XCTAssertEqual(controller.mountedPageHostCountForTesting, initiallyMountedHostCount)
            currentTemplate = requested
        }

        let offscreenPageID = pageIDs[pageCount - 1]
        XCTAssertNil(controller.paperTemplateViewForTesting(pageID: offscreenPageID))
        controller.scrollToPage(id: offscreenPageID, animated: false)
        XCTAssertEqual(
            controller.paperTemplateViewForTesting(pageID: offscreenPageID)?.template,
            currentTemplate
        )
    }

    @MainActor
    func testTransientPaperKitSerializationFailureIsClassifiedAndCanRetrySameGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notate-FlakyCodec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CanvasCoreStore(rootURL: root, codec: FailOnceCanvasMarkupCodec())
        let page = CanvasPageSnapshot(
            markup: PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_400))
        )
        let snapshot = CanvasCoreSnapshot(
            generation: 1,
            pages: [page],
            currentPageID: page.id
        )

        do {
            try await store.checkpoint(snapshot)
            XCTFail("The injected first serialization attempt should fail.")
        } catch let error as CanvasCoreStoreError {
            XCTAssertTrue(error.isTransientCheckpointFailure)
            XCTAssertTrue(error.localizedDescription.contains("injected PaperKit encode failure"))
        }

        try await store.checkpoint(snapshot)
        guard case let .restored(restored) = await store.load() else {
            return XCTFail("The retry should publish a verified checkpoint.")
        }
        XCTAssertEqual(restored.generation, snapshot.generation)
        XCTAssertEqual(restored.currentPageID, page.id)
    }

    func testResourceLimitFailureIsPermanentAndExplained() {
        let error = CanvasCoreStoreError.resourceLimitExceeded(
            "The document exceeds the supported PaperKit size limit."
        )

        XCTAssertFalse(error.isTransientCheckpointFailure)
        XCTAssertTrue(error.localizedDescription.contains("supported storage limit"))
    }

    @MainActor
    func testCanvasClearanceUsesMeasuredChromeHeight() {
        let safeArea = UIEdgeInsets(top: 24, left: 0, bottom: 0, right: 0)
        let measuredChrome: CGFloat = 168

        XCTAssertEqual(
            CanvasStackLayout.topClearance(
                safeAreaInsets: safeArea,
                topChromeHeight: measuredChrome
            ),
            safeArea.top + measuredChrome + CanvasConstants.firstPageToolbarGap
        )
    }

    @MainActor
    func testExpandedChromeDoesNotScaleWithCanvasZoom() {
        let viewport = CGSize(width: 1_000, height: 800)
        let safeArea = UIEdgeInsets(top: 24, left: 0, bottom: 0, right: 0)
        let regular = CanvasStackLayout.contentInset(
            viewportSize: viewport,
            safeAreaInsets: safeArea,
            zoomScale: 0.5,
            contentWidth: 300,
            topChromeHeight: 80
        )
        let expanded = CanvasStackLayout.contentInset(
            viewportSize: viewport,
            safeAreaInsets: safeArea,
            zoomScale: 0.5,
            contentWidth: 300,
            topChromeHeight: 176
        )

        XCTAssertEqual(expanded.top - regular.top, 96)
    }

    @MainActor
    func testBoundaryPullRequiresDeliberateRevealAtBothEndsAndAxes() {
        let insets = UIEdgeInsets(top: 80, left: 20, bottom: 20, right: 20)
        let verticalSize = CGSize(width: 500, height: 700)
        let verticalContent = CGSize(width: 500, height: 1_000)
        let verticalStart = CanvasStackLayout.boundaryPagePull(
            contentOffset: CGPoint(x: 0, y: -150),
            panTranslation: CGPoint(x: 0, y: 80),
            viewportSize: verticalSize,
            contentSize: verticalContent,
            contentInset: insets,
            zoomScale: 1
        )
        let ordinaryVerticalBounce = CanvasStackLayout.boundaryPagePull(
            contentOffset: CGPoint(x: 0, y: -40),
            panTranslation: CGPoint(x: 0, y: 25),
            viewportSize: verticalSize,
            contentSize: verticalContent,
            contentInset: insets,
            zoomScale: 1
        )

        let horizontalLayout = CanvasPageLayoutPreferences(
            scrollDirection: .horizontal
        )
        let horizontalStart = CanvasStackLayout.boundaryPagePull(
            contentOffset: CGPoint(x: -90, y: 0),
            panTranslation: CGPoint(x: 80, y: 0),
            viewportSize: CGSize(width: 900, height: 600),
            contentSize: CGSize(width: 1_400, height: 700),
            contentInset: insets,
            zoomScale: 1,
            pageLayout: horizontalLayout
        )
        let horizontalEnd = CanvasStackLayout.boundaryPagePull(
            contentOffset: CGPoint(x: 590, y: 0),
            panTranslation: CGPoint(x: -80, y: 0),
            viewportSize: CGSize(width: 900, height: 600),
            contentSize: CGSize(width: 1_400, height: 700),
            contentInset: insets,
            zoomScale: 1,
            pageLayout: horizontalLayout
        )

        XCTAssertEqual(verticalStart?.boundary, .start)
        XCTAssertNil(ordinaryVerticalBounce)
        XCTAssertEqual(horizontalStart?.boundary, .start)
        XCTAssertEqual(horizontalEnd?.boundary, .end)
    }

    func testNewCanvasToolStateStartsWithBlackPen() {
        let state = CanvasToolState()

        XCTAssertEqual(state.activeTool, .pen)
        XCTAssertEqual(state.configuration(for: .pen)?.color, .black)
    }


    // MARK: - Tool model regression tests

    func testPenFamilyOffersMonolineBallpointAndCalligraphy() {
        XCTAssertEqual(CanvasTool.pen.toolbarFamilyVariants, [.pen, .ballpoint, .calligraphy])
        XCTAssertEqual(CanvasTool.ballpoint.toolbarFamilyRoot, .pen)
        XCTAssertEqual(CanvasTool.calligraphy.toolbarFamilyRoot, .pen)
        XCTAssertEqual(CanvasTool.pen.title, "Monoline")
        XCTAssertEqual(CanvasTool.pen.toolbarFamilyTitle, "Pen")
    }

    func testBrushFamilyOffersFountainWatercolorAndCrayon() {
        XCTAssertEqual(CanvasTool.fountainPen.toolbarFamilyVariants, [.fountainPen, .watercolor, .crayon])
        XCTAssertEqual(CanvasTool.crayon.toolbarFamilyRoot, .fountainPen)
        XCTAssertEqual(CanvasTool.fountainPen.toolbarFamilyTitle, "Brush")
        XCTAssertEqual(CanvasTool.fountainPen.title, "Fountain Pen")
    }

    func testEveryDrawingToolHasDefaultConfigurationAndSixWidths() {
        let drawingTools: [CanvasTool] = [
            .pen, .ballpoint, .calligraphy, .pencil,
            .fountainPen, .watercolor, .crayon, .highlighter,
        ]
        for tool in drawingTools {
            XCTAssertNotNil(CanvasToolState.defaults[tool], "\(tool) lacks defaults")
            XCTAssertEqual(CanvasToolState.widthPresets(for: tool).count, 6, "\(tool)")
        }
        XCTAssertNotNil(CanvasToolState.defaults[.eraser])
        XCTAssertNotNil(CanvasToolState.defaults[.laserPointer])
    }

    func testToolStateFromBeforeBallpointAndLaserColorStillDecodes() throws {
        var legacy = CanvasToolState.defaults
        legacy.removeValue(forKey: .ballpoint)
        legacy.removeValue(forKey: .laserPointer)
        let state = CanvasToolState(configurations: legacy)

        let decoded = try JSONDecoder().decode(
            CanvasToolState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertNotNil(decoded.configuration(for: .ballpoint))
        XCTAssertNotNil(decoded.configuration(for: .laserPointer))
        XCTAssertTrue(decoded.hasValidConfigurations)
    }

    func testPreferredPenAndBrushFollowTheActiveVariant() {
        var state = CanvasToolState()
        state.activeTool = .ballpoint
        XCTAssertEqual(state.preferredPenTool, .ballpoint)
        state.activeTool = .watercolor
        XCTAssertEqual(state.preferredBrushTool, .watercolor)
        XCTAssertEqual(state.preferredPenTool, .ballpoint)
    }

    func testQuickPalettesAreFiveSwatches() {
        XCTAssertEqual(RGBAColor.quickInkPalette.count, 5)
        XCTAssertGreaterThanOrEqual(RGBAColor.highlighterPalette.count, 5)
    }

    @MainActor
    func testToolBarKeepsElevenControlsAndThreePipesInACompactRow() {
        // Undo Redo | Lasso Pen Pencil Brush Highlighter | Eraser Ruler Laser | +
        XCTAssertEqual(CanvasToolPicker.BarMetrics.itemCount, 11)
        XCTAssertEqual(CanvasToolPicker.BarMetrics.pipeCount, 3)
        XCTAssertEqual(CanvasToolPicker.BarMetrics.itemWidth, 44)
        XCTAssertGreaterThan(CanvasToolPicker.preferredBarWidth, 460)
        XCTAssertLessThan(CanvasToolPicker.preferredBarWidth, 560)
    }

    @MainActor
    func testEveryPanelUsesTheSameSixColumnWidth() {
        XCTAssertEqual(CanvasToolPicker.PanelMetrics.contentWidth, 252)
    }

    @MainActor
    func testPanelsAreCentredUnderTheToolbar() {
        XCTAssertEqual(
            CanvasToolPicker.anchorKey(for: .toolOptions(.calligraphy), activeTool: .calligraphy),
            "bar"
        )
        XCTAssertEqual(CanvasToolPicker.anchorKey(for: .geometryTools, activeTool: .pen), "bar")
        XCTAssertEqual(CanvasToolPicker.anchorKey(for: .insert, activeTool: .pen), "bar")
        XCTAssertNil(CanvasToolPicker.anchorKey(for: .none, activeTool: .pen))
    }


    // MARK: - Pull-to-add-page: instant arm, never during normal scrolling

    private func fullPull(_ boundary: CanvasPageBoundary) -> CanvasBoundaryPagePull {
        CanvasBoundaryPagePull(boundary: boundary, progress: 1)
    }

    func testPullArmsTheMomentItReachesTheArmDistanceWithNoHold() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [.start])

        let armed = gate.update(measuredPull: fullPull(.start), now: 1)

        XCTAssertEqual(armed?.isArmed, true)
        XCTAssertEqual(gate.end(releaseVelocity: .zero), .start)
    }

    func testPullBetweenRevealAndArmNeverInsertsOnRelease() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [.start])
        let partial = gate.update(
            measuredPull: CanvasBoundaryPagePull(boundary: .start, progress: 0.5),
            now: 1
        )

        XCTAssertEqual(partial?.progress, 0.5)
        XCTAssertNil(gate.end(releaseVelocity: .zero))
    }

    func testArmedPullReleasedWithAFlickDoesNotInsert() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [.end])
        _ = gate.update(measuredPull: fullPull(.end), now: 10)

        XCTAssertNil(gate.end(releaseVelocity: CGPoint(x: 0, y: -900)))
    }

    func testDragThatDidNotStartAtAnEdgeNeverPulls() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [])

        XCTAssertNil(gate.update(measuredPull: fullPull(.start), now: 1))
        XCTAssertNil(gate.end(releaseVelocity: .zero))
    }

    func testPullTowardTheOtherEdgeIsIgnored() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [.start])

        XCTAssertNil(gate.update(measuredPull: fullPull(.end), now: 1))
        XCTAssertNil(gate.end(releaseVelocity: .zero))
    }

    func testPullingBackBelowDisarmCancelsTheInsertion() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [.end])
        _ = gate.update(measuredPull: fullPull(.end), now: 1)
        // Back below the reveal distance the layout reports no pull at all.
        XCTAssertNil(gate.update(measuredPull: nil, now: 2))

        XCTAssertNil(gate.end(releaseVelocity: .zero))
    }

    func testSmallReversalWhileArmedStaysArmed() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [.end])
        _ = gate.update(measuredPull: fullPull(.end), now: 1)
        // Progress 0.8 is above the disarm threshold (0.69), so it holds.
        let steady = gate.update(
            measuredPull: CanvasBoundaryPagePull(boundary: .end, progress: 0.8),
            now: 2
        )

        XCTAssertEqual(steady?.isArmed, true)
        XCTAssertEqual(gate.end(releaseVelocity: .zero), .end)
    }

    func testAValidPullInsertsExactlyOnePage() {
        var gate = CanvasBoundaryPullGate()
        gate.begin(eligibleBoundaries: [.end])
        _ = gate.update(measuredPull: fullPull(.end), now: 5)

        XCTAssertEqual(gate.end(releaseVelocity: .zero), .end)
        XCTAssertNil(gate.end(releaseVelocity: .zero))
    }

    func testPullDistancesAreDeliberateButShort() {
        XCTAssertLessThanOrEqual(CanvasConstants.boundaryPullArmDistance, 60)
        XCTAssertGreaterThanOrEqual(CanvasConstants.boundaryPullArmDistance, 48)
        XCTAssertLessThan(
            CanvasConstants.boundaryPullRevealDistance,
            CanvasConstants.boundaryPullDisarmDistance
        )
        XCTAssertLessThan(
            CanvasConstants.boundaryPullDisarmDistance,
            CanvasConstants.boundaryPullArmDistance
        )
    }

    @MainActor
    func testSidewaysOrShortDragsAtTheEdgeDoNotPull() {
        let insets = UIEdgeInsets(top: 80, left: 20, bottom: 20, right: 20)
        let size = CGSize(width: 500, height: 700)
        let content = CGSize(width: 500, height: 1_000)

        let mostlySideways = CanvasStackLayout.boundaryPagePull(
            contentOffset: CGPoint(x: 0, y: -150),
            panTranslation: CGPoint(x: 120, y: 60),
            viewportSize: size,
            contentSize: content,
            contentInset: insets,
            zoomScale: 1
        )
        let belowReveal = CanvasStackLayout.boundaryPagePull(
            contentOffset: CGPoint(x: 0, y: -90),
            panTranslation: CGPoint(x: 0, y: 40),
            viewportSize: size,
            contentSize: content,
            contentInset: insets,
            zoomScale: 1
        )
        let scrollingUpInTheMiddle = CanvasStackLayout.boundaryPagePull(
            contentOffset: CGPoint(x: 0, y: 300),
            panTranslation: CGPoint(x: 0, y: -80),
            viewportSize: size,
            contentSize: content,
            contentInset: insets,
            zoomScale: 1
        )

        XCTAssertNil(mostlySideways)
        XCTAssertNil(belowReveal)
        XCTAssertNil(scrollingUpInTheMiddle)
    }

}
