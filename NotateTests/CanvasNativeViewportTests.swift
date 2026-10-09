import XCTest
import PaperKit
import PencilKit
import PDFKit
import UIKit
@testable import Notate

@MainActor
final class CanvasNativeViewportTests: XCTestCase {
    func testNativeViewportIsDefaultAndDebugLegacyRendererCanBeSelected() {
        XCTAssertEqual(
            CanvasPagedRenderingMode.resolve(environmentOverride: nil, allowsLegacyRenderer: true),
            .nativeViewport
        )
        XCTAssertEqual(
            CanvasPagedRenderingMode.resolve(environmentOverride: "1", allowsLegacyRenderer: true),
            .nativeViewport
        )
        XCTAssertEqual(
            CanvasPagedRenderingMode.resolve(environmentOverride: "0", allowsLegacyRenderer: true),
            .fullPage
        )
        XCTAssertEqual(
            CanvasPagedRenderingMode.resolve(environmentOverride: "unexpected", allowsLegacyRenderer: true),
            .nativeViewport
        )
    }

    func testLegacyRendererOverrideIsUnavailableInReleaseBuilds() {
        XCTAssertEqual(
            CanvasPagedRenderingMode.resolve(environmentOverride: "0", allowsLegacyRenderer: false),
            .nativeViewport
        )
        #if DEBUG
        XCTAssertTrue(CanvasPagedRenderingMode.currentBuildAllowsLegacyRenderer)
        #else
        XCTAssertFalse(CanvasPagedRenderingMode.currentBuildAllowsLegacyRenderer)
        #endif
    }

    func testConfiguredRendererHonorsOnlyTheCurrentBuildsAllowedOverride() {
        let explicitlyRequestsLegacy = ProcessInfo.processInfo.environment[
            "NOTATE_NATIVE_PAGED_VIEWPORT"
        ] == "0"
        let expected: CanvasPagedRenderingMode =
            CanvasPagedRenderingMode.currentBuildAllowsLegacyRenderer && explicitlyRequestsLegacy
                ? .fullPage
                : .nativeViewport
        XCTAssertEqual(CanvasPagedRenderingMode.configured, expected)
    }

    func testNativeRendererRangeCoversTransientNotebookZoomBounce() {
        XCTAssertEqual(CanvasConstants.absoluteZoomRange, 0.5...10)
        XCTAssertLessThan(
            CanvasConstants.nativeViewportRenderingZoomRange.lowerBound,
            CanvasConstants.absoluteZoomRange.lowerBound
        )
        XCTAssertGreaterThan(
            CanvasConstants.nativeViewportRenderingZoomRange.upperBound,
            CanvasConstants.absoluteZoomRange.upperBound
        )
        XCTAssertTrue(CanvasConstants.nativeViewportRenderingZoomRange.contains(0.4))
        XCTAssertTrue(CanvasConstants.nativeViewportRenderingZoomRange.contains(10.5))
    }

    func testNativeViewportClampsOuterZoomAtSupportedMinimum() {
        let native = makeController(mode: .nativeViewport)
        defer { native.completeDismantle() }
        XCTAssertFalse(native.outerScrollViewForTesting.bouncesZoom,
            "The sibling native PaperKit viewport cannot safely mirror an outer spring below 50%.")

        let legacy = makeController(mode: .fullPage)
        defer { legacy.completeDismantle() }
        XCTAssertTrue(legacy.outerScrollViewForTesting.bouncesZoom,
            "The rollback renderer retains its established zoom bounce.")
    }

