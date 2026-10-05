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
        XCTAssertEqual(
            CanvasTool.fountainPen.toolbarFamilyVariants,
            [.fountainPen, .watercolor, .crayon]
        )
        XCTAssertEqual(CanvasTool.crayon.toolbarFamilyRoot, .fountainPen)
        XCTAssertEqual(CanvasTool.fountainPen.toolbarFamilyTitle, "Brush")
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
        XCTAssertGreaterThan(CanvasToolPicker.preferredBarWidth, 460)
        XCTAssertLessThan(CanvasToolPicker.preferredBarWidth, 520)
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
