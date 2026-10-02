import SwiftUI
import UIKit

/// An immutable presentation of a canvas document. Reader Mode intentionally
/// renders committed snapshots instead of mounting PaperKit, so none of the
/// authoring gestures or mutation callbacks exist in this view hierarchy.
struct CanvasReaderView: View {
    let pages: [CanvasPageSnapshot]
    let currentPageID: UUID?
    let preferences: CanvasReaderPreferences
    let reduceMotion: Bool
    let onPageChanged: @MainActor (UUID) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visiblePageID: UUID?
    @State private var requestedPageID: UUID?
    @State private var zoomPercentage = 100
    @State private var zoomCommand: CanvasReaderZoomCommand?
    @State private var isPageTransitioning = false

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let layout = preferences.resolvedPageLayout(for: viewportSize)
            let transition = preferences.resolvedPageTransition(
                for: viewportSize,
                reduceMotion: reduceMotion
            )
            let usesStackedControls = CanvasReaderMetrics.usesStackedControls(
                viewportSize: viewportSize,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )

            ZStack(alignment: .bottomTrailing) {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                if pages.isEmpty {
                    ContentUnavailableView(
                        "No Pages",
                        systemImage: "doc",
                        description: Text("There are no pages available to read.")
                    )
                } else {
                    readerSurface(
                        layout: layout,
                        transition: transition,
                        viewportSize: viewportSize
                    )

                    readerControls(
                        layout: layout,
                        usesStackedLayout: usesStackedControls
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
            .task(id: pages.map(\.id)) {
                synchronizeVisiblePage()
            }
            .onChange(of: currentPageID) { _, _ in
                synchronizeVisiblePage()
            }
        }
    }

    @ViewBuilder
    private func readerSurface(
        layout: CanvasPageLayoutPreferences,
        transition: CanvasReaderPageTransition,
        viewportSize: CGSize
    ) -> some View {
        CanvasReaderPager(
            pages: pages,
            currentPageID: requestedPageID ?? resolvedVisiblePageID,
            pageDisplayMode: layout.pageDisplayMode,
            scrollDirection: layout.scrollDirection,
            pageTransition: transition,
            reduceMotion: reduceMotion,
            zoomCommand: zoomCommand,
            onPageChanged: { pageID in
                readerDidSelectPage(pageID, layout: layout)
            },
            onZoomChanged: readerZoomDidChange,
            onTransitionChanged: { isTransitioning in
                guard isPageTransitioning != isTransitioning else { return }
                isPageTransitioning = isTransitioning
            }
        )
        // UIPageViewController cannot change transition style or navigation
        // orientation after initialization. Recreate only when that native
        // configuration changes; page/layout updates stay coordinator-driven.
        .id("\(layout.scrollDirection.rawValue)-\(transition.rawValue)")
        .frame(width: viewportSize.width, height: viewportSize.height)
        .accessibilityAction(named: "Previous Page") {
            navigate(by: -1, layout: layout)
        }
        .accessibilityAction(named: "Next Page") {
            navigate(by: 1, layout: layout)
        }
        .accessibilityAction(named: "Zoom In") { sendZoomCommand(.zoomIn) }
        .accessibilityAction(named: "Zoom Out") { sendZoomCommand(.zoomOut) }
        .accessibilityAction(named: "Fit Page") { sendZoomCommand(.fit) }
    }

    private func readerControls(
        layout: CanvasPageLayoutPreferences,
        usesStackedLayout: Bool
    ) -> some View {
        Group {
            if usesStackedLayout {
                VStack(alignment: .trailing, spacing: 8) {
                    zoomControls
                    navigationControls(layout: layout)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    navigationControls(layout: layout)
                    Spacer(minLength: 0)
                    zoomControls
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private func navigationControls(
        layout: CanvasPageLayoutPreferences
    ) -> some View {
        let previousSymbol = layout.scrollDirection == .horizontal
            ? "chevron.left" : "chevron.up"
        let nextSymbol = layout.scrollDirection == .horizontal
            ? "chevron.right" : "chevron.down"

        return HStack(spacing: 2) {
            Button {
                navigate(by: -1, layout: layout)
            } label: {
                Image(systemName: previousSymbol)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                isPageTransitioning
                        || canNavigate(by: -1, layout: layout) == false
            )
            .accessibilityIdentifier("canvas.reader.previous")
            .accessibilityLabel("Previous Page")

            pageStatus(layout: layout)
                .frame(width: 132)

            Button {
                navigate(by: 1, layout: layout)
            } label: {
                Image(systemName: nextSymbol)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                isPageTransitioning
                        || canNavigate(by: 1, layout: layout) == false
            )
            .accessibilityIdentifier("canvas.reader.next")
            .accessibilityLabel("Next Page")
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                sendZoomCommand(.zoomOut)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoomPercentage <= 100)
            .accessibilityIdentifier("canvas.reader.zoom-out")
            .accessibilityLabel("Zoom Out")

            Text("\(zoomPercentage)%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 48)
                .accessibilityIdentifier("canvas.reader.zoom-status")
                .accessibilityLabel("Zoom")
                .accessibilityValue("\(zoomPercentage) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        sendZoomCommand(.zoomIn)
                    case .decrement:
                        sendZoomCommand(.zoomOut)
                    @unknown default:
                        break
                    }
                }

            Button {
                sendZoomCommand(.zoomIn)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoomPercentage >= CanvasReaderZoomLevels.maximumPercentage)
            .accessibilityIdentifier("canvas.reader.zoom-in")
            .accessibilityLabel("Zoom In")

            Button("Fit") {
                sendZoomCommand(.fit)
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .frame(width: 44, height: 44)
            .opacity(zoomPercentage > 100 ? 1 : 0.35)
            .disabled(zoomPercentage <= 100)
            .accessibilityHidden(zoomPercentage <= 100)
            .accessibilityIdentifier("canvas.reader.zoom-reset")
            .accessibilityLabel("Fit Page")
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
    }

    private func pageStatus(layout: CanvasPageLayoutPreferences) -> some View {
        Text(pageStatusText(layout: layout))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityIdentifier("canvas.reader.page-status")
            .allowsHitTesting(false)
    }

    private func pageStatusText(
        layout: CanvasPageLayoutPreferences
    ) -> String {
        let selectedIndex = pages.firstIndex { $0.id == resolvedVisiblePageID } ?? 0
        if layout.scrollDirection == .horizontal,
           layout.pageDisplayMode == .twoPage {
            let firstIndex = (selectedIndex / 2) * 2
            let lastIndex = min(firstIndex + 1, pages.count - 1)
            return firstIndex == lastIndex
                ? "Page \(firstIndex + 1) of \(pages.count)"
                : "Pages \(firstIndex + 1)\u{2013}\(lastIndex + 1) of \(pages.count)"
        }
        return "Page \(selectedIndex + 1) of \(pages.count)"
    }

    private var resolvedVisiblePageID: UUID? {
        if let visiblePageID,
           pages.contains(where: { $0.id == visiblePageID }) {
            return visiblePageID
        }
        if let currentPageID,
           pages.contains(where: { $0.id == currentPageID }) {
            return currentPageID
        }
        return pages.first?.id
    }

    private func synchronizeVisiblePage() {
        requestedPageID = nil
        isPageTransitioning = false
        if let currentPageID,
           pages.contains(where: { $0.id == currentPageID }) {
            visiblePageID = currentPageID
        } else if let visiblePageID,
                  pages.contains(where: { $0.id == visiblePageID }) {
            // Keep the reader anchored when snapshots refresh in place.
        } else {
            visiblePageID = pages.first?.id
        }
    }

    private func readerDidSelectPage(
        _ pageID: UUID,
        layout: CanvasPageLayoutPreferences
    ) {
        guard pages.contains(where: { $0.id == pageID }) else { return }
        requestedPageID = nil
        isPageTransitioning = false
        zoomPercentage = 100
        guard visiblePageID != pageID else { return }
        visiblePageID = pageID
        onPageChanged(pageID)
        UIAccessibility.post(
            notification: .pageScrolled,
            argument: pageStatusText(layout: layout)
        )
    }

    private func readerZoomDidChange(_ scale: CGFloat) {
        let percentage = Int((scale * 100).rounded())
        guard zoomPercentage != percentage else { return }
        zoomPercentage = percentage
    }

    private func sendZoomCommand(_ action: CanvasReaderZoomAction) {
        zoomCommand = CanvasReaderZoomCommand(action: action)
    }

    private func canNavigate(
        by spreadDelta: Int,
        layout: CanvasPageLayoutPreferences
    ) -> Bool {
        navigationTarget(by: spreadDelta, layout: layout) != nil
    }

    private func navigate(
        by spreadDelta: Int,
        layout: CanvasPageLayoutPreferences
    ) {
        guard let pageID = navigationTarget(by: spreadDelta, layout: layout) else {
            return
        }
        sendZoomCommand(.fit)
        requestedPageID = pageID
        isPageTransitioning = true
    }

    private func navigationTarget(
        by spreadDelta: Int,
        layout: CanvasPageLayoutPreferences
    ) -> UUID? {
        guard pages.isEmpty == false else { return nil }
        let selectedIndex = pages.firstIndex { $0.id == resolvedVisiblePageID } ?? 0
        let pagesPerScreen = layout.scrollDirection == .horizontal
            && layout.pageDisplayMode == .twoPage ? 2 : 1
        let screenIndex = selectedIndex / pagesPerScreen
        let screenCount = (pages.count + pagesPerScreen - 1) / pagesPerScreen
        let targetScreenIndex = screenIndex + spreadDelta
        guard targetScreenIndex >= 0, targetScreenIndex < screenCount else { return nil }
        return pages[targetScreenIndex * pagesPerScreen].id
    }
}

enum CanvasReaderZoomAction: Equatable, Sendable {
    case zoomIn
    case zoomOut
    case fit
}

struct CanvasReaderZoomCommand: Equatable, Sendable {
    let id: UUID
    let action: CanvasReaderZoomAction

    init(id: UUID = UUID(), action: CanvasReaderZoomAction) {
        self.id = id
        self.action = action
    }
}

enum CanvasReaderZoomLevels {
    static let percentages = [100, 150, 200, 300, 400]
    static let maximumPercentage = percentages.last ?? 400

    static func zoomedIn(from percentage: Int) -> Int {
        percentages.first(where: { $0 > percentage }) ?? maximumPercentage
    }

    static func zoomedOut(from percentage: Int) -> Int {
        percentages.last(where: { $0 < percentage }) ?? 100
    }
}

private struct CanvasReaderSpread: Equatable {
    struct Page: Identifiable, Equatable {
        let snapshot: CanvasPageSnapshot
        let pageNumber: Int

        var id: UUID { snapshot.id }
    }

    let pages: [Page]
    let slotCount: Int

    static func make(
        from snapshots: [CanvasPageSnapshot],
        displayMode: CanvasPageDisplayMode
    ) -> [CanvasReaderSpread] {
        guard snapshots.isEmpty == false else { return [] }
        let pageCount = displayMode == .twoPage ? 2 : 1
        var result: [CanvasReaderSpread] = []
        result.reserveCapacity((snapshots.count + pageCount - 1) / pageCount)

        for startIndex in stride(from: 0, to: snapshots.count, by: pageCount) {
            let endIndex = min(startIndex + pageCount, snapshots.count)
            let spreadPages = (startIndex..<endIndex).map { index in
                Page(snapshot: snapshots[index], pageNumber: index + 1)
            }
            result.append(
                CanvasReaderSpread(pages: spreadPages, slotCount: pageCount)
            )
        }
        return result
    }
}

private struct CanvasReaderSpreadView: View {
    let spread: CanvasReaderSpread
    let renderScale: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let contentInsets = CanvasReaderMetrics.contentInsets(
                viewportSize: proxy.size,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            let slotSize = CanvasReaderMetrics.spreadSlotSize(
                pageCount: spread.slotCount,
                viewportSize: proxy.size,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )

            HStack(spacing: CanvasReaderMetrics.spreadGap) {
                ForEach(spread.pages) { page in
                    CanvasReaderPageSlot(
                        page: page.snapshot,
                        pageNumber: page.pageNumber,
                        slotSize: slotSize,
                        renderScale: renderScale
                    )
                    .frame(width: slotSize.width, height: slotSize.height)
                }
                ForEach(spread.pages.count..<spread.slotCount, id: \.self) { _ in
                    Color.clear
                        .frame(width: slotSize.width, height: slotSize.height)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(contentInsets)
        }
    }
}

private struct CanvasReaderPageSlot: View {
    let page: CanvasPageSnapshot
    let pageNumber: Int
    let slotSize: CGSize
    let renderScale: CGFloat

    var body: some View {
        let renderedSize = CanvasReaderMetrics.aspectFit(
            page.displaySize,
            inside: slotSize
        )

        CanvasReaderRenderedPage(
            page: page,
            pageNumber: pageNumber,
            renderedSize: renderedSize,
            renderScale: renderScale
        )
        .frame(width: renderedSize.width, height: renderedSize.height)
        .frame(width: slotSize.width, height: slotSize.height)
    }
}

private struct CanvasReaderRenderedPage: View {
    let page: CanvasPageSnapshot
    let pageNumber: Int
    let renderedSize: CGSize
    let renderScale: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var didFail = false
    @State private var retryGeneration = 0

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityHidden(true)
            } else if didFail {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("This page couldn\u{2019}t be rendered.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        retryGeneration += 1
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Rendering page \(pageNumber)\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 7, y: 2)
        .accessibilityElement(children: didFail ? .contain : .ignore)
        .accessibilityLabel("Page \(pageNumber)")
        .task(id: renderRequest) {
            // Keep the fitted raster visible while a sharper zoom tier renders.
            // Clearing here produces a disruptive loading flash after every
            // pinch or double tap.
            if image == nil {
                didFail = false
            }
            do {
                let rendered = try await CanvasDocumentExporter.shared.thumbnail(
                    for: page,
                    maximumPixelSize: renderRequest.maximumPixelSize
                )
                try Task.checkCancellation()
                image = UIImage(cgImage: rendered)
            } catch is CancellationError {
                return
            } catch {
                if image == nil {
                    didFail = true
                }
            }
        }
        .onDisappear {
            // Lazy scrolling and UIPageViewController retain only nearby page
            // shells; explicitly releasing decoded rasters keeps that window
            // bounded for long notebooks.
            image = nil
            didFail = false
        }
    }

    private var renderRequest: CanvasReaderRenderRequest {
        CanvasReaderRenderRequest(
            pageID: page.id,
            maximumPixelSize: CanvasReaderMetrics.renderPixelSize(
                for: renderedSize,
                displayScale: displayScale,
                readerZoomScale: renderScale
            ),
            retryGeneration: retryGeneration
        )
    }
}

private struct CanvasReaderRenderRequest: Equatable {
    let pageID: UUID
    let maximumPixelSize: CGSize
    let retryGeneration: Int
}

private enum CanvasReaderMetrics {
    static let spreadGap: CGFloat = 16
    private static let stackedControlsWidthThreshold: CGFloat = 480
    private static let maximumRenderDimension: CGFloat = 3_072
    private static let maximumRenderPixelCount: CGFloat = 8_388_608
    private static let renderQuantum: CGFloat = 64

    static func usesStackedControls(
        viewportSize: CGSize,
        isAccessibilitySize: Bool
    ) -> Bool {
        isAccessibilitySize
            || viewportSize.width < stackedControlsWidthThreshold
    }

    static func contentInsets(
        viewportSize: CGSize,
        isAccessibilitySize: Bool
    ) -> EdgeInsets {
        let stackedControls = usesStackedControls(
            viewportSize: viewportSize,
            isAccessibilitySize: isAccessibilitySize
        )
        return EdgeInsets(
            top: 68,
            leading: 20,
            bottom: stackedControls ? 120 : 76,
            trailing: 20
        )
    }

    static func spreadSlotSize(
        pageCount: Int,
        viewportSize: CGSize,
        isAccessibilitySize: Bool
    ) -> CGSize {
        let count = CGFloat(max(pageCount, 1))
        let insets = contentInsets(
            viewportSize: viewportSize,
            isAccessibilitySize: isAccessibilitySize
        )
        let horizontalInsets = insets.leading
            + insets.trailing
            + (spreadGap * max(count - 1, 0))
        return CGSize(
            width: max((viewportSize.width - horizontalInsets) / count, 1),
            height: max(viewportSize.height - insets.top - insets.bottom, 1)
        )
    }

    static func aspectFit(_ sourceSize: CGSize, inside bounds: CGSize) -> CGSize {
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }

    static func renderPixelSize(
        for renderedSize: CGSize,
        displayScale: CGFloat,
        readerZoomScale: CGFloat
    ) -> CGSize {
        let resolvedZoomScale = readerZoomScale.isFinite
            ? min(max(readerZoomScale, 1), 4)
            : 1
        var width = max(renderedSize.width * max(displayScale, 1) * resolvedZoomScale, 1)
        var height = max(renderedSize.height * max(displayScale, 1) * resolvedZoomScale, 1)
        let dimensionScale = min(maximumRenderDimension / max(width, height), 1)
        let pixelCountScale = min(
            sqrt(maximumRenderPixelCount / max(width * height, 1)),
            1
        )
        let scale = min(dimensionScale, pixelCountScale)
        width *= scale
        height *= scale

        // Quantization prevents transient layout changes from repeatedly
        // restarting an expensive full-page render.
        width = max(ceil(width / renderQuantum) * renderQuantum, 1)
        height = max(ceil(height / renderQuantum) * renderQuantum, 1)
        return CGSize(width: width, height: height)
    }
}

/// One native page container serves vertical paging, horizontal paging, and
/// horizontal page curl. Every child is exactly one screen-sized page/spread
/// and owns an independent UIScrollView for anchored pinch zoom and panning.
private struct CanvasReaderPager: UIViewControllerRepresentable {
    let pages: [CanvasPageSnapshot]
    let currentPageID: UUID?
    let pageDisplayMode: CanvasPageDisplayMode
    let scrollDirection: CanvasScrollDirection
    let pageTransition: CanvasReaderPageTransition
    let reduceMotion: Bool
    let zoomCommand: CanvasReaderZoomCommand?
    let onPageChanged: @MainActor (UUID) -> Void
    let onZoomChanged: @MainActor (CGFloat) -> Void
    let onTransitionChanged: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPageChanged: onPageChanged,
            onZoomChanged: onZoomChanged,
            onTransitionChanged: onTransitionChanged
        )
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let usesPageCurl = pageTransition == .pageCurl
        let transitionStyle: UIPageViewController.TransitionStyle = usesPageCurl
            ? .pageCurl : .scroll
        let navigationOrientation: UIPageViewController.NavigationOrientation =
            scrollDirection == .vertical ? .vertical : .horizontal
        let options: [UIPageViewController.OptionsKey: Any] = usesPageCurl
            ? [
                .spineLocation: NSNumber(
                    value: UIPageViewController.SpineLocation.min.rawValue
                )
            ]
            : [.interPageSpacing: NSNumber(value: 0)]
        let controller = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: navigationOrientation,
            options: options
        )
        if usesPageCurl {
            controller.isDoubleSided = false
        }
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        // Page turning is intentionally a one-finger gesture. Restricting the
        // outer controller's pans keeps a two-finger pinch available to the
        // visible page's zoom scroll view instead of letting the pager claim
        // both touches first.
        controller.gestureRecognizers
            .compactMap { $0 as? UIPanGestureRecognizer }
            .forEach { $0.maximumNumberOfTouches = 1 }
        controller.view.backgroundColor = .systemGroupedBackground
        controller.view.clipsToBounds = true
        controller.view.accessibilityIdentifier = "canvas.reader.surface"
        context.coordinator.pageViewController = controller
        context.coordinator.configure(
            pages: pages,
            currentPageID: currentPageID,
            pageDisplayMode: pageDisplayMode,
            reduceMotion: reduceMotion,
            zoomCommand: zoomCommand,
            in: controller,
            force: true
        )
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIPageViewController,
        context: Context
    ) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.onTransitionChanged = onTransitionChanged
        context.coordinator.configure(
            pages: pages,
            currentPageID: currentPageID,
            pageDisplayMode: pageDisplayMode,
            reduceMotion: reduceMotion,
            zoomCommand: zoomCommand,
            in: uiViewController
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: UIPageViewController,
        coordinator: Coordinator
    ) {
        uiViewController.dataSource = nil
        uiViewController.delegate = nil
        // A page-curl controller with a minimum spine requires one visible
        // controller. Let UIKit release the final child with its container.
        coordinator.reset()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private struct PendingConfiguration {
            let pages: [CanvasPageSnapshot]
            let currentPageID: UUID?
            let pageDisplayMode: CanvasPageDisplayMode
            let reduceMotion: Bool
            let zoomCommand: CanvasReaderZoomCommand?
            let force: Bool
        }

        var onPageChanged: @MainActor (UUID) -> Void
        var onZoomChanged: @MainActor (CGFloat) -> Void
        var onTransitionChanged: @MainActor (Bool) -> Void
        weak var pageViewController: UIPageViewController?

        private var pages: [CanvasPageSnapshot] = []
        private var pageDisplayMode: CanvasPageDisplayMode = .singlePage
        private var reduceMotion = false
        private var cachedControllers: [Int: CanvasReaderZoomHostingController] = [:]
        private var selectedSpreadIndex = 0
        private var lastRequestedPageID: UUID?
        private var lastZoomCommandID: UUID?
        private var isTransitioning = false
        private var isConfiguring = false
        private var pendingConfiguration: PendingConfiguration?

        init(
            onPageChanged: @escaping @MainActor (UUID) -> Void,
            onZoomChanged: @escaping @MainActor (CGFloat) -> Void,
            onTransitionChanged: @escaping @MainActor (Bool) -> Void
        ) {
            self.onPageChanged = onPageChanged
            self.onZoomChanged = onZoomChanged
            self.onTransitionChanged = onTransitionChanged
        }

        func configure(
            pages: [CanvasPageSnapshot],
            currentPageID: UUID?,
            pageDisplayMode: CanvasPageDisplayMode,
            reduceMotion: Bool,
            zoomCommand: CanvasReaderZoomCommand?,
            in pageViewController: UIPageViewController,
            force: Bool = false
        ) {
            // Reader pages are immutable for this coordinator's lifetime, so
            // stable identities are sufficient and avoid comparing large
            // PaperMarkup/background values on every SwiftUI update.
            let contentChanged = self.pages.map(\.id) != pages.map(\.id)
                || self.pageDisplayMode != pageDisplayMode
            let requestChanged = lastRequestedPageID != currentPageID
            let isInitialConfiguration = force
                && self.pages.isEmpty
                && pageViewController.viewControllers == nil
            if isInitialConfiguration {
                // Zoom commands are transient. Recreating the pager for a
                // direction or transition change must begin at Fit instead of
                // replaying the previous pager's last command.
                lastZoomCommandID = zoomCommand?.id
            }
            let zoomCommandChanged = zoomCommand?.id != lastZoomCommandID
            let motionChanged = self.reduceMotion != reduceMotion
            guard force || contentChanged || requestChanged
                || zoomCommandChanged || motionChanged else { return }

            if isTransitioning {
                pendingConfiguration = PendingConfiguration(
                    pages: pages,
                    currentPageID: currentPageID,
                    pageDisplayMode: pageDisplayMode,
                    reduceMotion: reduceMotion,
                    zoomCommand: zoomCommand,
                    force: force
                )
                return
            }

            isConfiguring = true
            defer { isConfiguring = false }
            self.reduceMotion = reduceMotion
            cachedControllers.values.forEach {
                $0.setReduceMotionEnabled(reduceMotion)
            }
            if contentChanged {
                visibleZoomController?.resetZoom(animated: false, notify: false)
                self.pages = pages
                self.pageDisplayMode = pageDisplayMode
                cachedControllers.removeAll()
                setPagingEnabled(true)
                publishZoomChanged(1)
            }
            lastRequestedPageID = currentPageID

            guard spreadCount > 0 else { return }

            let previousIndex = selectedSpreadIndex
            let targetIndex = spreadIndex(containing: currentPageID)
                ?? min(selectedSpreadIndex, spreadCount - 1)
            guard let target = controller(at: targetIndex) else { return }
            let changesVisibleScreen = pageViewController.viewControllers?.first !== target
            if changesVisibleScreen {
                visibleZoomController?.resetZoom(animated: false, notify: false)
                target.resetZoom(animated: false, notify: false)
                setPagingEnabled(true)
                selectedSpreadIndex = targetIndex
                publishZoomChanged(1)
            }

            if pageViewController.viewControllers?.first !== target {
                let shouldAnimate = force == false
                    && contentChanged == false
                    && reduceMotion == false
                let shouldCommitPageChange = requestChanged && force == false
                isTransitioning = shouldAnimate
                if shouldAnimate {
                    publishTransitionChanged(true)
                }
                pageViewController.setViewControllers(
                    [target],
                    direction: targetIndex < previousIndex ? .reverse : .forward,
                    animated: shouldAnimate
                ) { [weak self, weak pageViewController] finished in
                    guard let self, let pageViewController else { return }
                    self.isTransitioning = false
                    let committedIndex = finished ? targetIndex : previousIndex
                    self.selectedSpreadIndex = committedIndex
                    self.pruneCache(around: committedIndex)
                    if shouldAnimate {
                        self.publishTransitionChanged(false)
                        if shouldCommitPageChange,
                           let pageID = self.firstPageID(in: committedIndex) {
                            self.onPageChanged(pageID)
                        }
                    } else if shouldCommitPageChange,
                              let pageID = self.firstPageID(in: committedIndex) {
                        // A nonanimated UIPageViewController completion may be
                        // invoked synchronously from updateUIViewController.
                        // Publish state on the next main-actor turn instead.
                        Task { @MainActor [weak self] in
                            self?.publishTransitionChanged(false)
                            self?.onPageChanged(pageID)
                        }
                    }
                    self.applyPendingConfiguration(in: pageViewController)
                }
            } else {
                selectedSpreadIndex = targetIndex
            }
            pruneCache(around: targetIndex)

            if zoomCommandChanged, let zoomCommand {
                lastZoomCommandID = zoomCommand.id
                target.perform(
                    zoomCommand.action,
                    animated: reduceMotion == false
                )
            }
        }

        func reset() {
            cachedControllers.values.forEach { $0.onZoomChanged = nil }
            cachedControllers.removeAll()
            pages = []
            selectedSpreadIndex = 0
            lastRequestedPageID = nil
            lastZoomCommandID = nil
            isTransitioning = false
            pendingConfiguration = nil
            pageViewController = nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? CanvasReaderZoomHostingController else {
                return nil
            }
            return controller(at: current.spreadIndex - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? CanvasReaderZoomHostingController else {
                return nil
            }
            return controller(at: current.spreadIndex + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            _ = pageViewController
            _ = pendingViewControllers
            isTransitioning = true
            publishTransitionChanged(true)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            _ = finished
            _ = previousViewControllers
            isTransitioning = false
            publishTransitionChanged(false)
            var completedPageID: UUID?
            if completed,
               let visible = pageViewController.viewControllers?.first
               as? CanvasReaderZoomHostingController {
                selectedSpreadIndex = visible.spreadIndex
                visible.resetZoom(animated: false, notify: false)
                setPagingEnabled(true)
                publishZoomChanged(1)
                pruneCache(around: visible.spreadIndex)
                if let pageID = firstPageID(in: visible.spreadIndex) {
                    completedPageID = pageID
                    onPageChanged(pageID)
                }
            }

            applyPendingConfiguration(
                in: pageViewController,
                completedPageID: completedPageID,
                completedInteractiveTransition: completed
            )
        }

        private var pagesPerSpread: Int {
            pageDisplayMode == .twoPage ? 2 : 1
        }

        private var spreadCount: Int {
            guard pages.isEmpty == false else { return 0 }
            return (pages.count + pagesPerSpread - 1) / pagesPerSpread
        }

        private func spreadIndex(containing pageID: UUID?) -> Int? {
            guard let pageID,
                  let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
                return nil
            }
            return pageIndex / pagesPerSpread
        }

        private func firstPageID(in spreadIndex: Int) -> UUID? {
            let pageIndex = spreadIndex * pagesPerSpread
            guard pages.indices.contains(pageIndex) else { return nil }
            return pages[pageIndex].id
        }

        private var visibleZoomController: CanvasReaderZoomHostingController? {
            pageViewController?.viewControllers?.first as? CanvasReaderZoomHostingController
        }

        private func controller(at spreadIndex: Int) -> CanvasReaderZoomHostingController? {
            guard spreadIndex >= 0, spreadIndex < spreadCount else { return nil }
            if let cached = cachedControllers[spreadIndex] {
                cached.setReduceMotionEnabled(reduceMotion)
                return cached
            }

            let startIndex = spreadIndex * pagesPerSpread
            let endIndex = min(startIndex + pagesPerSpread, pages.count)
            let spread = CanvasReaderSpread(
                pages: (startIndex..<endIndex).map { pageIndex in
                    CanvasReaderSpread.Page(
                        snapshot: pages[pageIndex],
                        pageNumber: pageIndex + 1
                    )
                },
                slotCount: pagesPerSpread
            )
            let controller = CanvasReaderZoomHostingController(
                spreadIndex: spreadIndex,
                spread: spread,
                reduceMotion: reduceMotion
            )
            controller.onZoomChanged = { [weak self] index, scale in
                self?.childZoomDidChange(at: index, scale: scale)
            }
            cachedControllers[spreadIndex] = controller
            return controller
        }

        private func childZoomDidChange(at spreadIndex: Int, scale: CGFloat) {
            guard spreadIndex == selectedSpreadIndex else { return }
            let isZoomed = scale > 1.01
            setPagingEnabled(isZoomed == false)
            publishZoomChanged(scale)
        }

        private func publishZoomChanged(_ scale: CGFloat) {
            let callback = onZoomChanged
            guard isConfiguring else {
                callback(scale)
                return
            }
            Task { @MainActor in callback(scale) }
        }

        private func publishTransitionChanged(_ isTransitioning: Bool) {
            let callback = onTransitionChanged
            guard isConfiguring else {
                callback(isTransitioning)
                return
            }
            Task { @MainActor in callback(isTransitioning) }
        }

        private func setPagingEnabled(_ isEnabled: Bool) {
            guard let pageViewController else { return }
            let targetDataSource: UIPageViewControllerDataSource? = isEnabled ? self : nil
            if pageViewController.dataSource !== targetDataSource {
                pageViewController.dataSource = targetDataSource
            }
        }

        private func applyPendingConfiguration(
            in pageViewController: UIPageViewController,
            completedPageID: UUID? = nil,
            completedInteractiveTransition: Bool = false
        ) {
            guard let pendingConfiguration else { return }
            self.pendingConfiguration = nil
            // An unrelated SwiftUI refresh can carry the pre-turn page ID.
            // Preserve a genuinely new external request, but retarget that
            // stale request to the spread UIKit just finished revealing.
            let pendingPageID = if completedInteractiveTransition,
                                   pendingConfiguration.currentPageID
                                   == lastRequestedPageID,
                                   let completedPageID {
                completedPageID
            } else {
                pendingConfiguration.currentPageID
            }
            configure(
                pages: pendingConfiguration.pages,
                currentPageID: pendingPageID,
                pageDisplayMode: pendingConfiguration.pageDisplayMode,
                reduceMotion: pendingConfiguration.reduceMotion,
                zoomCommand: pendingConfiguration.zoomCommand,
                in: pageViewController,
                force: pendingConfiguration.force
            )
        }

        private func pruneCache(around spreadIndex: Int) {
            let retainedIndices = Set([
                spreadIndex - 1,
                spreadIndex,
                spreadIndex + 1
            ])
            cachedControllers = cachedControllers.filter { retainedIndices.contains($0.key) }
        }
    }
}

@MainActor
private final class CanvasReaderZoomHostingController: UIViewController, UIScrollViewDelegate {
    let spreadIndex: Int
    var onZoomChanged: (@MainActor (Int, CGFloat) -> Void)?

    private let spread: CanvasReaderSpread
    private var reduceMotion: Bool
    private let scrollView = UIScrollView()
    private let hostingController: UIHostingController<CanvasReaderSpreadView>
    private var renderScale: CGFloat = 1
    private var lastBoundsSize: CGSize = .zero
    private var lastReportedPercentage = 100

    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    init(
        spreadIndex: Int,
        spread: CanvasReaderSpread,
        reduceMotion: Bool
    ) {
        self.spreadIndex = spreadIndex
        self.spread = spread
        self.reduceMotion = reduceMotion
        hostingController = UIHostingController(
            rootView: CanvasReaderSpreadView(
                spread: spread,
                renderScale: 1
            )
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .systemGroupedBackground
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = self
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.pinchGestureRecognizer?.isEnabled = true
        scrollView.accessibilityIdentifier = "canvas.reader.zoom-surface"
        scrollView.addGestureRecognizer(doubleTapRecognizer)

        addChild(hostingController)
        hostingController.loadViewIfNeeded()
        guard let hostedView = hostingController.view else {
            hostingController.removeFromParent()
            return
        }
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.backgroundColor = .clear
        scrollView.addSubview(hostedView)
        hostingController.didMove(toParent: self)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostedView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor
            ),
            hostedView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor
            ),
            hostedView.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor
            ),
            hostedView.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor
            ),
            hostedView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
            hostedView.heightAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.heightAnchor
            ),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if lastBoundsSize != .zero, lastBoundsSize != size {
            resetZoom(animated: false)
        }
        lastBoundsSize = size
        updateContentInsets()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        hostingController.view
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateZoomInteraction()
        updateContentInsets()
        reportZoomIfNeeded()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        _ = view
        finishZoomInteraction(at: scale)
    }

