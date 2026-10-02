import CoreGraphics
import UIKit

/// Bounds the live PaperKit surface independently from the user-facing zoom.
///
/// PaperKit's native zoom determines how many physical pixels it allocates
/// internally. Freeform boards grow without bound so the basis is kept
/// independent of zoom and low enough that a 2x display's live surface
/// stays inside Metal's texture dimension limits. Paged documents are
/// authored at a 1× PaperKit scale and share one scroll view.
///
/// Callers combine this value with UIScrollView's zoomScale separately.
enum CanvasLiveRenderScale {
    /// Roughly 9.4M pixels at the longest square case. PaperKit owns several
    ///  layers, so this is deliberately below the dimensions users can author.
    static let maximumSurfacePixelDimension: CGFloat = 3_072
    static let pressuredSurfacePixelDimension: CGFloat = 2_048

    /// Paged documents normally remain at their authored 1x PaperKit basis.
    ///  Oversized imported pages may still be reduced to stay within this
    ///  bounded live-surface budget.
    static let pagedMaximumSurfacePixelDimension: CGFloat = 2_560
    static let pagedMaximumNativeScale: CGFloat = 1

    /// PaperKit rebuilds its entire tiled hierarchy whenever its native zoom
    ///  changes. Freeform boards can grow to tens of thousands of points, so
    ///  a quantized-mantissa ladder stops excessive rebuilds while keeping the
    ///  basis as close to 1 as geometry allows. The ladder repeats at every
    ///  power-of-two exponent so the list itself stays short.
    ///
    private static let renderScaleMantissas: [CGFloat] = [1, 0.75, 0.5, 0.375]

    private static func quantizedScale(notExceeding upperBound: CGFloat) -> CGFloat {
        guard upperBound.isFinite, upperBound > 0 else { return 0.0001 }
        if upperBound >= 1 { return 1 }

        var exponentScale: CGFloat = 1
        while exponentScale > 0.0001 {
            for mantissa in renderScaleMantissas {
                let candidate = exponentScale * mantissa
                if candidate <= upperBound { return max(candidate, 0.0001) }
            }
            exponentScale *= 0.5
        }
        return 0.0001
    }

    static func nativeScale(
            pageSizes: [CGSize],
            displayScale: CGFloat,
            documentMode: CanvasDocumentMode = .freeform,
            logicalZoomScale: CGFloat = CanvasConstants.defaultZoomScale,
            isUnderMemoryPressure: Bool = false
    ) -> CGFloat {
        let maximumPageDimension = pageSizes.reduce(CGFloat.zero) { result, size in
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 0,
                  size.height > 0 else { return result }
            return max(result, size.width, size.height)
        }
        guard maximumPageDimension > 0 else { return CanvasConstants.defaultZoomScale }

        let resolvedDisplayScale = displayScale.isFinite && displayScale > 0
            ? displayScale
            : 1
        let pixelBudget: CGFloat
        if isUnderMemoryPressure {
            pixelBudget = pressuredSurfacePixelDimension
        } else {
            pixelBudget = documentMode == .paged
                ? pagedMaximumSurfacePixelDimension
                : maximumSurfacePixelDimension
        }
        let geometryLimitedScale = pixelBudget
            / (maximumPageDimension * resolvedDisplayScale)
        guard geometryLimitedScale.isFinite, geometryLimitedScale > 0 else {
            return 0.0001
        }
        switch documentMode {
        case .freeform:
            // Freeform expansion may produce a board tens of thousands of
            // points wide. Keep its basis independent of zoom so repeated
            // settles cannot rebuild a correspondingly huge PaperKit host.
            return quantizedScale(
                notExceeding: min(CanvasConstants.defaultZoomScale, geometryLimitedScale)
            )
        case .paged:
            // Keep normal pages at one native PaperKit scale across the whole
            // 50-1000% presentation range. This prevents held-to-shape ink
            // from being re-tessellated when a pinch settles. Only geometry or
            // memory pressure may lower the basis for an oversized page.
            return quantizedScale(
                notExceeding: min(
                    geometryLimitedScale,
                    pagedMaximumNativeScale
                )
            )
        }
    }
}

/// Pure geometry for a continuous vertical notebook or a horizontally paged
/// notebook. Horizontal callers can provide a viewport-sized center stride so
/// adjacent sheets read as separate destinations instead of one long board.
///
/// Page coordinates remain authored and unscaled. The stable PaperKit native
/// basis and outer UIScrollView presentation scale combine to translate these
/// logical frames into screen space.
enum CanvasStackLayout {
    typealias VerticalContentOffsetBounds = (minimum: CGFloat, maximum: CGFloat)

    /// One immutable resolution of the complete notebook geometry. Callers
    ///  that perform more than one lookup should retain this value: every page
    ///  frame is then O(1), and focus/visibility scans remain O(N) instead of
    ///  rebuilding the complete geometry once for every page they inspect.
    struct LayoutPlan {
        let pageLayout: CanvasPageLayoutPreferences
        let pageFrames: [CGRect]
        let contentSize: CGSize

        /// A structural operation count used by the 1,000-page regression
        ///  test. A plan resolves exactly one frame per page and subsequent
        ///  lookups never mutate or increase this value.
        let geometryResolutionOperationCount: Int

        fileprivate init(
            pageLayout: CanvasPageLayoutPreferences,
            pageFrames: [CGRect],
            contentSize: CGSize
        ) {
            self.pageLayout = pageLayout
            self.pageFrames = pageFrames
            self.contentSize = contentSize
            geometryResolutionOperationCount = pageFrames.count
        }

        var pageCount: Int { pageFrames.count }

        func pageFrame(at index: Int) -> CGRect {
            guard pageFrames.indices.contains(index) else { return .null }
            return pageFrames[index]
        }

        func presentationFrame(containing pageIndex: Int) -> CGRect {
            let page = pageFrame(at: pageIndex)
            guard pageLayout.pageDisplayMode == .twoPage else { return page }
            let firstIndex = pageIndex - (pageIndex % 2)
            let first = pageFrame(at: firstIndex)
            let second = pageFrame(at: firstIndex + 1)
            guard second.isNull == false else { return first }
            return first.union(second)
        }

        func focusedPageIndex(
                visibleDocumentRect: CGRect,
                preferredPageIndex: Int? = nil
        ) -> Int? {
            guard pageFrames.isEmpty == false,
                  visibleDocumentRect.isNull == false,
                  visibleDocumentRect.isEmpty == false else { return nil }

            var bestIndex = 0
            var bestArea: CGFloat = -1
            var bestCenterDistance = CGFloat.greatestFiniteMagnitude
            for (index, page) in pageFrames.enumerated() {
                let intersection = page.intersection(visibleDocumentRect)
                let area = intersection.isNull || intersection.isEmpty
                    ? 0
                    : intersection.width * intersection.height
                let centerDistance = pageLayout == .default
                    ? abs(page.midY - visibleDocumentRect.midY)
                    : hypot(
                        page.midX - visibleDocumentRect.midX,
                        page.midY - visibleDocumentRect.midY
                    )
                let areasTie = abs(area - bestArea) < 0.0001
                let distancesTie = abs(centerDistance - bestCenterDistance) < 0.0001
                if area > bestArea
                    || (areasTie && centerDistance < bestCenterDistance)
                    || (areasTie && distancesTie && index == preferredPageIndex) {
                    bestIndex = index
                    bestArea = area
                    bestCenterDistance = centerDistance
                }
            }
            return bestIndex
        }