    func testTemporarySubminimumZoomKeepsPaperKitInkInTheSameScaleAsTheSheet() throws {
        let controller = makeController()
        defer { controller.completeDismantle() }
        let pageID = controller.focusedPageIDForTesting
        let outerScroll = controller.outerScrollViewForTesting

        // UIKit only enters this interval during its native zoom bounce. Lower
        // the test scroll view's minimum to reproduce that transient frame.
        outerScroll.minimumZoomScale = CanvasConstants.nativeViewportRenderingZoomRange.lowerBound
        outerScroll.setZoomScale(0.4, animated: false)
        controller.scrollViewDidZoom(outerScroll)
        controller.flushNativeViewportUpdatesForTesting()

        let viewport = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pageID))
        let paper = try XCTUnwrap(controller.nativePaperControllerForTesting(pageID: pageID))
        XCTAssertEqual(viewport.logicalZoom, 0.4, accuracy: 0.001)
        XCTAssertEqual(controller.nativePaperZoomForTesting(pageID: pageID) ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(paper.zoomRange, CanvasConstants.nativeViewportRenderingZoomRange)
        XCTAssertTrue(controller.nativePaperProjectionMatchesForTesting(pageID: pageID),
                      controller.nativePaperProjectionDiagnosticsForTesting(pageID: pageID))

        outerScroll.setZoomScale(CanvasConstants.absoluteZoomRange.lowerBound, animated: false)
        controller.scrollViewDidZoom(outerScroll)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.nativePaperZoomForTesting(pageID: pageID) ?? -1,
                       CanvasConstants.absoluteZoomRange.lowerBound, accuracy: 0.001)
    }

    func testNativePinchKeepsItsFocusedPageAnchoredThroughMinimumZoomSettlement() throws {
        let pages = (0..<3).map { _ in CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup()) }
        let controller = makeNotebook(pages: pages)
        defer { controller.completeDismantle() }
        controller.setZoomScale(CanvasConstants.absoluteZoomRange.lowerBound)
        controller.scrollToPage(id: pages[2].id, animated: false)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.focusedPageIDForTesting, pages[2].id)

        let outerScroll = controller.outerScrollViewForTesting
        outerScroll.minimumZoomScale = CanvasConstants.nativeViewportRenderingZoomRange.lowerBound
        controller.scrollViewWillBeginZooming(outerScroll, with: nil)
        outerScroll.setZoomScale(CanvasConstants.nativeViewportRenderingZoomRange.lowerBound, animated: false)
        controller.scrollViewDidZoom(outerScroll)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.focusedPageIDForTesting, pages[2].id,
            "A subminimum pinch must not switch its page anchor to a newly visible neighbor.")

        outerScroll.setZoomScale(CanvasConstants.absoluteZoomRange.lowerBound, animated: false)
        controller.scrollViewDidZoom(outerScroll)
        let offsetAtRelease = outerScroll.contentOffset
        controller.scrollViewDidEndZooming(outerScroll, with: nil,
                                           atScale: outerScroll.zoomScale)
        XCTAssertEqual(outerScroll.contentOffset.x, offsetAtRelease.x, accuracy: 0.5,
            "Native viewport settlement must not recenter the pinch from a clamped page-relative anchor.")
        XCTAssertEqual(outerScroll.contentOffset.y, offsetAtRelease.y, accuracy: 0.5,
            "Native viewport settlement must keep UIKit's final vertical position.")
        controller.scrollViewDidEndDecelerating(outerScroll)
        controller.scrollViewDidEndScrollingAnimation(outerScroll)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.focusedPageIDForTesting, pages[2].id,
            "Zoom and settlement callbacks must preserve the page that owned the pinch.")
    }

    func testFirstNativeZoomDoesNotRepositionThePageAtSettlement() throws {
        let pages = (0..<3).map { _ in CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup()) }
        let controller = makeNotebook(pages: pages)
        defer { controller.completeDismantle() }
        controller.scrollToPage(id: pages[1].id, animated: false)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.focusedPageIDForTesting, pages[1].id)

        let outerScroll = controller.outerScrollViewForTesting
        controller.scrollViewWillBeginZooming(outerScroll, with: nil)
        outerScroll.setZoomScale(1.6, animated: false)
        controller.scrollViewDidZoom(outerScroll)
        controller.flushNativeViewportUpdatesForTesting()
        let offsetAtLiftOff = outerScroll.contentOffset

        controller.scrollViewDidEndZooming(outerScroll, with: nil, atScale: outerScroll.zoomScale)
        controller.flushNativeViewportUpdatesForTesting()

        XCTAssertEqual(outerScroll.contentOffset.x, offsetAtLiftOff.x, accuracy: 0.5,
            "The first native zoom must not recenter horizontally when PaperKit settles.")
        XCTAssertEqual(outerScroll.contentOffset.y, offsetAtLiftOff.y, accuracy: 0.5,
            "The first native zoom must not move the focused page vertically on lift-off.")
        XCTAssertEqual(controller.focusedPageIDForTesting, pages[1].id,
            "The page under the first pinch must remain the page that owns the zoom.")
    }

    func testMarkupPublicationWaitsUntilContactEndsAndReadsOnlyChangedPage() throws {
        let page = CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup())
        var publishedPageIDs: [UUID] = []
        let controller = PaperCanvasViewController(
            pages: [page], currentPageID: page.id,
            viewport: .stackViewport(zoomScale: 1, normalizedCenterX: 0.5, normalizedCenterY: 0.5),
            inputMode: .pencilOnly, pagedRenderingMode: .nativeViewport,
            callbacks: PaperCanvasCallbacks(markupChanged: { pageID, _ in
                publishedPageIDs.append(pageID)
            }, interactionBegan: {}, undoAvailabilityChanged: { _, _ in }, viewportChanged: { _, _ in })
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 768, height: 1_024)
        controller.view.layoutIfNeeded()
        controller.applyToolState(CanvasToolState())
        controller.flushNativeViewportUpdatesForTesting()
        defer { controller.completeDismantle() }

        let paper = try XCTUnwrap(controller.nativePaperControllerForTesting(pageID: page.id))
        var changedMarkup = try XCTUnwrap(paper.markup)
        changedMarkup.insertNewTextbox(
            attributedText: NSAttributedString(string: "revision boundary"),
            frame: CGRect(x: 80, y: 180, width: 260, height: 48)
        )

        controller.beginContactForTesting()
        paper.markup = changedMarkup
        controller.paperMarkupViewControllerDidChangeMarkup(paper)
        XCTAssertTrue(publishedPageIDs.isEmpty, "PaperMarkup must not be copied into the model during contact")
        XCTAssertEqual(controller.pendingMarkupPageCountForTesting, 1)

        controller.endContactForTesting()
        XCTAssertEqual(publishedPageIDs, [page.id])
        XCTAssertEqual(controller.pendingMarkupPageCountForTesting, 0)
    }

    func testFingerContactInsideNativeSelectionIsEditingRatherThanScrolling() throws {
        let controller = makeController()
        defer { controller.completeDismantle() }
        let pageID = controller.focusedPageIDForTesting
        controller.setZoomScale(CanvasConstants.absoluteZoomRange.lowerBound)
        controller.flushNativeViewportUpdatesForTesting()
        let paper = try XCTUnwrap(controller.nativePaperControllerForTesting(pageID: pageID))
        paper.selectedMarkup = try XCTUnwrap(paper.markup)
        let selectionFrame = paper.selectedMarkup.contentsRenderFrame
        XCTAssertFalse(selectionFrame.isNull)
        XCTAssertFalse(selectionFrame.isEmpty)
        let screenFrame = try XCTUnwrap(controller.pageFrameForTesting(selectionFrame, pageID: pageID))
        XCTAssertTrue(controller.directTouchWouldManipulateNativeSelectionForTesting(
            at: CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        ), "A finger beginning on selected handwriting should freeze native viewport geometry.")

        let outsidePoint = CGPoint(x: controller.view.bounds.maxX - 4,
                                   y: controller.view.bounds.maxY - 4)
        XCTAssertFalse(controller.directTouchWouldManipulateNativeSelectionForTesting(at: outsidePoint),
            "A finger starting outside the selection must remain available for ordinary scrolling.")
    }

    func testSelectionTransformDefersPaperViewportReconciliationUntilLiftOff() throws {
        let controller = makeController()
        defer { controller.completeDismantle() }
        let pageID = controller.focusedPageIDForTesting
        let paper = try XCTUnwrap(controller.nativePaperControllerForTesting(pageID: pageID))
        let originalMarkup = try XCTUnwrap(paper.markup)
        let originalViewport = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pageID))

        controller.beginContactForTesting()
        let geometryApplicationsAtContact = try XCTUnwrap(
            controller.nativeGeometryApplicationCountForTesting(pageID: pageID)
        )
        var movedMarkup = originalMarkup
        movedMarkup.transformContent(CGAffineTransform(translationX: 18, y: 12))
        paper.markup = movedMarkup
        controller.paperMarkupViewControllerDidChangeMarkup(paper)

        // PaperKit reports contentVisibleFrame changes while a selection's
        // handles and contents move. Those callbacks must not rewrite the
        // native surface under the active transform gesture.
        paper.contentVisibleFrame = originalViewport.renderPageRect.offsetBy(dx: 12, dy: 8)
        controller.paperMarkupViewControllerDidChangeContentVisibleFrame(paper)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.nativeViewportForTesting(pageID: pageID), originalViewport)
        XCTAssertEqual(controller.nativeGeometryApplicationCountForTesting(pageID: pageID),
                       geometryApplicationsAtContact)
        XCTAssertEqual(controller.pendingMarkupPageCountForTesting, 1)

        controller.endContactForTesting()
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(paper.markup, movedMarkup,
            "The selection transform must survive the deferred viewport reconciliation.")
        XCTAssertTrue(controller.nativePaperProjectionMatchesForTesting(pageID: pageID),
            controller.nativePaperProjectionDiagnosticsForTesting(pageID: pageID))
    }

    func testCroppedViewportUsesAuthoredCoordinatesAndScreenBoundedFrame() throws {
        let value = try XCTUnwrap(CanvasNativeViewport(
            pageID: UUID(), projectedPageFrame: CGRect(x: -1_200, y: -2_500, width: 5_950, height: 8_420),
            viewportBounds: CGRect(x: 0, y: 0, width: 768, height: 1_024), logicalZoom: 10
        ))
        XCTAssertEqual(value.screenFrame, CGRect(x: 0, y: 0, width: 768, height: 1_024))
        XCTAssertEqual(value.visiblePageRect, CGRect(x: 120, y: 250, width: 76.8, height: 102.4))
        XCTAssertEqual(value.pagePoint(fromLocal: .zero), CGPoint(x: 120, y: 250))
    }

    func testRoundTripsAcrossZoomPageEdgesAndNonzeroScrollBoundsOrigin() throws {
        for zoom: CGFloat in [0.5, 1, 6, 8, 10] {
            for origin in [CGPoint(x: 40, y: 80), CGPoint(x: -120, y: -250)] {
                let value = try XCTUnwrap(CanvasNativeViewport(
                    pageID: UUID(), projectedPageFrame: CGRect(origin: origin,
                        size: CGSize(width: 595 * zoom, height: 842 * zoom)),
                    viewportBounds: CGRect(x: 100, y: 150, width: 768, height: 1_024), logicalZoom: zoom
                ))
                for point in [CGPoint.zero, CGPoint(x: 300, y: 400), CGPoint(x: 595, y: 842)] {
                    let result = value.pagePoint(fromLocal: value.localPoint(fromPage: point))
                    XCTAssertEqual(result.x, point.x, accuracy: 0.00001)
                    XCTAssertEqual(result.y, point.y, accuracy: 0.00001)
                }
                XCTAssertLessThanOrEqual(value.screenFrame.width, 768)
                XCTAssertLessThanOrEqual(value.screenFrame.height, 1_024)
                XCTAssertEqual(value.localRect(fromPage: value.renderPageRect).origin.x, 0, accuracy: 0.00001)
                XCTAssertEqual(value.localRect(fromPage: value.renderPageRect).origin.y, 0, accuracy: 0.00001)
            }
        }
    }

    func testVisibilityIntersectionChangesDoNotImplyPaperKitSurfaceRebuild() throws {
        let pageID = UUID()
        let projectedPage = CGRect(x: 0, y: 0, width: 595 * 0.5, height: 842 * 0.5)
        let first = try XCTUnwrap(CanvasNativeViewport(
            pageID: pageID, projectedPageFrame: projectedPage,
            viewportBounds: CGRect(x: 0, y: 100, width: 768, height: 800), logicalZoom: 0.5
        ))
        let second = try XCTUnwrap(CanvasNativeViewport(
            pageID: pageID, projectedPageFrame: projectedPage,
            viewportBounds: CGRect(x: 0, y: 120, width: 768, height: 800), logicalZoom: 0.5
        ))
        XCTAssertNotEqual(first.visiblePageRect, second.visiblePageRect)
        XCTAssertTrue(first.hasSameRenderingProjection(as: second))
    }

    func testRejectsInvalidOrOffscreenGeometry() {
        let frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        for zoom: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertNil(CanvasNativeViewport(pageID: UUID(), projectedPageFrame: frame,
                                              viewportBounds: frame, logicalZoom: zoom))
        }
        for invalid in [CGRect.null, CGRect.infinite, CGRect.zero,
                        CGRect(x: 2_000, y: 2_000, width: 20, height: 20)] {
            XCTAssertNil(CanvasNativeViewport(pageID: UUID(), projectedPageFrame: invalid,
                                              viewportBounds: frame, logicalZoom: 1))
        }
    }

    func testFitPageRenderWindowKeepsItsSizeWhileVisibilityChanges() throws {
        let id = UUID()
        for zoom: CGFloat in [0.5, 0.6, 1, 6, 10] {
            let page = CGRect(x: 100, y: 1_000, width: 595 * zoom, height: 842 * zoom)
            for offset: CGFloat in [-500, -200, 0, 200, 500] {
                let screen = CGRect(x: 0, y: page.midY - 410 + offset, width: 1_180, height: 820)
                guard let value = CanvasNativeViewport(pageID: id, projectedPageFrame: page,
                    viewportBounds: screen, logicalZoom: zoom) else { continue }
                XCTAssertEqual(value.renderScreenFrame.width, min(page.width, screen.width), accuracy: 0.001)
                XCTAssertEqual(value.renderScreenFrame.height, min(page.height, screen.height), accuracy: 0.001)
                XCTAssertTrue(value.renderPageRect.insetBy(dx: -0.001, dy: -0.001).contains(value.visiblePageRect))
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 595, height: 842)
                    .insetBy(dx: -0.001, dy: -0.001).contains(value.renderPageRect))
                XCTAssertEqual(value.renderScreenFrame.intersection(screen).minY, value.screenFrame.minY, accuracy: 0.001)
                XCTAssertEqual(value.renderScreenFrame.intersection(screen).height, value.screenFrame.height, accuracy: 0.001)
                if zoom <= 0.6 {
                    XCTAssertEqual(value.renderPageRect, CGRect(x: 0, y: 0, width: 595, height: 842))
                }
            }
        }
    }

    func testFixedZoomPanMovesPaperWithoutResizingOrReconfiguringNativeEditor() async throws {
        let pages = (0..<12).map { index -> CanvasPageSnapshot in
            var markup = PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
            markup.insertNewTextbox(attributedText: NSAttributedString(string: "Fixed scroll page \(index + 1)",
                attributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.black]),
                frame: CGRect(x: 65, y: 160, width: 440, height: 60))
            return CanvasPageSnapshot(markup: markup, paperTemplate: CanvasPaperTemplate(
                style: index.isMultiple(of: 2) ? .grid : .ruled,
                tone: index.isMultiple(of: 2) ? .cream : .white))
        }
        let controller = makeNotebook(pages: pages)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            controller.completeDismantle()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for direction in [CanvasScrollDirection.vertical, .horizontal] {
            controller.setPageLayout(CanvasPageLayoutPreferences(scrollDirection: direction))
            for requested: CGFloat in [0.5, 0.6, 1] {
                controller.scrollToPage(id: pages[4].id, animated: false)
                let offsetAfterJump = controller.outerScrollViewForTesting.contentOffset
                let stateAfterJump = controller.navigationDiagnosticsForTesting(pageID: pages[4].id)
                controller.setZoomScale(requested)
                let offsetAfterZoom = controller.outerScrollViewForTesting.contentOffset
                controller.flushNativeViewportUpdatesForTesting()
                try await Task.sleep(for: .milliseconds(50))
                controller.flushNativeViewportUpdatesForTesting()
                let zoom = controller.effectiveZoomScaleForTesting
                let scroll = controller.outerScrollViewForTesting
                let initialOffset = scroll.contentOffset
                let paper = try XCTUnwrap(
                    controller.nativePaperControllerForTesting(pageID: pages[4].id),
                    "page 5 host missing after navigation: focus=\(controller.focusedPageIDForTesting), " +
                        "mounted=\(controller.mountedPageIDsForTesting.count), " +
                        "offsets=\(offsetAfterJump)->\(offsetAfterZoom)->\(scroll.contentOffset), " +
                        "contentSize=\(scroll.contentSize), inset=\(scroll.contentInset), " +
                        "zoom=\(controller.effectiveZoomScaleForTesting), " +
                        "stateAfterJump=\(stateAfterJump), " +
                        "state=\(controller.navigationDiagnosticsForTesting(pageID: pages[4].id))"
                )
                let bounds = paper.view.bounds
                let renderRect = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pages[4].id)).renderPageRect
                let count = try XCTUnwrap(controller.nativeGeometryApplicationCountForTesting(pageID: pages[4].id))
                let forward = stride(from: CGFloat(0), through: CGFloat(180), by: 12).map { $0 }
                for delta in forward + forward.reversed() + forward.map({ -$0 }) + forward.reversed().map({ -$0 }) {
                    var offset = initialOffset
                    if direction == .vertical { offset.y += delta } else { offset.x += delta }
                    scroll.setContentOffset(offset, animated: false)
                    // Let the normal display-link path run during motion.
                    try await Task.sleep(for: .milliseconds(20))
                    let viewport = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pages[4].id))
                    XCTAssertEqual(paper.view.bounds, bounds)
                    if direction == .horizontal || zoom <= 0.6 {
                        XCTAssertEqual(viewport.renderPageRect, renderRect)
                        XCTAssertEqual(controller.nativeGeometryApplicationCountForTesting(pageID: pages[4].id), count)
                    }
                    XCTAssertEqual(paper.zoomRange, CanvasConstants.nativeViewportRenderingZoomRange)
                    XCTAssertEqual(controller.effectiveZoomScaleForTesting, zoom, accuracy: 0.0001)
                    let projected = try XCTUnwrap(controller.projectedPageFrameForTesting(pageID: pages[4].id))
                    let anchor = try XCTUnwrap(controller.pageFrameForTesting(
                        CGRect(x: 100, y: 200, width: 20, height: 20), pageID: pages[4].id))
                    XCTAssertEqual(anchor.minX, projected.minX - scroll.bounds.minX + 100 * zoom, accuracy: 0.01)
                    XCTAssertEqual(anchor.minY, projected.minY - scroll.bounds.minY + 200 * zoom, accuracy: 0.01)
                    let nativeAnchor = try XCTUnwrap(controller.nativeContentFrameForTesting(
                        CGRect(x: 100, y: 200, width: 20, height: 20), pageID: pages[4].id))
                    XCTAssertEqual(nativeAnchor.minX, anchor.minX, accuracy: 0.51)
                    XCTAssertEqual(nativeAnchor.minY, anchor.minY, accuracy: 0.51)
                    XCTAssertEqual(nativeAnchor.width, 20 * zoom, accuracy: 0.01)
                    XCTAssertEqual(nativeAnchor.height, 20 * zoom, accuracy: 0.01)
                    XCTAssertEqual(controller.nativeViewportViolationCountForProfiling, 0,
                                   controller.nativeViewportViolationDiagnosticsForTesting)
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "fixed-scroll-\(direction.rawValue)-\(requested)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testNativeEditorRendersAtActualZoomWithoutAncestorMagnification() throws {
        let controller = makeController()
        defer { controller.completeDismantle() }
        let pageID = controller.focusedPageIDForTesting
        let paper = controller.paperMarkupControllerForTesting
        let originalBounds = try XCTUnwrap(paper.markup).bounds
        for zoom: CGFloat in [1, 6, 8, 10] {
            controller.setZoomScale(zoom)
            controller.flushNativeViewportUpdatesForTesting()
            let value = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pageID))
            XCTAssertEqual(controller.renderedZoomScaleForTesting, 1)
            XCTAssertTrue(controller.pageHostIsOutsideZoomedDocumentForTesting(pageID: pageID))
            XCTAssertEqual(paper.view.transform, .identity)
            XCTAssertEqual(paper.zoomRange, CanvasConstants.nativeViewportRenderingZoomRange)
            XCTAssertEqual(paper.contentVisibleFrame.width, value.renderPageRect.width, accuracy: 0.05)
            XCTAssertEqual(paper.contentVisibleFrame.minX, value.renderPageRect.minX, accuracy: 0.05)
            if #available(iOS 27.0, *) {
                XCTAssertEqual(paper.scrollConfiguration.zoomScale, zoom, accuracy: 0.001)
            }
            XCTAssertLessThanOrEqual(paper.view.bounds.width, controller.view.bounds.width)
            XCTAssertLessThanOrEqual(paper.view.bounds.height, controller.view.bounds.height)
            XCTAssertEqual(paper.markup?.bounds, originalBounds)
            XCTAssertEqual(controller.isPageRasterizedForTesting(pageID: pageID), false)
        }
        XCTAssertTrue(paper === controller.paperMarkupControllerForTesting)
    }

    func testPendingNavigationFlushesBeforeContactAndZoomDefersUntilLiftOff() throws {
        let controller = makeController()
        defer { controller.completeDismantle() }
        let pageID = controller.focusedPageIDForTesting
        let scroll = controller.outerScrollViewForTesting
        let before = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pageID))
        scroll.contentOffset.x += 90
        controller.scrollViewDidScroll(scroll)
        XCTAssertTrue(controller.hasPendingNativeViewportUpdateForTesting)
        XCTAssertEqual(controller.nativeViewportForTesting(pageID: pageID), before)
        controller.beginContactForTesting()
        XCTAssertFalse(controller.hasPendingNativeViewportUpdateForTesting)
        let writingViewport = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pageID))
        XCTAssertNotEqual(writingViewport.visiblePageRect.minX, before.visiblePageRect.minX)
        XCTAssertFalse(scroll.panGestureRecognizer.isEnabled)
        controller.setZoomScale(10)
        XCTAssertEqual(controller.nativeViewportForTesting(pageID: pageID), writingViewport)
        controller.endContactForTesting()
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertTrue(scroll.panGestureRecognizer.isEnabled)
        XCTAssertEqual(controller.paperMarkupControllerForTesting.zoomRange,
                       CanvasConstants.nativeViewportRenderingZoomRange)
    }

    func testOverlayMappingsAndNativeScrollFeedbackRemainAligned() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = makeController(viewSize: scene.coordinateSpace.bounds.size)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            controller.completeDismantle()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        let pageID = controller.focusedPageIDForTesting
        let point = CGPoint(x: 280, y: 375)
        let frame = try XCTUnwrap(controller.pageFrameForTesting(
            CGRect(origin: point, size: CGSize(width: 10, height: 10)), pageID: pageID
        ))
        let roundTrip = try XCTUnwrap(controller.pagePointForTesting(frame.origin, pageID: pageID))
        XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.001)
        let paper = controller.paperMarkupControllerForTesting
        let visible = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pageID)).renderPageRect
        try await Task.sleep(for: .milliseconds(50))
        controller.flushNativeViewportUpdatesForTesting()
        paper.contentVisibleFrame = visible.offsetBy(dx: 5, dy: 5)
        controller.paperMarkupViewControllerDidChangeContentVisibleFrame(paper)
        try await Task.sleep(for: .milliseconds(50))
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertTrue(controller.nativePaperProjectionMatchesForTesting(pageID: pageID),
            "native PaperKit content projection drifted: \(controller.nativePaperProjectionDiagnosticsForTesting(pageID: pageID))")
        controller.beginContactForTesting()
        paper.contentVisibleFrame = visible.offsetBy(dx: 5, dy: 5)
        controller.paperMarkupViewControllerDidChangeContentVisibleFrame(paper)
        controller.endContactForTesting()
        try await Task.sleep(for: .milliseconds(50))
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertTrue(controller.nativePaperProjectionMatchesForTesting(pageID: pageID),
            "deferred native PaperKit projection drifted: \(controller.nativePaperProjectionDiagnosticsForTesting(pageID: pageID))")
    }

    func testLegacyAndFreeformKeepExistingRendererAndDismantleCancelsPendingFrame() {
        for (mode, documentMode) in [(CanvasPagedRenderingMode.fullPage, CanvasDocumentMode.paged),
                                     (.nativeViewport, .freeform)] {
            let controller = makeController(mode: mode, documentMode: documentMode)
            XCTAssertFalse(controller.usesNativePageViewportsForTesting)
            XCTAssertNil(controller.nativeViewportForTesting(pageID: controller.focusedPageIDForTesting))
            controller.completeDismantle()
        }
        let controller = makeController()
        controller.scrollViewDidScroll(controller.outerScrollViewForTesting)
        XCTAssertTrue(controller.hasPendingNativeViewportUpdateForTesting)
        controller.prepareForDismantle()
        XCTAssertFalse(controller.hasPendingNativeViewportUpdateForTesting)
        controller.scrollViewDidScroll(controller.outerScrollViewForTesting)
        XCTAssertFalse(controller.hasPendingNativeViewportUpdateForTesting)
        controller.completeDismantle()
    }

    func testNativeHostsAreLazyForSmallAndThousandPageNotebooks() {
        let markup = CanvasInkViewportFixture.markup()
        for count in [2, 32, 1_000] {
            let pages = (0..<count).map { _ in CanvasPageSnapshot(markup: markup) }
            let controller = makeNotebook(pages: pages)
            defer { controller.completeDismantle() }
            XCTAssertTrue(controller.virtualizesPageHostsForTesting)
            XCTAssertLessThanOrEqual(controller.mountedPageHostCountForTesting, 3)
            for index in [0, count / 2, count - 1, 0] {
                controller.scrollToPage(id: pages[index].id, animated: false)
                let offsetAfterJump = controller.outerScrollViewForTesting.contentOffset
                let focusAfterJump = controller.focusedPageIDForTesting
                controller.flushNativeViewportUpdatesForTesting()
                XCTAssertEqual(
                    controller.focusedPageIDForTesting,
                    pages[index].id,
                    "focus mismatch at page index \(index); offset=\(controller.outerScrollViewForTesting.contentOffset), " +
                        "contentSize=\(controller.outerScrollViewForTesting.contentSize), " +
                        "inset=\(controller.outerScrollViewForTesting.contentInset), " +
                        "zoom=\(controller.effectiveZoomScaleForTesting), " +
                        "jumpOffset=\(offsetAfterJump), focusAfterJump=\(focusAfterJump), " +
                        "visible=\(controller.visibleDocumentRectForTesting), " +
                        "state=\(controller.navigationDiagnosticsForTesting(pageID: pages[index].id))"
                )
                XCTAssertLessThanOrEqual(controller.mountedPageHostCountForTesting, 3)
                XCTAssertEqual(controller.snapshotActivePage()?.markup, markup)
                for id in controller.renderedPageIDsForTesting {
                    XCTAssertTrue(controller.pageHostIsOutsideZoomedDocumentForTesting(pageID: id))
                    XCTAssertEqual(controller.isPageRasterizedForTesting(pageID: id), false)
                    if controller.nativeViewportForTesting(pageID: id) != nil,
                       let frame = controller.pageHostFrameForTesting(pageID: id) {
                        // A stable renderer can extend past a viewport edge,
                        // but its allocation remains capped at screen size.
                        XCTAssertLessThanOrEqual(frame.width, controller.view.bounds.width + 0.001)
                        XCTAssertLessThanOrEqual(frame.height, controller.view.bounds.height + 0.001)
                    }
                }
            }
        }
    }

    func testSameZoomPageTransitionsKeepA4ProjectionAndViewportClipping() throws {
        let styles: [CanvasPaperStyle] = [.blank, .ruled, .dotted]
        let pages = styles.map { CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup(),
            paperTemplate: CanvasPaperTemplate(style: $0)) }
        let controller = makeNotebook(pages: pages)
        defer { controller.completeDismantle() }
        for zoom: CGFloat in [0.6, 1, 6, 10] {
            controller.setZoomScale(zoom)
            for size in [CGSize(width: 1_180, height: 820), CGSize(width: 820, height: 1_180)] {
                controller.view.frame.size = size
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                for (step, page) in (pages + pages.reversed()).enumerated() {
                    controller.scrollToPage(id: page.id, animated: false)
                    controller.setZoomScale(zoom)
                    controller.updateTopChromeHeight(step.isMultiple(of: 2) ? 140 : 141)
                    controller.flushNativeViewportUpdatesForTesting()
                    let projected = try XCTUnwrap(controller.projectedPageFrameForTesting(pageID: page.id))
                    XCTAssertEqual(projected.width, 595 * zoom, accuracy: 0.05)
                    XCTAssertEqual(projected.height, 842 * zoom, accuracy: 0.05)
                    let viewport = try XCTUnwrap(
                        controller.nativeViewportForTesting(pageID: page.id),
                        "missing viewport at zoom \(zoom), size \(size), step \(step), " +
                            "focus \(controller.focusedPageIDForTesting), " +
                            "offset \(controller.outerScrollViewForTesting.contentOffset), " +
                            "visible \(controller.visibleDocumentRectForTesting), " +
                            "state \(controller.navigationDiagnosticsForTesting(pageID: page.id))"
                    )
                    let expected = projected.intersection(controller.outerScrollViewForTesting.bounds)
                    XCTAssertEqual(viewport.screenFrame.width, expected.width, accuracy: 0.05)
                    XCTAssertEqual(viewport.screenFrame.height, expected.height, accuracy: 0.05)
                    let host = try XCTUnwrap(controller.pageHostFrameForTesting(pageID: page.id))
                    XCTAssertEqual(host.width, min(projected.width, controller.outerScrollViewForTesting.bounds.width), accuracy: 0.05)
                    XCTAssertEqual(host.height, min(projected.height, controller.outerScrollViewForTesting.bounds.height), accuracy: 0.05)
                    XCTAssertEqual(controller.paperTemplateForTesting(pageID: page.id), page.paperTemplate)
                    XCTAssertEqual(controller.snapshotActivePage()?.markup.bounds.size, CanvasConstants.a4PortraitSize)
                }
            }
        }
    }

    func testScrollingLazyPagesKeepsEveryBackgroundAtItsAuthoredPosition() async throws {
        let markup = CanvasInkViewportFixture.markup()
        let pages = (0..<12).map { index in CanvasPageSnapshot(markup: markup,
            paperTemplate: CanvasPaperTemplate(style: index.isMultiple(of: 2) ? .grid : .ruled,
                tone: index.isMultiple(of: 2) ? .cream : .white)) }
        let controller = makeNotebook(pages: pages)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            controller.completeDismantle()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        controller.setZoomScale(0.6)
        let plan = CanvasStackLayout.layoutPlan(pageSizes: pages.map(\.displaySize), pageLayout: .default)
        let scroll = controller.outerScrollViewForTesting
        // No page-layout/zoom refresh between mounts: exercise manual scroll's
        // lazy path, which previously placed viewport-sized backgrounds at zero.
        for index in [1, 3, 7, 10, 5, 2, 0] {
            scroll.contentOffset.y = plan.pageFrame(at: index).minY * 0.6
            controller.scrollViewDidScroll(scroll)
            controller.flushNativeViewportUpdatesForTesting()
            // PaperKit finishes its first attached canvas layout on the next
            // presentation turn. Exercise paced, rendered scrolling rather
            // than seven unpresented controller constructions in one turn.
            try await Task.sleep(for: .milliseconds(50))
            controller.flushNativeViewportUpdatesForTesting()
            for mounted in pages.indices {
                guard let background = controller.paperTemplateDecorationViewForTesting(pageID: pages[mounted].id) else { continue }
                XCTAssertEqual(background.frame, plan.pageFrame(at: mounted))
                XCTAssertEqual(background.template, pages[mounted].paperTemplate)
                let projected = background.convert(background.bounds, to: scroll)
                XCTAssertEqual(projected.width, 595 * 0.6, accuracy: 0.05)
                XCTAssertEqual(projected.height, 842 * 0.6, accuracy: 0.05)
            }
            XCTAssertEqual(controller.nativeViewportViolationCountForProfiling, 0)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "native-scroll-window-page-\(index + 1)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testIdleNativeEditorsReuseWithoutMarkupSelectionOrUndoCrossingPages() async throws {
        var pages: [CanvasPageSnapshot] = []
        pages.reserveCapacity(1_000)
        for index in 0..<1_000 {
            pages.append(autoreleasepool {
                CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup())
            })
            // Present between batches and release image-renderer temporaries;
            // fixture generation must not monopolize the device main thread.
            if index.isMultiple(of: 20) { await Task.yield() }
        }
        let controller = makeNotebook(pages: pages)
        for index in stride(from: 0, to: 1_000, by: 37) {
            controller.scrollToPage(id: pages[index].id, animated: false)
            controller.flushNativeViewportUpdatesForTesting()
            let paper = controller.paperMarkupControllerForTesting
            XCTAssertEqual(paper.markup, pages[index].markup)
            XCTAssertTrue(paper.selectedMarkup.contentsRenderFrame.isNull || paper.selectedMarkup.contentsRenderFrame.isEmpty)
            XCTAssertEqual(paper.undoManager?.canUndo, false)
            XCTAssertLessThanOrEqual(controller.idleNativeControllerCountForTesting, 1)
            XCTAssertLessThanOrEqual(controller.mountedPageHostCountForTesting, 3)
            XCTAssertLessThanOrEqual(controller.mountedPageHostCountForTesting
                + controller.idleNativeControllerCountForTesting, 4)
        }
        XCTAssertGreaterThan(controller.nativeControllerReuseCountForTesting, 0)
        controller.didReceiveMemoryWarning()
        XCTAssertEqual(controller.idleNativeControllerCountForTesting, 0)
        controller.completeDismantle()
        XCTAssertEqual(controller.idleNativeControllerCountForTesting, 0)
    }

    func testPageIndexInvalidationAndUndoSurviveLazyRemounts() {
        let markup = CanvasInkViewportFixture.markup()
        let pages = (0..<32).map { _ in CanvasPageSnapshot(markup: markup) }
        let controller = makeNotebook(pages: pages)
        defer { controller.completeDismantle() }
        let original = pages[0].paperTemplate
        let changed = CanvasPaperTemplate(style: .grid)
        controller.setPaperTemplate(changed, for: pages[0].id)
        controller.scrollToPage(id: pages[31].id, animated: false)
        controller.flushNativeViewportUpdatesForTesting()
        controller.scrollToPage(id: pages[0].id, animated: false)
        controller.flushNativeViewportUpdatesForTesting()
        controller.undo()
        XCTAssertEqual(controller.pageSnapshotsForTesting[0].paperTemplate, original)
        controller.redo()
        XCTAssertEqual(controller.pageSnapshotsForTesting[0].paperTemplate, changed)
        let inserted = CanvasPageSnapshot(markup: markup)
        controller.insertPage(inserted, at: 0, scrollTo: true, animated: false)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.focusedPageIDForTesting, inserted.id)
        controller.scrollToPage(id: pages[31].id, animated: false)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.focusedPageIDForTesting, pages[31].id)
        XCTAssertEqual(controller.snapshotActivePage()?.markup, markup)
    }

    func testCurrentToolPickerInputAndRulerStateReachNewlyMountedEditors() throws {
        let pages = (0..<32).map { _ in CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup()) }
        let controller = makeNotebook(pages: pages)
        defer { controller.completeDismantle() }
        controller.applyInputMode(.pencilAndFinger)
        controller.setRulerActive(true)
        for (index, state) in [CanvasToolState(activeTool: .highlighter),
                               CanvasToolState(activeTool: .eraser, eraserMode: .stroke),
                               CanvasToolState(activeTool: .eraser, eraserMode: .pixel),
                               CanvasToolState(activeTool: .lasso)].enumerated() {
            controller.applyToolState(state)
            controller.scrollToPage(id: pages[4 + index * 6].id, animated: false)
            controller.flushNativeViewportUpdatesForTesting()
            let paper = controller.paperMarkupControllerForTesting
            let expected = try XCTUnwrap(CanvasNativeToolMapper.nativeTool(for: state))
            if let expected = expected as? PKInkingTool {
                XCTAssertEqual(paper.drawingTool as? PKInkingTool, expected)
            } else if let expected = expected as? PKEraserTool {
                XCTAssertEqual(paper.drawingTool as? PKEraserTool, expected)
            } else {
                XCTAssertTrue(paper.drawingTool is PKLassoTool)
            }
            XCTAssertEqual(paper.directTouchMode, .drawing)
            XCTAssertTrue(paper.isRulerActive)
        }
    }

    func testFocusedNativeRulerGetsCanvasMarginsOutsideThePaper() throws {
        let controller = makeController(viewSize: CGSize(width: 768, height: 1_024))
        defer { controller.completeDismantle() }
        let pageID = controller.focusedPageIDForTesting
        controller.setZoomScale(0.5)
        controller.flushNativeViewportUpdatesForTesting()
        controller.setRulerActive(true)
        controller.flushNativeViewportUpdatesForTesting()

        let viewport = try XCTUnwrap(controller.nativeViewportForTesting(pageID: pageID))
        let paper = try XCTUnwrap(controller.nativePaperControllerForTesting(pageID: pageID))
        let authoredBounds = try XCTUnwrap(paper.markup).bounds
        XCTAssertEqual(viewport.renderScreenFrame, controller.outerScrollViewForTesting.bounds)
        XCTAssertLessThan(viewport.renderPageRect.minX, authoredBounds.minX)
        XCTAssertGreaterThan(viewport.renderPageRect.maxX, authoredBounds.maxX)
        XCTAssertTrue(paper.isRulerActive)
        let projectedPage = try XCTUnwrap(controller.projectedPageFrameForTesting(pageID: pageID))
        let expectedPageFrame = controller.outerScrollViewForTesting.convert(
            projectedPage, to: controller.view
        )
        let actualPageFrame = try XCTUnwrap(controller.nativeContentFrameForTesting(
            authoredBounds, pageID: pageID
        ))
        XCTAssertEqual(actualPageFrame.minX, expectedPageFrame.minX, accuracy: 0.5,
                       controller.nativePaperProjectionDiagnosticsForTesting(pageID: pageID))
        XCTAssertEqual(actualPageFrame.minY, expectedPageFrame.minY, accuracy: 0.5,
                       controller.nativePaperProjectionDiagnosticsForTesting(pageID: pageID))
        XCTAssertEqual(actualPageFrame.width, expectedPageFrame.width, accuracy: 0.5)
        XCTAssertEqual(actualPageFrame.height, expectedPageFrame.height, accuracy: 0.5)
    }

    func testNativeRulerRemainsOnTheFocusedPageAcrossNavigationAndRotation() throws {
        let pages = (0..<4).map { _ in CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup()) }
        let controller = makeNotebook(pages: pages)
        defer { controller.completeDismantle() }

        controller.setRulerActive(true)
        controller.scrollToPage(id: pages[2].id, animated: false)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertEqual(controller.rulerActivePageIDsForTesting, [pages[2].id])
        XCTAssertTrue(controller.nativeRulerHostIsFrontmostForTesting)
        let destinationViewport = try XCTUnwrap(
            controller.nativeViewportForTesting(pageID: pages[2].id)
        )
        XCTAssertTrue(destinationViewport.expandsToViewport,
                      "The destination PaperKit controller must have its screen-sized ruler viewport before activation.")
        XCTAssertTrue(controller.nativePaperProjectionMatchesForTesting(pageID: pages[2].id),
                      controller.nativePaperProjectionDiagnosticsForTesting(pageID: pages[2].id))

        controller.view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.flushNativeViewportUpdatesForTesting()

        XCTAssertEqual(controller.focusedPageIDForTesting, pages[2].id)
        XCTAssertEqual(controller.rulerActivePageIDsForTesting, [pages[2].id])
        let paper = try XCTUnwrap(controller.nativePaperControllerForTesting(pageID: pages[2].id))
        XCTAssertTrue(paper.isRulerActive)
        XCTAssertTrue(controller.nativeRulerHostIsFrontmostForTesting)
        let rotatedViewport = try XCTUnwrap(
            controller.nativeViewportForTesting(pageID: pages[2].id)
        )
        XCTAssertTrue(rotatedViewport.expandsToViewport,
                      "Rotation must keep ruler margins attached to the screen-sized PaperKit viewport.")
        XCTAssertTrue(controller.nativePaperProjectionMatchesForTesting(pageID: pages[2].id),
                      controller.nativePaperProjectionDiagnosticsForTesting(pageID: pages[2].id))

        controller.setRulerActive(false)
        controller.flushNativeViewportUpdatesForTesting()
        XCTAssertTrue(controller.rulerActivePageIDsForTesting.isEmpty)
    }

    func testRotationAndHorizontalPagingKeepViewportBoundedAndAligned() throws {
        let pages = (0..<8).map { _ in CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup()) }
        let controller = makeNotebook(pages: pages)
        defer { controller.completeDismantle() }
        for direction in [CanvasScrollDirection.vertical, .horizontal] {
            controller.setPageLayout(CanvasPageLayoutPreferences(scrollDirection: direction))
            for size in [CGSize(width: 1_024, height: 768), CGSize(width: 768, height: 1_024)] {
                controller.view.frame.size = size
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                controller.scrollToPage(id: pages[4].id, animated: false)
                controller.setZoomScale(10)
                controller.flushNativeViewportUpdatesForTesting()
                let id = controller.focusedPageIDForTesting
                let viewport = try XCTUnwrap(controller.nativeViewportForTesting(pageID: id))
                XCTAssertLessThanOrEqual(viewport.screenFrame.width, size.width)
                XCTAssertLessThanOrEqual(viewport.screenFrame.height, size.height)
                let point = CGPoint(x: 280, y: 375)
                let frame = try XCTUnwrap(controller.pageFrameForTesting(CGRect(origin: point,
                    size: CGSize(width: 1, height: 1)), pageID: id))
                let result = try XCTUnwrap(controller.pagePointForTesting(frame.origin, pageID: id))
                XCTAssertEqual(result.x, point.x, accuracy: 0.001)
                XCTAssertEqual(result.y, point.y, accuracy: 0.001)
            }
        }
    }

    func testMixedContentExportPreservesFullPageDespiteCroppedViewport() async throws {
        let controller = makeController()
        defer { controller.completeDismantle() }
        controller.setZoomScale(10)
        controller.flushNativeViewportUpdatesForTesting()
        let snapshot = try XCTUnwrap(controller.snapshotActivePage())
        let page = CanvasPageSnapshot(markup: snapshot.markup)
        let artifact = try await CanvasDocumentExporter.shared.export(
            pages: [CanvasExportPage(sourcePageNumber: 1, snapshot: page)], format: .pdf)
        defer { artifact.removeTemporaryFiles() }
        let pdf = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(artifact.urls.first)))
        XCTAssertEqual(pdf.pageCount, 1)
        let exported = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(exported.bounds(for: .mediaBox).size, snapshot.markup.bounds.size)
        XCTAssertTrue(exported.string?.contains("Thin ink") == true)
    }

    func testPencilTransitionsWithRestingFingerAndCancellation() {
        var state = CanvasContactState<Int>()
        XCTAssertTrue(state.begin([(1, false)]).began)
        let pencilDown = state.begin([(2, true)])
        XCTAssertFalse(pencilDown.began)
        XCTAssertTrue(pencilDown.pencilBegan)
        let pencilUp = state.end([2])
        XCTAssertTrue(pencilUp.pencilEnded)
        XCTAssertFalse(pencilUp.ended)
        XCTAssertTrue(state.hasContact)
        XCTAssertFalse(state.hasPencil)
        XCTAssertTrue(state.reset().ended)
        XCTAssertFalse(state.reset().ended)
        XCTAssertTrue(state.begin([(3, true), (4, false)]).pencilBegan)
        let cancelled = state.reset()
        XCTAssertTrue(cancelled.ended)
        XCTAssertTrue(cancelled.pencilEnded)
        XCTAssertFalse(state.end([3, 4]).ended)
    }

    func testIndexedLayoutMatchesFullScanForUnequalPagesAndSpreads() {
        var sizes: [CGSize] = []
        for index in 0..<1_001 {
            let width = CGFloat(300 + (index % 7) * 80)
            let height = CGFloat(400 + (index % 11) * 90)
            sizes.append(CGSize(width: width, height: height))
        }
        for direction in [CanvasScrollDirection.vertical, .horizontal] {
            for mode in [CanvasPageDisplayMode.singlePage, .twoPage] {
                let layout = CanvasPageLayoutPreferences(scrollDirection: direction, pageDisplayMode: mode)
                let plan = CanvasStackLayout.layoutPlan(pageSizes: sizes, pageLayout: layout,
                                                        horizontalPageStride: 1_100)
                for index in stride(from: 0, to: sizes.count, by: 17) {
                    for offset: CGFloat in [-900, 0, 900] {
                        let page = plan.pageFrame(at: index)
                        let rect = CGRect(x: page.midX - 350 + offset, y: page.midY - 450 + offset,
                                          width: 700, height: 900)
                        let expected = plan.pageFrames.indices.filter { plan.pageFrames[$0].intersects(rect) }
                        XCTAssertEqual(plan.visiblePageIndices(visibleDocumentRect: rect), expected)
                        XCTAssertEqual(plan.focusedPageIndex(visibleDocumentRect: rect, preferredPageIndex: index),
                            referenceFocus(plan: plan, rect: rect, preferred: index))
                        XCTAssertLessThan(plan.candidatePageIndices(intersecting: rect).count, 12)
                    }
                }
            }
        }
    }

    func testTiledPaperSnapshotUpdatesDuringBackgroundDrawing() async {
        let source = CanvasPaperTemplateDrawingSource(template: CanvasPaperTemplate(style: .grid),
            pageSize: CGSize(width: 595, height: 842), renderScale: 1)
        let layer = CanvasPaperTemplateTiledLayer(drawingSource: source)
        let store = layer.drawingSourceStoreForTesting
        let worker = Task.detached(priority: .userInitiated) {
            var completed = 0
            for _ in 0..<200 {
                guard let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                    bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                store.draw(in: context)
                if context.makeImage() != nil { completed += 1 }
            }
            return completed
        }
        let styles: [CanvasPaperStyle] = [.grid, .dotted, .music, .cornell, .legal]
        for index in 0..<200 {
            layer.update(drawingSource: CanvasPaperTemplateDrawingSource(
                template: CanvasPaperTemplate(style: styles[index % styles.count]),
                pageSize: CGSize(width: 595, height: 842), renderScale: 1))
            await Task.yield()
        }
        let completed = await worker.value
        XCTAssertEqual(completed, 200)
    }

    private func referenceFocus(plan: CanvasStackLayout.LayoutPlan, rect: CGRect, preferred: Int) -> Int {
        var best = 0
        var area: CGFloat = -1
        var distance = CGFloat.greatestFiniteMagnitude
        for (index, page) in plan.pageFrames.enumerated() {
            let intersection = page.intersection(rect)
            let nextArea = intersection.isNull || intersection.isEmpty ? 0 : intersection.width * intersection.height
            let nextDistance = plan.pageLayout == .default ? abs(page.midY - rect.midY)
                : hypot(page.midX - rect.midX, page.midY - rect.midY)
            if nextArea > area || (abs(nextArea - area) < 0.0001 && nextDistance < distance)
                || (abs(nextArea - area) < 0.0001 && abs(nextDistance - distance) < 0.0001 && index == preferred) {
                best = index
                area = nextArea
                distance = nextDistance
            }
        }
        return best
    }

    private func makeNotebook(pages: [CanvasPageSnapshot]) -> PaperCanvasViewController {
        let controller = PaperCanvasViewController(pages: pages, currentPageID: pages[0].id,
            viewport: .stackViewport(zoomScale: 1, normalizedCenterX: 0.5, normalizedCenterY: 0.5),
            inputMode: .pencilOnly, pagedRenderingMode: .nativeViewport,
            callbacks: PaperCanvasCallbacks(markupChanged: { _, _ in }, interactionBegan: {},
                undoAvailabilityChanged: { _, _ in }, viewportChanged: { _, _ in }))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 768, height: 1_024)
        controller.view.layoutIfNeeded()
        controller.applyToolState(CanvasToolState())
        controller.flushNativeViewportUpdatesForTesting()
        return controller
    }

    private func makeController(mode: CanvasPagedRenderingMode = .nativeViewport,
                                documentMode: CanvasDocumentMode = .paged,
                                viewSize: CGSize = CGSize(width: 768, height: 1_024)) -> PaperCanvasViewController {
        let page = CanvasPageSnapshot(markup: CanvasInkViewportFixture.markup())
        let controller = PaperCanvasViewController(
            pages: [page], currentPageID: page.id,
            viewport: .stackViewport(zoomScale: 6, normalizedCenterX: 0.48, normalizedCenterY: 0.45),
            inputMode: .pencilOnly, documentMode: documentMode, pagedRenderingMode: mode,
            callbacks: PaperCanvasCallbacks(markupChanged: { _, _ in }, interactionBegan: {},
                undoAvailabilityChanged: { _, _ in }, viewportChanged: { _, _ in })
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: viewSize)
        controller.view.layoutIfNeeded()
        controller.applyToolState(CanvasToolState())
        controller.flushNativeViewportUpdatesForTesting()
        return controller
    }
}