    func perform(_ action: CanvasReaderZoomAction, animated: Bool) {
        let currentPercentage = Int((scrollView.zoomScale * 100).rounded())
        switch action {
        case .zoomIn:
            setZoom(
                percentage: CanvasReaderZoomLevels.zoomedIn(from: currentPercentage),
                animated: animated
            )
        case .zoomOut:
            setZoom(
                percentage: CanvasReaderZoomLevels.zoomedOut(from: currentPercentage),
                animated: animated
            )
        case .fit:
            resetZoom(animated: animated)
        }
    }

    func setReduceMotionEnabled(_ isEnabled: Bool) {
        reduceMotion = isEnabled
    }

    func resetZoom(animated: Bool, notify: Bool = true) {
        scrollView.setZoomScale(1, animated: animated && reduceMotion == false)
        if animated == false || reduceMotion {
            scrollView.contentInset = .zero
            scrollView.setContentOffset(.zero, animated: false)
            updateZoomInteraction()
        }
        if notify {
            reportZoomIfNeeded(force: true)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            resetZoom(animated: true)
            return
        }

        let targetScale: CGFloat = 2
        let point = recognizer.location(in: hostingController.view)
        let width = scrollView.bounds.width / targetScale
        let height = scrollView.bounds.height / targetScale
        let zoomRect = CGRect(
            x: point.x - (width / 2),
            y: point.y - (height / 2),
            width: width,
            height: height
        )
        upgradeRenderScale(for: targetScale)
        scrollView.zoom(to: zoomRect, animated: reduceMotion == false)
    }