        func visiblePageIndices(
                visibleDocumentRect: CGRect,
                overscanViewports: CGFloat = 0
        ) -> [Int] {
            guard pageFrames.isEmpty == false,
                  visibleDocumentRect.isNull == false,
                  visibleDocumentRect.isEmpty == false else { return [] }
            let overscan = max(overscanViewports, 0)
            let expanded: CGRect
            switch pageLayout.scrollDirection {
            case .vertical:
                expanded = visibleDocumentRect.insetBy(
                    dx: 0,
                    dy: -visibleDocumentRect.height * overscan
                )
            case .horizontal:
                expanded = visibleDocumentRect.insetBy(
                    dx: -visibleDocumentRect.width * overscan,
                    dy: 0
                )
            }
            return pageFrames.indices.filter { pageFrames[$0].intersects(expanded) }
        }
    }

    static func layoutPlan(
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences,
            horizontalPageStride: CGFloat? = nil
    ) -> LayoutPlan {
        resolvedGeometry(
            pageSizes: pageSizes,
            pageLayout: pageLayout,
            horizontalPageStride: horizontalPageStride
        )
    }

    static func pageFrame(at index: Int) -> CGRect {
        guard index >= 0 else { return .null }
        return CGRect(
            x: 0,
            y: CGFloat(index) * (CanvasConstants.a4PortraitSize.height + CanvasConstants.pageGap),
            width: CanvasConstants.a4PortraitSize.width,
            height: CanvasConstants.a4PortraitSize.height
        )
    }

    static func pageFrame(at index: Int, pageSizes: [CGSize]) -> CGRect {
        guard pageSizes.indices.contains(index) else { return .null }
        let validSizes = pageSizes.map(sanitizedPageSize)
        let maximumWidth = validSizes.map(\.width).max() ?? CanvasConstants.a4PortraitSize.width
        let y = validSizes[..<index].reduce(CGFloat.zero) { partial, size in
            partial + size.height + CanvasConstants.pageGap
        }
        let size = validSizes[index]
        return CGRect(
            x: (maximumWidth - size.width) / 2,
            y: y,
            width: size.width,
            height: size.height
        )
    }

    static func contentSize(pageCount: Int) -> CGSize {
        guard pageCount > 0 else { return .zero }
        return CGSize(
            width: CanvasConstants.a4PortraitSize.width,
            height: CGFloat(pageCount) * CanvasConstants.a4PortraitSize.height
                + CGFloat(pageCount - 1) * CanvasConstants.pageGap
        )
    }

    static func contentSize(pageSizes: [CGSize]) -> CGSize {
        guard pageSizes.isEmpty == false else { return .zero }
        let validSizes = pageSizes.map(sanitizedPageSize)
        return CGSize(
            width: validSizes.map(\.width).max() ?? CanvasConstants.a4PortraitSize.width,
            height: validSizes.reduce(CGFloat.zero) { $0 + $1.height }
                + CGFloat(max(validSizes.count - 1, 0)) * CanvasConstants.pageGap
        )
    }

    static func pageFrame(
            at index: Int,
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences
    ) -> CGRect {
        return resolvedGeometry(
            pageSizes: pageSizes,
            pageLayout: pageLayout
        ).pageFrame(at: index)
    }

    static func contentSize(
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences
    ) -> CGSize {
        return resolvedGeometry(pageSizes: pageSizes, pageLayout: pageLayout).contentSize
    }

    /// Resolves every authored page in one pass. A horizontal single-page
    ///  stride is optional so pure authored/export geometry remains independent
    ///  from a device viewport. Legacy two-page values remain readable while
    ///  product-facing state is normalized to single-page presentation.
    private static func resolvedGeometry(
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences,
            horizontalPageStride: CGFloat? = nil
    ) -> LayoutPlan {
        guard pageSizes.isEmpty == false else {
            return LayoutPlan(
                pageLayout: pageLayout,
                pageFrames: [],
                contentSize: .zero
            )
        }
        let sizes = pageSizes.map(sanitizedPageSize)
        let gap = CanvasConstants.pageGap

        switch (pageLayout.scrollDirection, pageLayout.pageDisplayMode) {
        case (.vertical, .singlePage):
            // Keep this path byte-for-byte equivalent to the original stack:
            // pages are centered within the widest authored page and their
            // individual heights determine the vertical offsets.
            let maximumWidth = sizes.map(\.width).max()
                ?? CanvasConstants.a4PortraitSize.width
            var y: CGFloat = 0
            var frames: [CGRect] = []
            frames.reserveCapacity(sizes.count)
            for (index, size) in sizes.enumerated() {
                frames.append(
                    CGRect(
                        x: (maximumWidth - size.width) / 2,
                        y: y,
                        width: size.width,
                        height: size.height
                    )
                )
                y += size.height
                if index < sizes.count - 1 { y += gap }
            }
            return LayoutPlan(
                pageLayout: pageLayout,
                pageFrames: frames,
                contentSize: CGSize(width: maximumWidth, height: y)
            )

        case (.horizontal, .singlePage):
            let maximumHeight = sizes.map(\.height).max()
                ?? CanvasConstants.a4PortraitSize.height
            let requestedStride = horizontalPageStride.flatMap { stride in
                stride.isFinite && stride > 0 ? stride : nil
            }
            var frames: [CGRect] = []
            frames.reserveCapacity(sizes.count)
            for size in sizes {
                let x: CGFloat
                if let previous = frames.last {
                    let adjacentStride = previous.width / 2 + gap + size.width / 2
                    x = previous.midX + max(requestedStride ?? adjacentStride, adjacentStride)
                        - size.width / 2
                } else {
                    x = 0
                }
                frames.append(
                    CGRect(
                        x: x,
                        y: (maximumHeight - size.height) / 2,
                        width: size.width,
                        height: size.height
                    )
                )
            }
            return LayoutPlan(
                pageLayout: pageLayout,
                pageFrames: frames,
                contentSize: CGSize(
                    width: frames.last?.maxX ?? 0,
                    height: maximumHeight
                )
            )

        case (.vertical, .twoPage):
            var frames = Array(repeating: CGRect.null, count: sizes.count)
            var y: CGFloat = 0
            var maximumWidth: CGFloat = 0
            let groupCount = (sizes.count + 1) / 2
            for groupIndex in 0..<groupCount {
                let firstIndex = groupIndex * 2
                let firstSize = sizes[firstIndex]
                frames[firstIndex] = CGRect(
                    x: 0,
                    y: y,
                    width: firstSize.width,
                    height: firstSize.height
                )

                var groupWidth = firstSize.width
                var groupHeight = firstSize.height
                let secondIndex = firstIndex + 1
                if sizes.indices.contains(secondIndex) {
                    let secondSize = sizes[secondIndex]
                    frames[secondIndex] = CGRect(
                        x: firstSize.width + gap,
                        y: y,
                        width: secondSize.width,
                        height: secondSize.height
                    )
                    groupWidth += gap + secondSize.width
                    groupHeight = max(groupHeight, secondSize.height)
                }
                maximumWidth = max(maximumWidth, groupWidth)
                y += groupHeight
                if groupIndex < groupCount - 1 { y += gap }
            }
            return LayoutPlan(
                pageLayout: pageLayout,
                pageFrames: frames,
                contentSize: CGSize(width: maximumWidth, height: y)
            )

        case (.horizontal, .twoPage):
            var frames = Array(repeating: CGRect.null, count: sizes.count)
            var x: CGFloat = 0
            var maximumHeight: CGFloat = 0
            let groupCount = (sizes.count + 1) / 2
            for groupIndex in 0..<groupCount {
                let firstIndex = groupIndex * 2
                let firstSize = sizes[firstIndex]
                frames[firstIndex] = CGRect(
                    x: x,
                    y: 0,
                    width: firstSize.width,
                    height: firstSize.height
                )
                var groupWidth = firstSize.width
                var groupHeight = firstSize.height
                let secondIndex = firstIndex + 1
                if sizes.indices.contains(secondIndex) {
                    let secondSize = sizes[secondIndex]
                    frames[secondIndex] = CGRect(
                        x: x + firstSize.width + gap,
                        y: 0,
                        width: secondSize.width,
                        height: secondSize.height
                    )
                    groupWidth += gap + secondSize.width
                    groupHeight = max(groupHeight, secondSize.height)
                }
                maximumHeight = max(maximumHeight, groupHeight)
                x += groupWidth
                if groupIndex < groupCount - 1 { x += gap }
            }
            return LayoutPlan(
                pageLayout: pageLayout,
                pageFrames: frames,
                contentSize: CGSize(width: x, height: maximumHeight)
            )
        }
    }

