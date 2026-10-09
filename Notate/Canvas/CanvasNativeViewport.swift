import CoreGraphics
import Foundation

/// Notebook navigation and native rendering are independent. The native
/// viewport is always the Release renderer. Debug builds can select the
/// established full-page PaperKit renderer with
/// `NOTATE_NATIVE_PAGED_VIEWPORT=0` for comparison and regression diagnosis.
/// This override never changes saved notebook preferences.
nonisolated enum CanvasPagedRenderingMode: Equatable, Sendable {
    case fullPage
    case nativeViewport

    static var currentBuildAllowsLegacyRenderer: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var configured: Self {
        resolve(
            environmentOverride: ProcessInfo.processInfo.environment[
                "NOTATE_NATIVE_PAGED_VIEWPORT"
            ],
            allowsLegacyRenderer: currentBuildAllowsLegacyRenderer
        )
    }

    static func resolve(environmentOverride: String?, allowsLegacyRenderer: Bool) -> Self {
        guard allowsLegacyRenderer else { return .nativeViewport }
        switch environmentOverride {
        case "0": return .fullPage
        default: return .nativeViewport
        }
    }
}

/// Screen coordinates are in the outer scroll view's coordinate space,
/// including its bounds origin. Local coordinates belong to the unscaled
/// PaperKit host; authored coordinates always belong to the full page.
nonisolated struct CanvasNativeViewport: Equatable, Sendable {
    let pageID: UUID
    let visiblePageRect: CGRect
    let screenFrame: CGRect
    /// The renderer keeps a stable size as a sheet crosses the viewport edge.
    /// Only the outer scroll view clips visibility; PaperKit does not reflow
    /// into a shrinking slice on every navigation frame.
    let renderPageRect: CGRect
    let renderScreenFrame: CGRect
    let logicalZoom: CGFloat
    let expandsToViewport: Bool

    init?(
        pageID: UUID,
        projectedPageFrame: CGRect,
        viewportBounds: CGRect,
        logicalZoom: CGFloat,
        expandsToViewport: Bool = false
    ) {
        guard logicalZoom.isFinite, logicalZoom > 0,
              Self.isValid(projectedPageFrame), Self.isValid(viewportBounds) else { return nil }
        let intersection = projectedPageFrame.intersection(viewportBounds)
        guard Self.isValid(intersection) else { return nil }
        let visible = CGRect(
            x: (intersection.minX - projectedPageFrame.minX) / logicalZoom,
            y: (intersection.minY - projectedPageFrame.minY) / logicalZoom,
            width: intersection.width / logicalZoom,
            height: intersection.height / logicalZoom
        )
        let pageSize = CGSize(width: projectedPageFrame.width / logicalZoom,
                              height: projectedPageFrame.height / logicalZoom)
        let renderSize = CGSize(width: (expandsToViewport ? viewportBounds.width : min(projectedPageFrame.width, viewportBounds.width)) / logicalZoom,
                                height: (expandsToViewport ? viewportBounds.height : min(projectedPageFrame.height, viewportBounds.height)) / logicalZoom)
        let renderRect: CGRect
        if expandsToViewport {
            // PaperKit receives a canvas-sized viewport while the authored
            // page remains in its original coordinate space. Negative or
            // beyond-page visible coordinates are intentional margins for
            // the native ruler and selection controls.
            renderRect = CGRect(
                x: (viewportBounds.minX - projectedPageFrame.minX) / logicalZoom,
                y: (viewportBounds.minY - projectedPageFrame.minY) / logicalZoom,
                width: renderSize.width,
                height: renderSize.height
            )
        } else {
            renderRect = CGRect(
                x: min(max(visible.midX - renderSize.width / 2, 0), pageSize.width - renderSize.width),
                y: min(max(visible.midY - renderSize.height / 2, 0), pageSize.height - renderSize.height),
                width: renderSize.width,
                height: renderSize.height
            )
        }
        guard Self.isValid(visible), Self.isValid(renderRect) else { return nil }
        self.pageID = pageID
        self.screenFrame = intersection
        self.logicalZoom = logicalZoom
        self.visiblePageRect = visible
        self.renderPageRect = renderRect
        self.expandsToViewport = expandsToViewport
        self.renderScreenFrame = expandsToViewport ? viewportBounds : CGRect(
            x: projectedPageFrame.minX + renderRect.minX * logicalZoom,
            y: projectedPageFrame.minY + renderRect.minY * logicalZoom,
            width: renderSize.width * logicalZoom, height: renderSize.height * logicalZoom)
    }

    var pageToLocalTransform: CGAffineTransform {
        CGAffineTransform(a: logicalZoom, b: 0, c: 0, d: logicalZoom,
                          tx: -renderPageRect.minX * logicalZoom,
                          ty: -renderPageRect.minY * logicalZoom)
    }

    func pagePoint(fromLocal point: CGPoint) -> CGPoint {
        point.applying(pageToLocalTransform.inverted())
    }

    func localPoint(fromPage point: CGPoint) -> CGPoint {
        point.applying(pageToLocalTransform)
    }

    func localRect(fromPage rect: CGRect) -> CGRect {
        rect.applying(pageToLocalTransform)
    }

    /// Visibility intersections can differ briefly while UIKit is moving the
    /// outer scroll view between coalesced viewport transactions. That does
    /// not mean PaperKit's current content projection is stale. Compare only
    /// the geometry that controls the actual PaperKit surface and screen frame.
    func hasSameRenderingProjection(as other: Self, tolerance: CGFloat = 0.01) -> Bool {
        pageID == other.pageID
            && abs(renderPageRect.minX - other.renderPageRect.minX) <= tolerance
            && abs(renderPageRect.minY - other.renderPageRect.minY) <= tolerance
            && abs(renderPageRect.width - other.renderPageRect.width) <= tolerance
            && abs(renderPageRect.height - other.renderPageRect.height) <= tolerance
            && abs(renderScreenFrame.minX - other.renderScreenFrame.minX) <= tolerance
            && abs(renderScreenFrame.minY - other.renderScreenFrame.minY) <= tolerance
            && abs(renderScreenFrame.width - other.renderScreenFrame.width) <= tolerance
            && abs(renderScreenFrame.height - other.renderScreenFrame.height) <= tolerance
            && abs(logicalZoom - other.logicalZoom) <= 0.0001
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite
            && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