    private func setZoom(percentage: Int, animated: Bool) {
        let targetScale = CGFloat(percentage) / 100
        upgradeRenderScale(for: targetScale)
        scrollView.setZoomScale(
            min(max(targetScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale),
            animated: animated && reduceMotion == false
        )
        if animated == false || reduceMotion {
            updateZoomInteraction()
            updateContentInsets()
            reportZoomIfNeeded(force: true)
        }
    }

    private func updateZoomInteraction() {
        let isZoomed = scrollView.zoomScale > 1.01
        scrollView.panGestureRecognizer.isEnabled = isZoomed
        scrollView.showsHorizontalScrollIndicator = isZoomed
        scrollView.showsVerticalScrollIndicator = isZoomed
        if isZoomed == false {
            scrollView.contentInset = .zero
        }
    }

    private func finishZoomInteraction(at scale: CGFloat) {
        if scale > 1.01, scale < 1.08 {
            resetZoom(animated: true)
            return
        }
        upgradeRenderScale(for: scale)
        updateZoomInteraction()
        reportZoomIfNeeded(force: true)
    }

    private func updateContentInsets() {
        guard scrollView.zoomScale > 1.01 else {
            scrollView.contentInset = .zero
            return
        }
        let horizontal = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let vertical = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: vertical,
            left: horizontal,
            bottom: vertical,
            right: horizontal
        )
    }

    private func reportZoomIfNeeded(force: Bool = false) {
        let percentage = Int((scrollView.zoomScale * 100).rounded())
        guard force || percentage != lastReportedPercentage else { return }
        lastReportedPercentage = percentage
        onZoomChanged?(spreadIndex, scrollView.zoomScale)
    }

    private func upgradeRenderScale(for zoomScale: CGFloat) {
        let requestedScale: CGFloat = if zoomScale <= 1.01 {
            1
        } else if zoomScale <= 2.01 {
            2
        } else {
            4
        }
        guard requestedScale > renderScale else { return }
        renderScale = requestedScale
        hostingController.rootView = CanvasReaderSpreadView(
            spread: spread,
            renderScale: requestedScale
        )
    }
}