    static func topClearance(
        safeAreaInsets: UIEdgeInsets,
        topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> CGFloat {
        safeAreaInsets.top
            + max(topChromeHeight, 0)
            + CanvasConstants.firstPageToolbarGap
    }

    /// Insets are expressed in screen points. In particular, the first-page
    ///  clearance must not shrink at 50% or grow at 1000%.
    static func contentInset(
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            contentWidth: CGFloat = CanvasConstants.a4PortraitSize.width,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> UIEdgeInsets {
        let resolvedScale = max(zoomScale, 0.0001)
        let availableWidth = max(
            viewportSize.width - safeAreaInsets.left - safeAreaInsets.right,
            0
        )
        let scaledPageWidth = max(contentWidth, 1) * resolvedScale
        let horizontalCentering = max((availableWidth - scaledPageWidth) / 2, 0)
        return UIEdgeInsets(
            top: topClearance(safeAreaInsets: safeAreaInsets, topChromeHeight: topChromeHeight),
            left: safeAreaInsets.left + horizontalCentering,
            bottom: safeAreaInsets.bottom + CanvasConstants.pageGap,
            right: safeAreaInsets.right + horizontalCentering
        )
    }

    static func contentInset(
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            contentSize: CGSize,
            pageSizes: [CGSize] = [],
            pageLayout: CanvasPageLayoutPreferences,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> UIEdgeInsets {
        guard pageLayout.scrollDirection == .horizontal else {
            return contentInset(
                viewportSize: viewportSize,
                safeAreaInsets: safeAreaInsets,
                zoomScale: zoomScale,
                contentWidth: contentSize.width,
                topChromeHeight: topChromeHeight
            )
        }

        let resolvedScale = max(zoomScale, 0.0001)
        let top = topClearance(safeAreaInsets: safeAreaInsets, topChromeHeight: topChromeHeight)
        let availableHeight = max(
            viewportSize.height - top - safeAreaInsets.bottom,
            0
        )
        let scaledContentHeight = max(contentSize.height, 1) * resolvedScale
        let verticalCentering = max(
            (availableHeight - scaledContentHeight) / 2,
            0
        )
        let availableWidth = max(
            viewportSize.width - safeAreaInsets.left - safeAreaInsets.right,
            0
        )
        let plan = pageSizes.isEmpty
            ? nil
            : layoutPlan(pageSizes: pageSizes, pageLayout: pageLayout)
        let firstPresentationWidth = plan?.presentationFrame(containing: 0).width
            ?? contentSize.width
        let lastPresentationWidth = plan?.presentationFrame(
            containing: pageSizes.count - 1
        ).width ?? contentSize.width
        let leadingCentering = max(
            (availableWidth - max(firstPresentationWidth, 1) * resolvedScale) / 2,
            0
        )
        let trailingCentering = max(
            (availableWidth - max(lastPresentationWidth, 1) * resolvedScale) / 2,
            0
        )
        return UIEdgeInsets(
            top: top + verticalCentering,
            left: safeAreaInsets.left + leadingCentering,
            bottom: safeAreaInsets.bottom + verticalCentering,
            right: safeAreaInsets.right + trailingCentering
        )
    }

    static func contentInset(
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            layoutPlan: LayoutPlan,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> UIEdgeInsets {
        guard layoutPlan.pageLayout.scrollDirection == .horizontal else {
            return contentInset(
                viewportSize: viewportSize,
                safeAreaInsets: safeAreaInsets,
                zoomScale: zoomScale,
                contentWidth: layoutPlan.contentSize.width,
                topChromeHeight: topChromeHeight
            )
        }

        let resolvedScale = max(zoomScale, 0.0001)
        let top = topClearance(safeAreaInsets: safeAreaInsets, topChromeHeight: topChromeHeight)
        let availableHeight = max(
            viewportSize.height - top - safeAreaInsets.bottom,
            0
        )
        let scaledContentHeight = max(layoutPlan.contentSize.height, 1) * resolvedScale
        let verticalCentering = max((availableHeight - scaledContentHeight) / 2, 0)
        let availableWidth = max(
            viewportSize.width - safeAreaInsets.left - safeAreaInsets.right,
            0
        )
        let firstWidth = layoutPlan.presentationFrame(containing: 0).width
        let lastWidth = layoutPlan.presentationFrame(
            containing: layoutPlan.pageCount - 1
        ).width
        let leadingCentering = max(
            (availableWidth - max(firstWidth, 1) * resolvedScale) / 2,
            0
        )
        let trailingCentering = max(
            (availableWidth - max(lastWidth, 1) * resolvedScale) / 2,
            0
        )
        return UIEdgeInsets(
            top: top + verticalCentering,
            left: safeAreaInsets.left + leadingCentering,
            bottom: safeAreaInsets.bottom + verticalCentering,
            right: safeAreaInsets.right + trailingCentering
        )
    }

    static func unobscuredViewportRect(
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> CGRect {
        let top = topClearance(safeAreaInsets: safeAreaInsets, topChromeHeight: topChromeHeight)
        return CGRect(
            x: safeAreaInsets.left,
            y: top,
            width: max(viewportSize.width - safeAreaInsets.left - safeAreaInsets.right, 0),
            height: max(viewportSize.height - top - safeAreaInsets.bottom, 0)
        )
    }

    static func visibleDocumentRect(
            contentOffset: CGPoint,
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> CGRect {
        let scale = max(zoomScale, 0.0001)
        let viewport = unobscuredViewportRect(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            topChromeHeight: topChromeHeight
        )
        return CGRect(
            x: (contentOffset.x + viewport.minX) / scale,
            y: (contentOffset.y + viewport.minY) / scale,
            width: viewport.width / scale,
            height: viewport.height / scale
        )
    }

    static func focusedPageIndex(
            visibleDocumentRect: CGRect,
            pageCount: Int
    ) -> Int? {
        guard pageCount > 0,
              visibleDocumentRect.isNull == false,
              visibleDocumentRect.isEmpty == false else { return nil }

        var bestIndex = 0
        var bestArea: CGFloat = -1
        var bestCenterDistance = CGFloat.greatestFiniteMagnitude
        for index in 0..<pageCount {
            let page = pageFrame(at: index)
            let intersection = page.intersection(visibleDocumentRect)
            let area = intersection.isNull || intersection.isEmpty
                ? 0
                : intersection.width * intersection.height
            let centerDistance = abs(page.midY - visibleDocumentRect.midY)
            if area > bestArea
                || (abs(area - bestArea) < 0.0001 && centerDistance < bestCenterDistance) {
                bestIndex = index
                bestArea = area
                bestCenterDistance = centerDistance
            }
        }
        return bestIndex
    }

    static func focusedPageIndex(
            visibleDocumentRect: CGRect,
            pageSizes: [CGSize]
    ) -> Int? {
        layoutPlan(
            pageSizes: pageSizes,
            pageLayout: .default
        ).focusedPageIndex(visibleDocumentRect: visibleDocumentRect)
    }

    static func focusedPageIndex(
            visibleDocumentRect: CGRect,
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences,
            preferredPageIndex: Int? = nil
    ) -> Int? {
        layoutPlan(
            pageSizes: pageSizes,
            pageLayout: pageLayout
        ).focusedPageIndex(
            visibleDocumentRect: visibleDocumentRect,
            preferredPageIndex: preferredPageIndex
        )
    }

    static func visiblePageIndices(
            visibleDocumentRect: CGRect,
            pageCount: Int,
            overscanViewports: CGFloat = 1
    ) -> Range<Int> {
        guard pageCount > 0,
              visibleDocumentRect.isNull == false,
              visibleDocumentRect.isEmpty == false,
              visibleDocumentRect.minY.isFinite,
              visibleDocumentRect.maxY.isFinite,
              visibleDocumentRect.height.isFinite,
              overscanViewports.isFinite else { return 0..<0 }
        let overscan = max(overscanViewports, 0) * visibleDocumentRect.height
        guard overscan.isFinite else { return 0..<0 }
        let expanded = visibleDocumentRect.insetBy(dx: 0, dy: -overscan)
        let extent = CanvasConstants.a4PortraitSize.height + CanvasConstants.pageGap
        let rawFirst = floor(expanded.minY / extent)
        let rawLast = floor(expanded.maxY / extent)
        guard rawFirst.isFinite,
              rawLast.isFinite,
              rawFirst >= CGFloat(Int.min),
              rawFirst < CGFloat(Int.max),
              rawLast >= CGFloat(Int.min),
              rawLast < CGFloat(Int.max) else { return 0..<0 }
        let first = max(Int(rawFirst), 0)
        let last = min(Int(rawLast), pageCount - 1)
        guard first <= last else { return 0..<0 }
        return first..<(last + 1)
    }

    static func visiblePageIndices(
            visibleDocumentRect: CGRect,
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences,
            overscanViewports: CGFloat = 0
    ) -> [Int] {
        layoutPlan(
            pageSizes: pageSizes,
            pageLayout: pageLayout
        ).visiblePageIndices(
            visibleDocumentRect: visibleDocumentRect,
            overscanViewports: overscanViewports
        )
    }

    static func primaryAxisDistance(
            from pageFrame: CGRect,
            to visibleDocumentRect: CGRect,
            pageLayout: CanvasPageLayoutPreferences
    ) -> CGFloat {
        switch pageLayout.scrollDirection {
        case .vertical:
            abs(pageFrame.midY - visibleDocumentRect.midY)
        case .horizontal:
            abs(pageFrame.midX - visibleDocumentRect.midX)
        }
    }

    static func viewportState(
            focusedPageIndex: Int,
            visibleDocumentRect: CGRect,
            zoomScale: CGFloat
    ) -> CanvasViewportState {
        let page = pageFrame(at: focusedPageIndex)
        guard page.isNull == false else { return CanvasViewportState() }
        return .stackViewport(
            zoomScale: zoomScale,
            normalizedCenterX: (visibleDocumentRect.midX - page.minX) / page.width,
            normalizedCenterY: (visibleDocumentRect.midY - page.minY) / page.height
        )
    }

    static func viewportState(
            focusedPageIndex: Int,
            visibleDocumentRect: CGRect,
            zoomScale: CGFloat,
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences
    ) -> CanvasViewportState {
        viewportState(
            focusedPageIndex: focusedPageIndex,
            visibleDocumentRect: visibleDocumentRect,
            zoomScale: zoomScale,
            layoutPlan: layoutPlan(
                pageSizes: pageSizes,
                pageLayout: pageLayout
            )
        )
    }

    static func viewportState(
            focusedPageIndex: Int,
            visibleDocumentRect: CGRect,
            zoomScale: CGFloat,
            layoutPlan: LayoutPlan
    ) -> CanvasViewportState {
        let page = layoutPlan.pageFrame(at: focusedPageIndex)
        guard page.isNull == false else { return CanvasViewportState() }
        return .stackViewport(
            zoomScale: zoomScale,
            normalizedCenterX: (visibleDocumentRect.midX - page.minX) / page.width,
            normalizedCenterY: (visibleDocumentRect.midY - page.minY) / page.height
        )
    }

    static func viewportState(
            focusedPageIndex: Int,
            visibleDocumentRect: CGRect,
            zoomScale: CGFloat,
            pageSizes: [CGSize]
    ) -> CanvasViewportState {
        let page = pageFrame(at: focusedPageIndex, pageSizes: pageSizes)
        guard page.isNull == false else { return CanvasViewportState() }
        return .stackViewport(
            zoomScale: zoomScale,
            normalizedCenterX: (visibleDocumentRect.midX - page.minX) / page.width,
            normalizedCenterY: (visibleDocumentRect.midY - page.minY) / page.height
        )
    }

    static func targetContentOffset(
            pageIndex: Int,
            viewport: CanvasViewportState,
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            pageCount: Int,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> CGPoint {
        let page = pageFrame(at: pageIndex)
        let unobscured = unobscuredViewportRect(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            topChromeHeight: topChromeHeight
        )
        let insets = contentInset(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            zoomScale: zoomScale,
            topChromeHeight: topChromeHeight
        )

        let proposed: CGPoint
        if viewport.usesFitPage {
            proposed = CGPoint(
                x: page.midX * zoomScale - unobscured.midX,
                y: page.minY * zoomScale - unobscured.minY
            )
        } else {
            let target = CGPoint(
                x: page.minX + CGFloat(viewport.normalizedCenterX) * page.width,
                y: page.minY + CGFloat(viewport.normalizedCenterY) * page.height
            )
            proposed = CGPoint(
                x: target.x * zoomScale - unobscured.midX,
                y: target.y * zoomScale - unobscured.midY
            )
        }
        return clampedContentOffset(
            proposed,
            viewportSize: viewportSize,
            contentSize: contentSize(pageCount: pageCount),
            contentInset: insets,
            zoomScale: zoomScale
        )
    }

    static func targetContentOffset(
            pageIndex: Int,
            viewport: CanvasViewportState,
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> CGPoint {
        targetContentOffset(
            pageIndex: pageIndex,
            viewport: viewport,
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            zoomScale: zoomScale,
            layoutPlan: layoutPlan(
                pageSizes: pageSizes,
                pageLayout: pageLayout
            ),
            topChromeHeight: topChromeHeight
        )
    }

    static func targetContentOffset(
            pageIndex: Int,
            viewport: CanvasViewportState,
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            layoutPlan: LayoutPlan,
            topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    ) -> CGPoint {
        let page = layoutPlan.pageFrame(at: pageIndex)
        guard page.isNull == false else { return .zero }
        let unobscured = unobscuredViewportRect(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            topChromeHeight: topChromeHeight
        )
        let insets = contentInset(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            zoomScale: zoomScale,
            layoutPlan: layoutPlan,
            topChromeHeight: topChromeHeight
        )

        let proposed: CGPoint
        if viewport.usesFitPage {
            let presentationFrame = layoutPlan.presentationFrame(containing: pageIndex)
            switch layoutPlan.pageLayout.scrollDirection {
            case .vertical:
                proposed = CGPoint(
                    x: presentationFrame.midX * zoomScale - unobscured.midX,
                    y: presentationFrame.minY * zoomScale - unobscured.minY
                )
            case .horizontal:
                proposed = CGPoint(
                    x: presentationFrame.midX * zoomScale - unobscured.midX,
                    y: presentationFrame.midY * zoomScale - unobscured.midY
                )
            }
        } else {
            var target = CGPoint(
                x: page.minX + CGFloat(viewport.normalizedCenterX) * page.width,
                y: page.minY + CGFloat(viewport.normalizedCenterY) * page.height
            )
            if layoutPlan.pageLayout.pageDisplayMode == .twoPage {
                let spread = layoutPlan.presentationFrame(containing: pageIndex)
                // Keep the persisted viewport page-relative for backward
                // compatibility. When the whole spread fits, its horizontal
                // midpoint is the unambiguous runtime presentation anchor;
                // this also repairs legacy left=1/right=0 clamping without a
                // schema reinterpretation.
                if spread.width * zoomScale <= unobscured.width + 0.5 {
                    target.x = spread.midX
                }
            }
            proposed = CGPoint(
                x: target.x * zoomScale - unobscured.midX,
                y: target.y * zoomScale - unobscured.midY
            )
        }
        return clampedContentOffset(
            proposed,
            viewportSize: viewportSize,
            contentSize: layoutPlan.contentSize,
            contentInset: insets,
            zoomScale: zoomScale
        )
    }

    /// Resolves UIKit's projected horizontal destination to one stable page or
    /// spread. High-zoom content deliberately opts out so a release never
    /// recenters an authored region the user was panning within.
    static func horizontalPageSnapTarget(
            proposedContentOffset: CGPoint,
            currentPageIndex: Int,
            horizontalVelocity: CGFloat,
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            pageSizes: [CGSize],
            pageLayout: CanvasPageLayoutPreferences
    ) -> CGPoint? {
        horizontalPageSnapTarget(
            proposedContentOffset: proposedContentOffset,
            currentPageIndex: currentPageIndex,
            horizontalVelocity: horizontalVelocity,
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            zoomScale: zoomScale,
            layoutPlan: layoutPlan(
                pageSizes: pageSizes,
                pageLayout: pageLayout
            )
        )
    }

    static func horizontalPageSnapTarget(
            proposedContentOffset: CGPoint,
            currentPageIndex: Int,
            horizontalVelocity: CGFloat,
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            layoutPlan: LayoutPlan
    ) -> CGPoint? {
        guard layoutPlan.pageLayout.scrollDirection == .horizontal,
              layoutPlan.pageFrames.indices.contains(currentPageIndex),
              layoutPlan.pageCount > 0,
              zoomScale.isFinite,
              zoomScale > 0 else { return nil }

        let unobscured = unobscuredViewportRect(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets
        )
        guard unobscured.width > 0 else { return nil }

        let pagesPerGroup = layoutPlan.pageLayout.pageDisplayMode == .twoPage ? 2 : 1
        let groupCount = (layoutPlan.pageCount + pagesPerGroup - 1) / pagesPerGroup
        let currentGroup = currentPageIndex / pagesPerGroup
        let currentFrame = layoutPlan.presentationFrame(containing: currentPageIndex)
        guard currentFrame.isNull == false,
              currentFrame.width * zoomScale <= unobscured.width + 0.5 else {
            return nil
        }

        let projectedDocumentCenter = (
            proposedContentOffset.x + unobscured.midX
        ) / zoomScale
        var nearestGroup = currentGroup
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for group in 0..<groupCount {
            let frame = layoutPlan.presentationFrame(containing: group * pagesPerGroup)
            let distance = abs(frame.midX - projectedDocumentCenter)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestGroup = group
            }
        }

        // UIKit's velocity is normalized for this delegate callback. A clear
        // flick advances one group even when the projected offset remains on
        // the current page, while all gestures remain capped to one group.
        let flickThreshold: CGFloat = 0.25
        let desiredGroup: Int
        if horizontalVelocity >= flickThreshold {
            desiredGroup = currentGroup + 1
        } else if horizontalVelocity <= -flickThreshold {
            desiredGroup = currentGroup - 1
        } else {
            desiredGroup = nearestGroup
        }
        let lowerGroup = max(currentGroup - 1, 0)
        let upperGroup = min(currentGroup + 1, groupCount - 1)
        let targetGroup = min(max(desiredGroup, lowerGroup), upperGroup)
        let targetFrame = layoutPlan.presentationFrame(
            containing: targetGroup * pagesPerGroup
        )
        guard targetFrame.isNull == false,
              targetFrame.width * zoomScale <= unobscured.width + 0.5 else {
            return nil
        }

        let insets = contentInset(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            zoomScale: zoomScale,
            layoutPlan: layoutPlan
        )
        return clampedContentOffset(
            CGPoint(
                x: targetFrame.midX * zoomScale - unobscured.midX,
                y: proposedContentOffset.y
            ),
            viewportSize: viewportSize,
            contentSize: layoutPlan.contentSize,
            contentInset: insets,
            zoomScale: zoomScale
        )
    }

    static func targetContentOffset(
            pageIndex: Int,
            viewport: CanvasViewportState,
            viewportSize: CGSize,
            safeAreaInsets: UIEdgeInsets,
            zoomScale: CGFloat,
            pageSizes: [CGSize]
    ) -> CGPoint {
        let page = pageFrame(at: pageIndex, pageSizes: pageSizes)
        let unobscured = unobscuredViewportRect(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets
        )
        let size = contentSize(pageSizes: pageSizes)
        let insets = contentInset(
            viewportSize: viewportSize,
            safeAreaInsets: safeAreaInsets,
            zoomScale: zoomScale,
            contentWidth: size.width
        )
        let proposed: CGPoint
        if viewport.usesFitPage {
            proposed = CGPoint(
                x: page.midX * zoomScale - unobscured.midX,
                y: page.minY * zoomScale - unobscured.minY
            )
        } else {
            let target = CGPoint(
                x: page.minX + CGFloat(viewport.normalizedCenterX) * page.width,
                y: page.minY + CGFloat(viewport.normalizedCenterY) * page.height
            )
            proposed = CGPoint(
                x: target.x * zoomScale - unobscured.midX,
                y: target.y * zoomScale - unobscured.midY
            )
        }
        return clampedContentOffset(
            proposed,
            viewportSize: viewportSize,
            contentSize: size,
            contentInset: insets,
            zoomScale: zoomScale
        )
    }

    private static func sanitizedPageSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return CanvasConstants.a4PortraitSize
        }
        return size
    }

    static func clampedContentOffset(
            _ proposed: CGPoint,
            viewportSize: CGSize,
            contentSize: CGSize,
            contentInset: UIEdgeInsets,
            zoomScale: CGFloat
    ) -> CGPoint {
        let scaledSize = CGSize(
            width: contentSize.width * zoomScale,
            height: contentSize.height * zoomScale
        )
        let minimumX = -contentInset.left
        let minimumY = -contentInset.top
        let maximumX = max(
            minimumX,
            scaledSize.width - viewportSize.width + contentInset.right
        )
        let maximumY = max(
            minimumY,
            scaledSize.height - viewportSize.height + contentInset.bottom
        )
        return CGPoint(
            x: proposed.x.clamped(to: minimumX...maximumX),
            y: proposed.y.clamped(to: minimumY...maximumY)
        )
    }

    static func boundaryPagePull(
            contentOffset: CGPoint,
            panTranslation: CGPoint,
            viewportSize: CGSize,
            contentSize: CGSize,
            contentInset: UIEdgeInsets,
            zoomScale: CGFloat
    ) -> CanvasBoundaryPagePull? {
        let verticalTranslation = abs(panTranslation.y)
        guard let bounds = verticalContentOffsetBounds(
            viewportSize: viewportSize,
            contentSize: contentSize,
            contentInset: contentInset,
            zoomScale: zoomScale
        ),
              verticalTranslation
            > abs(panTranslation.x) * CanvasConstants.boundaryPullVerticalDominance else {
            return nil
        }

        let boundary: CanvasPageBoundary
        let overscroll: CGFloat
        if panTranslation.y > 0 {
            boundary = .start
            overscroll = bounds.minimum - contentOffset.y
        } else {
            boundary = .end
            overscroll = contentOffset.y - bounds.maximum
        }

        let revealDistance = CanvasConstants.boundaryPullRevealDistance
        guard overscroll > revealDistance else { return nil }
        let progressRange = CanvasConstants.boundaryPullArmDistance - revealDistance
        let progress = (overscroll - revealDistance) / max(progressRange, 1)
        return CanvasBoundaryPagePull(boundary: boundary, progress: progress)
    }

    static func boundaryPagePull(
            contentOffset: CGPoint,
            panTranslation: CGPoint,
            viewportSize: CGSize,
            contentSize: CGSize,
            contentInset: UIEdgeInsets,
            zoomScale: CGFloat,
            pageLayout: CanvasPageLayoutPreferences
    ) -> CanvasBoundaryPagePull? {
        guard pageLayout != .default else {
            return boundaryPagePull(
                contentOffset: contentOffset,
                panTranslation: panTranslation,
                viewportSize: viewportSize,
                contentSize: contentSize,
                contentInset: contentInset,
                zoomScale: zoomScale
            )
        }
        guard let bounds = primaryContentOffsetBounds(
            viewportSize: viewportSize,
            contentSize: contentSize,
            contentInset: contentInset,
            zoomScale: zoomScale,
            direction: pageLayout.scrollDirection
        ) else { return nil }

        let primaryTranslation: CGFloat
        let secondaryTranslation: CGFloat
        let signedTranslation: CGFloat
        let offset: CGFloat
        switch pageLayout.scrollDirection {
        case .vertical:
            primaryTranslation = abs(panTranslation.y)
            secondaryTranslation = abs(panTranslation.x)
            signedTranslation = panTranslation.y
            offset = contentOffset.y
        case .horizontal:
            primaryTranslation = abs(panTranslation.x)
            secondaryTranslation = abs(panTranslation.y)
            signedTranslation = panTranslation.x
            offset = contentOffset.x
        }
        guard primaryTranslation
            > secondaryTranslation * CanvasConstants.boundaryPullVerticalDominance else {
            return nil
        }

        let boundary: CanvasPageBoundary
        let overscroll: CGFloat
        if signedTranslation > 0 {
            boundary = .start
            overscroll = bounds.minimum - offset
        } else {
            boundary = .end
            overscroll = offset - bounds.maximum
        }

        let revealDistance = CanvasConstants.boundaryPullRevealDistance
        guard overscroll > revealDistance else { return nil }
        let progressRange = CanvasConstants.boundaryPullArmDistance - revealDistance
        let progress = (overscroll - revealDistance) / max(progressRange, 1)
        return CanvasBoundaryPagePull(boundary: boundary, progress: progress)
    }

    static func boundaryPagePullEligibleBoundaries(
            contentOffset: CGPoint,
            viewportSize: CGSize,
            contentSize: CGSize,
            contentInset: UIEdgeInsets,
            zoomScale: CGFloat
    ) -> Set<CanvasPageBoundary> {
        guard let bounds = verticalContentOffsetBounds(
            viewportSize: viewportSize,
            contentSize: contentSize,
            contentInset: contentInset,
            zoomScale: zoomScale
        ) else { return [] }

        let slop = CanvasConstants.boundaryPullStartSlop
        var result: Set<CanvasPageBoundary> = []
        if abs(contentOffset.y - bounds.minimum) <= slop {
            result.insert(.start)
        }
        if abs(contentOffset.y - bounds.maximum) <= slop {
            result.insert(.end)
        }
        return result
    }

    static func boundaryPagePullEligibleBoundaries(
            contentOffset: CGPoint,
            viewportSize: CGSize,
            contentSize: CGSize,
            contentInset: UIEdgeInsets,
            zoomScale: CGFloat,
            pageLayout: CanvasPageLayoutPreferences
    ) -> Set<CanvasPageBoundary> {
        guard pageLayout != .default else {
            return boundaryPagePullEligibleBoundaries(
                contentOffset: contentOffset,
                viewportSize: viewportSize,
                contentSize: contentSize,
                contentInset: contentInset,
                zoomScale: zoomScale
            )
        }
        guard let bounds = primaryContentOffsetBounds(
            viewportSize: viewportSize,
            contentSize: contentSize,
            contentInset: contentInset,
            zoomScale: zoomScale,
            direction: pageLayout.scrollDirection
        ) else { return [] }

        let offset = pageLayout.scrollDirection == .vertical
            ? contentOffset.y
            : contentOffset.x
        let slop = CanvasConstants.boundaryPullStartSlop
        var result: Set<CanvasPageBoundary> = []
        if abs(offset - bounds.minimum) <= slop { result.insert(.start) }
        if abs(offset - bounds.maximum) <= slop { result.insert(.end) }
        return result
    }

    private static func primaryContentOffsetBounds(
            viewportSize: CGSize,
            contentSize: CGSize,
            contentInset: UIEdgeInsets,
            zoomScale: CGFloat,
            direction: CanvasScrollDirection
    ) -> VerticalContentOffsetBounds? {
        switch direction {
        case .vertical:
            return verticalContentOffsetBounds(
                viewportSize: viewportSize,
                contentSize: contentSize,
                contentInset: contentInset,
                zoomScale: zoomScale
            )
        case .horizontal:
            guard viewportSize.width > 0,
                  contentSize.width > 0,
                  zoomScale.isFinite,
                  zoomScale > 0 else { return nil }
            let minimum = -contentInset.left
            let scaledWidth = contentSize.width * zoomScale
            let maximum = max(
                minimum,
                scaledWidth - viewportSize.width + contentInset.right
            )
            return (minimum, maximum)
        }
    }

    private static func verticalContentOffsetBounds(
            viewportSize: CGSize,
            contentSize: CGSize,
            contentInset: UIEdgeInsets,
            zoomScale: CGFloat
    ) -> VerticalContentOffsetBounds? {
        guard viewportSize.height > 0,
              contentSize.height > 0,
              zoomScale.isFinite,
              zoomScale > 0 else { return nil }

        let minimum = -contentInset.top
        let scaledHeight = contentSize.height * zoomScale
        let maximum = max(
            minimum,
            scaledHeight - viewportSize.height + contentInset.bottom
        )
        return (minimum, maximum)
    }
}

struct FreeformCanvasExpansion: Equatable, Sendable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    var isEmpty: Bool {
        left <= 0 && right <= 0 && top <= 0 && bottom <= 0
    }

    var contentTranslation: CGPoint {
        CGPoint(x: max(left, 0), y: max(top, 0))
    }

    func expandedSize(from size: CGSize) -> CGSize {
        CGSize(
            width: size.width + max(left, 0) + max(right, 0),
            height: size.height + max(top, 0) + max(bottom, 0)
        )
    }
}

/// Pure geometry for the single-board editor. Expansion inserts storage space
/// outside the visible region, then rebases both content and the viewport by
/// the same translation so the pixels under the user's fingers do not move.
enum FreeformCanvasLayout {
    static func expansion(
            visibleRect: CGRect,
            canvasSize: CGSize,
            zoomScale: CGFloat,
            edgeThreshold: CGFloat = CanvasConstants.freeformEdgeThreshold,
            minimumChunk: CGFloat = CanvasConstants.freeformExpansionChunk,
            maximumDimension: CGFloat = CanvasConstants.maximumPersistedCanvasDimension
    ) -> FreeformCanvasExpansion {
        guard visibleRect.isNull == false,
              visibleRect.isEmpty == false,
              canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0,
              zoomScale.isFinite,
              zoomScale > 0,
              maximumDimension > 0 else { return FreeformCanvasExpansion() }

        let logicalThreshold = max(edgeThreshold, 0) / zoomScale
        let requestedChunk = max(
            minimumChunk,
            visibleRect.width,
            visibleRect.height
        )
        let horizontal = edgeDeltas(
            wantsNegative: visibleRect.minX <= logicalThreshold,
            wantsPositive: visibleRect.maxX >= canvasSize.width - logicalThreshold,
            requestedChunk: requestedChunk,
            available: max(maximumDimension - canvasSize.width, 0)
        )
        let vertical = edgeDeltas(
            wantsNegative: visibleRect.minY <= logicalThreshold,
            wantsPositive: visibleRect.maxY >= canvasSize.height - logicalThreshold,
            requestedChunk: requestedChunk,
            available: max(maximumDimension - canvasSize.height, 0)
        )
        return FreeformCanvasExpansion(
            left: horizontal.negative,
            right: horizontal.positive,
            top: vertical.negative,
            bottom: vertical.positive
        )
    }

    static func translatedViewport(
            _ viewport: CanvasViewportState,
            from oldSize: CGSize,
            expansion: FreeformCanvasExpansion
    ) -> CanvasViewportState {
        let newSize = expansion.expandedSize(from: oldSize)
        guard viewport.isValid,
              oldSize.width > 0,
              oldSize.height > 0,
              newSize.width > 0,
              newSize.height > 0 else { return viewport }

        let translation = expansion.contentTranslation
        let oldCenter = CGPoint(
            x: CGFloat(viewport.normalizedCenterX) * oldSize.width,
            y: CGFloat(viewport.normalizedCenterY) * oldSize.height
        )
        return CanvasViewportState(
            normalizedCenterX: min(
                max(Double((oldCenter.x + translation.x) / newSize.width), 0),
                1
            ),
            normalizedCenterY: min(
                max(Double((oldCenter.y + translation.y) / newSize.height), 0),
                1
            ),
            visibleWidth: viewport.visibleWidth,
            // A rebase must remain centered on the same logical point instead
            // of re-entering the launch-only fit-page behavior.
            usesFitPage: false
        )
    }

    static func translatedContentOffset(
            _ contentOffset: CGPoint,
            expansion: FreeformCanvasExpansion,
            zoomScale: CGFloat
    ) -> CGPoint {
        guard zoomScale.isFinite, zoomScale > 0 else { return contentOffset }
        let translation = expansion.contentTranslation
        return CGPoint(
            x: contentOffset.x + translation.x * zoomScale,
            y: contentOffset.y + translation.y * zoomScale
        )
    }

    static func expandedGeometry(
            _ geometry: CanvasPageGeometry,
            expansion: FreeformCanvasExpansion
    ) -> CanvasPageGeometry? {
        guard geometry.isValid, geometry.quarterTurns == 0 else { return nil }
        let newSize = expansion.expandedSize(from: geometry.displaySize)
        guard newSize.width.isFinite,
              newSize.height.isFinite,
              newSize.width > 0,
              newSize.height > 0 else {
            return nil
        }
        let translation = expansion.contentTranslation
        return CanvasPageGeometry(
            authoredSize: newSize,
            logicalOrigin: CGPoint(
                x: geometry.logicalOrigin.x - translation.x,
                y: geometry.logicalOrigin.y - translation.y
            )
        )
    }

    static func logicalPoint(
            forStoredPoint point: CGPoint,
            geometry: CanvasPageGeometry
    ) -> CGPoint {
        CGPoint(
            x: point.x + geometry.logicalOrigin.x,
            y: point.y + geometry.logicalOrigin.y
        )
    }

    private static func edgeDeltas(
            wantsNegative: Bool,
            wantsPositive: Bool,
            requestedChunk: CGFloat,
            available: CGFloat
    ) -> (negative: CGFloat, positive: CGFloat) {
        guard available > 0, requestedChunk > 0 else { return (0, 0) }
        switch (wantsNegative, wantsPositive) {
        case (true, true):
            let each = min(requestedChunk, available / 2)
            return (each, each)
        case (true, false):
            return (min(requestedChunk, available), 0)
        case (false, true):
            return (0, min(requestedChunk, available))
        case (false, false):
            return (0, 0)
        }
    }
}

/// Resolves the board region used by its 4:3 library preview. A freeform
/// canvas is commonly much larger than its content, so previewing the entire
/// backing store would make useful marks disappear into empty space. The last
/// persisted viewport is a deterministic crop that also survives recovery.
enum FreeformCanvasPreviewLayout {
    static func cropRect(
            canvasSize: CGSize,
            viewport: CanvasViewportState,
            outputAspectRatio: CGFloat = CanvasConstants.freeformLibraryAspectRatio
    ) -> CGRect {
        guard canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0,
              viewport.isValid,
              outputAspectRatio.isFinite,
              outputAspectRatio > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }

        var width = min(max(CGFloat(viewport.visibleWidth), 1), canvasSize.width)
        var height = width / outputAspectRatio
        if height > canvasSize.height {
            height = canvasSize.height
            width = min(height * outputAspectRatio, canvasSize.width)
        }

        let center = CGPoint(
            x: CGFloat(viewport.normalizedCenterX) * canvasSize.width,
            y: CGFloat(viewport.normalizedCenterY) * canvasSize.height
        )
        let maximumX = max(canvasSize.width - width, 0)
        let maximumY = max(canvasSize.height - height, 0)
        return CGRect(
            x: (center.x - width / 2).clamped(to: 0...maximumX),
            y: (center.y - height / 2).clamped(to: 0...maximumY),
            width: width,
            height: height
        )
    }

    /// Fits a 4:3 preview inside an arbitrary pixel budget without inheriting
    /// the caller's shape. A portrait or square budget therefore constrains
    /// resolution but can never turn a canvas card into a page or square.
    static func libraryPixelSize(inside maximumPixelSize: CGSize) -> CGSize {
        guard maximumPixelSize.width.isFinite,
              maximumPixelSize.height.isFinite,
              maximumPixelSize.width > 0,
              maximumPixelSize.height > 0 else { return .zero }

        let maximumWidth = max(floor(maximumPixelSize.width), 1)
        let maximumHeight = max(floor(maximumPixelSize.height), 1)
        let aspectRatio = CanvasConstants.freeformLibraryAspectRatio

        if maximumWidth / maximumHeight > aspectRatio {
            let width = max(floor(maximumHeight * aspectRatio), 1)
            return CGSize(width: width, height: maximumHeight)
        }

        let height = max(floor(maximumWidth / aspectRatio), 1)
        return CGSize(width: maximumWidth, height: height)
    }
}

/// Intent policy for pull-to-add. Geometry remains in `CanvasStackLayout`;
/// this gate distinguishes a deliberate edge pull from a scroll that merely
/// reaches an edge at speed.
struct CanvasBoundaryPullGate {
    private enum Phase: Equatable {
        case idle
        case pulling(CanvasPageBoundary)
        case armed(CanvasPageBoundary)
    }

    private(set) var sessionID: UInt = 0
    private(set) var isTracking = false
    private var eligibleBoundaries: Set<CanvasPageBoundary> = []
    private var lockedBoundary: CanvasPageBoundary?
    private var latestMeasuredPull: CanvasBoundaryPagePull?
    private var phase: Phase = .idle

    var eligibleBoundariesAtStart: Set<CanvasPageBoundary> {
        eligibleBoundaries
    }

    mutating func begin(eligibleBoundaries: Set<CanvasPageBoundary>) {
        sessionID &+= 1
        isTracking = true
        self.eligibleBoundaries = eligibleBoundaries
        lockedBoundary = nil
        latestMeasuredPull = nil
        phase = .idle
    }

    mutating func update(
            measuredPull: CanvasBoundaryPagePull?,
            now: TimeInterval
    ) -> CanvasBoundaryPagePull? {
        guard isTracking,
              let measuredPull,
              eligibleBoundaries.contains(measuredPull.boundary) else {
            latestMeasuredPull = nil
            phase = .idle
            return nil
        }

        if let lockedBoundary, lockedBoundary != measuredPull.boundary {
            latestMeasuredPull = nil
            phase = .idle
            return nil
        }
        if lockedBoundary == nil {
            lockedBoundary = measuredPull.boundary
        }
        latestMeasuredPull = measuredPull

        // Arms the instant the pull reaches the arm distance while the finger
        // is still dragging. There is deliberately no "hold still" step: the
        // edge-start, drag-only, direction, distance and release-speed gates
        // already separate a deliberate pull from ordinary scrolling.
        if case let .armed(boundary) = phase,
           boundary == measuredPull.boundary {
            if measuredPull.progress >= Self.disarmProgress {
                return CanvasBoundaryPagePull(boundary: boundary, progress: 1)
            }
            phase = .pulling(boundary)
            return measuredPull
        }

        guard measuredPull.progress >= 1 else {
            phase = .pulling(measuredPull.boundary)
            return measuredPull
        }

        phase = .armed(measuredPull.boundary)
        return CanvasBoundaryPagePull(boundary: measuredPull.boundary, progress: 1)
    }

    mutating func end(releaseVelocity: CGPoint) -> CanvasPageBoundary? {
        let boundary: CanvasPageBoundary?
        if case let .armed(armedBoundary) = phase,
           hypot(releaseVelocity.x, releaseVelocity.y)
            <= CanvasConstants.boundaryPullMaximumReleaseVelocityPointsPerSecond {
            boundary = armedBoundary
        } else {
            boundary = nil
        }
        cancel()
        return boundary
    }

    mutating func cancel() {
        sessionID &+= 1
        isTracking = false
        eligibleBoundaries = []
        lockedBoundary = nil
        latestMeasuredPull = nil
        phase = .idle
    }

    private static var disarmProgress: CGFloat {
        let reveal = CanvasConstants.boundaryPullRevealDistance
        let range = max(CanvasConstants.boundaryPullArmDistance - reveal, 1)
        return (CanvasConstants.boundaryPullDisarmDistance - reveal) / range
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
