//
//  NotateTests.swift
//  NotateTests
//
//  Created by Akshat Srivastava on 21/09/26.
//

import XCTest
@testable import Notate
import UIKit

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

    func testBoundaryPullMustHoldBeforeItCanInsertOnePage() {
        var gate = CanvasBoundaryPullGate()
        let pull = CanvasBoundaryPagePull(boundary: .start, progress: 1)
        gate.begin(eligibleBoundaries: [.start])

        _ = gate.update(measuredPull: pull, now: 10)
        XCTAssertTrue(gate.needsHoldTimer)
        XCTAssertNil(gate.end(releaseVelocity: .zero))

        gate.begin(eligibleBoundaries: [.start])
        _ = gate.update(measuredPull: pull, now: 20)
        let armed = gate.completeHold(
            now: 20.25,
            panVelocity: .zero,
            isDragging: true
        )
        XCTAssertEqual(armed?.progress, 1)
        XCTAssertEqual(gate.end(releaseVelocity: .zero), .start)
        XCTAssertNil(gate.end(releaseVelocity: .zero))
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
    func testPickerPillWidthIsPositiveAndGroupedWiderThanHistory() {
        XCTAssertGreaterThan(CanvasToolPicker.preferredPillWidth, CanvasToolPicker.preferredHistoryWidth)
    }

}
