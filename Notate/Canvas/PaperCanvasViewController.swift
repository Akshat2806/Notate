import Foundation
import PaperKit
import PencilKit
import QuartzCore
import UIKit

private enum CanvasTableTransformKind {
    case move
    case resize
}

/// PaperKit can begin a direct-touch drawing recognizer before the third
/// finger arrives. Keep the canvas history swipe eligible until its direction
/// resolves, then let UIKit cancel the competing authoring recognizer.
@MainActor
private final class CanvasHistorySwipeGestureRecognizer: UISwipeGestureRecognizer {
    override func canBePrevented(
        by preventingGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

@MainActor
final class PaperCanvasViewController: UIViewController, PaperCanvasCommanding {
    /// PaperKit's insertion controller registers process-lifetime notification
    /// helpers on current SDKs. Reusing one feature-identical context keeps
    /// those framework-owned helpers bounded across editor lifecycles. All
    /// access is main-actor serialized with the canvas controllers.
    private static let sharedInsertionContext = MarkupEditViewController(
        supportedFeatureSet: PaperFeatureSetFactory.canvas,
        additionalActions: []
    )

    /// The system editing interaction presents a white three-finger command
    /// palette over the canvas. Notate keeps the familiar undo/redo swipes via
    /// canvas-owned recognizers instead, so that palette never obscures ink.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    var hasActiveSnapshotContact: Bool { hasActiveContact }
    var hasPendingProgrammaticInsertions: Bool {
        insertionHistoryTask != nil
            || queuedInsertionCountByPageID.isEmpty == false
            || pagesPreparingInsertionHistory.isEmpty == false
            || pendingInsertions.isEmpty == false
            || retainedProgrammaticInsertionCosts.isEmpty == false
    }

    private struct ViewportEnvironment: Equatable {
        let size: CGSize
        let safeAreaInsets: UIEdgeInsets
        let displayScale: CGFloat
    }

    private enum PendingHistoryAction {
        case undo
        case redo
    }

    private struct PendingHistoryCommand {
        let action: PendingHistoryAction
        let pageID: UUID
    }

    private struct PendingAppUndoRegistration {
        let pageID: UUID
        let manager: UndoManager
        let actionName: String
        let retainedSerializedByteCount: Int
        let handler: @MainActor (PaperCanvasViewController) -> Void
    }

    private enum PendingGeometryToolUpdate {
        case set(CanvasGeometryTool?)
    }

    private struct PendingProgrammaticInsertion {
        let insertion: CanvasInsertion
        let pageID: UUID
        let acceptanceSequence: UInt64
        let retentionCost: ProgrammaticInsertionRetentionCost
    }

    private struct ProgrammaticInsertionRetentionCost: Equatable {
        let imageCount: Int
        let imageBytes: Int
        let textBytes: Int
    }

    private struct RegionSelectionInteractionSnapshot {
        let scrollWasEnabled: Bool
        let laserGestureWasEnabled: Bool
        let geometryInteractionWasEnabled: Bool
        let pageInteractionByID: [UUID: Bool]
    }

    private struct TableHitTarget {
        let pageID: UUID
        let tableID: UUID
        let row: Int
        let column: Int
    }

    private struct TableCellTarget: Equatable {
        let pageID: UUID
        let tableID: UUID
        let row: Int
        let column: Int
    }

    private struct TableAccessibilityKey: Hashable {
        let pageID: UUID
        let tableID: UUID
    }

    private struct TableTransformSession {
        let kind: CanvasTableTransformKind
        let pageID: UUID
        let tableID: UUID
        let originalTables: [CanvasTable]
        let originalTable: CanvasTable
        let startAuthoredPoint: CGPoint
        let scrollWasEnabled: Bool
        var previewTable: CanvasTable
    }

    private enum PendingPageCommand {
        case insert(CanvasPageSnapshot, index: Int, scrollTo: Bool, animated: Bool)
        case replace(CanvasPageSnapshot)
        case scroll(UUID, animated: Bool)
        case navigateToRegion(UUID, CGRect, animated: Bool)
        case activate(UUID, PaperMarkup, CanvasViewportState)
    }

    /// PaperKit resolves undo through its containing controller. Give every
    /// page its own containment boundary so native and app-owned history from
    /// sibling pages cannot collapse into the window's shared undo manager.
    @MainActor
    private final class PageUndoViewController: UIViewController {
        private final class PassthroughView: UIView {
            override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
                .none
            }

            override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
                let hitView = super.hitTest(point, with: event)
                // Preserve the old direct-child behavior when PaperKit is
                // hidden or disabled for laser/region-selection interaction.
                return hitView === self ? nil : hitView
            }
        }

        private let pageUndoManager: UndoManager = {
            let manager = UndoManager()
            manager.levelsOfUndo = PaperCanvasViewController
                .maximumUndoLevelCountPerPage
            return manager
        }()

        override var undoManager: UndoManager? { pageUndoManager }
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
            .none
        }

        override func loadView() {
            let view = PassthroughView()
            view.backgroundColor = .clear
            view.clipsToBounds = false
            self.view = view
        }
    }

    @MainActor
    private final class PageHost {
        let id: UUID
        let controller: PaperMarkupViewController
        let undoController: PageUndoViewController
        let decorationView: PaperPageDecorationView
        let contentView: PaperPageContentView
        var lastDeliveredMarkup: PaperMarkup
        var renderedZoomScale: CGFloat = CanvasConstants.defaultZoomScale
        var hasConfiguredGeometry = false
        var isApplyingGeometry = false

    init(
        id: UUID,
        controller: PaperMarkupViewController,
        markup: PaperMarkup,
        paperTemplate: CanvasPaperTemplate,
        geometry: CanvasPageGeometry,
        background: CanvasPageBackground,
        tables: [CanvasTable],
        rendersPaperTemplateInContentView: Bool
    ) {
        self.id = id
        self.controller = controller
        undoController = PageUndoViewController()
        decorationView = PaperPageDecorationView(
            template: paperTemplate,
            pageBackground: background,
            startsRenderingActive: false
        )
        contentView = PaperPageContentView(
            template: paperTemplate,
            geometry: geometry,
            background: background,
            tables: tables,
            rendersPaperTemplate: rendersPaperTemplateInContentView,
            startsRenderingActive: false
        )
        lastDeliveredMarkup = markup
    }
}

private let scrollView = UIScrollView()
private let documentView = UIView()
private let contactMonitor = CanvasContactGestureRecognizer()
private let laserPointerView = CanvasLaserPointerView()
private let laserPointerGestureRecognizer = CanvasLaserPointerGestureRecognizer()
private let geometryInstrumentView = CanvasGeometryInstrumentView()
private let regionSelectionView = CanvasRegionSelectionView()
private let tableInteractionView = CanvasTableInteractionOverlayView()
private lazy var threeFingerUndoSwipeGestureRecognizer = historySwipeGesture(
    direction: .left,
    action: #selector(handleThreeFingerUndoSwipe(_:))
)
private lazy var threeFingerRedoSwipeGestureRecognizer = historySwipeGesture(
    direction: .right,
    action: #selector(handleThreeFingerRedoSwipe(_:))
)
private lazy var tableSelectionTapGestureRecognizer = UITapGestureRecognizer(
    target: self,
    action: #selector(handleTableSelectionTap(_:))
)
private lazy var tableHoverGestureRecognizer = UIHoverGestureRecognizer(
    target: self,
    action: #selector(handleTableHover(_:))
)

private var callbacks: PaperCanvasCallbacks
private var hasCompletedDismantle = false
private let documentMode: CanvasDocumentMode
private var pages: [CanvasPageSnapshot]
private var hostsByPageID: [UUID: PageHost] = [:]
private var pageIDByController: [ObjectIdentifier: UUID] = [:]
    private var focusedPageID: UUID
    private var initialViewport: CanvasViewportState
    private var inputMode: CanvasInputMode
    private var pageLayout: CanvasPageLayoutPreferences
    private var isReaderModeEnabled = false
    private var activeGeometryTool: CanvasGeometryTool?
    private var topChromeHeight = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight
    private var isRulerActive: Bool { activeGeometryTool == .ruler }
    private var appliedToolState: CanvasToolState?
    private var appliedInputMode: CanvasInputMode?
    private var pendingToolState: CanvasToolState?
    private var pendingInputMode: CanvasInputMode?
    private var pendingPageLayout: CanvasPageLayoutPreferences?
    private var pendingGeometryToolUpdate: PendingGeometryToolUpdate?
    private var pendingZoomScale: CGFloat?
    private var pendingPageCommands: [PendingPageCommand] = []
    /// The latest requested paper for each page while Pencil contact pins the
    /// live host. Snapshots overlay these values so autosave/backgrounding can
    /// never roll a user's selection back before Pencil-up applies it visually.
    private var pendingPaperTemplates: [UUID: CanvasPaperTemplate] = [:]
    private var pendingInsertions: [PendingProgrammaticInsertion] = []
    private var pendingHistoryCommands: [PendingHistoryCommand] = []
    private var pendingAppUndoRegistrations:
        [ObjectIdentifier: [PendingAppUndoRegistration]] = [:]
    private var undoManagersFlushingAppRegistrations: Set<ObjectIdentifier> = []
    /// Undo-bearing hosts remain mounted so page-scoped native history stays
    /// valid. Bound that pin set separately from viewport virtualization: a
    /// long session across hundreds of pages must not retain one PaperKit undo
    /// graph per visited page.
    private var undoHistoryPageRecency: [UUID] = []
    private var isObservingUndoGroupClosure = false
    private var regionSelectionInteractionSnapshot: RegionSelectionInteractionSnapshot?
    private var regionSelectionCaptureTask: Task<Void, Never>?
    private var regionSelectionID: UUID?
    private var regionSelectionPageID: UUID?
    private var regionSelectionPagePath: CGPath?
    private var regionSelectionContext: CanvasRegionSelectionContext?
    private var regionSelectionCheckpointGeneration: Int64 = 0
    private var activeTableTarget: (pageID: UUID, tableID: UUID)?
    private var activeTableCell: TableCellTarget?
private var hoveredTableCell: TableCellTarget?
private var tableTransformSession: TableTransformSession?
private var minimumInteractiveTableCellSizeByID: [UUID: CGSize] = [:]
private var tableAccessibilityElementsByKey: [TableAccessibilityKey: CanvasTableAccessibilityElement] = [:]
    // Programmatic PaperKit insertions need async serialization to produce
    // immutable undo snapshots. Chaining the tasks preserves command order;
    // the Boolean result acknowledges the durable in-memory Canvas Core
    // publication rather than merely accepting work into the queue.
private var insertionHistoryTask: Task<Bool, Never>?
private var insertionHistorySequence: UInt64 = 0
    // Every accepted insertion, including synchronous tables and commands
    // deferred behind contact, receives one monotonically increasing token.
    // Snapshot readiness captures this frontier once so it cannot chase work
    // submitted by a producer that keeps extending the serialized tail.
private var programmaticInsertionAcceptanceSequence: UInt64 = 0
private var programmaticInsertionSequence: UInt64 = 0
private var settledProgrammaticInsertionSequences: Set<UInt64> = []
private var outOfOrderSettledProgrammaticInsertionSequences: Set<UInt64> = []
private var insertionHistoryTasksByAcceptanceSequence: [UInt64: Task<Bool, Never>] = [:]
private var settledProgrammaticInsertionSequence: UInt64 = 0
    // While a snapshot caller owns this boundary, later insertions remain in
    // the deferred queue. The caller first settles everything it observed,
    // then fails closed without waiting for the newer tail.
private var activeProgrammaticInsertionReadinessBoundary: UInt64?
    // Accepted insertions are pinned from enqueue through serialization. The
    // task itself may not start until a later MainActor turn, so the active
    // transaction set alone is too late to protect its source controller.
private var queuedInsertionCountByPageID: [UUID: Int] = [:]
    // Includes commands deferred behind contact/readiness and commands whose
    // serialized task is queued or running. The sequence key makes release
    // idempotent across cancellation/dismantle paths.
    private var retainedProgrammaticInsertionCosts: [UInt64: ProgrammaticInsertionRetentionCost] = [:]
private var retainedProgrammaticInsertionImageCount = 0
private var retainedProgrammaticInsertionImageBytes = 0
private var retainedProgrammaticInsertionTextBytes = 0
private var pagesPreparingInsertionHistory: Set<UUID> = []
private var isDocumentSynchronizationPending = false
private var hasAppliedInitialViewport = false
private var isApplyingGeometry = false
private var isDirectInteractionActive = false
    // Distinguishes the horizontal pager's responsive whole-page resting
    // state from an explicit zoom that happens to be at or below 100%.
    // Without this bit, a rotation would silently turn a user's saved 75%
    // view back into a centered fit-page view.
private var usesHorizontalPageFit = false
private var settledEnvironment: ViewportEnvironment?
private var lastPublishedViewport: CanvasViewportState?
private var lastPublishedViewportPageID: UUID?
private var activeBoundaryPagePull: CanvasBoundaryPagePull?
private var boundaryPullGate = CanvasBoundaryPullGate()
private var boundaryPullHoldTask: Task<Void, Never>?
private var pendingBoundaryPageInsertion: CanvasPageBoundary?
private var dragStartFocusedPageID: UUID?
private var dragStartContentOffset: CGPoint?
    // Suppresses transient focus/viewport writes while UIKit animates to a
    // requested page. The destination's persisted viewport must not be
    // overwritten by intermediate offsets along that animation.
private var programmaticNavigationPageID: UUID?
    // The stable destination paired with `programmaticNavigationPageID`.
    // Snapshot callers use this instead of serializing an in-flight offset.
private var programmaticNavigationViewport: CanvasViewportState?
private let boundaryPageFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
private lazy var pencilInteraction = UIPencilInteraction(delegate: self)
    // PaperKit owns a stable, geometry-budgeted native rendering scale. The
    // outer scroll view carries the remaining logical 50-1000% zoom so large
    // freeform boards never become equally large native editing surfaces.
private var renderedZoomScale = CanvasConstants.defaultZoomScale
private var isZoomScrubbing = false
private var isNativeZoomInteractionActive = false
private var pendingRenderedPageWindowUpdate = false
private var shouldSettleTransientZoomAfterContact = false
private var isUnderMemoryPressure = false
    // UIScrollView can deliver dozens of zoom/scroll callbacks per second.
    // Publishing each one copies the observable page array and cancels then
    // recreates the preferences task in CanvasEditorModel. Coalesce those
    // callbacks while interaction is live, then synchronously flush the final
    // viewport when UIKit settles.
private var transientViewportPublicationTask: Task<Void, Never>?
private var transientViewportPublicationToken: UInt64 = 0
private var transientViewportPublicationPending = false
    // Freeform's 4096-point surface can cause PaperKit to allocate and churn
    // live tiles faster than Core Animation can retire them during repeated
    // extreme zoom. Keep only that mode on a bounded transient composite;
    // paged notebooks remain live so their ink stays sharp while zooming.
private var zoomPresentationReleaseTask: Task<Void, Never>?
private var zoomPresentationReleaseToken: UInt64 = 0
private var isInteractiveZoomPresentationFrozen = false
    // Keyboard shortcuts and accessibility actions arrive as discrete zoom
    // commands instead of one UIScrollView pinch lifecycle. Coalesce a burst
    // of those commands so the large freeform PaperKit host is promoted only
    // once after the user pauses, rather than rebuilding its tile hierarchy
    // at every intermediate scale.
private var programmaticFreeformZoomSettlementTask: Task<Void, Never>?
private static let renderedPageOverscanViewports: CGFloat = 0.25
    // Small notebooks retain the long-standing one-controller-per-page
    // behavior so page identity and native undo semantics remain unchanged.
    // Larger documents create PaperKit stacks only for the active viewport;
    // hosts with native undo or live interaction state remain pinned.
private static let maximumEagerPageHostCount = 32
    // A page-local stack is necessary because PaperKit resolves undo through
    // containment. Twenty levels covers a paragraph of handwriting corrections
    // while keeping both native and app-owned history finite.
private static let maximumUndoLevelCountPerPage = 20
    // The focused page plus seven recently edited page histories stay pinned,
    // so scrolling between a few pages while writing doesn't lose undo.
    // Authored snapshots remain durable and remountable after an older
    // offscreen history is discarded.
private static let maximumRetainedUndoPageHostCount = 8
    // Pending app-owned undo registrations share one byte budget per page,
    // independent of the level count, so deeper undo cannot raise peak memory.
private static let maximumPendingAppUndoSerializedByteCount = 48 * 1_024 * 1_024
    // Programmatic insertion history retains immutable before/after archives.
    // Admit their combined bytes, not each archive independently.
private static let maximumAppOwnedUndoActionSerializedByteCount = 4 * 1_024 * 1_024
    // Bound every payload captured by deferred commands and the serialized
    // task tail. Image cost uses decoded row bytes rather than encoded size.
private static let maximumRetainedProgrammaticInsertionCount = 8
private static let maximumRetainedProgrammaticInsertionImageCount = 2
private static let maximumRetainedProgrammaticInsertionImageBytes = 128 * 1_024 * 1_024
private static let maximumSingleProgrammaticInsertionTextBytes = 256 * 1_024
private static let maximumRetainedProgrammaticInsertionTextBytes = 512 * 1_024
    // History commands can arrive from hardware keyboards and accessibility
    // while an insertion owns the page's native undo manager. Retain a generous
    // but finite burst so a stuck framework transaction cannot grow memory
    // without bound.
private static let maximumPendingHistoryCommandCount = 64
private static let transientViewportPublicationInterval = Duration.milliseconds(50)
private static let zoomPresentationReleaseDelay = Duration.milliseconds(140)
    // Discrete keyboard/accessibility zoom commands do not provide a native
    // begin/end gesture lifecycle. Keep their one bounded freeform composite
    // alive across the short pauses between repeated endpoint commands, then
    // restore live PaperKit only after genuine idle. Pencil contact bypasses
    // this delay in `contactDidBegin()` so drawing is never raster-backed.
private static let programmaticFreeformZoomSettlementDelay = Duration.milliseconds(1_800)
private static let zoomPresentationMaximumPixelDimension: CGFloat = 1_024
private static let imagePlaygroundMinimumSourceDimension = 384
private static let imagePlaygroundMaximumSourceDimension = 1_024
private static let minimumInteractiveTableCellDimension: CGFloat = 24
private static let tableAccessibilityMoveStep: CGFloat = 12
private static let tableAccessibilityResizeStep: CGFloat = 6
private static var hasRegisteredHistoryGestureConflictWithZoom = false
private var virtualizesPageHosts: Bool {
    documentMode == .paged && pages.count > Self.maximumEagerPageHostCount
}
#if DEBUG
enum TableGrowthAxisForTesting: Equatable {
    case rows
    case columns
}

enum SerializedInsertionFailureForTesting: Equatable, Sendable {
    case redoSerialization
    case retainedHostValidation
}

var pageSnapshotsForTesting: [CanvasPageSnapshot] { pages }
var isReaderModeEnabledForTesting: Bool { isReaderModeEnabled }
func pageHostIsEditableForTesting(pageID: UUID) -> Bool? {
    hostsByPageID[pageID]?.controller.isEditable
}

func pageHostInteractionIsEnabledForTesting(pageID: UUID) -> Bool? {
    hostsByPageID[pageID]?.controller.view.isUserInteractionEnabled
}

func pageUndoEditingInteractionConfigurationForTesting(
    pageID: UUID
) -> UIEditingInteractionConfiguration? {
    hostsByPageID[pageID]?.undoController.editingInteractionConfiguration
}

var threeFingerHistoryGestureRecognizersForTesting: [UISwipeGestureRecognizer] {
    [threeFingerUndoSwipeGestureRecognizer, threeFingerRedoSwipeGestureRecognizer]
}

func performThreeFingerHistorySwipeForTesting(
    _ direction: UISwipeGestureRecognizer.Direction
) {
    performThreeFingerHistorySwipe(direction)
}

var insertionContextIdentifierForTesting: ObjectIdentifier {
    ObjectIdentifier(Self.sharedInsertionContext)
}

var activeGeometryToolForTesting: CanvasGeometryTool? { activeGeometryTool }
var geometryInstrumentViewForTesting: CanvasGeometryInstrumentView {
    geometryInstrumentView
}

func tablesForTesting(pageID: UUID) -> [CanvasTable] {
    pages.first(where: { $0.id == pageID })?.tables ?? []
}
@discardableResult
func addRowToActiveTableForTesting() -> Bool {
    growActiveTable(axis: .rows)
}

@discardableResult
func addColumnToActiveTableForTesting() -> Bool {
    growActiveTable(axis: .columns)
}
@discardableResult
func moveActiveTableForTesting(by delta: CGSize) -> Bool {
    moveActiveTable(by: delta)
}
@discardableResult
func resizeActiveTableForTesting(byCellDelta delta: CGSize) -> Bool {
    resizeActiveTable(byCellDelta: delta)
}
var tableTransformControlFramesForTesting: (move: CGRect?, resize: CGRect?) {
    tableInteractionView.transformControlFrames
}
var tableResizeGripFramesForTesting: (visual: CGRect?, hit: CGRect?) {
    tableInteractionView.resizeGripFrames
}
var tableVisibleAffordanceIdentifiersForTesting: [String] {
    tableInteractionView.visibleAffordanceIdentifiers
}
var tableHasContextInteractionForTesting: Bool {
    tableInteractionView.hasContextInteraction
}
func tableContextActionNamesForTesting() -> [String] {
    tableInteractionView.contextActionNames
}
var minimumInteractiveTableCellDimensionForTesting: CGFloat {
    Self.minimumInteractiveTableCellDimension
}
static var maximumUndoLevelCountPerPageForTesting: Int {
    maximumUndoLevelCountPerPage
}
static var maximumRetainedUndoPageHostCountForTesting: Int {
    maximumRetainedUndoPageHostCount
}
var retainedProgrammaticInsertionCountForTesting: Int {
    retainedProgrammaticInsertionCosts.count
}
var retainedProgrammaticInsertionImageBytesForTesting: Int {
    retainedProgrammaticInsertionImageBytes
}
var retainedProgrammaticInsertionTextBytesForTesting: Int {
    retainedProgrammaticInsertionTextBytes
}
func setProgrammaticInsertionRetentionLimitsForTesting(
    count: Int? = nil,
    imageCount: Int? = nil,
    imageBytes: Int? = nil,
    singleTextBytes: Int? = nil,
    textBytes: Int? = nil
) {
    maximumRetainedProgrammaticInsertionCountForTesting = count
    maximumRetainedProgrammaticInsertionImageCountForTesting = imageCount
    maximumRetainedProgrammaticInsertionImageBytesForTesting = imageBytes
    maximumSingleProgrammaticInsertionTextBytesForTesting = singleTextBytes
    maximumRetainedProgrammaticInsertionTextBytesForTesting = textBytes
}
func setMaximumAppOwnedUndoActionSerializedByteCountForTesting(
    _ byteCount: Int?
) {
    maximumAppOwnedUndoActionSerializedByteCountForTesting = byteCount
}
func tableTransformAccessibilityActionNamesForTesting() -> (
    move: [String],
        resize: [String]
) {
    refreshTableAccessibilityElements()
    let move = activeTableTarget.flatMap { target in
        tableAccessibilityElementsByKey[
            TableAccessibilityKey(pageID: target.pageID, tableID: target.tableID)
        ]?.accessibilityCustomActions?.map(\.name).filter {
            $0.hasPrefix("Move ")
        } ?? []
    }
    return (
        move: move ?? [],
        resize: tableInteractionView.transformAccessibilityActionNames.resize
    )
}
@discardableResult
func selectTableForTesting(
    pageID: UUID,
    tableID: UUID
) -> Bool {
    return activateAccessibleTable(pageID: pageID, tableID: tableID)
}
    var tableSelectionControlsAreVisibleForTesting: Bool {
        tableInteractionView.controlsAreVisible
    }
    var selectedTableFrameForTesting: CGRect? {
        tableInteractionView.selectedTableFrame
    }
    func tableAccessibilityElementCountForTesting() -> Int {
        refreshTableAccessibilityElements()
        return tableAccessibilityElementsByKey.count
    }
    func tableAccessibilityValueForTesting(
        pageID: UUID,
        tableID: UUID
    ) -> String? {
        refreshTableAccessibilityElements()
        return tableAccessibilityElementsByKey[
            TableAccessibilityKey(pageID: pageID, tableID: tableID)
        ]?.accessibilityValue
    }
    func tableAccessibilityActionNamesForTesting(
        pageID: UUID,
        tableID: UUID
    ) -> [String] {
        refreshTableAccessibilityElements()
        return tableAccessibilityElementsByKey[
            TableAccessibilityKey(pageID: pageID, tableID: tableID)
        ]?.accessibilityCustomActions?.map(\.name) ?? []
    }
    @discardableResult
    func activateTableAccessibilityElementForTesting(
        pageID: UUID,
        tableID: UUID
    ) -> Bool {
        refreshTableAccessibilityElements()
        return tableAccessibilityElementsByKey[
            TableAccessibilityKey(pageID: pageID, tableID: tableID)
        ]?.accessibilityActivate() ?? false
    }
    @discardableResult
    func performTableAccessibilityGrowthForTesting(
        pageID: UUID,
        tableID: UUID,
        axis: TableGrowthAxisForTesting
    ) -> Bool {
refreshTableAccessibilityElements()
guard let element = tableAccessibilityElementsByKey[
TableAccessibilityKey(pageID: pageID, tableID: tableID)
] else { return false }
switch axis {
case .rows:
return element.performAddRowForTesting()
case .columns:
return element.performAddColumnForTesting()
}
}
private(set) var lastNativeBasisResetReachedIdentityForTesting = true
@discardableResult
func expandFreeformCanvasForTesting(visibleRect: CGRect) -> Bool {
expandFreeformCanvasIfNeeded(visibleRect: visibleRect)
}
private var isContactForcedForTesting = false
private var nextSerializedInsertionFailureForTesting: SerializedInsertionFailureForTesting?
private var shouldPauseNextSerializedInsertionForTesting = false
private var pausedSerializedInsertionContinuationForTesting: CheckedContinuation<Void, Never>?
private var maximumRetainedProgrammaticInsertionCountForTesting: Int?
private var maximumRetainedProgrammaticInsertionImageCountForTesting: Int?
private var maximumRetainedProgrammaticInsertionImageBytesForTesting: Int?
private var maximumRetainedProgrammaticInsertionTextBytesForTesting: Int?
private var maximumSingleProgrammaticInsertionTextBytesForTesting: Int?
private var maximumAppOwnedUndoActionSerializedByteCountForTesting: Int?
#endif

private var pageSizes: [CGSize] { pages.map(\.displaySize) }
private var cachedLayoutPlan: CanvasStackLayout.LayoutPlan?
private var layoutPlan: CanvasStackLayout.LayoutPlan {
    if let cachedLayoutPlan { return cachedLayoutPlan }
    let plan = CanvasStackLayout.layoutPlan(
        pageSizes: pageSizes,
        pageLayout: pageLayout,
        horizontalPageStride: horizontalPageStride
    )
    cachedLayoutPlan = plan
    return plan
}

private func invalidateLayoutPlan() {
cachedLayoutPlan = nil
}
// Horizontal notebooks use the Photos-style resting scale as their
// minimum: one complete sheet remains visible, while pinching in still
// gives writing the full 1000% zoom range.
private var horizontalPageFitScale: CGFloat {
guard documentMode == .paged,
pageLayout.scrollDirection == .horizontal,
pageSizes.isEmpty == false else {
return CanvasConstants.defaultZoomScale
}
let viewport = CanvasStackLayout.unobscuredViewportRect(
viewportSize: scrollView.bounds.size,
safeAreaInsets: view.safeAreaInsets,
topChromeHeight: topChromeHeight
)
guard viewport.width > 0, viewport.height > 0 else {
return CanvasConstants.defaultZoomScale
}
let maximumWidth = pageSizes.map(\.width).max()
    ?? CanvasConstants.a4PortraitSize.width
let maximumHeight = pageSizes.map(\.height).max()
?? CanvasConstants.a4PortraitSize.height
let scale = min(
CanvasConstants.defaultZoomScale,
viewport.width / max(maximumWidth, 1),
viewport.height / max(maximumHeight, 1)
)
return CanvasZoom.clampedScale(scale)
}
// Keeps adjacent horizontal pages in separate viewport-sized slots.
// CanvasStackLayout still stores authored page frames, so the stride is
// converted back from screen points using the resting fit scale.
private var horizontalPageStride: CGFloat? {
guard documentMode == .paged,
pageLayout.scrollDirection == .horizontal else { return nil }
let viewport = CanvasStackLayout.unobscuredViewportRect(
viewportSize: scrollView.bounds.size,
safeAreaInsets: view.safeAreaInsets,
topChromeHeight: topChromeHeight
)
guard viewport.width > 0 else { return nil }
return (viewport.width + CanvasConstants.pageGap) / horizontalPageFitScale
}

private var minimumLogicalZoomScale: CGFloat {
guard documentMode == .paged,
pageLayout.scrollDirection == .horizontal else {
return CanvasConstants.absoluteZoomRange.lowerBound
}
return max(
CanvasConstants.absoluteZoomRange.lowerBound,
horizontalPageFitScale
)
}

private func viewportForCurrentPageMode(
_ viewport: CanvasViewportState,
prefersHorizontalFit: Bool
) -> CanvasViewportState {
guard documentMode == .paged,
pageLayout.scrollDirection == .horizontal else { return viewport }
let requestedScale = viewport.stackZoomScale
let fitScale = minimumLogicalZoomScale
let shouldFit = requestedScale < fitScale - 0.0001
|| prefersHorizontalFit
guard shouldFit else { return viewport }
usesHorizontalPageFit = true
var fittedViewport = CanvasViewportState.stackViewport(
zoomScale: fitScale,
normalizedCenterX: 0.5,
normalizedCenterY: 0.5
)
fittedViewport.usesFitPage = true
return fittedViewport
}
private func shouldRestoreHorizontalPageFit(
from viewport: CanvasViewportState
) -> Bool {
guard documentMode == .paged,
pageLayout.scrollDirection == .horizontal else { return false }
if viewport.usesFitPage { return true }
let requestedScale = viewport.stackZoomScale
let fitScale = minimumLogicalZoomScale
if requestedScale < fitScale - 0.0001 { return true }
// Settled fit-page viewports are persisted as an explicit scale. A
// centered viewport at that exact scale is the recoverable signature;
// other explicit zooms and panned anchors remain user-authored.
let isCentered = abs(viewport.normalizedCenterX - 0.5) < 0.001
&& abs(viewport.normalizedCenterY - 0.5) < 0.001
return isCentered && abs(requestedScale - fitScale) < 0.005
}
// Restores the viewport and its presentation intent as one state. Every
// path that adopts persisted page state must use this helper so an older
// page's fit bit cannot leak into the newly focused page.
private func restoredViewportForCurrentPageMode(
_ viewport: CanvasViewportState
) -> CanvasViewportState {
usesHorizontalPageFit = shouldRestoreHorizontalPageFit(from: viewport)
return viewportForCurrentPageMode(
viewport,
prefersHorizontalFit: usesHorizontalPageFit
)
}
init(
pages: [CanvasPageSnapshot],
currentPageID: UUID,
viewport: CanvasViewportState,
inputMode: CanvasInputMode,
pageLayout: CanvasPageLayoutPreferences = .default,
documentMode: CanvasDocumentMode = .paged,
callbacks: PaperCanvasCallbacks
) {
let allValidPages = pages.filter { page in
let tablesAreValid = Set(page.tables.map { table in table.id }).count
== page.tables.count
&& page.tables.allSatisfy { table in
table.isValid(in: page.markup.bounds)
}
return page.markup.bounds.origin == .zero
&& page.geometry.isValid
&& page.background.isValid
&& page.markup.bounds.size == page.geometry.displaySize
&& tablesAreValid
}
let validPages: [CanvasPageSnapshot]
if documentMode == .freeform,
let board = allValidPages.first(where: { $0.id == currentPageID })
?? allValidPages.first {
validPages = [board]
} else {
validPages = allValidPages
}
self.documentMode = documentMode
if validPages.isEmpty {
let size = documentMode == .freeform
? CanvasConstants.freeformInitialSize
: CanvasConstants.a4PortraitSize
let markup = PaperMarkup(
bounds: CGRect(origin: .zero, size: size)
)
let page = CanvasPageSnapshot(id: currentPageID, markup: markup)
self.pages = [page]
focusedPageID = page.id
} else {
self.pages = validPages
focusedPageID = validPages.contains(where: { $0.id == currentPageID })
? currentPageID
: validPages[0].id
}
initialViewport = viewport.isValid ? viewport : CanvasViewportState()
self.inputMode = inputMode
self.pageLayout = documentMode == .paged
? pageLayout.singlePageOnly
: .default
self.callbacks = callbacks
super.init(nibName: nil, bundle: nil)
}
convenience init(
pageID: UUID,
markup: PaperMarkup,
viewport: CanvasViewportState,
inputMode: CanvasInputMode,
pageLayout: CanvasPageLayoutPreferences = .default,
documentMode: CanvasDocumentMode = .paged,
callbacks: PaperCanvasCallbacks
) {
self.init(
pages: [ CanvasPageSnapshot(
id: pageID,
markup: markup,
viewport: viewport
)
],
currentPageID: pageID,
viewport: viewport,
inputMode: inputMode,
pageLayout: pageLayout,
documentMode: documentMode,
callbacks: callbacks
)
}
@available(*, unavailable)
required init?(coder: NSCoder) {
return nil
}
override func viewDidLoad() {
super.viewDidLoad()
if isObservingUndoGroupClosure == false {
NotificationCenter.default.addObserver(
self,
selector: #selector(undoManagerDidCloseGroup(_:)),
name: .NSUndoManagerDidCloseUndoGroup,
object: nil
)
}
isObservingUndoGroupClosure = true
view.backgroundColor = CanvasConstants.workspaceBackground(for: documentMode)
configureOuterScrollView()
view.addInteraction(pencilInteraction)
configureContactMonitor()
configureThreeFingerHistoryGestures()
configureLaserPointer()
configureGeometryInstrument()
configureRegionSelection()
configureTableInteraction()
renderedZoomScale = resolvedNativeRenderScale(
for: initialViewport.stackZoomScale
)
rebuildAllPageHosts()
publishUndoAvailability()
}
override func viewDidLayoutSubviews() {
super.viewDidLayoutSubviews()
defer {
refreshRegionSelectionPresentation()
refreshTableAccessibilityElements()
}
let environment = currentViewportEnvironment
guard environment.size.width > 0, environment.size.height > 0 else { return }
if hasAppliedInitialViewport == false {
hasAppliedInitialViewport = true
invalidateLayoutPlan()
applyViewport(
restoredViewportForCurrentPageMode(initialViewport),
focusedOn: focusedPageID
)
settledEnvironment = environment
return
}
guard isApplyingGeometry == false, settledEnvironment != environment else { return }
let retainedPageID = lastPublishedViewportPageID.flatMap { id in
pages.contains(where: { $0.id == id }) ? id : nil
} ?? focusedPageID
let retainedViewport = lastPublishedViewport ?? currentViewportState()
settledEnvironment = environment
setFocusedPage(retainedPageID, fromDirectInteraction: false)
invalidateLayoutPlan()
applyViewport(
viewportForCurrentPageMode(
retainedViewport,
prefersHorizontalFit: usesHorizontalPageFit
),
focusedOn: retainedPageID
)
}
override func viewSafeAreaInsetsDidChange() {
super.viewSafeAreaInsetsDidChange()
guard hasAppliedInitialViewport else { return }
view.setNeedsLayout()
}
override func didReceiveMemoryWarning() {
super.didReceiveMemoryWarning()
isUnderMemoryPressure = true
// Pressure is transient. Leaving the flag set would disable prefetch and
// discard undo history on every eviction for the rest of the session.
Task { @MainActor [weak self] in
try? await Task.sleep(for: .seconds(10))
self?.isUnderMemoryPressure = false
}
cancelProgrammaticFreeformZoomSettlement()
endInteractiveZoomPresentation()
    guard hasActiveContact == false,
        scrollView.isZooming == false,
        isZoomScrubbing == false else {
        shouldSettleTransientZoomAfterContact = true
        return
    }
    guard hasAppliedInitialViewport else { return }
    let retainedPageID = focusedPageID
    let retainedViewport = currentViewportState()
    applyViewport(retainedViewport, focusedOn: retainedPageID, preserveFocusedPage: true)
    }

    func updateCallbacks(_ callbacks: PaperCanvasCallbacks) {
        self.callbacks = callbacks
    }

    func updateTopChromeHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0,
              abs(topChromeHeight - height) > 0.5 else { return }
        topChromeHeight = height
        geometryInstrumentView.topChromeHeight = height
        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0,
              hasActiveContact == false else { return }
        let viewport = currentViewportState()
        applyViewport(viewport, focusedOn: focusedPageID, preserveFocusedPage: true)
    }

    /// Stops presentation-only work when SwiftUI retires this controller. An
    /// accepted insertion tail is deliberately left running so the editor model
    /// can drain and snapshot it after detachment.
    func prepareForDismantle() {
        guard hasCompletedDismantle == false else { return }
        if isObservingUndoGroupClosure {
            NotificationCenter.default.removeObserver(
                self,
                name: .NSUndoManagerDidCloseUndoGroup,
                object: nil
            )
            isObservingUndoGroupClosure = false
        }
        resetRegionSelection()
        cancelBoundaryPagePullGesture()
        threeFingerUndoSwipeGestureRecognizer.isEnabled = false
        threeFingerRedoSwipeGestureRecognizer.isEnabled = false
        transientViewportPublicationToken &+= 1
        transientViewportPublicationTask?.cancel()
        transientViewportPublicationTask = nil
        transientViewportPublicationPending = false
        cancelProgrammaticFreeformZoomSettlement()
        endInteractiveZoomPresentation()
        laserPointerView.cancel()
    }

    /// Called by the editor model only after it has captured the retiring
    /// controller's final stable document. PaperKit currently installs private
// is no public unregister API, so sever every public ownership edge and
// UIKit containment boundary to ensure any framework-retained helper
// cannot retain document data or the live view hierarchy.
func completeDismantle() {
guard hasCompletedDismantle == false else { return }
prepareForDismantle()
hasCompletedDismantle = true
scrollView.delegate = nil
contactMonitor.isEnabled = false
contactMonitor.onContactBegan = nil
contactMonitor.onContactEnded = nil
contactMonitor.shouldTrackDirectTouches = { false }
pencilInteraction.delegate = nil
view.removeInteraction(pencilInteraction)
insertionHistoryTask?.cancel()
insertionHistoryTask = nil
for task in insertionHistoryTasksByAcceptanceSequence.values {
task.cancel()
insertionHistoryTasksByAcceptanceSequence.removeAll(keepingCapacity: false)
}
queuedInsertionCountByPageID.removeAll(keepingCapacity: false)
retainedProgrammaticInsertionCosts.removeAll(keepingCapacity: false)
retainedProgrammaticInsertionImageCount = 0
retainedProgrammaticInsertionImageBytes = 0
retainedProgrammaticInsertionTextBytes = 0
pagesPreparingInsertionHistory.removeAll(keepingCapacity: false)
pendingInsertions.removeAll(keepingCapacity: false)
pendingPageCommands.removeAll(keepingCapacity: false)
pendingHistoryCommands.removeAll(keepingCapacity: false)
pendingPaperTemplates.removeAll(keepingCapacity: false)
let mountedPageIDs = Array(hostsByPageID.keys)
for pageID in mountedPageIDs {
hostsByPageID[pageID]?.controller.undoManager?.removeAllActions()
_ = detachPageHost(id: pageID)
}
        pageIDByController.removeAll(keepingCapacity: false)
        pendingAppUndoRegistrations.removeAll(keepingCapacity: false)
        undoManagersFlushingAppRegistrations.removeAll(keepingCapacity: false)
        undoHistoryPageRecency.removeAll(keepingCapacity: false)
    }

    @discardableResult
    func setReaderModeEnabled(_ isEnabled: Bool) -> Bool {
        guard isReaderModeEnabled != isEnabled else { return true }
        if isEnabled {
            guard hasActiveContact == false,
                hasPendingProgrammaticInsertions == false,
                pendingPageCommands.isEmpty,
                pendingHistoryCommands.isEmpty,
                pendingPaperTemplates.isEmpty,
                pendingAppUndoRegistrations.values.allSatisfy(\.isEmpty),
                undoManagersFlushingAppRegistrations.isEmpty,
                hostsByPageID.values.allSatisfy({
                    ($0.controller.undoManager?.groupingLevel ?? 0) == 0
                }),
                tableTransformSession == nil else { return false }
        }

        isReaderModeEnabled = isEnabled
        if isEnabled {
            view.endEditing(true)
            // Text editing can commit its final native markup while resigning
            // first responder. Pull that value into the controller-owned page
            // snapshots before the model performs its post-lock capture.
            deliverAllChangedMarkup()
            resetRegionSelection()
            cancelBoundaryPagePullGesture()
            if tableTransformSession != nil { cancelTableTransform() }
            clearActiveTableTarget()
        }
        refreshInteractionPolicy()
        return true
    }

    /// Recomputes every authoring affordance from retained editor state. Reader
    /// Mode suppresses presentation only; the selected tool, input preference,
    /// ruler choice, and undo stacks remain untouched for a lossless return.
    private func refreshInteractionPolicy() {
        let hasAppliedTool = appliedToolState != nil
        let laserIsSelected = appliedToolState?.activeTool == .laserPointer
        let laserIsActive = isReaderModeEnabled == false && laserIsSelected
        let regionSelectionIsActive = regionSelectionInteractionSnapshot != nil
        let pageInteractionIsEnabled = isReaderModeEnabled == false
            && laserIsActive == false
            && regionSelectionIsActive == false
            && isDocumentSynchronizationPending == false

        contactMonitor.isEnabled = isReaderModeEnabled == false
        threeFingerUndoSwipeGestureRecognizer.isEnabled = isReaderModeEnabled == false
        threeFingerRedoSwipeGestureRecognizer.isEnabled = isReaderModeEnabled == false
        pencilInteraction.isEnabled = isReaderModeEnabled == false
        for host in hostsByPageID.values {
            host.controller.isEditable = pageInteractionIsEnabled
            host.controller.view.isUserInteractionEnabled = pageInteractionIsEnabled
        }

        if laserIsActive, let appliedToolState {
            laserPointerGestureRecognizer.isEnabled = true
            laserPointerView.activate(
                style: appliedToolState.laserPointerStyle,
                color: appliedToolState.configuration(for: .laserPointer)?.color.uiColor
            )
        } else {
            laserPointerGestureRecognizer.isEnabled = false
            laserPointerView.cancel()
            laserPointerView.deactivate()
        }

        geometryInstrumentView.setTool(isReaderModeEnabled ? nil : activeGeometryTool)
        geometryInstrumentView.isUserInteractionEnabled = isReaderModeEnabled == false
            && regionSelectionIsActive == false
        tableSelectionTapGestureRecognizer.isEnabled = isReaderModeEnabled == false
            && regionSelectionIsActive == false
            && laserIsActive == false
        tableHoverGestureRecognizer.isEnabled = tableSelectionTapGestureRecognizer.isEnabled
        tableInteractionView.isUserInteractionEnabled = tableSelectionTapGestureRecognizer.isEnabled
        tableInteractionView.isHidden = isReaderModeEnabled

        if hasAppliedTool == false, isReaderModeEnabled == false {
            laserPointerGestureRecognizer.isEnabled = false
        }
        synchronizeRulerState()
        configureOuterPanForInputMode()
        refreshTableAccessibilityElements()
    }

    /// A replacement controller must not accept edits until it has adopted the
    /// model's authoritative snapshot; strokes drawn earlier would be
    /// overwritten by the synchronization.
    func setDocumentSynchronizationPending(_ isPending: Bool) {
        guard isDocumentSynchronizationPending != isPending else { return }
        isDocumentSynchronizationPending = isPending
        // Before the view loads there is nothing to lock yet; the flag is
        // honored by the first `refreshInteractionPolicy()` after load.
        guard isViewLoaded else { return }
        refreshInteractionPolicy()
    }

    func applyToolState(_ state: CanvasToolState) {
        guard state.hasValidConfigurations else { return }
        if hasActiveContact {
            pendingToolState = state
            return
        }
        guard appliedToolState != state else { return }

        let nativeTool = CanvasNativeToolMapper.nativeTool(for: state)
        let isLaserPointerActive = state.activeTool == .laserPointer
        if isLaserPointerActive, tableTransformSession != nil {
            cancelTableTransform()
        }
        for host in hostsByPageID.values {
            if let nativeTool { host.controller.drawingTool = nativeTool }
            host.controller.isEditable = isLaserPointerActive == false
            // `isEditable` stops markup changes, but PaperKit's own viewport
            // gestures remain live. Freeze the page host so a one-contact
            // laser trace cannot pan its content; the recognizer on our root
            // view and the outer two-contact navigation gestures stay active.
            host.controller.view.isUserInteractionEnabled = isLaserPointerActive == false
        }
        appliedToolState = state
        if isLaserPointerActive {
            laserPointerGestureRecognizer.isEnabled = true
            laserPointerView.activate(
                style: state.laserPointerStyle,
                color: state.configuration(for: .laserPointer)?.color.uiColor
            )
        } else {
            laserPointerGestureRecognizer.isEnabled = false
            laserPointerView.deactivate()
        }
        if regionSelectionInteractionSnapshot != nil {
            laserPointerGestureRecognizer.isEnabled = false
            tableSelectionTapGestureRecognizer.isEnabled = false
            tableHoverGestureRecognizer.isEnabled = false
            for host in hostsByPageID.values {
                host.controller.view.isUserInteractionEnabled = false
            }
        } else {
            tableSelectionTapGestureRecognizer.isEnabled = isLaserPointerActive == false
            tableHoverGestureRecognizer.isEnabled = isLaserPointerActive == false
        }
        refreshTableAccessibilityElements()
        configureOuterPanForInputMode()
        refreshInteractionPolicy()
    }

    func applyInputMode(_ mode: CanvasInputMode) {
        if hasActiveContact {
            pendingInputMode = mode
            return
        }
        guard appliedInputMode != mode else { return }
        inputMode = mode
        for host in hostsByPageID.values {
            applyInputMode(mode, to: host.controller)
        }
        configureOuterPanForInputMode()
        appliedInputMode = mode
        refreshTableAccessibilityElements()
        refreshInteractionPolicy()
    }

    func setPageLayout(_ layout: CanvasPageLayoutPreferences) {
        guard documentMode == .paged else { return }
        let normalizedLayout = layout.singlePageOnly
        if hasActiveContact {
            pendingPageLayout = normalizedLayout
            return
        }
        guard pageLayout != normalizedLayout else { return }

        let wasHorizontal = pageLayout.scrollDirection == .horizontal
        let retainedPageID = focusedPageID
        let retainedViewport = hasAppliedInitialViewport
            ? currentViewportState()
            : initialViewport
        cancelBoundaryPagePullGesture()
        pageLayout = normalizedLayout
        invalidateLayoutPlan()
        configureScrollAxes()

        if normalizedLayout.scrollDirection == .horizontal {
            // Enter the pager at its full-sheet resting state for ordinary
            // <=100% notebook views. Deliberately magnified views retain their
            // authored zoom and anchor.
            if wasHorizontal == false {
                usesHorizontalPageFit = retainedViewport.stackZoomScale
                    <= CanvasConstants.defaultZoomScale + 0.0001
            }
        } else {
            usesHorizontalPageFit = false
        }

        guard isViewLoaded, hasAppliedInitialViewport else {
            initialViewport = retainedViewport
            return
        }
        applyViewport(
            viewportForCurrentPageMode(
                    retainedViewport,
                prefersHorizontalFit: usesHorizontalPageFit
            ),
            focusedOn: retainedPageID,
            preserveFocusedPage: true
        )
    }

    func setGeometryTool(_ tool: CanvasGeometryTool?) {
        if hasActiveContact {
            pendingGeometryToolUpdate = .set(tool)
            return
        }
        guard activeGeometryTool != tool else { return }
        activeGeometryTool = tool
        synchronizeRulerState()
        geometryInstrumentView.setTool(isReaderModeEnabled ? nil : tool)
    }

    func setRulerActive(_ isActive: Bool) {
        setGeometryTool(isActive ? .ruler : nil)
    }

    @discardableResult
    func setZoomScale(_ requestedScale: CGFloat) -> CGFloat {
        let requestedScale = CanvasZoom.clampedScale(requestedScale)
        let scale = max(
            requestedScale,
            minimumLogicalZoomScale
        )
        if documentMode == .paged,
            pageLayout.scrollDirection == .horizontal,
            scrollView.bounds.width > 0,
            scrollView.bounds.height > 0 {
            usesHorizontalPageFit = abs(scale - minimumLogicalZoomScale) < 0.0001
        }
        if hasActiveContact {
            pendingZoomScale = scale
            return scale
        }

        let retainedViewport = hasAppliedInitialViewport
            ? currentViewportState()
            : initialViewport
        let viewport = CanvasViewportState.stackViewport(
            zoomScale: scale,
            normalizedCenterX: CGFloat(retainedViewport.normalizedCenterX),
            normalizedCenterY: CGFloat(retainedViewport.normalizedCenterY)
        )

        guard hasAppliedInitialViewport else {
            initialViewport = viewport
            return scale
        }
        guard abs(effectiveZoomScale - scale) > 0.0001 else {
            // The model may have optimistically displayed the requested value
            // before this controller enforced the horizontal fit minimum.
            // Publish the authoritative viewport even though UIKit has no
            // geometry work to perform.
            if abs(requestedScale - scale) > 0.0001 {
                lastPublishedViewport = nil
                lastPublishedViewportPageID = nil
                publishViewport()
            }
            return scale
        }
        if isZoomScrubbing {
            applyTransientZoom(viewport, focusedOn: focusedPageID)
        } else if documentMode == .freeform {
            beginInteractiveZoomPresentation()
            applyTransientZoom(viewport, focusedOn: focusedPageID)
            scheduleProgrammaticFreeformZoomSettlement()
        } else {
            applyViewport(viewport, focusedOn: focusedPageID, preserveFocusedPage: true)
        }
        return scale
    }

    func beginZoomScrubbing() {
        guard isZoomScrubbing == false else { return }
        cancelProgrammaticNavigationForDirectInteraction()
        cancelProgrammaticFreeformZoomSettlement()
        isZoomScrubbing = true
        cancelBoundaryPagePullGesture()
        beginInteractiveZoomPresentation()
        callbacks.zoomInteractionChanged(true)
    }

    func endZoomScrubbing() {
        guard isZoomScrubbing else { return }
        isZoomScrubbing = false
        settleTransientZoom()
        flushTransientViewportPublication()
        scheduleEndInteractiveZoomPresentation()
        callbacks.zoomInteractionChanged(false)
    }

    func setPaperTemplate(_ template: CanvasPaperTemplate, for pageID: UUID) {
        guard isReaderModeEnabled == false,
            pages.contains(where: { $0.id == pageID }) else { return }
        if hasActiveContact
            || pagesPreparingInsertionHistory.contains(pageID)
            || queuedInsertionCountByPageID[pageID, default: 0] > 0 {
            pendingPaperTemplates[pageID] = template
            return
        }
        pendingPaperTemplates.removeValue(forKey: pageID)
        performPaperTemplateChange(template, for: pageID, registersUndo: true)
    }

    func insertPage(_ page: CanvasPageSnapshot, at index: Int, scrollTo: Bool) {
        insertPage(page, at: index, scrollTo: scrollTo, animated: false)
    }

    func insertPage(
        _ page: CanvasPageSnapshot,
        at index: Int,
        scrollTo: Bool,
        animated: Bool
    ) {
        guard documentMode == .paged, isReaderModeEnabled == false else { return }
        guard page.markup.bounds.origin == .zero,
            page.geometry.isValid,
            page.background.isValid,
            page.markup.bounds.size == page.geometry.displaySize,
            pages.contains(where: { $0.id == page.id }) == false else { return }
        if hasActiveContact
            || pagesPreparingInsertionHistory.isEmpty == false
            || queuedInsertionCountByPageID.isEmpty == false {
            pendingPageCommands.append(
                .insert(page, index: index, scrollTo: scrollTo, animated: animated)
            )
            return
        }
        performPageInsertion(page, at: index, scrollTo: scrollTo, animated: animated)
    }

    @discardableResult
    func removePage(id: UUID, focusOn pageID: UUID) -> Bool {
        guard documentMode == .paged,
            isReaderModeEnabled == false,
            pages.count > 1,
            id != pageID,
            pages.contains(where: { $0.id == id }),
            pages.contains(where: { $0.id == pageID }),
            hasActiveContact == false,
            pagesPreparingInsertionHistory.isEmpty,
            queuedInsertionCountByPageID[id, default: 0] == 0,
            hasPendingAppUndoRegistration(for: id) == false else { return false }
        performPageRemoval(id: id, focusOn: pageID)
        return true
    }

    @discardableResult
    func reorderPages(_ orderedPageIDs: [UUID], focusOn pageID: UUID) -> Bool {
        guard documentMode == .paged,
            isReaderModeEnabled == false,
            hasActiveContact == false,
            pagesPreparingInsertionHistory.isEmpty,
            orderedPageIDs.count == pages.count,
            Set(orderedPageIDs).count == orderedPageIDs.count,
            Set(orderedPageIDs) == Set(pages.map(\.id)),
            orderedPageIDs.contains(pageID) else { return false }

        deliverAllChangedMarkup()
        captureAndPublishCurrentViewport()
        guard pages.map(\.id) != orderedPageIDs else {
            setFocusedPage(pageID, fromDirectInteraction: false)
            return true
        }

        let retainedViewport = currentViewportState()
        let pagesByID = Dictionary(
            pages.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        guard orderedPageIDs.allSatisfy({ pagesByID[$0] != nil }) else { return false }

        cancelBoundaryPagePullGesture()
        isApplyingGeometry = true
        pages = orderedPageIDs.compactMap { pagesByID[$0] }
        invalidateLayoutPlan()
        layoutDocumentAtRenderedScale()
        isApplyingGeometry = false

        lastPublishedViewport = nil
        lastPublishedViewportPageID = nil
        setFocusedPage(pageID, fromDirectInteraction: false)
        applyViewport(retainedViewport, focusedOn: pageID, preserveFocusedPage: true)
        return true
    }

    func replacePage(_ page: CanvasPageSnapshot) {
        guard isReaderModeEnabled == false,
            page.markup.bounds.origin == .zero,
            page.geometry.isValid,
            page.background.isValid,
            page.markup.bounds.size == page.geometry.displaySize,
            pages.contains(where: { $0.id == page.id }) else { return }
        if hasActiveContact
            || pagesPreparingInsertionHistory.contains(page.id)
            || queuedInsertionCountByPageID[page.id, default: 0] > 0 {
            pendingPageCommands.append(.replace(page))
            return
        }
        performPageReplacement(page, registersUndo: true)
    }

    func scrollToPage(id: UUID, animated: Bool) {
        guard let destinationIndex = pages.firstIndex(where: { $0.id == id }) else { return }
        if hasActiveContact {
            pendingPageCommands.append(.scroll(id, animated: animated))
            return
        }
        captureAndPublishCurrentViewport()
        let persistedViewport = pages[destinationIndex].viewport.isValid
            ? pages[destinationIndex].viewport
            : CanvasViewportState()
        setFocusedPage(id, fromDirectInteraction: false)
        applyViewport(
            restoredViewportForCurrentPageMode(persistedViewport),
            focusedOn: id,
            preserveFocusedPage: true,
            animated: animated
        )
    }

    func navigateToPageRegion(
        pageID: UUID,
        pageBounds: CGRect,
        animated: Bool
    ) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        if hasActiveContact {
            pendingPageCommands.append(
                .navigateToRegion(pageID, pageBounds, animated: animated)
            )
            return
        }

        let page = pages[index]
        let bounds = validPageRegionBounds(pageBounds, in: page.markup.bounds)
        guard let bounds else {
            scrollToPage(id: pageID, animated: animated)
            return
        }

        captureAndPublishCurrentViewport()
        let viewport = CanvasViewportState.stackViewport(
            zoomScale: effectiveZoomScale,
            normalizedCenterX: bounds.midX / page.displaySize.width,
            normalizedCenterY: bounds.midY / page.displaySize.height
        )
        setFocusedPage(pageID, fromDirectInteraction: false)
        applyViewport(
            restoredViewportForCurrentPageMode(viewport),
            focusedOn: pageID,
            preserveFocusedPage: true,
            animated: animated
        )
    }

    // MARK: - Controller attachment synchronization

    func synchronizeDocumentAfterAttachment(
        _ snapshot: CanvasDocumentSnapshot
    ) -> Bool {
        loadViewIfNeeded()
        guard hasActiveContact == false,
            hasPendingProgrammaticInsertions == false,
            pendingAppUndoRegistrations.isEmpty,
            undoManagersFlushingAppRegistrations.isEmpty,
            hostsByPageID.values.allSatisfy({
                ($0.controller.undoManager?.groupingLevel ?? 0) == 0
            }),
            snapshot.viewport.isValid,
            snapshot.pages.isEmpty == false,
            snapshot.pages.allSatisfy({ $0.viewport.isValid }),
            snapshot.pages.map(\.id) == pages.map(\.id),
            snapshot.pages.contains(where: { $0.id == snapshot.currentPageID }) else {
            return false
        }
        initialViewport = snapshot.viewport
        let restoredSnapshotViewport = restoredViewportForCurrentPageMode(
            snapshot.viewport
        )

        for desiredPage in snapshot.pages {
            guard let index = pages.firstIndex(where: { $0.id == desiredPage.id }) else {
                return false
            }
            let livePage = pages[index]
            let contentDiffers = livePage.markup != desiredPage.markup
                || livePage.tables != desiredPage.tables
                || livePage.paperTemplate != desiredPage.paperTemplate
                || livePage.geometry != desiredPage.geometry
                || livePage.background != desiredPage.background
            if contentDiffers {
                if hostsByPageID[desiredPage.id] != nil {
                    performPageReplacement(desiredPage, registersUndo: false)
                } else {
                    // A detached large-document page has no native state to
                    // reconcile. Keep it detached and hydrate its canonical
                    // snapshot directly; mounting it only to replace it would
                    // recreate the original thousand-controller startup cost.
                    pages[index] = desiredPage
                    invalidateLayoutPlan()
                }
            }
            guard let refreshedIndex = pages.firstIndex(where: { $0.id == desiredPage.id }) else {
                return false
            }
            if pages[refreshedIndex].viewport != desiredPage.viewport {
                pages[refreshedIndex] = pages[refreshedIndex].replacing(
                    viewport: desiredPage.viewport
                )
            }
        }
        setFocusedPage(snapshot.currentPageID, fromDirectInteraction: false)
        applyViewport(
            restoredSnapshotViewport,
            focusedOn: snapshot.currentPageID,
            preserveFocusedPage: true
        )

        return zip(pages, snapshot.pages).allSatisfy { livePage, desiredPage in
            livePage.id == desiredPage.id
                && livePage.markup == desiredPage.markup
                && livePage.tables == desiredPage.tables
                && livePage.paperTemplate == desiredPage.paperTemplate
                && livePage.geometry == desiredPage.geometry
                && livePage.background == desiredPage.background
        }
    }

    // Transitional command used by the former one-page-at-a-time model.
    func activatePage(id: UUID, markup: PaperMarkup, viewport: CanvasViewportState) {
        guard isReaderModeEnabled == false,
            markup.bounds.origin == .zero,
            markup.bounds.size == CanvasConstants.a4PortraitSize,
            viewport.isValid else { return }
        if hasActiveContact
            || pagesPreparingInsertionHistory.contains(id)
            || queuedInsertionCountByPageID[id, default: 0] > 0 {
            pendingPageCommands.append(.activate(id, markup, viewport))
            return
        }
        performLegacyActivation(id: id, markup: markup, viewport: viewport)
    }
    func performInsertion(_ insertion: CanvasInsertion) {
        performInsertion(insertion, on: focusedPageID)
    }
    func performInsertion(_ insertion: CanvasInsertion, on pageID: UUID) {
        guard isReaderModeEnabled == false else {
            callbacks.programmaticInsertionFailed(.controllerBusy)
            return
        }
        let acceptedInsertion: PendingProgrammaticInsertion
        do {
            acceptedInsertion = try acceptProgrammaticInsertion(insertion, on: pageID)
        } catch let error as PaperCanvasInsertionCommitError {
            callbacks.programmaticInsertionFailed(error)
            return
        } catch {
            callbacks.programmaticInsertionFailed(.controllerBusy)
            return
        }
        dispatchAcceptedProgrammaticInsertion(acceptedInsertion)
    }
    private func acceptProgrammaticInsertion(
        _ insertion: CanvasInsertion,
        on pageID: UUID
    ) throws -> PendingProgrammaticInsertion {
        guard programmaticInsertionAcceptanceSequence < UInt64.max,
            let retentionCost = Self.programmaticInsertionRetentionCost(
                for: insertion
            ),
            canRetainProgrammaticInsertion(retentionCost) else {
            throw PaperCanvasInsertionCommitError.controllerBusy
        }
        programmaticInsertionAcceptanceSequence += 1
        retainedProgrammaticInsertionCosts[
            programmaticInsertionAcceptanceSequence
        ] = retentionCost
        retainedProgrammaticInsertionImageCount += retentionCost.imageCount
        retainedProgrammaticInsertionImageBytes += retentionCost.imageBytes
        retainedProgrammaticInsertionTextBytes += retentionCost.textBytes
        return PendingProgrammaticInsertion(
            insertion: insertion,
            pageID: pageID,
            acceptanceSequence: programmaticInsertionAcceptanceSequence,
            retentionCost: retentionCost
        )
    }

    private static func programmaticInsertionRetentionCost(
        for insertion: CanvasInsertion
    ) -> ProgrammaticInsertionRetentionCost? {
        switch insertion {
            case let .image(image), let .positionedImage(image, _):
                guard image.width > 0, image.height > 0 else { return nil }
                let (decodedBytes, overflowed) = image.bytesPerRow
                    .multipliedReportingOverflow(by: image.height)
                guard overflowed == false, decodedBytes > 0 else { return nil }
                return ProgrammaticInsertionRetentionCost(
                    imageCount: 1,
                    imageBytes: decodedBytes,
                    textBytes: 0
                )
            case .text, .shape, .table, .circle:
                return ProgrammaticInsertionRetentionCost(
                    imageCount: 0,
                    imageBytes: 0,
                    textBytes: 0
                )
    }
    }
    private func canRetainProgrammaticInsertion(
        _ cost: ProgrammaticInsertionRetentionCost
    ) -> Bool {
        guard retainedProgrammaticInsertionCosts.count
            < effectiveMaximumRetainedProgrammaticInsertionCount,
            cost.textBytes
            <= effectiveMaximumSingleProgrammaticInsertionTextBytes else {
            return false
        }
        let (nextImageCount, imageCountOverflowed) =
            retainedProgrammaticInsertionImageCount.addingReportingOverflow(
                cost.imageCount
            )
        let (nextImageBytes, imageBytesOverflowed) =
            retainedProgrammaticInsertionImageBytes.addingReportingOverflow(
                cost.imageBytes
            )
        let (nextTextBytes, textBytesOverflowed) =
            retainedProgrammaticInsertionTextBytes.addingReportingOverflow(
                cost.textBytes
            )
        return imageCountOverflowed == false
            && imageBytesOverflowed == false
            && textBytesOverflowed == false
            && nextImageCount
            <= effectiveMaximumRetainedProgrammaticInsertionImageCount
            && nextImageBytes
            <= effectiveMaximumRetainedProgrammaticInsertionImageBytes
            && nextTextBytes
            <= effectiveMaximumRetainedProgrammaticInsertionTextBytes

    }
    private var effectiveMaximumRetainedProgrammaticInsertionCount: Int {
        #if DEBUG
        max(maximumRetainedProgrammaticInsertionCountForTesting
            ?? Self.maximumRetainedProgrammaticInsertionCount, 0)
        #else
        Self.maximumRetainedProgrammaticInsertionCount
        #endif
    }
    private var effectiveMaximumRetainedProgrammaticInsertionImageCount: Int {
        #if DEBUG
        max(maximumRetainedProgrammaticInsertionImageCountForTesting
            ?? Self.maximumRetainedProgrammaticInsertionImageCount, 0)
        #else
        Self.maximumRetainedProgrammaticInsertionImageCount
        #endif
    }
    private var effectiveMaximumRetainedProgrammaticInsertionImageBytes: Int {
        #if DEBUG
        max(maximumRetainedProgrammaticInsertionImageBytesForTesting
            ?? Self.maximumRetainedProgrammaticInsertionImageBytes, 0)
        #else
        Self.maximumRetainedProgrammaticInsertionImageBytes
        #endif
    }
    private var effectiveMaximumSingleProgrammaticInsertionTextBytes: Int {
        #if DEBUG
        max(maximumSingleProgrammaticInsertionTextBytesForTesting
            ?? Self.maximumSingleProgrammaticInsertionTextBytes, 0)
        #else
        Self.maximumSingleProgrammaticInsertionTextBytes
        #endif
    }
    private var effectiveMaximumRetainedProgrammaticInsertionTextBytes: Int {
        #if DEBUG
        max(maximumRetainedProgrammaticInsertionTextBytesForTesting
            ?? Self.maximumRetainedProgrammaticInsertionTextBytes, 0)
        #else
        Self.maximumRetainedProgrammaticInsertionTextBytes
        #endif
    }
    private func dispatchAcceptedProgrammaticInsertion(
        _ pendingInsertion: PendingProgrammaticInsertion
    ) {
        let insertion = pendingInsertion.insertion
        let pageID = pendingInsertion.pageID
        if let readinessBoundary = activeProgrammaticInsertionReadinessBoundary,
            pendingInsertion.acceptanceSequence > readinessBoundary {
            pendingInsertions.append(pendingInsertion)
            return
        }
        if hasActiveContact || pendingInsertions.isEmpty == false {
            pendingInsertions.append(pendingInsertion)
            return
        }
        if case let .table(size) = insertion {
            if pagesPreparingInsertionHistory.isEmpty == false
                || queuedInsertionCountByPageID.isEmpty == false {
                pendingInsertions.append(pendingInsertion)
                return
            }
            let previousTables = pages.first(where: { $0.id == pageID })?.tables
                ?? []
            insertTable(size: size, on: pageID)
            settleProgrammaticInsertion(pendingInsertion)
            guard let page = pages.first(where: { $0.id == pageID }),
                page.tables != previousTables else {
                callbacks.programmaticInsertionFailed(
                    .serializationOrHostValidationFailed
                )
                return
            }
            return
        }
        clearActiveTableTarget()
        guard let insertionTask = enqueueInsertionTask(pendingInsertion) else {
            settleProgrammaticInsertion(pendingInsertion)
            callbacks.programmaticInsertionFailed(
                .serializationOrHostValidationFailed
            )
            return
        }
        Task { @MainActor [weak self] in
            guard await insertionTask.value == false else { return }
            self?.callbacks.programmaticInsertionFailed(
                .serializationOrHostValidationFailed
            )
        }
    }
    func performInsertionWithReceipt(
        _ insertion: CanvasInsertion,
        on pageID: UUID
    ) async throws -> PaperCanvasInsertionReceipt {
        // Waiting across an active Pencil contact would leave a one-shot
        // producer with no bounded completion point. Let it retain the source
        // request and retry after the contact ends instead.
        guard isReaderModeEnabled == false,
            hasActiveContact == false,
            pendingInsertions.isEmpty,
            activeProgrammaticInsertionReadinessBoundary == nil else {
            throw PaperCanvasInsertionCommitError.controllerBusy
        }
        guard pages.contains(where: { $0.id == pageID }) else {
            throw PaperCanvasInsertionCommitError.pageUnavailable
        }
        if case let .table(size) = insertion {
            guard pagesPreparingInsertionHistory.isEmpty,
                queuedInsertionCountByPageID.isEmpty else {
                throw PaperCanvasInsertionCommitError.controllerBusy
            }
            let acceptedInsertion = try acceptProgrammaticInsertion(
                insertion,
                on: pageID
            )
            let previousTables = pages.first(where: { $0.id == pageID })?.tables
            insertTable(size: size, on: pageID)
            settleProgrammaticInsertion(acceptedInsertion)
            guard let page = pages.first(where: { $0.id == pageID }),
                page.tables != previousTables else {
                throw PaperCanvasInsertionCommitError.serializationOrHostValidationFailed
            }
            return PaperCanvasInsertionReceipt(
                acceptanceSequence: acceptedInsertion.acceptanceSequence,
                page: page
            )
        }
        let acceptedInsertion = try acceptProgrammaticInsertion(
            insertion,
            on: pageID
        )
        clearActiveTableTarget()
        guard let task = enqueueInsertionTask(acceptedInsertion) else {
            settleProgrammaticInsertion(acceptedInsertion)
            throw PaperCanvasInsertionCommitError.serializationOrHostValidationFailed
        }
        guard await task.value,
            let page = pages.first(where: { $0.id == pageID }) else {
            throw PaperCanvasInsertionCommitError.serializationOrHostValidationFailed
        }
        return PaperCanvasInsertionReceipt(
            acceptanceSequence: acceptedInsertion.acceptanceSequence,
            page: page
        )
    }

    @discardableResult
    func performInsertionAndWait(_ insertion: CanvasInsertion) async -> Bool {
        do {
            _ = try await performInsertionWithReceipt(
                insertion,
                on: focusedPageID
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func finishPendingProgrammaticInsertions() async -> Bool {
        // Concurrent snapshot attempts cannot safely redefine the boundary
        // owned by the first waiter. Fail closed and let the caller retry.
        guard activeProgrammaticInsertionReadinessBoundary == nil else {
            return false
        }
        let acceptedBoundary = programmaticInsertionAcceptanceSequence
        guard settledProgrammaticInsertionSequence < acceptedBoundary else {
            return true
        }

        activeProgrammaticInsertionReadinessBoundary = acceptedBoundary
        defer {
            activeProgrammaticInsertionReadinessBoundary = nil
            // Commands newer than this fixed boundary were deliberately held.
            // Resume normal ordered processing only after this waiter returns.
            drainDeferredCommandsAfterSerializedInsertion()
        }

        while settledProgrammaticInsertionSequence < acceptedBoundary {
            // An insertion deferred behind Pencil contact has no finite commit
            // boundary until UIKit ends that contact. Preserve the existing
            // contact contract and let snapshot callers fail closed for now.
            guard hasActiveContact == false else { return false }

            drainDeferredCommandsAfterSerializedInsertion()
            guard settledProgrammaticInsertionSequence < acceptedBoundary else {
                break
            }
            let nextUnsettledSequence = settledProgrammaticInsertionSequence &+ 1
            guard let acceptedTask = insertionHistoryTasksByAcceptanceSequence[
                nextUnsettledSequence
            ] else {
                // No live task and no synchronous drain progress means the
                // accepted command is still gated by interaction/framework
                // state. There is no bounded snapshot point yet.
                return false
            }
            _ = await acceptedTask.value
        }

        // Do not roll a continuously extended producer into this snapshot.
        // Every command at the captured boundary is settled, but any newer
        // accepted work makes this particular capture unstable.
        return programmaticInsertionAcceptanceSequence == acceptedBoundary
    }

    private func markProgrammaticInsertionSettled(_ sequence: UInt64) {
        guard sequence > settledProgrammaticInsertionSequence else { return }
        outOfOrderSettledProgrammaticInsertionSequences.insert(sequence)
        while outOfOrderSettledProgrammaticInsertionSequences.remove(
            settledProgrammaticInsertionSequence &+ 1
        ) != nil {
            settledProgrammaticInsertionSequence &+= 1
        }
    }

    private func settleProgrammaticInsertion(
        _ insertion: PendingProgrammaticInsertion
    ) {
        if let retained = retainedProgrammaticInsertionCosts.removeValue(
            forKey: insertion.acceptanceSequence
        ) {
            retainedProgrammaticInsertionImageCount = max(
                0,
                retainedProgrammaticInsertionImageCount - retained.imageCount
            )
            retainedProgrammaticInsertionImageBytes = max(
                0,
                retainedProgrammaticInsertionImageBytes - retained.imageBytes
            )
            retainedProgrammaticInsertionTextBytes = max(
                0,
                retainedProgrammaticInsertionTextBytes - retained.textBytes
            )
        }
        markProgrammaticInsertionSettled(insertion.acceptanceSequence)
    }

    private func insertTable(size: CanvasTableSize, on pageID: UUID) {
        guard isReaderModeEnabled == false,
            let index = pages.firstIndex(where: { $0.id == pageID }),
            let host = ensurePageHostMounted(for: pageID),
            let markup = host.controller.markup,
            size.isValid else { return }

        let tableInset = min(
            24,
            min(markup.bounds.width, markup.bounds.height) * 0.1
        )
        let tableBounds = markup.bounds.insetBy(dx: tableInset, dy: tableInset)
        let visibleBounds = tableBounds.intersection(host.controller.contentVisibleFrame)
        let insertionBounds = visibleBounds.isNull || visibleBounds.isEmpty
            ? tableBounds
            : visibleBounds
        let naturalSize = CGSize(
            width: CanvasTable.defaultCellSize.width * CGFloat(size.columnCount),
            height: CanvasTable.defaultCellSize.height * CGFloat(size.rowCount)
        )
        guard naturalSize.width > 0,
            naturalSize.height > 0,
            markup.bounds.width > 0,
            markup.bounds.height > 0 else { return }
        let fitScale = min(
            1,
            min(
                tableBounds.width / naturalSize.width,
                tableBounds.height / naturalSize.height
            )
        )
        let cellSize = CGSize(
            width: CanvasTable.defaultCellSize.width * fitScale,
            height: CanvasTable.defaultCellSize.height * fitScale
        )
        let requested = centeredFrame(
            size: CGSize(
                width: cellSize.width * CGFloat(size.columnCount),
                height: cellSize.height * CGFloat(size.rowCount)
            ),
            in: insertionBounds,
            constrainedTo: tableBounds
        )
        let suggested = host.controller.suggestedFrameForInserting(
            contentInFrame: requested
        )
        let frame = constrainedFrame(
            CGRect(origin: suggested.origin, size: requested.size),
            to: tableBounds
        )
        let table = CanvasTable(
            origin: frame.origin,
            rowCount: size.rowCount,
            columnCount: size.columnCount,
            cellSize: cellSize
        )
        guard table.isValid(in: markup.bounds) else { return }

        var tables = pages[index].tables
        tables.append(table)
        applyTableReplacement(
            pageID: pageID,
            tables: tables,
            actionName: "Insert Table",
            registersUndo: true
        )
        if pageID == focusedPageID {
            activeTableTarget = (pageID, table.id)
            activeTableCell = nil
        }
        refreshTableAccessibilityElements()
        UIAccessibility.post(
            notification: .announcement,
            argument: "Table with \(size.columnCount) columns and \(size.rowCount) rows inserted and selected."
        )
    }

    private func applyTableReplacement(
        pageID: UUID,
        tables: [CanvasTable],
        actionName: String,
        registersUndo: Bool
    ) {
        guard pagesPreparingInsertionHistory.contains(pageID) == false,
            let index = pages.firstIndex(where: { $0.id == pageID }),
            let host = hostsByPageID[pageID],
            Set(tables.map(\.id)).count == tables.count,
            tables.allSatisfy({ $0.isValid(in: pages[index].markup.bounds) }) else {
            return
        }

        let previousTables = pages[index].tables
        guard previousTables != tables else {
            host.contentView.tables = tables
            host.controller.contentView = host.contentView
            return
        }

        if registersUndo {
            registerAppOwnedUndo(pageID: pageID, actionName: actionName) { target in
                target.applyTableReplacement(
                    pageID: pageID,
                    tables: previousTables,
                    actionName: actionName,
                    registersUndo: true
                )
            }
        }
        let replacement = pages[index].replacing(tables: tables)
        pages[index] = replacement
        host.contentView.tables = tables
        // PaperKit snapshots its custom content surface. Reassigning the same
        // authored view invalidates that snapshot so a table mutation appears
        // immediately beneath existing ink rather than only in persistence.
        host.controller.contentView = host.contentView
        if let activeTableTarget,
            activeTableTarget.pageID == pageID,
            tables.contains(where: { $0.id == activeTableTarget.tableID }) == false {
            clearActiveTableTarget()
        }
        refreshTableAccessibilityElements()
        callbacks.pageReplaced(replacement)
        if pageID == focusedPageID { publishUndoAvailability() }
    }

    private func clearActiveTableTarget() {
        if tableTransformSession != nil {
            cancelTableTransform()
        }
        activeTableTarget = nil
        activeTableCell = nil
        refreshTableAccessibilityElements()
    }

    private func authoredTablePoint(
        _ point: CGPoint,
        pageID: UUID
    ) -> CGPoint? {
        guard let host = hostsByPageID[pageID],
            host.renderedZoomScale.isFinite,
            host.renderedZoomScale > 0 else { return nil }
        let nativePoint = host.controller.view.convert(point, from: tableInteractionView)
        return CGPoint(
            x: nativePoint.x / host.renderedZoomScale,
            y: nativePoint.y / host.renderedZoomScale
        )
    }

    private func tableInteractionFrame(
        for table: CanvasTable,
        pageID: UUID
    ) -> CGRect? {
        guard let host = hostsByPageID[pageID],
            host.renderedZoomScale.isFinite,
            host.renderedZoomScale > 0 else { return nil }
        let scale = host.renderedZoomScale
        let nativeFrame = CGRect(
            x: table.frame.minX * scale,
            y: table.frame.minY * scale,
            width: table.frame.width * scale,
            height: table.frame.height * scale
        )
        let frame = tableInteractionView.convert(nativeFrame, from: host.controller.view)
        guard frame.isNull == false, frame.isInfinite == false else { return nil }
        return frame
    }

    private func interactiveMinimumCellSize(for table: CanvasTable) -> CGSize {
        let candidate = CGSize(
            width: min(Self.minimumInteractiveTableCellDimension, table.cellSize.width),
            height: min(Self.minimumInteractiveTableCellDimension, table.cellSize.height)
        )
        let minimum: CGSize
        if let registered = minimumInteractiveTableCellSizeByID[table.id] {
            minimum = CGSize(
                width: min(registered.width, candidate.width),
                height: min(registered.height, candidate.height)
            )
        } else {
            minimum = candidate
        }
        minimumInteractiveTableCellSizeByID[table.id] = minimum
        return minimum
    }

    private func tableByMoving(
        _ original: CanvasTable,
        by delta: CGSize,
        in pageBounds: CGRect
    ) -> CanvasTable? {
        guard delta.width.isFinite, delta.height.isFinite else { return nil }
        var table = original
        let requestedFrame = original.frame.offsetBy(dx: delta.width, dy: delta.height)
        table.origin = constrainedFrame(requestedFrame, to: pageBounds).origin
        return table.isValid(in: pageBounds) ? table : nil
    }

    private func tableByResizing(
        _ original: CanvasTable,
        by delta: CGSize,
        in pageBounds: CGRect
    ) -> CanvasTable? {
        guard delta.width.isFinite, delta.height.isFinite else { return nil }
        let minimumCellSize = interactiveMinimumCellSize(for: original)
        let minimumWidth = minimumCellSize.width * CGFloat(original.columnCount)
        let minimumHeight = minimumCellSize.height * CGFloat(original.rowCount)
        let maximumWidth = pageBounds.maxX - original.frame.minX
        let maximumHeight = pageBounds.maxY - original.frame.minY
        guard maximumWidth >= minimumWidth, maximumHeight >= minimumHeight else { return nil }

        let width = (original.frame.width + delta.width)
            .clamped(to: minimumWidth...maximumWidth)
        let height = (original.frame.height + delta.height)
            .clamped(to: minimumHeight...maximumHeight)
        var table = original
        table.cellSize = CGSize(
            width: width / CGFloat(table.columnCount),
            height: height / CGFloat(table.rowCount)
        )
        table.cornerRadius = min(
            table.cornerRadius,
            min(table.cellSize.width, table.cellSize.height) / 2
        )
        return table.isValid(in: pageBounds) ? table : nil
    }

    private func beginTableTransform(
        kind: CanvasTableTransformKind,
        at point: CGPoint
    ) {
        guard tableTransformSession == nil,
            UIAccessibility.isVoiceOverRunning == false,
            regionSelectionInteractionSnapshot == nil,
            appliedToolState?.activeTool != .laserPointer,
            scrollView.isZooming == false,
            let activeTableTarget,
            pagesPreparingInsertionHistory.contains(activeTableTarget.pageID) == false,
            let pageIndex = pages.firstIndex(where: { $0.id == activeTableTarget.pageID }),
            let table = pages[pageIndex].tables.first(where: {
                $0.id == activeTableTarget.tableID
            }),
            let authoredPoint = authoredTablePoint(point, pageID: activeTableTarget.pageID),
            let frame = tableInteractionFrame(for: table, pageID: activeTableTarget.pageID)
        else { return }

        let scrollWasEnabled = scrollView.isScrollEnabled
        scrollView.isScrollEnabled = false
        hoveredTableCell = nil
        tableTransformSession = TableTransformSession(
            kind: kind,
            pageID: activeTableTarget.pageID,
            tableID: activeTableTarget.tableID,
            originalTables: pages[pageIndex].tables,
            originalTable: table,
            startAuthoredPoint: authoredPoint,
            scrollWasEnabled: scrollWasEnabled,
            previewTable: table
        )
        callbacks.interactionBegan(activeTableTarget.pageID)
        tableInteractionView.beginTransformPreview(
            frame: frame,
            sizeValue: tableSizeAccessibilityValue(
                table,
                in: pages[pageIndex].markup.bounds
            )
        )
    }

    private func updateTableTransform(
        kind: CanvasTableTransformKind,
        at point: CGPoint
    ) {
        guard var session = tableTransformSession,
            session.kind == kind,
            let pageIndex = pages.firstIndex(where: { $0.id == session.pageID }),
            pages[pageIndex].tables == session.originalTables,
            let authoredPoint = authoredTablePoint(point, pageID: session.pageID)
        else {
            if tableTransformSession != nil { cancelTableTransform() }
            return
        }
        let delta = CGSize(
            width: authoredPoint.x - session.startAuthoredPoint.x,
            height: authoredPoint.y - session.startAuthoredPoint.y
        )
        let pageBounds = pages[pageIndex].markup.bounds
        let candidate: CanvasTable?
        switch kind {
        case .move:
            candidate = tableByMoving(session.originalTable, by: delta, in: pageBounds)
        case .resize:
            candidate = tableByResizing(session.originalTable, by: delta, in: pageBounds)
        }
        guard let candidate, candidate != session.previewTable else { return }

        session.previewTable = candidate
        tableTransformSession = session
        var previewTables = session.originalTables
        guard let tableIndex = previewTables.firstIndex(where: { $0.id == session.tableID }),
            let host = hostsByPageID[session.pageID],
            let frame = tableInteractionFrame(for: candidate, pageID: session.pageID)
        else {
            cancelTableTransform()
            return
        }
        previewTables[tableIndex] = candidate
        host.contentView.tables = previewTables
        host.controller.contentView = host.contentView
        tableInteractionView.updateTransformPreview(
            frame: frame,
            sizeValue: tableSizeAccessibilityValue(candidate, in: pageBounds)
        )
    }

    private func finishTableTransform(
        kind: CanvasTableTransformKind,
        at point: CGPoint
    ) {
        updateTableTransform(kind: kind, at: point)
        guard let session = tableTransformSession else { return }
        tableTransformSession = nil
        scrollView.isScrollEnabled = session.scrollWasEnabled
        tableInteractionView.endTransformPreview()

        guard let pageIndex = pages.firstIndex(where: { $0.id == session.pageID }),
            pages[pageIndex].tables == session.originalTables,
            let tableIndex = session.originalTables.firstIndex(where: {
                $0.id == session.tableID
            }) else {
            let currentTables = pages.first(where: { $0.id == session.pageID })?.tables
                ?? session.originalTables
            restorePresentedTables(currentTables, pageID: session.pageID)
            refreshTableAccessibilityElements()
            return
        }

        guard session.previewTable != session.originalTable else {
            restorePresentedTables(session.originalTables, pageID: session.pageID)
            refreshTableAccessibilityElements()
            return
        }
        var tables = session.originalTables
        tables[tableIndex] = session.previewTable
        applyTableReplacement(
            pageID: session.pageID,
            tables: tables,
            actionName: kind == .move ? "Move Table" : "Resize Table",
            registersUndo: true
        )
        UIAccessibility.post(
            notification: .announcement,
            argument: kind == .move ? "Table moved" : "Table resized"
        )
    }

    private func cancelTableTransform() {
        guard let session = tableTransformSession else { return }
        tableTransformSession = nil
        scrollView.isScrollEnabled = session.scrollWasEnabled
        let currentTables = pages.first(where: { $0.id == session.pageID })?.tables
            ?? session.originalTables
        restorePresentedTables(currentTables, pageID: session.pageID)
        tableInteractionView.endTransformPreview()
        refreshTableAccessibilityElements()
    }

    private func restorePresentedTables(_ tables: [CanvasTable], pageID: UUID) {
        guard let host = hostsByPageID[pageID] else { return }
        host.contentView.tables = tables
        host.controller.contentView = host.contentView
    }

    @discardableResult
    private func moveActiveTable(by delta: CGSize) -> Bool {
        guard isReaderModeEnabled == false else { return false }
        return transformActiveTable(actionName: "Move Table") { table, pageBounds in
            tableByMoving(table, by: delta, in: pageBounds)
        }
    }

    @discardableResult
    private func resizeActiveTable(byCellDelta delta: CGSize) -> Bool {
        guard isReaderModeEnabled == false else { return false }
        return transformActiveTable(actionName: "Resize Table") { table, pageBounds in
            tableByResizing(
                table,
                by: CGSize(
                    width: delta.width * CGFloat(table.columnCount),
                    height: delta.height * CGFloat(table.rowCount)
                ),
                in: pageBounds
            )
        }
    }

    @discardableResult
    private func transformActiveTable(
        actionName: String,
        transform: (CanvasTable, CGRect) -> CanvasTable?
    ) -> Bool {
        guard tableTransformSession == nil,
            let activeTableTarget,
            let pageIndex = pages.firstIndex(where: { $0.id == activeTableTarget.pageID }),
            let tableIndex = pages[pageIndex].tables.firstIndex(where: {
                $0.id == activeTableTarget.tableID
            }),
            let table = transform(
                pages[pageIndex].tables[tableIndex],
                pages[pageIndex].markup.bounds
            ),
            table != pages[pageIndex].tables[tableIndex] else { return false }

        var tables = pages[pageIndex].tables
        tables[tableIndex] = table
        applyTableReplacement(
            pageID: activeTableTarget.pageID,
            tables: tables,
            actionName: actionName,
            registersUndo: true
        )
        UIAccessibility.post(
            notification: .announcement,
            argument: actionName == "Move Table" ? "Table moved" : "Table resized"
        )
        return true
    }

    private func tableSizeAccessibilityValue(
        _ table: CanvasTable,
        in pageBounds: CGRect
    ) -> String {
        let width = Int(
            ((table.frame.width / max(pageBounds.width, 1)) * 100)
                .clamped(to: 0...100)
                .rounded()
        )
        let height = Int(
            ((table.frame.height / max(pageBounds.height, 1)) * 100)
                .clamped(to: 0...100)
                .rounded()
        )
        return "Width \(width) percent, height \(height) percent"
    }

    @objc private func handleTableSelectionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let location = recognizer.location(in: view)
        guard let target = tableHitTarget(at: location) else {
            clearActiveTableTarget()
            return
        }
        setFocusedPage(target.pageID, fromDirectInteraction: true)
        activeTableTarget = (target.pageID, target.tableID)
        activeTableCell = TableCellTarget(
            pageID: target.pageID,
            tableID: target.tableID,
            row: target.row,
            column: target.column
        )
        refreshTableAccessibilityElements()
    }

    @objc private func handleTableHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let location = recognizer.location(in: view)
            let target = tableHitTarget(at: location)
            let hover = target.map {
                TableCellTarget(
                    pageID: $0.pageID,
                    tableID: $0.tableID,
                    row: $0.row,
                    column: $0.column
                )
            }
            guard hoveredTableCell != hover else { return }
            hoveredTableCell = hover
            refreshTableAccessibilityElements()
        case .ended, .cancelled, .failed:
            guard hoveredTableCell != nil else { return }
            hoveredTableCell = nil
            refreshTableAccessibilityElements()
        default:
            break
        }
    }

    private func tableHitTarget(at location: CGPoint) -> TableHitTarget? {
        for page in pages.reversed() {
            guard page.tables.isEmpty == false,
                let host = hostsByPageID[page.id],
                host.controller.view.isHidden == false,
                host.renderedZoomScale.isFinite,
                host.renderedZoomScale > 0 else { continue }

            let local = host.controller.view.convert(location, from: view)
            let authoredLocation = CGPoint(
                x: local.x / host.renderedZoomScale,
                y: local.y / host.renderedZoomScale
            )
            for table in page.tables.reversed() {
                guard table.frame.contains(authoredLocation) else { continue }
                let localX = max(0, authoredLocation.x - table.frame.minX)
                let localY = max(0, authoredLocation.y - table.frame.minY)
                let column = min(
                    table.columnCount - 1,
                    Int(floor(localX / table.cellSize.width))
                )
                let row = min(
                    table.rowCount - 1,
                    Int(floor(localY / table.cellSize.height))
                )
                return TableHitTarget(
                    pageID: page.id,
                    tableID: table.id,
                    row: row,
                    column: column
                )
            }
        }
        return nil
    }

    private func tableExists(
        pageID: UUID,
        tableID: UUID
    ) -> Bool {
        pages.first(where: { $0.id == pageID })?.tables.contains(where: {
            $0.id == tableID
        }) == true
    }

    private func activateAccessibleTable(pageID: UUID, tableID: UUID) -> Bool {
        guard tableExists(pageID: pageID, tableID: tableID) else {
            return false
        }
        setFocusedPage(pageID, fromDirectInteraction: true)
        activeTableTarget = (pageID, tableID)
        activeTableCell = nil
        refreshTableAccessibilityElements()
        return true
    }

    private func growAccessibleTable(
        pageID: UUID,
        tableID: UUID,
        axis: CanvasTableGrowthAxis
    ) -> Bool {
        guard activateAccessibleTable(pageID: pageID, tableID: tableID) else {
            return false
        }
        return growActiveTable(axis: axis)
    }

    private func refreshTableAccessibilityElements() {
        guard isViewLoaded,
            tableInteractionView.superview === scrollView,
            tableInteractionView.bounds.width > 0,
            tableInteractionView.bounds.height > 0 else {
            tableInteractionView.accessibilityElements = []
            return
        }
        let interactionIsAvailable = isReaderModeEnabled == false
            && regionSelectionInteractionSnapshot == nil
            && appliedToolState?.activeTool != .laserPointer
        guard interactionIsAvailable else {
            hoveredTableCell = nil
            tableInteractionView.accessibilityElements = []
            tableInteractionView.update(
                selectedTableFrame: nil,
                selectedCellFrame: nil,
                hoveredTableFrame: nil,
                hoveredCellFrame: nil,
                capabilities: .none,
                allowsDirectBodyTransform: false,
                sizeValue: nil
            )
            return
        }

        // Scrolling calls this every frame. A notebook with no tables, and no
        // table state left to clear, has nothing to lay out.
        if tableAccessibilityElementsByKey.isEmpty,
            activeTableTarget == nil,
            activeTableCell == nil,
            hoveredTableCell == nil,
            pages.allSatisfy({ $0.tables.isEmpty }) {
            return
        }

        var liveKeys = Set<TableAccessibilityKey>()
        var orderedElements: [Any] = []
        var selectedTableFrame: CGRect?
        var selectedCellFrame: CGRect?
        var hoveredTableFrame: CGRect?
        var hoveredCellFrame: CGRect?
        var capabilities = CanvasTableInteractionOverlayView.Capabilities.none
        var selectedSizeValue: String?
        for (pageIndex, page) in pages.enumerated() {
            guard let host = hostsByPageID[page.id],
                host.controller.view.isHidden == false,
                host.renderedZoomScale.isFinite,
                host.renderedZoomScale > 0 else { continue }

            for table in page.tables {
                let nativeScale = host.renderedZoomScale
                let nativeFrame = CGRect(
                    x: table.frame.minX * nativeScale,
                    y: table.frame.minY * nativeScale,
                    width: table.frame.width * nativeScale,
                    height: table.frame.height * nativeScale
                )
                let frame = tableInteractionView.convert(
                    nativeFrame,
                    from: host.controller.view
                )
                guard frame.isNull == false,
                    frame.isInfinite == false,
                    frame.intersects(tableInteractionView.bounds) else { continue }

                let key = TableAccessibilityKey(pageID: page.id, tableID: table.id)
                liveKeys.insert(key)
                let element: CanvasTableAccessibilityElement
                if let existing = tableAccessibilityElementsByKey[key] {
                    element = existing
                } else {
                    element = CanvasTableAccessibilityElement(
                        accessibilityContainer: tableInteractionView,
                        pageID: page.id,
                        tableID: table.id
                    )
                    element.onActivate = { [weak self] in
                        self?.activateAccessibleTable(
                            pageID: key.pageID,
                            tableID: key.tableID
                        ) ?? false
                    }
                    element.onAddRow = { [weak self] in
                        self?.growAccessibleTable(
                            pageID: key.pageID,
                            tableID: key.tableID,
                            axis: .rows
                        ) ?? false
                    }
                    element.onAddColumn = { [weak self] in
                        self?.growAccessibleTable(
                            pageID: key.pageID,
                            tableID: key.tableID,
                            axis: .columns
                        ) ?? false
                    }
                    element.onRemoveRow = { [weak self] in
                        self?.shrinkAccessibleTable(
                            pageID: key.pageID,
                            tableID: key.tableID,
                            axis: .rows
                        ) ?? false
                    }
                    element.onRemoveColumn = { [weak self] in
                        self?.shrinkAccessibleTable(
                            pageID: key.pageID,
                            tableID: key.tableID,
                            axis: .columns
                        ) ?? false
                    }
                    element.onDelete = { [weak self] in
                        self?.deleteAccessibleTable(
                            pageID: key.pageID,
                            tableID: key.tableID
                        ) ?? false
                    }
                    element.onMoveStep = { [weak self] direction in
                        guard let self,
                            self.activateAccessibleTable(
                                pageID: key.pageID,
                                tableID: key.tableID
                            ) else { return false }
                        return self.moveActiveTable(
                            by: CGSize(
            width: direction.width
                * Self.tableAccessibilityMoveStep,
            height: direction.height
                * Self.tableAccessibilityMoveStep
        )
        )
    }
        tableAccessibilityElementsByKey[key] = element
    }

        element.accessibilityLabel = "Table on page \(pageIndex + 1)"
        element.accessibilityValue =
            "\(table.rowCount) rows, \(table.columnCount) columns"
        element.accessibilityHint =
            "Double-tap to select. Drag to move, touch and hold for table actions, or use the corner grip to resize."
        element.accessibilityIdentifier =
            "canvas.table.\(page.id.uuidString).\(table.id.uuidString)"
        element.accessibilityTraits = activeTableTarget?.pageID == page.id
            && activeTableTarget?.tableID == table.id
            ? [.button, .selected]
            : [.button]
        element.accessibilityFrameInContainerSpace = frame
        orderedElements.append(element)

        let isSelected = activeTableTarget?.pageID == page.id
            && activeTableTarget?.tableID == table.id
        element.updateMovementActions()
        if isSelected {
            selectedTableFrame = frame
            let pageBounds = page.markup.bounds
            let minimumCellSize = interactiveMinimumCellSize(for: table)
            let boundaryTolerance: CGFloat = 0.5
            selectedSizeValue = tableSizeAccessibilityValue(
                table,
                in: pageBounds
            )
            if let activeTableCell,
                activeTableCell.pageID == page.id,
                activeTableCell.tableID == table.id,
                (0..<table.rowCount).contains(activeTableCell.row),
                (0..<table.columnCount).contains(activeTableCell.column) {
                let nativeCellFrame = CGRect(
                    x: (table.frame.minX
                        + CGFloat(activeTableCell.column) * table.cellSize.width)
                        * nativeScale,
                    y: (table.frame.minY
                        + CGFloat(activeTableCell.row) * table.cellSize.height)
                        * nativeScale,
                    width: table.cellSize.width * nativeScale,
                    height: table.cellSize.height * nativeScale
                )
                selectedCellFrame = tableInteractionView.convert(
                    nativeCellFrame,
                    from: host.controller.view
                )
            }
            capabilities = .init(
                    canAddRow: tableByAdding(
                        .rows,
                        to: table,
                        in: page.markup.bounds
                    ) != nil,
                    canAddColumn: tableByAdding(
                        .columns,
                        to: table,
                        in: page.markup.bounds
                    ) != nil,
                    canRemoveRow: table.rowCount > CanvasTable.minimumRowCount,
                    canRemoveColumn: table.columnCount > CanvasTable.minimumColumnCount,
                    canDelete: true,
            canMoveUp: table.frame.minY
                > pageBounds.minY + boundaryTolerance,
            canMoveDown: table.frame.maxY
                < pageBounds.maxY - boundaryTolerance,
            canMoveLeft: table.frame.minX
                > pageBounds.minX + boundaryTolerance,
            canMoveRight: table.frame.maxX
                < pageBounds.maxX - boundaryTolerance,
            canIncreaseWidth: table.frame.maxX
                < pageBounds.maxX - boundaryTolerance,
            canDecreaseWidth: table.cellSize.width
                > minimumCellSize.width + boundaryTolerance,
            canIncreaseHeight: table.frame.maxY
                < pageBounds.maxY - boundaryTolerance,
            canDecreaseHeight: table.cellSize.height
                > minimumCellSize.height + boundaryTolerance
        )
        element.updateMovementActions(
            canMoveUp: capabilities.canMoveUp,
            canMoveDown: capabilities.canMoveDown,
            canMoveLeft: capabilities.canMoveLeft,
            canMoveRight: capabilities.canMoveRight
        )
    }
        if let hoveredTableCell,
            hoveredTableCell.pageID == page.id,
            hoveredTableCell.tableID == table.id,
            (0..<table.rowCount).contains(hoveredTableCell.row),
            (0..<table.columnCount).contains(hoveredTableCell.column) {
            hoveredTableFrame = frame
            let nativeCellFrame = CGRect(
                x: (table.frame.minX
                    + CGFloat(hoveredTableCell.column) * table.cellSize.width)
                    * nativeScale,
                y: (table.frame.minY
                    + CGFloat(hoveredTableCell.row) * table.cellSize.height)
                    * nativeScale,
                width: table.cellSize.width * nativeScale,
                height: table.cellSize.height * nativeScale
            )
            hoveredCellFrame = tableInteractionView.convert(
                nativeCellFrame,
                        from: host.controller.view
                    )
                }
            }
        }

        let staleKeys = tableAccessibilityElementsByKey.keys.filter {
            liveKeys.contains($0) == false
        }
        for key in staleKeys {
            tableAccessibilityElementsByKey.removeValue(forKey: key)
        }
        tableInteractionView.update(
            selectedTableFrame: selectedTableFrame,
            selectedCellFrame: selectedCellFrame,
            hoveredTableFrame: hoveredTableFrame,
            hoveredCellFrame: hoveredCellFrame,
            capabilities: capabilities,
            allowsDirectBodyTransform: inputMode == .pencilOnly,
            sizeValue: selectedSizeValue
        )
        tableInteractionView.layoutIfNeeded()
        orderedElements.append(contentsOf: tableInteractionView.visibleAccessibilityControls)
        tableInteractionView.accessibilityElements = orderedElements
    }

    private func tableByAdding(
        _ axis: CanvasTableGrowthAxis,
        to original: CanvasTable,
        in pageBounds: CGRect
    ) -> CanvasTable? {
        var table = original
        switch axis {
        case .rows:
            guard table.rowCount < CanvasTable.maximumRowCount else { return nil }
            table.rowCount += 1
        case .columns:
            guard table.columnCount < CanvasTable.maximumColumnCount else { return nil }
            table.columnCount += 1
        }

        guard table.frame.width <= pageBounds.width,
            table.frame.height <= pageBounds.height else { return nil }
        table.origin = constrainedFrame(table.frame, to: pageBounds).origin
        return table.isValid(in: pageBounds) ? table : nil
    }

    @discardableResult
    private func growActiveTable(axis: CanvasTableGrowthAxis) -> Bool {
        guard isReaderModeEnabled == false,
            let activeTableTarget,
            let pageIndex = pages.firstIndex(where: { $0.id == activeTableTarget.pageID }),
            let tableIndex = pages[pageIndex].tables.firstIndex(
                where: { $0.id == activeTableTarget.tableID }
            ) else { return false }

        var tables = pages[pageIndex].tables
        guard let table = tableByAdding(
            axis,
            to: tables[tableIndex],
            in: pages[pageIndex].markup.bounds
        ) else { return false }

        tables[tableIndex] = table
        applyTableReplacement(
            pageID: activeTableTarget.pageID,
            tables: tables,
            actionName: axis == .rows ? "Add Table Row" : "Add Table Column",
            registersUndo: true
        )
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(table.rowCount) rows, \(table.columnCount) columns"
        )
        return true
    }

    @discardableResult
    private func shrinkAccessibleTable(
        pageID: UUID,
        tableID: UUID,
        axis: CanvasTableGrowthAxis
    ) -> Bool {
        guard activateAccessibleTable(pageID: pageID, tableID: tableID) else {
            return false
        }
        return shrinkActiveTable(axis: axis)
    }

    @discardableResult
    private func shrinkActiveTable(axis: CanvasTableGrowthAxis) -> Bool {
        guard isReaderModeEnabled == false,
            let activeTableTarget,
            let pageIndex = pages.firstIndex(where: { $0.id == activeTableTarget.pageID }),
            let tableIndex = pages[pageIndex].tables.firstIndex(
                where: { $0.id == activeTableTarget.tableID }
            ) else { return false }

        var tables = pages[pageIndex].tables
        var table = tables[tableIndex]
        switch axis {
        case .rows:
            guard table.rowCount > CanvasTable.minimumRowCount else { return false }
            table.rowCount -= 1
        case .columns:
            guard table.columnCount > CanvasTable.minimumColumnCount else { return false }
            table.columnCount -= 1
        }
        guard table.isValid(in: pages[pageIndex].markup.bounds) else { return false }
        tables[tableIndex] = table
        if let activeTableCell,
            activeTableCell.pageID == activeTableTarget.pageID,
            activeTableCell.tableID == activeTableTarget.tableID {
            self.activeTableCell = TableCellTarget(
                pageID: activeTableCell.pageID,
                tableID: activeTableCell.tableID,
                row: min(activeTableCell.row, table.rowCount - 1),
                column: min(activeTableCell.column, table.columnCount - 1)
            )
        }
        applyTableReplacement(
            pageID: activeTableTarget.pageID,
            tables: tables,
            actionName: axis == .rows ? "Remove Table Row" : "Remove Table Column",
            registersUndo: true
        )
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(table.rowCount) rows, \(table.columnCount) columns"
        )
        return true
    }

    @discardableResult
    private func deleteAccessibleTable(pageID: UUID, tableID: UUID) -> Bool {
        guard activateAccessibleTable(pageID: pageID, tableID: tableID) else {
            return false
        }
        return deleteActiveTable()
    }

    @discardableResult
    private func deleteActiveTable() -> Bool {
        guard isReaderModeEnabled == false,
            let activeTableTarget,
            let pageIndex = pages.firstIndex(where: { $0.id == activeTableTarget.pageID }) else {
            return false
        }
        var tables = pages[pageIndex].tables
        guard let tableIndex = tables.firstIndex(where: {
            $0.id == activeTableTarget.tableID
        }) else { return false }
        tables.remove(at: tableIndex)
        self.activeTableTarget = nil
        activeTableCell = nil
        if hoveredTableCell?.pageID == activeTableTarget.pageID,
            hoveredTableCell?.tableID == activeTableTarget.tableID {
            hoveredTableCell = nil
        }
        applyTableReplacement(
            pageID: activeTableTarget.pageID,
            tables: tables,
            actionName: "Delete Table",
            registersUndo: true
        )
        UIAccessibility.post(notification: .announcement, argument: "Table deleted")
        return true
    }

    @discardableResult
    func performImageInsertion(_ image: CGImage, atViewportPoint point: CGPoint) -> Bool {
        guard isReaderModeEnabled == false,
            hasActiveContact == false,
            point.x.isFinite,
            point.y.isFinite,
            let host = pages.lazy.compactMap({ self.hostsByPageID[$0.id] }).first(where: { host in
                guard host.controller.view.isHidden == false else { return false }
                let pageFrame = host.controller.view.convert(
                    host.controller.view.bounds,
                    to: view
                )
                return pageFrame.contains(point)
            }),
            let markup = host.controller.markup,
        host.renderedZoomScale.isFinite,
        host.renderedZoomScale > 0 else { return false }

    let localPoint = host.controller.view.convert(point, from: view)
    let authoredPoint = CGPoint(
        x: localPoint.x / host.renderedZoomScale,
        y: localPoint.y / host.renderedZoomScale
    )
    guard markup.bounds.contains(authoredPoint) else { return false }

    let maximumSize = CGSize(
        width: min(360, markup.bounds.width * 0.6),
        height: min(360, markup.bounds.height * 0.6)
    )
    let fittedSize = aspectFitSize(
        source: CGSize(width: image.width, height: image.height),
        maximum: maximumSize
    )
    let requestedFrame = constrainedFrame(
        CGRect(
            x: authoredPoint.x - fittedSize.width / 2,
            y: authoredPoint.y - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
            ),
            to: markup.bounds
        )
        guard requestedFrame.width >= 2, requestedFrame.height >= 2 else { return false }

        setFocusedPage(host.id, fromDirectInteraction: false)
        performInsertion(.positionedImage(image, frame: requestedFrame), on: host.id)
        return true
    }

    private func enqueueInsertionTask(
        _ pendingInsertion: PendingProgrammaticInsertion
    ) -> Task<Bool, Never>? {
        let insertion = pendingInsertion.insertion
        let pageID = pendingInsertion.pageID
        let acceptanceSequence = pendingInsertion.acceptanceSequence
        guard ensurePageHostMounted(for: pageID) != nil else { return nil }
        guard insertionHistorySequence < UInt64.max else { return nil }
        let precedingTask = insertionHistoryTask
        insertionHistorySequence += 1
        let sequence = insertionHistorySequence
        queuedInsertionCountByPageID[pageID, default: 0] += 1
        let task = Task { @MainActor [weak self] in
            _ = await precedingTask?.value
            guard let self else { return false }
            defer {
                let remaining = self.queuedInsertionCountByPageID[pageID, default: 1] - 1
                if remaining > 0 {
                    self.queuedInsertionCountByPageID[pageID] = remaining
                } else {
                    self.queuedInsertionCountByPageID.removeValue(forKey: pageID)
                }
                if self.insertionHistorySequence == sequence {
                    self.insertionHistoryTask = nil
                }
                self.insertionHistoryTasksByAcceptanceSequence.removeValue(
                    forKey: acceptanceSequence
                )
                self.settleProgrammaticInsertion(pendingInsertion)
                self.drainDeferredCommandsAfterSerializedInsertion()
                if self.insertionHistorySequence == sequence {
                    self.updateRenderedPageWindow(force: true)
                }
            }
            guard Task.isCancelled == false else { return false }
            return await self.performSerializedInsertion(
            insertion,
            pageID: pageID
        )
    }
    insertionHistoryTask = task
    insertionHistoryTasksByAcceptanceSequence[acceptanceSequence] = task
    return task
}

func undo() {
    guard isReaderModeEnabled == false else { return }
    submitHistoryCommand(.undo, on: focusedPageID)
}

func redo() {
    guard isReaderModeEnabled == false else { return }
    submitHistoryCommand(.redo, on: focusedPageID)
}

private func historySwipeGesture(
    direction: UISwipeGestureRecognizer.Direction,
    action: Selector
) -> UISwipeGestureRecognizer {
    let recognizer = CanvasHistorySwipeGestureRecognizer(
        target: self,
        action: action
    )
    recognizer.direction = direction
    recognizer.numberOfTouchesRequired = 3
    recognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    recognizer.cancelsTouchesInView = true
    recognizer.delegate = self
    return recognizer
}

private func configureThreeFingerHistoryGestures() {
    if Self.hasRegisteredHistoryGestureConflictWithZoom == false {
        UIAccessibility.registerGestureConflictWithZoom()
        Self.hasRegisteredHistoryGestureConflictWithZoom = true
    }
    view.addGestureRecognizer(threeFingerUndoSwipeGestureRecognizer)
    view.addGestureRecognizer(threeFingerRedoSwipeGestureRecognizer)
}

@objc private func handleThreeFingerUndoSwipe(
    _ recognizer: UISwipeGestureRecognizer
) {
    guard recognizer.state == .ended else { return }
    performThreeFingerHistorySwipe(.left)
}

@objc private func handleThreeFingerRedoSwipe(
    _ recognizer: UISwipeGestureRecognizer
) {
    guard recognizer.state == .ended else { return }
    performThreeFingerHistorySwipe(.right)
}

private func performThreeFingerHistorySwipe(
    _ direction: UISwipeGestureRecognizer.Direction
) {
    // Match the toolbar and keyboard contract: history belongs to the
    // focused page, even when several page surfaces are visible.
    switch direction {
    case .left:
        undo()
    case .right:
        redo()
    default:
        break
    }
}

private func isThreeFingerHistoryGesture(
    _ gestureRecognizer: UIGestureRecognizer
) -> Bool {
    gestureRecognizer === threeFingerUndoSwipeGestureRecognizer
        || gestureRecognizer === threeFingerRedoSwipeGestureRecognizer
}

private func submitHistoryCommand(
    _ action: PendingHistoryAction,
    on pageID: UUID
) {
    guard pages.contains(where: { $0.id == pageID }) else { return }
    let hasOpenUndoGroup = (
        hostsByPageID[pageID]?.controller.undoManager?.groupingLevel ?? 0
    ) > 0
    if hasActiveContact
        || pagesPreparingInsertionHistory.isEmpty == false
        || queuedInsertionCountByPageID.isEmpty == false
        || hasPendingAppUndoRegistration(for: pageID)
        || hasOpenUndoGroup {
        guard pendingHistoryCommands.count
            < Self.maximumPendingHistoryCommandCount else { return }
        pendingHistoryCommands.append(
            PendingHistoryCommand(action: action, pageID: pageID)
        )
        return
    }

    guard let host = ensurePageHostMounted(for: pageID) else { return }
    switch action {
    case .undo:
        host.controller.undoManager?.undo()
    case .redo:
        host.controller.undoManager?.redo()
    }
    recordUndoHistoryActivity(pageID: pageID)
    deliverMarkupIfChanged(pageID: pageID)
    if pageID == focusedPageID { publishUndoAvailability() }
    updateRenderedPageWindow(force: true)
}

private func drainPendingHistoryCommandsIfPossible() {
    guard hasActiveContact == false,
        pagesPreparingInsertionHistory.isEmpty,
        queuedInsertionCountByPageID.isEmpty,
        pendingAppUndoRegistrations.isEmpty,
        undoManagersFlushingAppRegistrations.isEmpty,
        pendingHistoryCommands.allSatisfy({ command in
            (hostsByPageID[command.pageID]?.controller.undoManager?.groupingLevel ?? 0)
                == 0
        }),
        pendingHistoryCommands.isEmpty == false else { return }
    let commands = pendingHistoryCommands
    pendingHistoryCommands.removeAll(keepingCapacity: true)
    for command in commands {
        submitHistoryCommand(command.action, on: command.pageID)
    }
}

/// The whole stack, read from the live PaperKit hosts. Returning nil while an
/// insertion is mid-transaction makes the model retry rather than save a
/// half-committed page.
func snapshotDocument() -> CanvasDocumentSnapshot? {
    guard pagesPreparingInsertionHistory.isEmpty,
        pages.contains(where: { $0.id == focusedPageID }) else { return nil }
    for page in pages {
        deliverMarkupIfChanged(pageID: page.id)
    }
    return CanvasDocumentSnapshot(
        pages: pages,
        currentPageID: focusedPageID,
        viewport: currentViewportState()
    )
}

func snapshotActivePage() -> CanvasActivePageSnapshot? {
    deliverMarkupIfChanged(pageID: focusedPageID)
    guard let page = pages.first(where: { $0.id == focusedPageID }) else { return nil }
    return CanvasActivePageSnapshot(
        id: page.id,
        markup: page.markup,
        tables: page.tables,
        viewport: currentViewportState()
    )
}

private func configureOuterScrollView() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = CanvasConstants.workspaceBackground(for: documentMode)
    scrollView.delegate = self
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.automaticallyAdjustsScrollIndicatorInsets = false
    scrollView.bounces = true
    scrollView.bouncesZoom = true
    scrollView.minimumZoomScale = CanvasConstants.absoluteZoomRange.lowerBound
    scrollView.maximumZoomScale = CanvasConstants.absoluteZoomRange.upperBound
    scrollView.zoomScale = CanvasConstants.defaultZoomScale
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    scrollView.isDirectionalLockEnabled = documentMode == .paged
    scrollView.keyboardDismissMode = .interactive
    scrollView.panGestureRecognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    scrollView.pinchGestureRecognizer?.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    configureScrollAxes()
    configureOuterPanForInputMode()

    view.addSubview(scrollView)
    NSLayoutConstraint.activate([
        scrollView.topAnchor.constraint(equalTo: view.topAnchor),
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    documentView.backgroundColor = .clear
    documentView.clipsToBounds = false
    scrollView.addSubview(documentView)
}

private func configureContactMonitor() {
    contactMonitor.cancelsTouchesInView = false
    contactMonitor.delaysTouchesBegan = false
    contactMonitor.delaysTouchesEnded = false
    contactMonitor.requiresExclusiveTouchType = false
    contactMonitor.shouldTrackDirectTouches = { [weak self] in
        self?.inputMode == .pencilAndFinger
    }
    contactMonitor.onContactBegan = { [weak self] in self?.contactDidBegin() }
    contactMonitor.onContactEnded = { [weak self] in self?.contactDidEnd() }
    contactMonitor.delegate = contactMonitor
    scrollView.addGestureRecognizer(contactMonitor)
}

private func configureTableInteraction() {
    tableInteractionView.translatesAutoresizingMaskIntoConstraints = false
    tableInteractionView.backgroundColor = .clear
    tableInteractionView.isOpaque = false
    tableInteractionView.onAddRow = { [weak self] in
        _ = self?.growActiveTable(axis: .rows)
    }
    tableInteractionView.onAddColumn = { [weak self] in
        _ = self?.growActiveTable(axis: .columns)
    }
    tableInteractionView.onRemoveRow = { [weak self] in
        _ = self?.shrinkActiveTable(axis: .rows)
    }
    tableInteractionView.onRemoveColumn = { [weak self] in
        _ = self?.shrinkActiveTable(axis: .columns)
    }
    tableInteractionView.onDelete = { [weak self] in
        _ = self?.deleteActiveTable()
    }
    tableInteractionView.onTransformBegan = { [weak self] kind, point in
        self?.beginTableTransform(kind: kind, at: point)
    }
    tableInteractionView.onTransformChanged = { [weak self] kind, point in
        self?.updateTableTransform(kind: kind, at: point)
    }
    tableInteractionView.onTransformEnded = { [weak self] kind, point in
        self?.finishTableTransform(kind: kind, at: point)
    }
    tableInteractionView.onTransformCancelled = { [weak self] in
        self?.cancelTableTransform()
    }
    tableInteractionView.onResizeStep = { [weak self] direction in
        self?.resizeActiveTable(
            byCellDelta: CGSize(
                width: direction.width * Self.tableAccessibilityResizeStep,
                height: direction.height * Self.tableAccessibilityResizeStep
            )
        ) ?? false
    }
    scrollView.addSubview(tableInteractionView)
    NSLayoutConstraint.activate([
        tableInteractionView.topAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.topAnchor
        ),
        tableInteractionView.leadingAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.leadingAnchor
        ),
        tableInteractionView.trailingAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.trailingAnchor
        ),
        tableInteractionView.bottomAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.bottomAnchor
        ),
    ])
    tableInteractionView.prioritizeTransforms(over: scrollView.panGestureRecognizer)

    tableSelectionTapGestureRecognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
    ]
    tableSelectionTapGestureRecognizer.cancelsTouchesInView = false
    tableSelectionTapGestureRecognizer.delaysTouchesBegan = false
    tableSelectionTapGestureRecognizer.delaysTouchesEnded = false
    tableSelectionTapGestureRecognizer.requiresExclusiveTouchType = false
    tableSelectionTapGestureRecognizer.delegate = self
    view.addGestureRecognizer(tableSelectionTapGestureRecognizer)

    tableHoverGestureRecognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
    ]
    tableHoverGestureRecognizer.cancelsTouchesInView = false
    tableHoverGestureRecognizer.delegate = self
    view.addGestureRecognizer(tableHoverGestureRecognizer)
}

private func configureLaserPointer() {
    laserPointerView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(laserPointerView)
    NSLayoutConstraint.activate([
        laserPointerView.topAnchor.constraint(equalTo: view.topAnchor),
        laserPointerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        laserPointerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        laserPointerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    laserPointerGestureRecognizer.cancelsTouchesInView = false
    laserPointerGestureRecognizer.delaysTouchesBegan = false
    laserPointerGestureRecognizer.delaysTouchesEnded = false
    laserPointerGestureRecognizer.requiresExclusiveTouchType = false
    laserPointerGestureRecognizer.delegate = laserPointerGestureRecognizer
    laserPointerGestureRecognizer.onBegan = { [weak self] sample in
        self?.cancelBoundaryPagePullGesture()
        self?.callbacks.presentationInteractionBegan()
        self?.laserPointerView.begin(
            at: sample.location,
            timestamp: sample.timestamp
        )
    }
    laserPointerGestureRecognizer.onMoved = { [weak self] samples in
        self?.laserPointerView.move(samples)
    }
    laserPointerGestureRecognizer.onEnded = { [weak self] sample in
        self?.laserPointerView.end(
            at: sample.location,
            timestamp: sample.timestamp
        )
    }
    laserPointerGestureRecognizer.onCancelled = { [weak self] in
        self?.laserPointerView.cancel()
    }
    view.addGestureRecognizer(laserPointerGestureRecognizer)

    let state = appliedToolState
    laserPointerGestureRecognizer.isEnabled = state?.activeTool == .laserPointer
    if let state, state.activeTool == .laserPointer {
        laserPointerView.activate(
                style: state.laserPointerStyle,
                color: state.configuration(for: .laserPointer)?.color.uiColor
            )
    } else {
        laserPointerView.deactivate()
    }
}

private func configureGeometryInstrument() {
    geometryInstrumentView.translatesAutoresizingMaskIntoConstraints = false
    geometryInstrumentView.tintColor = view.tintColor
    geometryInstrumentView.setTool(activeGeometryTool)
    geometryInstrumentView.onInsertCircle = { [weak self] center, radius in
        self?.insertCompassCircle(center: center, radius: radius) ?? false
    }
    view.addSubview(geometryInstrumentView)
    NSLayoutConstraint.activate([
        geometryInstrumentView.topAnchor.constraint(equalTo: view.topAnchor),
        geometryInstrumentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        geometryInstrumentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        geometryInstrumentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
}

private func configureRegionSelection() {
    regionSelectionView.translatesAutoresizingMaskIntoConstraints = false
    regionSelectionView.configureAppearance(
        workspaceColor: CanvasConstants.workspaceBackground(for: documentMode)
    )
    regionSelectionView.onCancel = { [weak self] in
        self?.resetRegionSelection()
    }
    regionSelectionView.onRegionConfirmed = { [weak self] path in
        self?.completeImageWandRegionSelection(path)
    }
    view.addSubview(regionSelectionView)
    NSLayoutConstraint.activate([
        regionSelectionView.topAnchor.constraint(equalTo: view.topAnchor),
        regionSelectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        regionSelectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        regionSelectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
}

    /// Starts Wand's one-shot circling mode over the focused page. Page,
    /// scroll, laser, and instrument interaction is suspended until the
    /// selection completes or is cancelled.
    func beginImageWandSelection(checkpointGeneration: Int64) {
        guard isReaderModeEnabled == false,
            let host = hostsByPageID[focusedPageID],
            host.controller.view.superview != nil,
            regionSelectionView.superview != nil else { return }

        resetRegionSelection()
        let pageFrame = regionSelectionView.convert(
            host.controller.view.bounds,
            from: host.controller.view
        )
        // Keep the circling area clear of the floating top chrome.
        var available = pageFrame.intersection(regionSelectionView.bounds)
        let chromeInset = max(view.safeAreaInsets.top, topChromeHeight)
        if available.minY < chromeInset {
            let delta = chromeInset - available.minY
            available.origin.y += delta
            available.size.height -= delta
        }
        guard available.isNull == false,
            available.width >= 20,
            available.height >= 20 else { return }

        regionSelectionPageID = host.id
        regionSelectionCheckpointGeneration = checkpointGeneration
        suspendInteractionForRegionSelection()
        regionSelectionView.begin(selectionBounds: available)
    }

    func cancelImageWandSelection() {
        resetRegionSelection()
    }

    private func completeImageWandRegionSelection(_ overlayPath: CGPath) {
    guard let pageID = regionSelectionPageID,
        pageID == focusedPageID,
        let host = hostsByPageID[pageID],
        let pageToOverlay = pageToRegionOverlayTransform(for: host),
        regionTransformIsInvertible(pageToOverlay) else {
        resetRegionSelection()
        return
    }

    var overlayToPage = pageToOverlay.inverted()
    guard let pagePath = overlayPath.copy(using: &overlayToPage),
        let page = pages.first(where: { $0.id == pageID }),
        let pageBounds = validPageRegionBounds(
            pagePath.boundingBoxOfPath,
            in: page.markup.bounds
        ) else {
        resetRegionSelection()
        return
    }

    let selectionID = UUID()
    regionSelectionID = selectionID
    regionSelectionPagePath = pagePath
    regionSelectionContext = nil
    restoreInteractionAfterRegionSelection()
    refreshRegionSelectionPresentation()

    let checkpointGeneration = regionSelectionCheckpointGeneration
    regionSelectionCaptureTask?.cancel()
    regionSelectionCaptureTask = Task { @MainActor [weak self] in
        guard let self else { return }
        let context = await self.makeRegionSelectionContext(
            id: selectionID,
            pageID: pageID,
            pageBounds: pageBounds,
            pagePath: pagePath,
            checkpointGeneration: checkpointGeneration
        )
        guard Task.isCancelled == false,
            self.regionSelectionID == selectionID else { return }
        self.regionSelectionCaptureTask = nil
        guard let context else {
            self.resetRegionSelection()
            return
        }
        self.regionSelectionContext = context
        self.callbacks.imageWandSelectionCompleted(
            CanvasImageWandRequest(selection: context)
        )
        self.resetRegionSelection()
        }
    }

    private func makeRegionSelectionContext(
        id: UUID,
        pageID: UUID,
        pageBounds requestedBounds: CGRect,
        pagePath: CGPath,
        checkpointGeneration: Int64
    ) async -> CanvasRegionSelectionContext? {
        guard let index = pages.firstIndex(where: { $0.id == pageID }),
            let host = hostsByPageID[pageID],
            let liveMarkup = host.controller.markup,
            let pageBounds = validPageRegionBounds(
                requestedBounds,
                in: liveMarkup.bounds
            ) else { return nil }

        let pageSnapshot = pages[index].replacing(markup: liveMarkup)
        let maximumDimension = max(pageBounds.width, pageBounds.height)
        let minimumDimension = min(pageBounds.width, pageBounds.height)
        guard maximumDimension.isFinite,
            minimumDimension.isFinite,
            maximumDimension > 0,
            minimumDimension > 0 else { return nil }
        // Keep ordinary authored regions at native density, raise small
        // regions toward Image Playground's useful source-image floor, and
        // retain the existing 1,024-pixel longest-edge memory bound.
        let longestEdgeScale = CGFloat(Self.imagePlaygroundMaximumSourceDimension)
            / maximumDimension
        let shortestEdgeScale = CGFloat(Self.imagePlaygroundMinimumSourceDimension)
            / minimumDimension
        let scale = min(longestEdgeScale, max(1, shortestEdgeScale))
guard let renderedThumbnail = try? await CanvasDocumentExporter.shared.renderImage(
            pageSnapshot,
            cropRect: pageBounds,
            scale: scale,
            mode: .imagePlaygroundSource
        ), Task.isCancelled == false,
        let maskedThumbnail = Self.maskRegionThumbnail(
            renderedThumbnail,
            pagePath: pagePath,
            pageBounds: pageBounds
        ),
        let thumbnail = Self.prepareImagePlaygroundSource(maskedThumbnail)
    else {
        return nil
    }

    return CanvasRegionSelectionContext(
        id: id,
        pageID: pageID,
        pageNumber: index + 1,
        pageBounds: pageBounds,
        pagePath: pagePath.copy() ?? pagePath,
        thumbnail: thumbnail,
        checkpointGeneration: max(checkpointGeneration, 0)
    )
}

        /// Removes every pixel outside the user's actual lasso before the image is
        /// available to Image Playground. The exporter intentionally uses the
        /// path's bounding box for a bounded, foreground-only render; this second
        /// stage is the privacy boundary that prevents neighboring authored
        /// content inside that box from entering the Image Wand request.
    private static func maskRegionThumbnail(
        _ thumbnail: CGImage,
        pagePath: CGPath,
        pageBounds: CGRect
    ) -> CGImage? {
        guard thumbnail.width > 0,
            thumbnail.height > 0,
            pageBounds.width.isFinite,
            pageBounds.height.isFinite,
            pageBounds.width > 0,
            pageBounds.height > 0 else { return nil }

        let pixelSize = CGSize(width: thumbnail.width, height: thumbnail.height)
        let scaleX = pixelSize.width / pageBounds.width
        let scaleY = pixelSize.height / pageBounds.height
        var pageToThumbnail = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: -pageBounds.minX * scaleX,
            ty: -pageBounds.minY * scaleY
        )
        guard let thumbnailPath = pagePath.copy(using: &pageToThumbnail) else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let maskedImage = renderer.image { context in
            context.cgContext.saveGState()
            context.cgContext.addPath(thumbnailPath)
            context.cgContext.clip(using: .evenOdd)
            UIImage(cgImage: thumbnail).draw(in: CGRect(origin: .zero, size: pixelSize))
            context.cgContext.restoreGState()
        }
        return maskedImage.cgImage
    }

/// Image Playground requires both source-image dimensions to meet its
/// minimum. A lasso around one line of text can be much wider than it is
/// tall, so enlarge the useful pixels only up to the existing memory cap,
/// then center them on a transparent minimum-size canvas instead of
/// stretching the content or adding an opaque backdrop.
private static func prepareImagePlaygroundSource(_ image: CGImage) -> CGImage? {
    guard image.width > 0, image.height > 0 else { return nil }

    let longestDimension = max(image.width, image.height)
    let downscale = min(
        1,
        CGFloat(imagePlaygroundMaximumSourceDimension) / CGFloat(longestDimension)
    )
    let contentSize = CGSize(
        width: max(floor(CGFloat(image.width) * downscale), 1),
        height: max(floor(CGFloat(image.height) * downscale), 1)
    )
    let canvasSize = CGSize(
        width: max(
            contentSize.width,
            CGFloat(imagePlaygroundMinimumSourceDimension)
        ),
        height: max(
            contentSize.height,
            CGFloat(imagePlaygroundMinimumSourceDimension)
        )
    )

    guard contentSize != CGSize(width: image.width, height: image.height)
        || canvasSize != contentSize else {
        return image
    }

    let contentRect = CGRect(
        x: (canvasSize.width - contentSize.width) / 2,
        y: (canvasSize.height - contentSize.height) / 2,
        width: contentSize.width,
        height: contentSize.height
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
    return renderer.image { _ in
        UIImage(cgImage: image).draw(in: contentRect)
        }.cgImage
    }

    private func suspendInteractionForRegionSelection() {
        guard regionSelectionInteractionSnapshot == nil else { return }
        if tableTransformSession != nil {
            cancelTableTransform()
        }
        regionSelectionInteractionSnapshot = RegionSelectionInteractionSnapshot(
            scrollWasEnabled: scrollView.isScrollEnabled,
            laserGestureWasEnabled: laserPointerGestureRecognizer.isEnabled,
            geometryInteractionWasEnabled: geometryInstrumentView.isUserInteractionEnabled,
            pageInteractionByID: hostsByPageID.mapValues {
                $0.controller.view.isUserInteractionEnabled
            }
        )
        scrollView.isScrollEnabled = false
        laserPointerGestureRecognizer.isEnabled = false
        laserPointerView.cancel()
        geometryInstrumentView.isUserInteractionEnabled = false
        tableSelectionTapGestureRecognizer.isEnabled = false
        tableHoverGestureRecognizer.isEnabled = false
        for host in hostsByPageID.values {
            host.controller.view.isUserInteractionEnabled = false
        }
        refreshTableAccessibilityElements()
    }

    private func restoreInteractionAfterRegionSelection() {
        guard let snapshot = regionSelectionInteractionSnapshot else { return }
        regionSelectionInteractionSnapshot = nil
        scrollView.isScrollEnabled = snapshot.scrollWasEnabled
        let hasAppliedTool = appliedToolState != nil
        let isLaserPointerActive = appliedToolState?.activeTool == .laserPointer
        laserPointerGestureRecognizer.isEnabled = hasAppliedTool
            ? isLaserPointerActive
            : snapshot.laserGestureWasEnabled
        geometryInstrumentView.isUserInteractionEnabled = snapshot.geometryInteractionWasEnabled
        tableSelectionTapGestureRecognizer.isEnabled = isLaserPointerActive == false
        tableHoverGestureRecognizer.isEnabled = isLaserPointerActive == false
        for (pageID, host) in hostsByPageID {
            host.controller.view.isUserInteractionEnabled = hasAppliedTool
                ? isLaserPointerActive == false
                : (snapshot.pageInteractionByID[pageID] ?? true)
        }
        refreshTableAccessibilityElements()
        refreshInteractionPolicy()
    }

    private func resetRegionSelection() {
        regionSelectionCaptureTask?.cancel()
        regionSelectionCaptureTask = nil
        restoreInteractionAfterRegionSelection()
        regionSelectionID = nil
        regionSelectionPageID = nil
        regionSelectionPagePath = nil
        regionSelectionContext = nil
        regionSelectionCheckpointGeneration = 0
        regionSelectionView.clear()
    }

    private func pageToRegionOverlayTransform(
        for host: PageHost
    ) -> CGAffineTransform? {
        let nativeScale = host.renderedZoomScale
        guard nativeScale.isFinite, nativeScale > 0,
            host.controller.view.superview != nil,
            regionSelectionView.superview != nil else { return nil }

        let origin = regionSelectionView.convert(CGPoint.zero, from: host.controller.view)
        let xUnit = regionSelectionView.convert(
            CGPoint(x: nativeScale, y: 0),
            from: host.controller.view
        )
        let yUnit = regionSelectionView.convert(
            CGPoint(x: 0, y: nativeScale),
            from: host.controller.view
        )
        let transform = CGAffineTransform(
            a: xUnit.x - origin.x,
            b: xUnit.y - origin.y,
            c: yUnit.x - origin.x,
            d: yUnit.y - origin.y,
            tx: origin.x,
            ty: origin.y
        )
        return regionTransformIsInvertible(transform) ? transform : nil
    }

    private func regionTransformIsInvertible(_ transform: CGAffineTransform) -> Bool {
        let determinant = transform.a * transform.d - transform.b * transform.c
        return determinant.isFinite && abs(determinant) > CGFloat.ulpOfOne
    }

    private func refreshRegionSelectionPresentation() {
        guard let pageID = regionSelectionPageID,
            let pagePath = regionSelectionPagePath,
            let host = hostsByPageID[pageID],
            let pageToOverlay = pageToRegionOverlayTransform(for: host) else { return }
        var mutableTransform = pageToOverlay
        guard let overlayPath = pagePath.copy(using: &mutableTransform),
            overlayPath.boundingBoxOfPath.intersects(view.bounds) else {
            regionSelectionView.clear()
            return
        }
        regionSelectionView.presentPersistentPath(overlayPath)
    }

    private func validPageRegionBounds(_ requested: CGRect, in pageBounds: CGRect) -> CGRect? {
        guard requested.isNull == false,
            requested.isInfinite == false,
            requested.origin.x.isFinite,
            requested.origin.y.isFinite,
            requested.width.isFinite,
            requested.height.isFinite else { return nil }
        let bounded = requested.standardized.intersection(pageBounds)
        guard bounded.isNull == false,
            bounded.width >= 2,
            bounded.height >= 2 else { return nil }
        return bounded
    }

    private func insertCompassCircle(center: CGPoint, radius: CGFloat) -> Bool {
        guard isReaderModeEnabled == false,
            radius.isFinite, radius > 0,
            let host = pageHost(containingCircleAt: center, radius: radius),
            host.renderedZoomScale.isFinite,
            host.renderedZoomScale > 0 else { return false }

        callbacks.presentationInteractionBegan()
        let centerInHost = geometryInstrumentView.convert(center, to: host.controller.view)
        let edgeInHost = geometryInstrumentView.convert(
            CGPoint(x: center.x + radius, y: center.y),
            to: host.controller.view
        )
        let pageCenter = CGPoint(
            x: centerInHost.x / host.renderedZoomScale,
            y: centerInHost.y / host.renderedZoomScale
        )
        let pageRadius = hypot(
            edgeInHost.x - centerInHost.x,
            edgeInHost.y - centerInHost.y
        ) / host.renderedZoomScale
        guard pageRadius.isFinite, pageRadius > 0.5 else { return false }

        setFocusedPage(host.id, fromDirectInteraction: false)
        performInsertion(
            .circle(
                frame: CGRect(
                    x: pageCenter.x - pageRadius,
                    y: pageCenter.y - pageRadius,
                    width: pageRadius * 2,
                    height: pageRadius * 2
                )
            ),
            on: host.id
        )
        return true
    }

    private func pageHost(
        containingCircleAt center: CGPoint,
        radius: CGFloat
    ) -> PageHost? {
        let circleFrame = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        return pages.lazy.compactMap { self.hostsByPageID[$0.id] }.first { host in
            guard host.controller.view.isHidden == false else { return false }
            let pageFrame = host.controller.view.convert(
                host.controller.view.bounds,
                to: self.geometryInstrumentView
            )
            return pageFrame.contains(circleFrame)
        }
    }

    private func configureOuterPanForInputMode() {
        if isReaderModeEnabled {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        } else if appliedToolState?.activeTool == .laserPointer
            || inputMode == .pencilAndFinger {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        } else {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        }
    }

    private func configureScrollAxes() {
        if documentMode == .freeform {
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = true
            scrollView.decelerationRate = .normal
            return
        }
        scrollView.alwaysBounceVertical = pageLayout.scrollDirection == .vertical
        scrollView.alwaysBounceHorizontal = pageLayout.scrollDirection == .horizontal
        scrollView.decelerationRate = pageLayout.scrollDirection == .horizontal
            ? .fast
            : .normal
    }

    private func rebuildAllPageHosts() {
        if virtualizesPageHosts {
            _ = ensurePageHostMounted(for: focusedPageID)
        } else {
            for page in pages { mountPage(page) }
        }
        layoutDocumentAtRenderedScale()
    }

    @discardableResult
    private func ensurePageHostMounted(for pageID: UUID) -> PageHost? {
        guard hasCompletedDismantle == false else { return nil }
        if let host = hostsByPageID[pageID] { return host }
        guard let page = pages.first(where: { $0.id == pageID }) else { return nil }
        mountPage(page)
        return hostsByPageID[pageID]
    }

    /// Small notebooks keep every controller mounted. Large notebooks create
    /// the same fully configured PaperKit host on demand, then retain it only
    /// while it is visible, interactive, or owns native undo history.
    private func mountPage(_ page: CanvasPageSnapshot) {
        guard hasCompletedDismantle == false else { return }
        guard hostsByPageID[page.id] == nil else { return }
        guard let pageIndex = pages.firstIndex(where: { $0.id == page.id }) else { return }
        let initialHostFrame = scaledRect(
            layoutPlan.pageFrame(at: pageIndex),
            by: renderedZoomScale
        )
        let pageBounds = CGRect(origin: .zero, size: page.displaySize)
        let paperController = PaperMarkupViewController(
            markup: page.markup,
            supportedFeatureSet: PaperFeatureSetFactory.canvas
        )
        let host = PageHost(
            id: page.id,
            controller: paperController,
            markup: page.markup,
            paperTemplate: page.paperTemplate,
            geometry: page.geometry,
            background: page.background,
            tables: page.tables,
            // Keep the freeform template in a sibling vector presentation so
            // thin rules and dots remain tiled independently of PaperKit ink.
            rendersPaperTemplateInContentView: documentMode != .freeform
        )
        hostsByPageID[page.id] = host
        pageIDByController[ObjectIdentifier(paperController)] = page.id

        addChild(host.undoController)
        // PaperKit creates its private zooming scroll view the first time its
        // view is loaded. Give that view a real viewport before loading it: a
        // zero-sized host lets PaperKit derive a zero zoom scale, which UIKit
        // rejects in `_clampedZoomScale` during launch.
        host.undoController.view.frame = initialHostFrame
        host.undoController.addChild(paperController)
        paperController.view.frame = host.undoController.view.bounds
        paperController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.undoController.view.addSubview(paperController.view)
        paperController.didMove(toParent: host.undoController)

        paperController.delegate = self
        // Paper tones are authored light surfaces and do not invert with the
        // app. Keep PaperKit in that same appearance so it does not adapt black
        // strokes for a dark surface that is not actually behind the ink.
        paperController.overrideUserInterfaceStyle = .light
        paperController.contentView = host.contentView
        let isLaserPointerActive = appliedToolState?.activeTool == .laserPointer
        paperController.isEditable = isReaderModeEnabled == false
            && isLaserPointerActive == false
        paperController.view.isUserInteractionEnabled = isReaderModeEnabled == false
            && isLaserPointerActive == false
            && regionSelectionInteractionSnapshot == nil
        paperController.isRulerActive = isReaderModeEnabled == false
            && isRulerActive
            && page.id == focusedPageID
        paperController.contentVisibleFrame = pageBounds
        paperController.zoomRange = renderedZoomScale...renderedZoomScale
        host.renderedZoomScale = renderedZoomScale
        host.hasConfiguredGeometry = true
        paperController.indirectPointerTouchMode = .selection
        paperController.view.backgroundColor = .clear
        paperController.view.clipsToBounds = false
        paperController.view.isHidden = true
        applyInputMode(inputMode, to: paperController)
        if let appliedToolState,
            let nativeTool = CanvasNativeToolMapper.nativeTool(for: appliedToolState) {
            paperController.drawingTool = nativeTool
        }
        if #available(iOS 27.0, *) {
            let scrollConfiguration = paperController.scrollConfiguration
            scrollConfiguration.visibleScrollIndicators = []
            scrollConfiguration.bounces = []
            scrollConfiguration.alwaysBounces = []
            scrollConfiguration.bouncesZoom = false
            scrollConfiguration.contentInset = .zero
            scrollConfiguration.contentInsetAdjustmentBehavior = .never
            scrollConfiguration.scrollsToTop = false
            // The outer notebook owns navigation and zoom, but PaperKit still
            // needs its internal scroll view enabled for selection and drawing
            // gesture routing. Disabling it requires physical-Pencil proof.
            scrollConfiguration.isScrollEnabled = true
        } else if #available(iOS 26.1, *) {
            paperController.showsVerticalScrollIndicator = false
            paperController.showsHorizontalScrollIndicator = false
        }

        documentView.addSubview(host.decorationView)
        documentView.addSubview(host.undoController.view)
        host.undoController.didMove(toParent: self)
        host.decorationView.renderScale = renderedZoomScale
        host.decorationView.frame = initialHostFrame
        if documentMode == .freeform {
            // The transparent template presentation remains independent of
            // PaperKit before, during, and after a pinch. It is intentionally
            // non-interactive, so Pencil and finger input still reaches the
            // native editor underneath it.
            host.decorationView.setOverlayPresentationActive(true)
            documentView.bringSubviewToFront(host.decorationView)
        }
    }

    private func unmountPage(id: UUID) {
        if activeTableTarget?.pageID == id { clearActiveTableTarget() }
        pendingPaperTemplates.removeValue(forKey: id)
        guard let host = hostsByPageID[id] else { return }
        host.controller.undoManager?.removeAllActions()
        _ = detachPageHost(id: id)
    }

    @discardableResult
    private func detachPageHost(id: UUID) -> PageHost? {
        guard let host = hostsByPageID.removeValue(forKey: id) else { return nil }
        undoHistoryPageRecency.removeAll { $0 == id }
        if let historyManager = host.controller.undoManager {
            let managerID = ObjectIdentifier(historyManager)
            pendingAppUndoRegistrations.removeValue(forKey: managerID)
            undoManagersFlushingAppRegistrations.remove(managerID)
        }
        pageIDByController.removeValue(forKey: ObjectIdentifier(host.controller))
        host.controller.delegate = nil
        host.controller.view.endEditing(true)
        host.controller.isEditable = false
        host.controller.isRulerActive = false
        host.contentView.setRenderingActive(false)
        host.decorationView.setRenderingActive(false)
        host.controller.willMove(toParent: nil)
        host.controller.view.removeFromSuperview()
        host.controller.removeFromParent()
        if let markupBounds = host.controller.markup?.bounds {
            host.controller.selectedMarkup = PaperMarkup(bounds: markupBounds)
        }
        host.controller.contentView = nil
        host.controller.markup = nil
        host.undoController.willMove(toParent: nil)
        host.undoController.view.removeFromSuperview()
        host.undoController.removeFromParent()
        host.decorationView.removeFromSuperview()
        return host
    }

    private func layoutDocumentAtRenderedScale() {
        let plan = layoutPlan
        let logicalSize = plan.contentSize
        let size = CGSize(
            width: logicalSize.width * renderedZoomScale,
            height: logicalSize.height * renderedZoomScale
        )
        documentView.transform = .identity
        documentView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        for (index, page) in pages.enumerated() {
            guard let host = hostsByPageID[page.id] else { continue }
            host.decorationView.renderScale = renderedZoomScale
            host.decorationView.frame = scaledRect(
                plan.pageFrame(at: index),
                by: renderedZoomScale
            )
        }
    }

    private func lockPaperViewport(for host: PageHost) {
        guard host.isApplyingGeometry == false else { return }
        guard hasActiveContact == false else {
            pendingRenderedPageWindowUpdate = true
            return
        }
        host.isApplyingGeometry = true
        let zoomRange = host.renderedZoomScale...host.renderedZoomScale
        if host.controller.zoomRange != zoomRange { host.controller.zoomRange = zoomRange }
        guard let page = pages.first(where: { $0.id == host.id }) else {
            host.isApplyingGeometry = false
            return
        }
        let bounds = CGRect(origin: .zero, size: page.displaySize)
        if approximatelyEqual(host.controller.contentVisibleFrame, bounds) == false {
            // PaperKit can transiently clear this value when an ancestor zoom
            // transform changes. Resolve its existing (bounded) layout before
            // restoring the authored viewport; this does not resize the host.
            host.controller.view.layoutIfNeeded()
            host.controller.contentVisibleFrame = bounds
        }
        host.isApplyingGeometry = false
    }

    private func scaledRect(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private func configureTransientZoomRange() {
        scrollView.minimumZoomScale = minimumLogicalZoomScale / renderedZoomScale
        scrollView.maximumZoomScale =
            CanvasConstants.absoluteZoomRange.upperBound / renderedZoomScale
    }

    private func resetPresentationZoomToIdentityForNativeBasisChange() {
        // A large-board basis can make the normal minimum outer zoom greater
        // than one (for example 0.5 / 0.375). Temporarily admit identity so
        // UIKit cannot clamp this reset while documentView's base frame changes.
        if scrollView.minimumZoomScale > 1 {
            scrollView.minimumZoomScale = 1
        }
        if scrollView.maximumZoomScale < 1 {
            scrollView.maximumZoomScale = 1
        }
        if abs(scrollView.zoomScale - 1) > 0.0001 {
            scrollView.setZoomScale(1, animated: false)
        }
        #if DEBUG
        lastNativeBasisResetReachedIdentityForTesting =
            abs(scrollView.zoomScale - 1) <= 0.0001
        #endif
    }

    private func resolvedNativeRenderScale(for logicalZoomScale: CGFloat) -> CGFloat {
        CanvasLiveRenderScale.nativeScale(
            pageSizes: pageSizes,
            displayScale: currentViewportEnvironment.displayScale,
            documentMode: documentMode,
            logicalZoomScale: logicalZoomScale,
            isUnderMemoryPressure: isUnderMemoryPressure
        )
    }

    private func configureHost(
        _ host: PageHost,
        at pageIndex: Int,
        renderedAt scale: CGFloat,
        hidden: Bool,
        force: Bool
    ) {
        let scaleChanged = abs(host.renderedZoomScale - scale) > 0.0001
        let logicalFrame = layoutPlan.pageFrame(at: pageIndex)
        let targetFrame = CGRect(
            x: logicalFrame.minX * renderedZoomScale,
            y: logicalFrame.minY * renderedZoomScale,
            width: logicalFrame.width * scale,
            height: logicalFrame.height * scale
        )
        let geometryChanged = approximatelyEqual(host.undoController.view.frame, targetFrame) == false
        let visibilityChanged = host.controller.view.isHidden != hidden
        let geometryMustApply = host.hasConfiguredGeometry == false
            || (geometryChanged && (hidden == false || visibilityChanged))
        let shouldRefreshVisibleHost = force && hidden == false

        // A retained hidden host only needs to follow its page origin. Keeping
        // its neutral-size bounds avoids waking PaperKit's layout/tile stack.
        if hidden,
            host.controller.view.isHidden,
            host.hasConfiguredGeometry,
            scaleChanged == false {
            if geometryChanged { host.undoController.view.frame.origin = targetFrame.origin }
            return
        }
        guard shouldRefreshVisibleHost
            || scaleChanged
            || geometryMustApply
            || visibilityChanged else { return }

        guard hasActiveContact == false else {
            pendingRenderedPageWindowUpdate = true
            return
        }

        // Hide before changing PaperKit's native zoom. This avoids presenting a
        // half-laid-out tile hierarchy while the controller rebuilds its canvas.
        host.controller.view.isHidden = true
        guard shouldRefreshVisibleHost || scaleChanged || geometryMustApply else {
            host.controller.view.isHidden = hidden
            return
        }

        host.isApplyingGeometry = true
        host.renderedZoomScale = scale
        let zoomRange = scale...scale
        if host.controller.zoomRange != zoomRange { host.controller.zoomRange = zoomRange }

        host.undoController.view.frame = targetFrame
        host.controller.view.frame = host.undoController.view.bounds
        host.undoController.view.layoutIfNeeded()
        host.controller.view.layoutIfNeeded()
        let pageBounds = CGRect(origin: .zero, size: pages[pageIndex].displaySize)
        if approximatelyEqual(host.controller.contentVisibleFrame, pageBounds) == false {
            host.controller.contentVisibleFrame = pageBounds
        }
        host.hasConfiguredGeometry = true
        host.isApplyingGeometry = false
        host.controller.view.isHidden = hidden
    }

    private func updateRenderedPageWindow(force: Bool = false) {
        guard hasCompletedDismantle == false,
            hasAppliedInitialViewport,
            hasActiveContact == false,
            isApplyingGeometry == false,
            isZoomScrubbing == false,
            scrollView.isZooming == false else {
            pendingRenderedPageWindowUpdate = true
            return
        }

        pendingRenderedPageWindowUpdate = false
        let visibleRect = visibleDocumentRect
        let prefetchedRect: CGRect
        switch pageLayout.scrollDirection {
        case .vertical:
            let overscan = visibleRect.height * Self.renderedPageOverscanViewports
            prefetchedRect = visibleRect.insetBy(dx: 0, dy: -overscan)
        case .horizontal:
            let overscan = visibleRect.width * Self.renderedPageOverscanViewports
            prefetchedRect = visibleRect.insetBy(dx: -overscan, dy: 0)
        }

        let plan = layoutPlan
        let exactlyVisible = plan.visiblePageIndices(
            visibleDocumentRect: visibleRect
        )
        let exactlyVisibleSet = Set(exactlyVisible)
        let prefetchLimit = isUnderMemoryPressure ? exactlyVisible.count : max(exactlyVisible.count, 2)
        let nearestPrefetch = pages.indices
            .filter {
                exactlyVisibleSet.contains($0) == false
                    && plan.pageFrame(at: $0).intersects(prefetchedRect)
            }
            .sorted {
                let lhsDistance = CanvasStackLayout.primaryAxisDistance(
                    from: plan.pageFrame(at: $0),
                    to: visibleRect,
                    pageLayout: pageLayout
                )
                let rhsDistance = CanvasStackLayout.primaryAxisDistance(
                    from: plan.pageFrame(at: $1),
                    to: visibleRect,
                    pageLayout: pageLayout
                )
                return lhsDistance < rhsDistance
            }
            .prefix(max(0, prefetchLimit - exactlyVisible.count))
        let renderedIndices = exactlyVisibleSet.union(nearestPrefetch)

        var requiredPageIDs = Set(renderedIndices.map { pages[$0].id })
        requiredPageIDs.insert(focusedPageID)
        if let programmaticNavigationPageID {
            requiredPageIDs.insert(programmaticNavigationPageID)
        }

        let mountedPageIDsBeforeUpdate = Set(hostsByPageID.keys)
        if virtualizesPageHosts {
            for pageID in requiredPageIDs {
                _ = ensurePageHostMounted(for: pageID)
            }
        } else {
            for page in pages { mountPage(page) }
        }

        for (index, page) in pages.enumerated() {
            guard let host = hostsByPageID[page.id] else { continue }
            if renderedIndices.contains(index) {
                host.contentView.setRenderingActive(true)
                host.decorationView.setRenderingActive(true)
                configureHost(
                    host,
                    at: index,
                    renderedAt: renderedZoomScale,
                    hidden: false,
                    force: force
                )
            } else {
                host.contentView.setRenderingActive(false)
                host.decorationView.setRenderingActive(false)
                configureHost(
                    host,
                    at: index,
                    // Retained hidden hosts must not silently return an
                    // oversized imported page or board to a full 1x surface.
                    renderedAt: renderedZoomScale,
                    hidden: true,
                    force: force
                )
            }
        }

        if virtualizesPageHosts {
            let evictionCandidates = hostsByPageID.keys.filter {
                requiredPageIDs.contains($0) == false
            }
            for pageID in evictionCandidates {
                evictPageHostIfSafe(
                    pageID: pageID,
                    discardingUndoHistory: isUnderMemoryPressure
                )
            }
        }

        if mountedPageIDsBeforeUpdate != Set(hostsByPageID.keys) {
            refreshTableAccessibilityElements()
        }
    }

    private func evictPageHostIfSafe(
        pageID: UUID,
        discardingUndoHistory: Bool = false
    ) {
        guard virtualizesPageHosts,
            pageID != focusedPageID,
            pageID != programmaticNavigationPageID,
            hasActiveContact == false,
            isDocumentSynchronizationPending == false,
            pendingPaperTemplates[pageID] == nil,
            queuedInsertionCountByPageID[pageID, default: 0] == 0,
            pagesPreparingInsertionHistory.contains(pageID) == false,
            pendingHistoryCommands.contains(where: { $0.pageID == pageID }) == false,
            hasPendingAppUndoRegistration(for: pageID) == false,
            pendingPageCommandsProtectHost(for: pageID) == false,
            regionSelectionPageID != pageID,
            regionSelectionContext?.pageID != pageID,
            activeTableTarget?.pageID != pageID,
            activeTableCell?.pageID != pageID,
            hoveredTableCell?.pageID != pageID,
            tableTransformSession?.pageID != pageID,
            let host = hostsByPageID[pageID],
            host.controller.presentedViewController == nil,
            host.controller.view.isFirstResponder == false else { return }

        if let historyManager = host.controller.undoManager {
            guard historyManager.isUndoing == false,
                historyManager.isRedoing == false,
                historyManager.groupingLevel == 0 else { return }
            // Ordinarily native undo pins a page host so history survives a
            // far jump. Under memory pressure, candidates are outside the
            // rendered, focused, and programmatic-navigation set. Their
            // canonical snapshot is verified below before the now-inactive
            // history is discarded and the heavyweight PaperKit host leaves
            // memory. The current page's undo stack is never eligible here.
            guard discardingUndoHistory
            || (historyManager.canUndo == false && historyManager.canRedo == false) else {
            return
        }
    }

        let selectedFrame = host.controller.selectedMarkup.contentsRenderFrame
        if selectedFrame.isNull == false, selectedFrame.isEmpty == false {
            guard discardingUndoHistory,
                let markupBounds = host.controller.markup?.bounds else { return }
            // Selection is transient controller state and otherwise keeps the
            // entire offscreen PaperKit hierarchy alive. Memory pressure may
            // retire that selection only after every interaction/undo safety
            // gate above has closed; authored content is verified below.
            host.controller.selectedMarkup = PaperMarkup(bounds: markupBounds)
        }

        // A framework mutation can arrive without a delegate callback. Make
        // the canonical page snapshot current before deciding the host is
        // disposable, then require every remountable surface to match it.
        deliverMarkupIfChanged(pageID: pageID)
        guard let page = pages.first(where: { $0.id == pageID }),
            let markup = host.controller.markup,
            markup == host.lastDeliveredMarkup,
            markup == page.markup,
            host.contentView.template == page.paperTemplate,
            host.contentView.geometry == page.geometry,
            host.contentView.pageBackground == page.background,
            host.contentView.tables == page.tables else { return }

        host.controller.undoManager?.removeAllActions()
        _ = detachPageHost(id: pageID)
    }
    private func pendingPageCommandsProtectHost(for pageID: UUID) -> Bool {
        pendingPageCommands.contains { command in
            switch command {
            case let .insert(page, _, _, _), let .replace(page):
                page.id == pageID
            case let .scroll(id, _), let .navigateToRegion(id, _, _), let .activate(id, _, _):
                id == pageID
            }
        }
    }
private func applyInputMode(
    _ mode: CanvasInputMode,
    to paperController: PaperMarkupViewController
) {
    paperController.directTouchAutomaticallyDraws = false
    paperController.directTouchMode = mode == .pencilAndFinger ? .drawing : .selection
}
private func performPaperTemplateChange(
    _ template: CanvasPaperTemplate,
    for pageID: UUID,
    registersUndo: Bool
) {
    guard let index = pages.firstIndex(where: { $0.id == pageID }),
        let host = ensurePageHostMounted(for: pageID) else { return }
    let previous = pages[index]
    guard previous.paperTemplate != template else { return }
    if registersUndo {
        let previousTemplate = previous.paperTemplate
            registerAppOwnedUndo(pageID: pageID, actionName: "Change Paper") { target in
                target.performPaperTemplateChange(
                    previousTemplate,
                    for: pageID,
                    registersUndo: true
                )
            }
        }

        pages[index] = previous.replacing(paperTemplate: template)
        host.contentView.template = template
        host.decorationView.template = template
        callbacks.paperTemplateChanged(pageID, template)
        if pageID == focusedPageID { publishUndoAvailability() }
    }
    private func performPageInsertion(
        _ page: CanvasPageSnapshot,
        at requestedIndex: Int,
        scrollTo: Bool,
        animated: Bool = false
    ) {
        captureAndPublishCurrentViewport()
        let retainedID = focusedPageID
        let retainedViewport = currentViewportState()
        let index = min(max(requestedIndex, pages.startIndex), pages.endIndex)

        isApplyingGeometry = true
        pages.insert(page, at: index)
        invalidateLayoutPlan()
        if virtualizesPageHosts == false || scrollTo {
            mountPage(page)
        }
        isApplyingGeometry = false

        if scrollTo {
            // Install the new geometry while keeping the old page on screen,
            // then perform one real transition to the inserted page. Applying
            applyViewport(
                viewportForCurrentPageMode(
                    retainedViewport,
                    prefersHorizontalFit: usesHorizontalPageFit
                ),
                focusedOn: retainedID,
                preserveFocusedPage: true
            )
        setFocusedPage(page.id, fromDirectInteraction: false)
        scrollPageToTop(id: page.id, animated: animated)
    } else {
        setFocusedPage(retainedID, fromDirectInteraction: false)
        applyViewport(retainedViewport, focusedOn: retainedID, preserveFocusedPage: true)
    }
    publishUndoAvailability()
}
    private func performPageRemoval(id: UUID, focusOn requestedFocusID: UUID) {
        guard pages.count > 1,
            let removalIndex = pages.firstIndex(where: { $0.id == id }) else { return }
        captureAndPublishCurrentViewport()
        let retainedViewport = currentViewportState()
        cancelBoundaryPagePullGesture()
        isApplyingGeometry = true
        pages.remove(at: removalIndex)
        invalidateLayoutPlan()
        unmountPage(id: id)
        isApplyingGeometry = false

        let fallbackIndex = min(removalIndex, pages.index(before: pages.endIndex))
        let focusID = pages.contains(where: { $0.id == requestedFocusID })
            ? requestedFocusID
            : pages[fallbackIndex].id
        lastPublishedViewport = nil
        lastPublishedViewportPageID = nil
        setFocusedPage(focusID, fromDirectInteraction: false)
        applyViewport(
            viewportForCurrentPageMode(
                retainedViewport,
                prefersHorizontalFit: usesHorizontalPageFit
            ),
            focusedOn: focusID,
            preserveFocusedPage: true
        )
    }
    private func performPageReplacement(
        _ page: CanvasPageSnapshot,
        registersUndo: Bool
    ) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }),
            let host = ensurePageHostMounted(for: page.id) else { return }
        let previous = pages[index]
        guard previous != page else { return }
        let retainedViewport = currentViewportState()
        let wasFocused = focusedPageID == page.id
        pages[index] = page
    invalidateLayoutPlan()
    host.lastDeliveredMarkup = page.markup
    host.contentView.template = page.paperTemplate
    host.contentView.geometry = page.geometry
    host.contentView.pageBackground = page.background
    host.contentView.tables = page.tables
    host.decorationView.template = page.paperTemplate
    host.decorationView.pageBackground = page.background
    host.controller.markup = page.markup
    host.controller.selectedMarkup = PaperMarkup(bounds: page.markup.bounds)
    host.hasConfiguredGeometry = false
    if let activeTableTarget,
        activeTableTarget.pageID == page.id,
        page.tables.contains(where: { $0.id == activeTableTarget.tableID }) == false {
        clearActiveTableTarget()
    }
    isApplyingGeometry = false
    setFocusedPage(focusedPageID, fromDirectInteraction: false)
    applyViewport(
        viewportForCurrentPageMode(
            retainedViewport,
            prefersHorizontalFit: usesHorizontalPageFit
        ),
        focusedOn: focusedPageID,
        preserveFocusedPage: true
    )
    callbacks.pageReplaced(page)
    if wasFocused { publishUndoAvailability() }
}
private func viewport(
    _ viewport: CanvasViewportState,
    replacing oldGeometry: CanvasPageGeometry,
    with newGeometry: CanvasPageGeometry
) -> CanvasViewportState {
    let delta = (newGeometry.quarterTurns - oldGeometry.quarterTurns + 4) % 4
    guard delta > 0 else { return viewport }
    return (0..<delta).reduce(viewport) { value, _ in
        value.rotated(clockwise: true)
    }
}
private func performLegacyActivation(
    id: UUID,
    markup: PaperMarkup,
    viewport: CanvasViewportState
) {
    if let index = pages.firstIndex(where: { $0.id == id }),
        let host = ensurePageHostMounted(for: id) {
        let existing = pages[index]
        pages[index] = existing.replacing(markup: markup)
        host.lastDeliveredMarkup = markup
        host.controller.markup = markup
        host.controller.selectedMarkup = PaperMarkup(bounds: markup.bounds)
        host.controller.undoManager?.removeAllActions()
        lockPaperViewport(for: host)
    } else {
        let page = CanvasPageSnapshot(id: id, markup: markup, viewport: viewport)
        performPageInsertion(page, at: pages.endIndex, scrollTo: false)
    }
    setFocusedPage(id, fromDirectInteraction: false)
    applyViewport(
        restoredViewportForCurrentPageMode(viewport),
        focusedOn: id
    )
    publishUndoAvailability()
}
    // Direct manipulation owns the viewport from this point forward. Stop an
    // in-flight page animation and discard its saved destination before a pan
    // or zoom can publish a new user-authored viewport.
    private func cancelProgrammaticNavigationForDirectInteraction() {
        guard programmaticNavigationPageID != nil
            || programmaticNavigationViewport != nil else { return }
        programmaticNavigationPageID = nil
        programmaticNavigationViewport = nil
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        updateFocusFromVisibleArea(unlessDirectInteraction: false)
        publishViewport()
    }


    private func scrollPageToTop(id: UUID, animated: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        updateContentInsets()
        let scale = effectiveZoomScale
        let target = CanvasStackLayout.targetContentOffset(
            pageIndex: index,
            viewport: CanvasViewportState(),
            viewportSize: scrollView.bounds.size,
            safeAreaInsets: view.safeAreaInsets,
            zoomScale: scale,
            layoutPlan: layoutPlan,
            topChromeHeight: topChromeHeight
        )
        let shouldAnimate = animated
            && UIAccessibility.isReduceMotionEnabled == false
            && (abs(scrollView.contentOffset.x - target.x) > 0.5
                || abs(scrollView.contentOffset.y - target.y) > 0.5)
        var destinationViewport = CanvasStackLayout.viewportState(
            focusedPageIndex: index,
            visibleDocumentRect: CanvasStackLayout.visibleDocumentRect(
                contentOffset: target,
                viewportSize: scrollView.bounds.size,
                safeAreaInsets: view.safeAreaInsets,
                zoomScale: scale,
                topChromeHeight: topChromeHeight
            ),
            zoomScale: scale,
            layoutPlan: layoutPlan
        )
        if documentMode == .paged,
            pageLayout.scrollDirection == .horizontal,
            usesHorizontalPageFit {
            destinationViewport.usesFitPage = true
        }
        if pages[index].viewport != destinationViewport {
            pages[index] = pages[index].replacing(viewport: destinationViewport)
        }
        programmaticNavigationPageID = shouldAnimate ? id : nil
        programmaticNavigationViewport = shouldAnimate ? destinationViewport : nil
        scrollView.setContentOffset(target, animated: shouldAnimate)
        if shouldAnimate == false {
            updateRenderedPageWindow()
            publishViewport()
        }
    }
    private func applyViewport(
        _ viewport: CanvasViewportState,
        focusedOn pageID: UUID,
        preserveFocusedPage: Bool = false,
        animated: Bool = false
    ) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
            ensurePageHostMounted(for: pageID) != nil,
            scrollView.bounds.width > 0,
            scrollView.bounds.height > 0 else { return }
        let resolvedViewport = viewportForCurrentPageMode(
            viewport,
            prefersHorizontalFit: false
        )
        isApplyingGeometry = true
        let scale = resolvedViewport.stackZoomScale
        let nativeScale = resolvedNativeRenderScale(for: scale)
        let nativeScaleChanged = abs(renderedZoomScale - nativeScale) > 0.0001
        if nativeScaleChanged {
            // Return to the untransformed basis before changing documentView's
            // authored frame. The retained viewport below restores the exact
            // logical center after the new basis is installed.
            resetPresentationZoomToIdentityForNativeBasisChange()
            renderedZoomScale = nativeScale
        }
        // Page insertion/reordering can change document geometry without
        // changing the native scale, so the lightweight outer layout still
        // needs to follow every applied viewport.
        layoutDocumentAtRenderedScale()
        configureTransientZoomRange()
        let presentationScale = scale / renderedZoomScale
        if abs(scrollView.zoomScale - presentationScale) > 0.0001 {
            scrollView.setZoomScale(presentationScale, animated: false)
        }
        updateContentInsets()
        let offset = CanvasStackLayout.targetContentOffset(
            pageIndex: pageIndex,
            viewport: resolvedViewport,
            viewportSize: scrollView.bounds.size,
            safeAreaInsets: view.safeAreaInsets,
            zoomScale: scale,
            layoutPlan: layoutPlan,
            topChromeHeight: topChromeHeight
        )
        let shouldAnimate = animated
            && UIAccessibility.isReduceMotionEnabled == false
            && (abs(scrollView.contentOffset.x - offset.x) > 0.5
            || abs(scrollView.contentOffset.y - offset.y) > 0.5)
        if let destinationIndex = pages.firstIndex(where: { $0.id == pageID }),
            pages[destinationIndex].viewport != resolvedViewport {
            pages[destinationIndex] = pages[destinationIndex].replacing(
                viewport: resolvedViewport
            )
        }
        programmaticNavigationPageID = shouldAnimate ? pageID : nil
        programmaticNavigationViewport = shouldAnimate ? resolvedViewport : nil
        scrollView.setContentOffset(offset, animated: shouldAnimate)
        isApplyingGeometry = false
        updatePaperTemplatePresentationWindows()
        settledEnvironment = currentViewportEnvironment
        if preserveFocusedPage || shouldAnimate {
            setFocusedPage(pageID, fromDirectInteraction: false)
        } else {
            updateFocusFromVisibleArea(unlessDirectInteraction: true)
        }
        updateRenderedPageWindow(force: nativeScaleChanged)
        if shouldAnimate == false { publishViewport() }
    }
    private func applyTransientZoom(
        _ viewport: CanvasViewportState,
        focusedOn pageID: UUID
    ) {
    guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
        scrollView.bounds.width > 0,
        scrollView.bounds.height > 0 else { return }
    isApplyingGeometry = true
    let scale = viewport.stackZoomScale
    scrollView.setZoomScale(scale / renderedZoomScale, animated: false)
    updateContentInsets()
    let offset = CanvasStackLayout.targetContentOffset(
        pageIndex: pageIndex,
        viewport: viewport,
        viewportSize: scrollView.bounds.size,
        safeAreaInsets: view.safeAreaInsets,
        zoomScale: scale,
        layoutPlan: layoutPlan,
        topChromeHeight: topChromeHeight
    )
    scrollView.setContentOffset(offset, animated: false)
    isApplyingGeometry = false
    updatePaperTemplatePresentationWindows()
    setFocusedPage(pageID, fromDirectInteraction: false)
    scheduleTransientViewportPublication()
}
private func settleTransientZoom() {
    guard hasAppliedInitialViewport else { return }
    guard hasActiveContact == false else {
        shouldSettleTransientZoomAfterContact = true
        return
    }
    shouldSettleTransientZoomAfterContact = false
    let retainedPageID = focusedPageID
    let retainedViewport = currentViewportState()
    let targetNativeScale = resolvedNativeRenderScale(
        for: retainedViewport.stackZoomScale
    )
    let targetPresentationScale = retainedViewport.stackZoomScale / targetNativeScale
    let offset = pages.firstIndex(where: { $0.id == retainedPageID }).map {
        CanvasStackLayout.targetContentOffset(
            pageIndex: $0,
            viewport: retainedViewport,
            viewportSize: scrollView.bounds.size,
            safeAreaInsets: view.safeAreaInsets,
            zoomScale: retainedViewport.stackZoomScale,
            layoutPlan: layoutPlan,
            topChromeHeight: topChromeHeight
        )
    } ?? scrollView.contentOffset
    let alreadySettled = abs(scrollView.zoomScale - targetPresentationScale) <= 0.0001
        && abs(scrollView.contentOffset.x - offset.x) <= 0.5
        && abs(scrollView.contentOffset.y - offset.y) <= 0.5
    guard alreadySettled == false else {
        updateRenderedPageWindow()
        publishViewport()
        return
    }
    applyViewport(retainedViewport, focusedOn: retainedPageID, preserveFocusedPage: true)
}
private var effectiveZoomScale: CGFloat {
    let scale = renderedZoomScale * scrollView.zoomScale
    guard scale.isFinite, scale > 0 else { return CanvasConstants.defaultZoomScale }
    return scale
}
private func updateContentInsets() {
    let plan = layoutPlan
    let insets = CanvasStackLayout.contentInset(
        viewportSize: scrollView.bounds.size,
        safeAreaInsets: view.safeAreaInsets,
        zoomScale: effectiveZoomScale,
        contentSize: plan.contentSize,
        pageSizes: pageSizes,
        pageLayout: pageLayout,
        topChromeHeight: topChromeHeight
    )
    if scrollView.contentInset != insets {
        scrollView.contentInset = insets
        scrollView.scrollIndicatorInsets = insets
    }
}
@discardableResult
private func expandFreeformCanvasIfNeeded(
    visibleRect: CGRect? = nil
) -> Bool {
    guard documentMode == .freeform,
        hasAppliedInitialViewport,
        hasActiveContact == false,
        pagesPreparingInsertionHistory.isEmpty,
        isApplyingGeometry == false,
        scrollView.isZooming == false,
        isZoomScrubbing == false,
        pages.count == 1,
        let page = pages.first else { return false }
    let expansion = FreeformCanvasLayout.expansion(
        visibleRect: visibleRect ?? visibleDocumentRect,
        canvasSize: page.displaySize,
        zoomScale: effectiveZoomScale
    )
    return performFreeformExpansion(expansion)
}
@discardableResult
private func performFreeformExpansion(
    _ expansion: FreeformCanvasExpansion
) -> Bool {
    guard documentMode == .freeform,
        expansion.isEmpty == false,
        pages.count == 1,
        let page = pages.first,
        let host = hostsByPageID[page.id],
        let geometry = FreeformCanvasLayout.expandedGeometry(
            page.geometry,
            expansion: expansion
        ) else { return false }
    let wasFocused = focusedPageID == page.id
    let currentViewport = currentViewportState()
    let latestPage = page
    let translatedViewport = FreeformCanvasLayout.translatedViewport(
        currentViewport,
        from: latestPage.displaySize,
        expansion: expansion
    )
    let oldContentOffset = scrollView.contentOffset
    let scale = effectiveZoomScale
    let translation = expansion.contentTranslation
    var markup = latestPage.markup
    markup.transformContent(
        CGAffineTransform(translationX: translation.x, y: translation.y)
    )
    markup.bounds = CGRect(origin: .zero, size: geometry.displaySize)
    let translatedTables = latestPage.tables.map { table in
        CanvasTable(
            id: table.id,
            origin: CGPoint(
                x: table.origin.x + translation.x,
                y: table.origin.y + translation.y
            ),
            rowCount: table.rowCount,
            columnCount: table.columnCount,
            cellSize: table.cellSize,
            cornerRadius: table.cornerRadius
        )
    }
    let replacement = latestPage.replacing(
        markup: markup,
        tables: translatedTables,
        viewport: translatedViewport,
        geometry: geometry
    )
    isApplyingGeometry = true
    pages[0] = replacement
    invalidateLayoutPlan()
    host.lastDeliveredMarkup = markup
    host.contentView.geometry = geometry
    host.contentView.tables = translatedTables
    let historyManager = host.controller.undoManager
    let shouldResumeUndoRegistration = historyManager?.isUndoRegistrationEnabled == true
    if shouldResumeUndoRegistration { historyManager?.disableUndoRegistration() }
    if #available(iOS 27.0, *) {
        let selectedElementIDs = host.controller.selection
        host.controller.markup = markup
        host.controller.selection = selectedElementIDs
    } else {
        host.controller.markup = markup
        host.controller.selectedMarkup = PaperMarkup(bounds: markup.bounds)
    }
    if shouldResumeUndoRegistration { historyManager?.enableUndoRegistration() }
    // Native PaperKit undo closures captured before a whole-document
    // coordinate rebase target the old bounds. Replaying them afterward
    // can move or resurrect content at stale coordinates. Public APIs do
    // not expose a way to transform those closures, so discard them at
    // this rare automatic boundary instead of retaining corrupt history.
    historyManager?.removeAllActions()
    let nativeScale = resolvedNativeRenderScale(for: scale)
    let nativeScaleChanged = abs(renderedZoomScale - nativeScale) > 0.0001
    if nativeScaleChanged {
        resetPresentationZoomToIdentityForNativeBasisChange()
        renderedZoomScale = nativeScale
    }
    layoutDocumentAtRenderedScale()
    configureTransientZoomRange()
    let presentationScale = scale / renderedZoomScale
    if abs(scrollView.zoomScale - presentationScale) > 0.0001 {
        scrollView.setZoomScale(presentationScale, animated: false)
    }
    updateContentInsets()
        let proposedOffset = FreeformCanvasLayout.translatedContentOffset(
            oldContentOffset,
            expansion: expansion,
            zoomScale: scale
        )
        let clampedOffset = CanvasStackLayout.clampedContentOffset(
            proposedOffset,
            viewportSize: scrollView.bounds.size,
            contentSize: layoutPlan.contentSize,
            contentInset: scrollView.contentInset,
            zoomScale: scale
        )
        scrollView.setContentOffset(clampedOffset, animated: false)
        isApplyingGeometry = false
        updatePaperTemplatePresentationWindows()

        lastPublishedViewport = nil
        lastPublishedViewportPageID = nil
        updateRenderedPageWindow(force: nativeScaleChanged)
callbacks.pageReplaced(replacement)
publishViewport()
publishUndoAvailability()
return true
}
private func updateBoundaryPagePull(
contentOffset: CGPoint,
panTranslation: CGPoint,
isDragging: Bool,
now: TimeInterval,
schedulesHoldTimer: Bool
) {
guard documentMode == .paged,
isReaderModeEnabled == false,
isDragging,
scrollView.isZooming == false,
isApplyingGeometry == false else {
cancelBoundaryPagePullGesture(clearPendingInsertion: false)
return
}
let measuredPull = CanvasStackLayout.boundaryPagePull(
contentOffset: contentOffset,
panTranslation: panTranslation,
viewportSize: scrollView.bounds.size,
contentSize: layoutPlan.contentSize,
contentInset: scrollView.contentInset,
zoomScale: effectiveZoomScale,
pageLayout: pageLayout
)
let pull = boundaryPullGate.update(
measuredPull: measuredPull,
now: now
)
setBoundaryPagePull(pull)
if schedulesHoldTimer {
if boundaryPullGate.needsHoldTimer {
synchronizeBoundaryPullHoldTask()
}
} else {
boundaryPullHoldTask?.cancel()
boundaryPullHoldTask = nil
}
}
private func beginBoundaryPagePullGesture(at contentOffset: CGPoint) {
guard documentMode == .paged, isReaderModeEnabled == false else {
cancelBoundaryPagePullGesture()
return
}
cancelBoundaryPagePullGesture()
let eligibleBoundaries = CanvasStackLayout.boundaryPagePullEligibleBoundaries(
contentOffset: contentOffset,
viewportSize: scrollView.bounds.size,
contentSize: layoutPlan.contentSize,
contentInset: scrollView.contentInset,
zoomScale: effectiveZoomScale,
pageLayout: pageLayout
)
boundaryPullGate.begin(eligibleBoundaries: eligibleBoundaries)
boundaryPageFeedbackGenerator.prepare()
}
private func synchronizeBoundaryPullHoldTask() {
boundaryPullHoldTask?.cancel()
boundaryPullHoldTask = nil
guard boundaryPullHoldTask == nil else { return }
let sessionID = boundaryPullGate.sessionID
boundaryPullHoldTask = Task { @MainActor [weak self] in
do {
try await Task.sleep(
for: .milliseconds(CanvasConstants.boundaryPullHoldMilliseconds)
)
} catch {
return
}

        guard let self,
            self.boundaryPullGate.sessionID == sessionID else { return }
        self.boundaryPullHoldTask = nil
        let pull = self.boundaryPullGate.completeHold(
            now: CACurrentMediaTime(),
            panVelocity: self.scrollView.panGestureRecognizer.velocity(
                in: self.scrollView
            ),
            isDragging: self.scrollView.isDragging
        )
        self.setBoundaryPagePull(pull)
        // Only a still-holding gate needs another tick. Re-arming after the
        // pull is armed would hit `completeHold` in the wrong phase and
        // cancel the gesture before release could insert the page.
        if self.boundaryPullGate.needsHoldTimer {
            self.synchronizeBoundaryPullHoldTask()
        }
        }
    }
    private func cancelBoundaryPagePullGesture(
        clearPendingInsertion: Bool = true
    ) {
        boundaryPullHoldTask?.cancel()
        boundaryPullHoldTask = nil
        boundaryPullGate.cancel()
        if clearPendingInsertion {
            pendingBoundaryPageInsertion = nil
        }
        setBoundaryPagePull(nil)
    }

    private func setBoundaryPagePull(_ pull: CanvasBoundaryPagePull?) {
        guard activeBoundaryPagePull != pull else { return }
        let becameArmed = pull?.isArmed == true
            && (activeBoundaryPagePull?.isArmed != true
            || activeBoundaryPagePull?.boundary != pull?.boundary)
        activeBoundaryPagePull = pull
        callbacks.boundaryPullChanged(pull)

        if becameArmed {
            boundaryPageFeedbackGenerator.impactOccurred(intensity: 0.75)
        } else if pull != nil {
boundaryPageFeedbackGenerator.prepare()
}
}
@discardableResult
private func prepareBoundaryPageInsertion(releaseVelocity: CGPoint) -> Bool {
guard isReaderModeEnabled == false else {
cancelBoundaryPagePullGesture()
return false
}
boundaryPullHoldTask?.cancel()
boundaryPullHoldTask = nil
pendingBoundaryPageInsertion = boundaryPullGate.end(
releaseVelocity: releaseVelocity
)
setBoundaryPagePull(nil)
return pendingBoundaryPageInsertion != nil
}
private func finishBoundaryPagePull() {
guard isReaderModeEnabled == false else {
cancelBoundaryPagePullGesture()
return
}
if boundaryPullGate.isTracking {
// A release that bypassed `scrollViewWillEndDragging` has no
// trustworthy velocity sample and must never create a page.
cancelBoundaryPagePullGesture(clearPendingInsertion: false)
}
guard let requestedBoundary = pendingBoundaryPageInsertion else { return }
pendingBoundaryPageInsertion = nil
// An accepted release replaces the bounce/deceleration destination
// with the newly inserted page. Unaccepted pulls never alter UIKit's
// native rubber-band or projected destination.
scrollView.setContentOffset(scrollView.contentOffset, animated: false)
callbacks.boundaryPageInsertionRequested(requestedBoundary)
}
private var visibleDocumentRect: CGRect {
CanvasStackLayout.visibleDocumentRect(
contentOffset: scrollView.contentOffset,
viewportSize: scrollView.bounds.size,
safeAreaInsets: view.safeAreaInsets,
zoomScale: effectiveZoomScale,
topChromeHeight: topChromeHeight
)
}
// Keeps the transient pattern path tied to the visible board rather than
// to the full (potentially 65K-point) freeform backing space. The modest
// overscan prevents seams while a pinch or pan crosses a lattice cell.
private func updatePaperTemplatePresentationWindows() {
guard hasAppliedInitialViewport,
scrollView.bounds.width > 0,
scrollView.bounds.height > 0 else { return }
let visible = visibleDocumentRect
let overscanned = visible.insetBy(
dx: -max(visible.width * 0.35, 64),
dy: -max(visible.height * 0.35, 64)
)
let plan = layoutPlan
let scale = effectiveZoomScale
for (index, page) in pages.enumerated() {
guard let host = hostsByPageID[page.id] else { continue }
let pageFrame = plan.pageFrame(at: index)
let intersection = overscanned.intersection(pageFrame)
let host_decoration = overscanned.intersection(pageFrame)
host.decorationView.presentationScale = scale
if intersection.isNull || intersection.isEmpty {
// `nil` means "render the whole page" to the artwork builder.
// An explicit null window means this page has no visible
// template work, preventing an offscreen expanded board from
// allocating a path for its entire logical extent.
host.decorationView.visibleLogicalRect = .null
} else {
host.decorationView.visibleLogicalRect = CGRect(
x: intersection.minX - pageFrame.minX,
y: intersection.minY - pageFrame.minY,
width: intersection.width,
height: intersection.height
)
}
}
}
private func currentViewportState() -> CanvasViewportState {
guard let index = pages.firstIndex(where: { $0.id == focusedPageID }),
scrollView.bounds.width > 0,
scrollView.bounds.height > 0 else { return initialViewport }
var viewport = CanvasStackLayout.viewportState(
focusedPageIndex: index,
visibleDocumentRect: visibleDocumentRect,
zoomScale: CanvasZoom.clampedScale(effectiveZoomScale),
layoutPlan: layoutPlan
)
if documentMode == .paged,
pageLayout.scrollDirection == .horizontal,
usesHorizontalPageFit {
viewport.usesFitPage = true
}
return viewport
}
private func updateFocusFromVisibleArea(unlessDirectInteraction: Bool) {
guard !(unlessDirectInteraction && isDirectInteractionActive),
let index = layoutPlan.focusedPageIndex(
visibleDocumentRect: visibleDocumentRect,
preferredPageIndex: pages.firstIndex(where: {
$0.id == focusedPageID
})
) else { return }
setFocusedPage(pages[index].id, fromDirectInteraction: false)
}
private func setFocusedPage(_ id: UUID, fromDirectInteraction: Bool) {
guard pages.contains(where: { $0.id == id }),
ensurePageHostMounted(for: id) != nil else { return }
isDirectInteractionActive = fromDirectInteraction
guard focusedPageID != id else {
publishUndoAvailability()
return
}
if let outgoingHost = hostsByPageID[focusedPageID] {
// Commit any active text editor before judging the outgoing host
// noninteractive. Authored changes and their native undo entry are
// then either checkpointed or keep this exact controller pinned.
outgoingHost.controller.view.endEditing(true)
deliverMarkupIfChanged(pageID: focusedPageID)
}
if let activeTableTarget, activeTableTarget.pageID != id {
clearActiveTableTarget()
}
focusedPageID = id
synchronizeRulerState()
recordUndoHistoryActivity(pageID: id)
lastPublishedViewport = nil
lastPublishedViewportPageID = nil
callbacks.focusedPageChanged(id)
publishUndoAvailability()
}
private func publishViewport() {
guard hasAppliedInitialViewport else { return }
let viewport = currentViewportState()
publishViewport(viewport, for: focusedPageID)
}
private func publishViewport(
_ viewport: CanvasViewportState,
for pageID: UUID
) {
guard viewport.isValid,
let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else { return }
if pages[pageIndex].viewport != viewport {
pages[pageIndex] = pages[pageIndex].replacing(viewport: viewport)
}
guard lastPublishedViewport != viewport
|| lastPublishedViewportPageID != pageID else { return }
lastPublishedViewport = viewport
lastPublishedViewportPageID = pageID
callbacks.viewportChanged(pageID, viewport)
}
private func captureAndPublishCurrentViewport() {
guard hasAppliedInitialViewport,
programmaticNavigationPageID == nil else { return }
let outgoingPageID = focusedPageID
publishViewport(currentViewportState(), for: outgoingPageID)
}
private func scheduleTransientViewportPublication() {
guard hasAppliedInitialViewport else { return }
transientViewportPublicationPending = true
guard transientViewportPublicationTask == nil else { return }
transientViewportPublicationToken &+= 1
let token = transientViewportPublicationToken
transientViewportPublicationTask = Task { @MainActor [weak self] in
do {
try await Task.sleep(for: Self.transientViewportPublicationInterval)
} catch {
return
}
guard let self,
token == transientViewportPublicationToken else { return }
transientViewportPublicationTask = nil
guard transientViewportPublicationPending else { return }
transientViewportPublicationPending = false
publishViewport()
}
}
private func flushTransientViewportPublication() {
transientViewportPublicationToken &+= 1
transientViewportPublicationTask?.cancel()
transientViewportPublicationTask = nil
transientViewportPublicationPending = false
publishViewport()
}
private func cancelProgrammaticFreeformZoomSettlement() {
programmaticFreeformZoomSettlementTask?.cancel()
programmaticFreeformZoomSettlementTask = nil
}
private func scheduleProgrammaticFreeformZoomSettlement() {
guard documentMode == .freeform else { return }
cancelProgrammaticFreeformZoomSettlement()
programmaticFreeformZoomSettlementTask = Task { @MainActor [weak self] in
do {
try await Task.sleep(for: Self.programmaticFreeformZoomSettlementDelay)
} catch {
return
}
guard let self else { return }
programmaticFreeformZoomSettlementTask = nil
flushTransientViewportPublication()
scheduleEndInteractiveZoomPresentation()
}
}
private func beginInteractiveZoomPresentation() {
guard documentMode == .freeform else {
// A notebook page is bounded and benefits from PaperKit's live
// tiled rendering at every intermediate zoom value.
// for host in hostsByPageID.values where host.controller.view.isHidden == false {
return
}
zoomPresentationReleaseToken &+= 1
zoomPresentationReleaseTask?.cancel()
zoomPresentationReleaseTask = nil
guard isInteractiveZoomPresentationFrozen == false else { return }
isInteractiveZoomPresentationFrozen = true
let displayScale = max(currentViewportEnvironment.displayScale, 1)
for host in hostsByPageID.values where host.controller.view.isHidden == false {
let layer = host.controller.view.layer
let largestDimension = max(max(layer.bounds.width, layer.bounds.height), 1)
layer.rasterizationScale = min(
displayScale,
Self.zoomPresentationMaximumPixelDimension / largestDimension
)
layer.shouldRasterize = true
host.decorationView.setOverlayPresentationActive(true)
documentView.bringSubviewToFront(host.decorationView)
}
}
private func scheduleEndInteractiveZoomPresentation() {
guard documentMode == .freeform else {
return
}
zoomPresentationReleaseToken &+= 1
let token = zoomPresentationReleaseToken
zoomPresentationReleaseTask?.cancel()
zoomPresentationReleaseTask = Task { @MainActor [weak self] in
do {
try await Task.sleep(for: Self.zoomPresentationReleaseDelay)
} catch {
return
}
guard let self,
token == zoomPresentationReleaseToken else { return }
zoomPresentationReleaseTask = nil
endInteractiveZoomPresentation()
}
}
private func endInteractiveZoomPresentation() {
zoomPresentationReleaseToken &+= 1
zoomPresentationReleaseTask?.cancel()
zoomPresentationReleaseTask = nil
isInteractiveZoomPresentationFrozen = false
for host in hostsByPageID.values {
let layer = host.controller.view.layer
layer.shouldRasterize = false
if documentMode == .freeform {
host.decorationView.setOverlayPresentationActive(true)
} else {
if host.decorationView.superview == documentView,
host.undoController.view.superview === documentView {
documentView.insertSubview(
host.decorationView,
belowSubview: host.undoController.view
)
}
}
}
}
private func contactDidBegin() {
// Reassert the live PaperKit hierarchy before drawing. Freeform paper
// continues to use its independent vector template presentation.
cancelProgrammaticFreeformZoomSettlement()
endInteractiveZoomPresentation()
// PaperKit establishes page focus after accepting the stroke.
}
private func contactDidEnd() {
let pageCommands = pendingPageCommands
pendingPageCommands.removeAll(keepingCapacity: true)
for command in pageCommands {
switch command {
case let .insert(page, index, scrollTo, animated):
insertPage(page, at: index, scrollTo: scrollTo, animated: animated)
case let .replace(page):
replacePage(page)
case let .scroll(id, animated):
scrollToPage(id: id, animated: animated)
case let .navigateToRegion(id, bounds, animated):
navigateToPageRegion(
pageID: id,
pageBounds: bounds,
animated: animated
)
case let .activate(id, markup, viewport):
activatePage(id: id, markup: markup, viewport: viewport)
}
}
let templateCommands = pendingPaperTemplates
pendingPaperTemplates.removeAll(keepingCapacity: true)
for (pageID, template) in templateCommands {
setPaperTemplate(template, for: pageID)
}
if let pendingToolState {
self.pendingToolState = nil
applyToolState(pendingToolState)
}
if let pendingInputMode {
self.pendingInputMode = nil
applyInputMode(pendingInputMode)
}
if let pendingPageLayout {
self.pendingPageLayout = nil
setPageLayout(pendingPageLayout)
}
if let pendingGeometryToolUpdate {
self.pendingGeometryToolUpdate = nil
switch pendingGeometryToolUpdate {
case let .set(tool):
setGeometryTool(tool)
}
}
if let pendingZoomScale {
self.pendingZoomScale = nil
setZoomScale(pendingZoomScale)
}
if pendingInsertions.isEmpty == false {
drainPendingProgrammaticInsertionsRespectingReadinessBoundary()
}
drainPendingHistoryCommandsIfPossible()
if shouldSettleTransientZoomAfterContact {
settleTransientZoom()
} else if pendingRenderedPageWindowUpdate {
updateRenderedPageWindow(force: true)
}
publishViewport()
publishUndoAvailability()
// Force one final PaperKit read at the stable contact boundary. The
// normal delegate usually delivered it already; this also covers an OS
// revision that delays its last markup callback until touch teardown.
deliverAllChangedMarkup()
callbacks.snapshotContactEnded()
}
private func synchronizeRulerState() {
for (pageID, host) in hostsByPageID {
let shouldBeActive = isReaderModeEnabled == false
&& isRulerActive
&& pageID == focusedPageID
if host.controller.isRulerActive != shouldBeActive {
host.controller.isRulerActive = shouldBeActive
}
}
}
private func deliverAllChangedMarkup() {
for page in pages { deliverMarkupIfChanged(pageID: page.id) }
}
private func deliverMarkupIfChanged(
pageID: UUID,
includingPreparedInsertion: Bool = false
) {
guard includingPreparedInsertion
|| pagesPreparingInsertionHistory.contains(pageID) == false,
let host = hostsByPageID[pageID],
let markup = host.controller.markup,
markup != host.lastDeliveredMarkup else { return }
host.lastDeliveredMarkup = markup
replacePageMarkup(id: pageID, markup: markup)
callbacks.markupChanged(pageID, markup)
}
private func replacePageMarkup(id: UUID, markup: PaperMarkup) {
guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
let previous = pages[index]
pages[index] = previous.replacing(markup: markup)
}
private func performSerializedInsertion(
_ insertion: CanvasInsertion, pageID: UUID
) async -> Bool {
guard let host = hostsByPageID[pageID],
let originalMarkup = host.controller.markup
else { return false }
let paperController = host.controller
let controllerIdentity = ObjectIdentifier(paperController)
let interactionWasEnabled = paperController.view.isUserInteractionEnabled
paperController.view.isUserInteractionEnabled = false
pagesPreparingInsertionHistory.insert(pageID)
defer {
pagesPreparingInsertionHistory.remove(pageID)
paperController.view.isUserInteractionEnabled = interactionWasEnabled
drainDeferredCommandsAfterSerializedInsertion()
}
#if DEBUG
await pauseSerializedInsertionIfRequestedForTesting()
#endif
guard let undoData = try? await originalMarkup.dataRepresentation(),
undoData.count
<= effectiveMaximumAppOwnedUndoActionSerializedByteCount,
let currentHost = hostsByPageID[pageID],
ObjectIdentifier(currentHost.controller) == controllerIdentity,
currentHost.controller.markup == originalMarkup else { return false }
let historyManager = paperController.undoManager
let shouldResumeNativeRegistration = historyManager?.isUndoRegistrationEnabled == true
if shouldResumeNativeRegistration { historyManager?.disableUndoRegistration() }
var nativeRegistrationIsSuspended = shouldResumeNativeRegistration
defer {
if nativeRegistrationIsSuspended {
historyManager?.enableUndoRegistration()
}
}
let originalSelection = paperController.selectedMarkup
insertImmediately(insertion, into: paperController)
guard let insertedMarkup = paperController.markup,
insertedMarkup != originalMarkup else {
    await restoreFailedInsertion(
on: paperController,
originalMarkup: originalMarkup,
originalSelection: originalSelection,
undoData: undoData
)
return false
}
#if DEBUG
if consumeSerializedInsertionFailureForTesting(.redoSerialization) {
await restoreFailedInsertion(
on: paperController,
originalMarkup: originalMarkup,
originalSelection: originalSelection,
undoData: undoData
)
return false
}
#endif
guard let redoData = try? await insertedMarkup.dataRepresentation() else {
await restoreFailedInsertion(
on: paperController,
originalMarkup: originalMarkup,
originalSelection: originalSelection,
undoData: undoData
)
return false
}
let (serializedHistoryBytes, historyByteCountOverflowed) = undoData.count
.addingReportingOverflow(redoData.count)
guard historyByteCountOverflowed == false,
serializedHistoryBytes
<= effectiveMaximumAppOwnedUndoActionSerializedByteCount else {
await restoreFailedInsertion(
on: paperController,
originalMarkup: originalMarkup,
originalSelection: originalSelection,
undoData: undoData
)
return false
}
#if DEBUG
if consumeSerializedInsertionFailureForTesting(.retainedHostValidation) {
await restoreFailedInsertion(
on: paperController,
originalMarkup: originalMarkup,
originalSelection: originalSelection,
undoData: undoData
)
return false
}
#endif
guard let retainedHost = hostsByPageID[pageID],
    ObjectIdentifier(retainedHost.controller) == controllerIdentity,
    retainedHost.controller.markup == insertedMarkup else {
    await restoreFailedInsertion(
        on: paperController,
        originalMarkup: originalMarkup,
        originalSelection: originalSelection,
        undoData: undoData
    )
    return false
}

        // PaperKit 26.0 can enqueue its own undo registration after the
        // insertion call returns. Keep registration suspended through the
        // serialization suspension point so that delayed framework action
        // cannot sit above Notate's immutable before/after history entry.
        await Task.yield()
        guard let finalHost = hostsByPageID[pageID],
            ObjectIdentifier(finalHost.controller) == controllerIdentity,
            finalHost.controller.markup == insertedMarkup,
            pages.contains(where: { $0.id == pageID }) else {
            // An unexpected framework-side mutation must not be overwritten
            // by rolling back a detached/stale controller. Refuse the
            // acknowledgement; ordinary snapshot capture will publish the
            // live authoritative value on its next safe pass.
            return false
        }
        if nativeRegistrationIsSuspended {
            historyManager?.enableUndoRegistration()
            nativeRegistrationIsSuspended = false
        }

        registerMarkupReplacement(
            pageID: pageID,
            undoData: undoData,
            redoData: redoData,
            actionName: insertion.historyActionName
        )
        deliverMarkupIfChanged(
            pageID: pageID,
            includingPreparedInsertion: true
        )
        guard pages.first(where: { $0.id == pageID })?.markup == insertedMarkup else {
            return false
        }
        if pageID == focusedPageID { publishUndoAvailability() }
        return true
    }

    private var effectiveMaximumAppOwnedUndoActionSerializedByteCount: Int {
    #if DEBUG
        max(maximumAppOwnedUndoActionSerializedByteCountForTesting
            ?? Self.maximumAppOwnedUndoActionSerializedByteCount, 0)
    #else
        Self.maximumAppOwnedUndoActionSerializedByteCount
    #endif
    }

        /// Toolbar/page commands can arrive while PaperKit asynchronously creates
        /// immutable insertion history. Run the deferred commands only after the
        /// target page transaction has either committed or rolled back, preserving
        /// the user's command order without allowing a stale snapshot to win.
    private func drainDeferredCommandsAfterSerializedInsertion() {
        guard pagesPreparingInsertionHistory.isEmpty,
            queuedInsertionCountByPageID.isEmpty,
            hasActiveContact == false else { return }

        let pageCommands = pendingPageCommands
        pendingPageCommands.removeAll(keepingCapacity: true)
        for command in pageCommands {
            switch command {
            case let .insert(page, index, scrollTo, animated):
                insertPage(page, at: index, scrollTo: scrollTo, animated: animated)
            case let .replace(page):
                replacePage(page)
            case let .scroll(id, animated):
                scrollToPage(id: id, animated: animated)
            case let .navigateToRegion(id, bounds, animated):
                navigateToPageRegion(pageID: id, pageBounds: bounds, animated: animated)
            case let .activate(id, markup, viewport):
                activatePage(id: id, markup: markup, viewport: viewport)
            }
        }

        let templateCommands = pendingPaperTemplates
        pendingPaperTemplates.removeAll(keepingCapacity: true)
        for (pendingPageID, template) in templateCommands {
            setPaperTemplate(template, for: pendingPageID)
        }

        if pendingInsertions.isEmpty == false {
            drainPendingProgrammaticInsertionsRespectingReadinessBoundary()
        }

        drainPendingHistoryCommandsIfPossible()
    }

    private func drainPendingProgrammaticInsertionsRespectingReadinessBoundary() {
        guard pendingInsertions.isEmpty == false else { return }

        let queuedInsertions = pendingInsertions
        pendingInsertions.removeAll(keepingCapacity: true)
        let eligibleCount: Int
        if let readinessBoundary = activeProgrammaticInsertionReadinessBoundary {
            eligibleCount = queuedInsertions.prefix {
                $0.acceptanceSequence <= readinessBoundary
            }.count
        } else {
            eligibleCount = queuedInsertions.count
        }

        for pendingInsertion in queuedInsertions.prefix(eligibleCount) {
            dispatchAcceptedProgrammaticInsertion(pendingInsertion)
        }
        // An eligible table may have been requeued behind an async insertion.
        // Keep all commands newer than the readiness boundary behind that
        // prefix so insertion and native undo order remain identical to tap
        // order.
        pendingInsertions.append(
            contentsOf: queuedInsertions.dropFirst(eligibleCount)
        )
    }

        /// A programmatic insertion is committed only after both immutable history
        /// snapshots exist and the original page host is still authoritative. If
        /// either condition fails, restore the serialized pre-insertion snapshot
        /// while native undo registration remains suspended. This keeps the live
        /// PaperKit controller, persisted page snapshot, and undo stack atomic.
    private func restoreFailedInsertion(
        on paperController: PaperMarkupViewController,
        originalMarkup: PaperMarkup,
        originalSelection: PaperMarkup,
        undoData: Data
    ) async {
        let restoredMarkup = (try? PaperMarkup(dataRepresentation: undoData))
            ?? originalMarkup
        // PaperKit does not always repaint a same-sized decoded replacement.
        // Detach first, matching the normal serialized undo/redo path.
        paperController.markup = nil
        paperController.markup = restoredMarkup
        paperController.selectedMarkup = originalSelection

        // PaperKit 26.0 can enqueue native undo work one run-loop turn after
        // insertion. Yield before registration is re-enabled by the caller's
        // defer so a failed transaction cannot leak a framework undo action.
        await Task.yield()
    }

    private func insertImmediately(
        _ insertion: CanvasInsertion,
        into paperController: PaperMarkupViewController
    ) {
        guard let markup = paperController.markup else { return }
        if case .text = insertion {
            paperController.markupEditViewControllerInsertNewTextbox(
                Self.sharedInsertionContext
            )
            return
        }

        let visibleBounds = markup.bounds.intersection(paperController.contentVisibleFrame)
        let insertionBounds = visibleBounds.isNull || visibleBounds.isEmpty
            ? markup.bounds
            : visibleBounds
        var inserted = PaperMarkup(bounds: markup.bounds)

        switch insertion {
        case let .shape(shape):
            let requested = centeredFrame(
                size: CGSize(width: 180, height: 120),
                in: insertionBounds,
                constrainedTo: markup.bounds
            )
            let configuration = ShapeConfiguration(
                type: shape.paperKitShape,
                fillColor: nil,
                strokeColor: RGBAColor.graphite.uiColor.cgColor,
                lineWidth: 2
            )
            inserted.insertNewShape(
                configuration: configuration,
                frame: paperController.suggestedFrameForInserting(contentInFrame: requested)
            )

        case .table:
            // Semantic tables are app-owned page content so they retain a
            // stable identity across selection, undo, and relaunch. They are
            // inserted by `insertTable(size:)` before this PaperKit-only path.
            return

        case let .circle(requestedFrame):
            let frame = constrainedFrame(requestedFrame, to: markup.bounds)
            guard frame.width >= 1, frame.height >= 1 else { return }
            let configuration = ShapeConfiguration(
                type: .ellipse,
                fillColor: nil,
                strokeColor: RGBAColor.graphite.uiColor.cgColor,
                lineWidth: 2
            )
            inserted.insertNewShape(configuration: configuration, frame: frame)

        case let .image(image):
            let maximumSize = CGSize(
                width: markup.bounds.width * 0.6,
                height: markup.bounds.height * 0.6
            )
            let fittedSize = aspectFitSize(
                source: CGSize(width: image.width, height: image.height),
                maximum: maximumSize
            )
            let requested = centeredFrame(
                size: fittedSize,
                in: insertionBounds,
                constrainedTo: markup.bounds
            )
            inserted.insertNewImage(
                image,
                frame: paperController.suggestedFrameForInserting(contentInFrame: requested)
            )

        case let .positionedImage(image, requestedFrame):
            let availableFrame = constrainedFrame(requestedFrame, to: markup.bounds)
            guard availableFrame.width >= 2, availableFrame.height >= 2 else { return }
            let fittedSize = aspectFitSize(
                source: CGSize(width: image.width, height: image.height),
                maximum: availableFrame.size
            )
            let positionedFrame = constrainedFrame(
                CGRect(
                    x: availableFrame.midX - fittedSize.width / 2,
                    y: availableFrame.midY - fittedSize.height / 2,
                    width: fittedSize.width,
                    height: fittedSize.height
                ),
                to: markup.bounds
            )
            inserted.insertNewImage(image, frame: positionedFrame)

            // PaperKit's paste-style insertion delegate deliberately moves
            // imported content toward its own suggested viewport location.
            // A drag destination is already an authored document coordinate,
            // so merge this one payload directly and let the surrounding
            // serialized before/after history register the undo operation.
            var combined = markup
            combined.append(contentsOf: inserted)
            paperController.markup = combined
            paperController.selectedMarkup = inserted
            return

        case .text:
            return
        }

        paperController.markupEditViewController(
            Self.sharedInsertionContext,
            insertNewContents: inserted
        )
        paperController.selectedMarkup = inserted
    }

    private func registerMarkupReplacement(
        pageID: UUID,
        undoData: Data,
        redoData: Data,
        actionName: String
    ) {
        let (retainedSerializedByteCount, overflowed) = undoData.count
            .addingReportingOverflow(redoData.count)
        guard overflowed == false,
            retainedSerializedByteCount
            <= effectiveMaximumAppOwnedUndoActionSerializedByteCount else {
            return
        }
        registerAppOwnedUndo(
            pageID: pageID,
            actionName: actionName,
            retainedSerializedByteCount: retainedSerializedByteCount
        ) { target in
            target.applyHistoryMarkup(
                pageID: pageID,
                data: undoData,
                inverseData: redoData,
                actionName: actionName
            )
        }
    }

    private func recordUndoHistoryActivity(pageID: UUID) {
        undoHistoryPageRecency.removeAll { $0 == pageID }
        guard let manager = hostsByPageID[pageID]?.controller.undoManager,
            manager.canUndo || manager.canRedo || manager.groupingLevel > 0
            || hasPendingAppUndoRegistration(for: pageID) else {
            enforceUndoBearingPageHostLimit(preserving: pageID)
            return
        }
        undoHistoryPageRecency.append(pageID)
        enforceUndoBearingPageHostLimit(preserving: pageID)
    }

    private func enforceUndoBearingPageHostLimit(preserving pageID: UUID) {
        var removedHistory = false
        undoHistoryPageRecency.removeAll { candidate in
            guard let manager = hostsByPageID[candidate]?.controller.undoManager else {
                return true
            }
            return manager.canUndo == false
                && manager.canRedo == false
                && manager.groupingLevel == 0
                && hasPendingAppUndoRegistration(for: candidate) == false
        }

        while undoHistoryPageRecency.count
            > Self.maximumRetainedUndoPageHostCount {
            guard let removalIndex = undoHistoryPageRecency.firstIndex(where: {
                candidate in
                guard candidate != focusedPageID,
                    candidate != pageID,
                    queuedInsertionCountByPageID[candidate, default: 0] == 0,
                    pagesPreparingInsertionHistory.contains(candidate) == false,
                    hasPendingAppUndoRegistration(for: candidate) == false,
                    let manager = hostsByPageID[candidate]?.controller.undoManager,
                    manager.groupingLevel == 0,
                    manager.isUndoing == false,
                    manager.isRedoing == false else { return false }
                return true
            }) else {
                // An open native event group is transiently protected. Its
                // close notification invokes this method again.
                return
            }
            let evictedPageID = undoHistoryPageRecency.remove(
                at: removalIndex
            )
            hostsByPageID[evictedPageID]?.controller.undoManager?
                .removeAllActions()
            removedHistory = true
        }
        if removedHistory, virtualizesPageHosts {
            updateRenderedPageWindow(force: true)
        }
    }

        /// App-owned mutations can be committed from Pencil-up while the native
        /// event undo group is still open. Keep the mutation synchronous, but wait
        /// for UndoManager's official close notification before adding a separate
        /// app-owned group. Manually closing the event group would leave the
        /// framework's scheduled close unmatched and can raise an exception.
    private func registerAppOwnedUndo(
        pageID: UUID,
        actionName: String,
        retainedSerializedByteCount: Int = 0,
        handler: @escaping @MainActor (PaperCanvasViewController) -> Void
    ) {
        guard retainedSerializedByteCount >= 0,
            retainedSerializedByteCount
            <= effectiveMaximumAppOwnedUndoActionSerializedByteCount,
            let historyManager = hostsByPageID[pageID]?.controller.undoManager else {
            return
        }

        if historyManager.isUndoing || historyManager.isRedoing {
            historyManager.registerUndo(withTarget: self, handler: handler)
            historyManager.setActionName(actionName)
            return
        }

        let registration = PendingAppUndoRegistration(
            pageID: pageID,
            manager: historyManager,
            actionName: actionName,
            retainedSerializedByteCount: retainedSerializedByteCount,
            handler: handler
        )
        guard historyManager.groupingLevel == 0 else {
            retainPendingAppUndoRegistration(registration)
            return
        }
        registerTopLevelAppUndo(registration)
    }

        /// App-owned entries can wait here while PaperKit owns an event group, so
        /// they are not yet covered by `UndoManager.levelsOfUndo`. Retain only the
        /// newest entries that would fit in the eventual page-local stack and its
        /// serialized insertion budget. Dropping an older undo entry is safer than
        /// retaining an unbounded closure tail if a framework group is delayed.
    private func retainPendingAppUndoRegistration(
        _ registration: PendingAppUndoRegistration
    ) {
        let managerID = ObjectIdentifier(registration.manager)
        var registrations = pendingAppUndoRegistrations[managerID] ?? []
        var retainedSerializedByteCount = registrations.reduce(into: 0) {
            partialResult,
            pending in
            let (next, overflowed) = partialResult.addingReportingOverflow(
                pending.retainedSerializedByteCount
            )
            partialResult = overflowed ? Int.max : next
        }
        let pendingSerializedByteBudget = Self.maximumPendingAppUndoSerializedByteCount

        while registrations.isEmpty == false {
            let (nextByteCount, overflowed) = retainedSerializedByteCount
                .addingReportingOverflow(
                    registration.retainedSerializedByteCount
                )
            if registrations.count < Self.maximumUndoLevelCountPerPage,
                overflowed == false,
                nextByteCount <= pendingSerializedByteBudget {
                break
            }
            let discarded = registrations.removeFirst()
            retainedSerializedByteCount = max(
                retainedSerializedByteCount
                - discarded.retainedSerializedByteCount,
                0
            )
        }
        registrations.append(registration)
        pendingAppUndoRegistrations[managerID] = registrations
        recordUndoHistoryActivity(pageID: registration.pageID)
    }

    private func registerTopLevelAppUndo(_ registration: PendingAppUndoRegistration) {
        let historyManager = registration.manager
        if historyManager.isUndoing || historyManager.isRedoing {
            historyManager.registerUndo(withTarget: self, handler: registration.handler)
            historyManager.setActionName(registration.actionName)
            return
        }
        guard historyManager.groupingLevel == 0 else {
            retainPendingAppUndoRegistration(registration)
            return
        }

        let managerID = ObjectIdentifier(historyManager)
        let ownsNotificationSuppression = undoManagersFlushingAppRegistrations
            .insert(managerID).inserted
        defer {
            if ownsNotificationSuppression {
                undoManagersFlushingAppRegistrations.remove(managerID)
            }
        }

        let restoresAutomaticGrouping = historyManager.groupsByEvent
        if restoresAutomaticGrouping {
            historyManager.groupsByEvent = false
        }
        historyManager.beginUndoGrouping()
        historyManager.registerUndo(withTarget: self, handler: registration.handler)
        historyManager.setActionName(registration.actionName)
        historyManager.endUndoGrouping()
        if restoresAutomaticGrouping {
            historyManager.groupsByEvent = true
        }
        recordUndoHistoryActivity(pageID: registration.pageID)
    }

    private func hasPendingAppUndoRegistration(for pageID: UUID) -> Bool {
        pendingAppUndoRegistrations.values.contains { registrations in
            registrations.contains { $0.pageID == pageID }
        }
    }

    @objc private func undoManagerDidCloseGroup(_ notification: Notification) {
        guard let historyManager = notification.object as? UndoManager else { return }
        guard let pageID = hostsByPageID.first(where: {
            $0.value.controller.undoManager === historyManager
        })?.key else { return }
        let managerID = ObjectIdentifier(historyManager)
        guard undoManagersFlushingAppRegistrations.contains(managerID) == false,
            historyManager.groupingLevel == 0 else { return }

        guard let registrations = pendingAppUndoRegistrations.removeValue(
            forKey: managerID
        ) else {
            recordUndoHistoryActivity(pageID: pageID)
            drainPendingHistoryCommandsIfPossible()
            return
        }

        undoManagersFlushingAppRegistrations.insert(managerID)
        defer {
            undoManagersFlushingAppRegistrations.remove(managerID)
            drainPendingHistoryCommandsIfPossible()
        }

        var updatedFocusedHistory = false
        for registration in registrations {
            guard hostsByPageID[registration.pageID]?.controller.undoManager
                === historyManager else { continue }
            registerTopLevelAppUndo(registration)
            updatedFocusedHistory = updatedFocusedHistory
                || registration.pageID == focusedPageID
        }
        if updatedFocusedHistory {
            publishUndoAvailability()
        }
        recordUndoHistoryActivity(pageID: pageID)
    }

    private func applyHistoryMarkup(
        pageID: UUID,
        data: Data,
        inverseData: Data,
        actionName: String
    ) {
        guard let host = hostsByPageID[pageID],
            let markup = try? PaperMarkup(dataRepresentation: data) else { return }
        let (retainedSerializedByteCount, overflowed) = data.count
            .addingReportingOverflow(inverseData.count)
        guard overflowed == false else { return }
        registerAppOwnedUndo(
            pageID: pageID,
            actionName: actionName,
            retainedSerializedByteCount: retainedSerializedByteCount
        ) { target in
            target.applyHistoryMarkup(
                pageID: pageID,
                data: inverseData,
                inverseData: data,
                actionName: actionName
            )
        }

        if let index = pages.firstIndex(where: { $0.id == pageID }) {
            let replacement = pages[index].replacing(markup: markup)
            // PaperKit 26.0 does not reliably refresh same-sized decoded
            // markup while the existing document remains attached. Detaching
            // first forces the controller to adopt the immutable snapshot.
            host.controller.markup = nil
            performPageReplacement(replacement, registersUndo: false)
        }

        if pageID == focusedPageID { publishUndoAvailability() }
    }

    private func publishUndoAvailability() {
        guard let manager = hostsByPageID[focusedPageID]?.controller.undoManager else {
            callbacks.undoAvailabilityChanged(focusedPageID, false, false)
            return
        }
        callbacks.undoAvailabilityChanged(focusedPageID, manager.canUndo, manager.canRedo)
    }

    private func centeredFrame(
        size: CGSize,
        in visibleBounds: CGRect,
        constrainedTo pageBounds: CGRect
    ) -> CGRect {
        var frame = CGRect(
            x: visibleBounds.midX - size.width / 2,
            y: visibleBounds.midY - size.height / 2,
            width: min(size.width, pageBounds.width),
            height: min(size.height, pageBounds.height)
        )
        frame.origin.x = min(max(frame.minX, pageBounds.minX), pageBounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, pageBounds.minY), pageBounds.maxY - frame.height)
        return frame
    }

    private func constrainedFrame(_ requestedFrame: CGRect, to bounds: CGRect) -> CGRect {
            guard requestedFrame.isNull == false,
            requestedFrame.isInfinite == false,
            requestedFrame.width.isFinite,
            requestedFrame.height.isFinite else { return .zero }

        let width = min(abs(requestedFrame.width), bounds.width)
        let height = min(abs(requestedFrame.height), bounds.height)
        var frame = CGRect(
            x: requestedFrame.standardized.minX,
            y: requestedFrame.standardized.minY,
            width: width,
            height: height
        )
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return frame
    }

    private func aspectFitSize(source: CGSize, maximum: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return maximum }
        let scale = min(maximum.width / source.width, maximum.height / source.height, 1)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private var currentViewportEnvironment: ViewportEnvironment {
        ViewportEnvironment(
            size: view.bounds.size,
            safeAreaInsets: view.safeAreaInsets,
            displayScale: view.traitCollection.displayScale
        )
    }

    private var hasActiveContact: Bool {
#if DEBUG
        contactMonitor.hasActiveContact || isContactForcedForTesting
#else
        contactMonitor.hasActiveContact
#endif
    }

#if DEBUG
    var outerScrollViewForTesting: UIScrollView { scrollView }
    var isObservingUndoGroupClosureForTesting: Bool { isObservingUndoGroupClosure }
    func pendingAppUndoRegistrationCountForTesting(pageID: UUID) -> Int {
        pendingAppUndoRegistrations.values.reduce(into: 0) { count, registrations in
            count += registrations.lazy.filter { $0.pageID == pageID }.count
        }
    }
    var laserPointerViewForTesting: CanvasLaserPointerView { laserPointerView }
    var regionSelectionViewForTesting: CanvasRegionSelectionView {
        regionSelectionView
    }
    var isRegionSelectionInteractionSuspendedForTesting: Bool {
        regionSelectionInteractionSnapshot != nil
    }
    var isLaserPointerGestureEnabledForTesting: Bool {
        laserPointerGestureRecognizer.isEnabled
    }
    static var maximumEagerPageHostCountForTesting: Int {
        maximumEagerPageHostCount
    }
    var pageIDsForTesting: [UUID] { pages.map(\.id) }
    var mountedPageIDsForTesting: [UUID] {
        pages.compactMap { hostsByPageID[$0.id] == nil ? nil : $0.id }
    }
    var mountedPageHostCountForTesting: Int { hostsByPageID.count }
    var virtualizesPageHostsForTesting: Bool { virtualizesPageHosts }
    func queuedInsertionCountForTesting(pageID: UUID) -> Int {
        queuedInsertionCountByPageID[pageID, default: 0]
    }
    var focusedPageIDForTesting: UUID { focusedPageID }
    var currentViewportForTesting: CanvasViewportState { currentViewportState() }
    var programmaticNavigationPageIDForTesting: UUID? {
        programmaticNavigationPageID
    }
    var programmaticNavigationViewportForTesting: CanvasViewportState? {
        programmaticNavigationViewport
    }
    var minimumZoomScaleForTesting: CGFloat { scrollView.minimumZoomScale }
    var renderedZoomScaleForTesting: CGFloat { renderedZoomScale }
    var effectiveZoomScaleForTesting: CGFloat { effectiveZoomScale }
    var isZoomScrubbingForTesting: Bool { isZoomScrubbing }
    var hasPendingTransientViewportPublicationForTesting: Bool {
        transientViewportPublicationPending || transientViewportPublicationTask != nil
    }
    func failNextSerializedInsertionForTesting(
        at failure: SerializedInsertionFailureForTesting
    ) {
        nextSerializedInsertionFailureForTesting = failure
    }
    func awaitSerializedInsertionForTesting() async {
        _ = await insertionHistoryTask?.value
    }
    var isProgrammaticInsertionReadinessActiveForTesting: Bool {
        activeProgrammaticInsertionReadinessBoundary != nil
    }
    var isSerializedInsertionPausedForTesting: Bool {
        pausedSerializedInsertionContinuationForTesting != nil
    }
    func pauseNextSerializedInsertionForTesting() {
        shouldPauseNextSerializedInsertionForTesting = true
    }
    func resumeSerializedInsertionForTesting() {
        let continuation = pausedSerializedInsertionContinuationForTesting
        pausedSerializedInsertionContinuationForTesting = nil
        continuation?.resume()
    }
    static func maskRegionThumbnailForTesting(
        _ thumbnail: CGImage,
        pagePath: CGPath,
        pageBounds: CGRect
    ) -> CGImage? {
        maskRegionThumbnail(
            thumbnail,
            pagePath: pagePath,
            pageBounds: pageBounds
        )
    }
    static func prepareImagePlaygroundSourceForTesting(_ image: CGImage) -> CGImage? {
        prepareImagePlaygroundSource(image)
    }
    private func consumeSerializedInsertionFailureForTesting(
        _ failure: SerializedInsertionFailureForTesting
    ) -> Bool {
        guard nextSerializedInsertionFailureForTesting == failure else { return false }
        nextSerializedInsertionFailureForTesting = nil
        return true
    }
    private func pauseSerializedInsertionIfRequestedForTesting() async {
        guard shouldPauseNextSerializedInsertionForTesting else { return }
        shouldPauseNextSerializedInsertionForTesting = false
        await withCheckedContinuation { continuation in
            pausedSerializedInsertionContinuationForTesting = continuation
        }
    }
    var isInteractiveZoomPresentationFrozenForTesting: Bool {
        isInteractiveZoomPresentationFrozen
    }
    func isPageRasterizedForTesting(pageID: UUID) -> Bool? {
        hostsByPageID[pageID]?.controller.view.layer.shouldRasterize
    }
    func pageRasterizationScaleForTesting(pageID: UUID) -> CGFloat? {
        hostsByPageID[pageID]?.controller.view.layer.rasterizationScale
    }
    var renderedPageIDsForTesting: [UUID] {
        pages.compactMap { page in
            hostsByPageID[page.id]?.controller.view.isHidden == false ? page.id : nil
        }
    }
    func renderedZoomScaleForTesting(pageID: UUID) -> CGFloat? {
        hostsByPageID[pageID]?.renderedZoomScale
    }
    func hostFrameForTesting(pageID: UUID) -> CGRect? {
        hostsByPageID[pageID]?.undoController.view.frame
    }
    func isPageBackgroundRenderingForTesting(pageID: UUID) -> Bool? {
        hostsByPageID[pageID]?.contentView.isRenderingActive
    }
    func paperTemplateDecorationViewForTesting(pageID: UUID) -> PaperPageDecorationView? {
        hostsByPageID[pageID]?.decorationView
    }
    func isTemplatePresentationInsideRasterizedAncestorForTesting(pageID: UUID) -> Bool? {
        guard let decorationView = hostsByPageID[pageID]?.decorationView else { return nil }
        var candidate: UIView? = decorationView
        while let view = candidate {
            if view.layer.shouldRasterize { return true }
            candidate = view.superview
        }
        return false
    }
    func isTemplatePresentationAbovePaperKitForTesting(pageID: UUID) -> Bool? {
        guard let host = hostsByPageID[pageID],
            host.decorationView.superview === documentView,
            host.undoController.view.superview === documentView,
            let decorationIndex = documentView.subviews.firstIndex(
                of: host.decorationView
            ),
            let paperIndex = documentView.subviews.firstIndex(
                of: host.undoController.view
            ) else { return nil }
        return decorationIndex > paperIndex
    }
    var paperMarkupControllerForTesting: PaperMarkupViewController {
        hostsByPageID[focusedPageID]!.controller
    }
    func paperMarkupControllerForTesting(pageID: UUID) -> PaperMarkupViewController? {
        hostsByPageID[pageID]?.controller
    }
    func paperTemplateForTesting(pageID: UUID) -> CanvasPaperTemplate? {
        pages.first(where: { $0.id == pageID })?.paperTemplate
    }
    func paperTemplateViewForTesting(pageID: UUID) -> PaperPageContentView? {
        hostsByPageID[pageID]?.contentView
    }
    func beginContactForTesting() {
        isContactForcedForTesting = true
        contactDidBegin()
    }
    func endContactForTesting() {
        isContactForcedForTesting = false
        contactDidEnd()
    }
    func beginBoundaryPagePullForTesting(contentOffset: CGPoint) {
        beginBoundaryPagePullGesture(at: contentOffset)
    }
    func updateBoundaryPagePullForTesting(
        contentOffset: CGPoint,
        panTranslation: CGPoint,
        isDragging: Bool,
        now: TimeInterval = 0
    ) {
        updateBoundaryPagePull(
            contentOffset: contentOffset,
            panTranslation: panTranslation,
            isDragging: isDragging,
            now: now,
            schedulesHoldTimer: false
        )
    }
    func completeBoundaryPagePullHoldForTesting(
        now: TimeInterval,
        panVelocity: CGPoint = .zero,
        isDragging: Bool = true
    ) {
        let pull = boundaryPullGate.completeHold(
            now: now,
            panVelocity: panVelocity,
            isDragging: isDragging
        )
        setBoundaryPagePull(pull)
    }
    @discardableResult
    func prepareBoundaryPageInsertionForTesting(
        releaseVelocity: CGPoint
    ) -> Bool {
        return prepareBoundaryPageInsertion(releaseVelocity: releaseVelocity)
    }
    func finishBoundaryPagePullForTesting() {
        finishBoundaryPagePull()
    }
#endif
}

extension PaperCanvasViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { documentView }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelProgrammaticNavigationForDirectInteraction()
        isDirectInteractionActive = false
        dragStartFocusedPageID = focusedPageID
        dragStartContentOffset = scrollView.contentOffset
        beginBoundaryPagePullGesture(at: scrollView.contentOffset)
        laserPointerView.cancel()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        cancelProgrammaticNavigationForDirectInteraction()
        isDirectInteractionActive = false
        isNativeZoomInteractionActive = true
        usesHorizontalPageFit = false
        cancelProgrammaticFreeformZoomSettlement()
        cancelBoundaryPagePullGesture()
        laserPointerView.cancel()
        beginInteractiveZoomPresentation()
        callbacks.zoomInteractionChanged(true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        defer {
            refreshRegionSelectionPresentation()
            refreshTableAccessibilityElements()
        }
        updateBoundaryPagePull(
            contentOffset: scrollView.contentOffset,
            panTranslation: scrollView.panGestureRecognizer.translation(in: scrollView),
            isDragging: scrollView.isDragging,
            now: CACurrentMediaTime(),
            schedulesHoldTimer: true
        )
        guard hasAppliedInitialViewport, isApplyingGeometry == false else { return }
        guard settledEnvironment == currentViewportEnvironment else {
            view.setNeedsLayout()
            return
        }
        updatePaperTemplatePresentationWindows()
        if expandFreeformCanvasIfNeeded() {
            return
        }
        if programmaticNavigationPageID != nil {
            updateRenderedPageWindow()
            return
        }
        updateFocusFromVisibleArea(unlessDirectInteraction: true)
        updateRenderedPageWindow()
        if scrollView.isDragging
            || scrollView.isDecelerating
            || scrollView.isZooming
            || isNativeZoomInteractionActive
            || isZoomScrubbing {
            scheduleTransientViewportPublication()
        } else {
            publishViewport()
        }
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // UIScrollViewDelegate reports points per millisecond, while the pan
        // recognizer and the intent gate use points per second.
        let releaseVelocity = CGPoint(
            x: velocity.x * 1_000,
            y: velocity.y * 1_000
        )
        let wasBoundaryPull = activeBoundaryPagePull != nil
        let eligibleBoundaries = boundaryPullGate.eligibleBoundariesAtStart
        let startOffset = dragStartContentOffset ?? scrollView.contentOffset
        let projectedPrimaryOffset = pageLayout.scrollDirection == .horizontal
            ? targetContentOffset.pointee.x
            : targetContentOffset.pointee.y
        let startPrimaryOffset = pageLayout.scrollDirection == .horizontal
            ? startOffset.x
            : startOffset.y
        let projectsOutsideStartEdge = eligibleBoundaries.contains(.start)
            && projectedPrimaryOffset <= startPrimaryOffset + 0.5
        let projectsOutsideEndEdge = eligibleBoundaries.contains(.end)
            && projectedPrimaryOffset >= startPrimaryOffset - 0.5
        if prepareBoundaryPageInsertion(releaseVelocity: releaseVelocity) {
            // Only an intentional, low-speed release discards UIKit's
            // projected destination in favor of the inserted page.
            targetContentOffset.pointee = scrollView.contentOffset
            return
        }
        // A revealed but rejected edge pull retains UIKit's native spring.
        guard wasBoundaryPull == false,
            projectsOutsideStartEdge == false,
            projectsOutsideEndEdge == false,
            documentMode == .paged,
            pageLayout.scrollDirection == .horizontal,
            let dragStartFocusedPageID,
            let pageIndex = pages.firstIndex(where: {
                $0.id == dragStartFocusedPageID
            }),
            let snapTarget = CanvasStackLayout.horizontalPageSnapTarget(
                proposedContentOffset: targetContentOffset.pointee,
                currentPageIndex: pageIndex,
                horizontalVelocity: velocity.x,
                viewportSize: scrollView.bounds.size,
                safeAreaInsets: view.safeAreaInsets,
                zoomScale: effectiveZoomScale,
                layoutPlan: layoutPlan
            ) else { return }
        targetContentOffset.pointee = snapTarget
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        finishBoundaryPagePull()
        dragStartFocusedPageID = nil
        dragStartContentOffset = nil
        if decelerate == false {
            updateFocusFromVisibleArea(unlessDirectInteraction: false)
            updateRenderedPageWindow(force: true)
            flushTransientViewportPublication()
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        defer {
            refreshRegionSelectionPresentation()
            refreshTableAccessibilityElements()
        }
        guard isApplyingGeometry == false else { return }
        isApplyingGeometry = true
        updateContentInsets()
        isApplyingGeometry = false
        guard hasAppliedInitialViewport else { return }
        guard settledEnvironment == currentViewportEnvironment else {
            view.setNeedsLayout()
            return
        }
        updatePaperTemplatePresentationWindows()
        updateFocusFromVisibleArea(unlessDirectInteraction: true)
        scheduleTransientViewportPublication()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        isNativeZoomInteractionActive = false
        if documentMode == .paged,
            pageLayout.scrollDirection == .horizontal {
            usesHorizontalPageFit = abs(
                effectiveZoomScale - minimumLogicalZoomScale
            ) < 0.005
        }
        settleTransientZoom()
        _ = expandFreeformCanvasIfNeeded()
        flushTransientViewportPublication()
        scheduleEndInteractiveZoomPresentation()
        callbacks.zoomInteractionChanged(false)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if expandFreeformCanvasIfNeeded() { return }
        if let destinationPageID = programmaticNavigationPageID {
            programmaticNavigationPageID = nil
            programmaticNavigationViewport = nil
            setFocusedPage(destinationPageID, fromDirectInteraction: false)
        }
        updateFocusFromVisibleArea(unlessDirectInteraction: false)
        updateRenderedPageWindow(force: true)
    flushTransientViewportPublication()
}

func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if expandFreeformCanvasIfNeeded() { return }
    updateFocusFromVisibleArea(unlessDirectInteraction: false)
    updateRenderedPageWindow(force: true)
    flushTransientViewportPublication()
}

}

extension PaperCanvasViewController: UIPencilInteractionDelegate {
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        _ = interaction
        _ = tap
        guard isReaderModeEnabled == false else { return }
        callbacks.pencilPreferredActionRequested(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        _ = interaction
        guard isReaderModeEnabled == false, squeeze.phase == .ended else { return }
        callbacks.pencilPreferredActionRequested(
            UIPencilInteraction.preferredSqueezeAction
        )
    }
}
extension PaperCanvasViewController: @MainActor PaperMarkupViewController.Delegate {
    func paperMarkupViewControllerDidChangeMarkup(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        guard isReaderModeEnabled == false,
            let pageID = pageIDByController[ObjectIdentifier(paperMarkupViewController)] else {
            return
        }
        guard pagesPreparingInsertionHistory.contains(pageID) == false else { return }
        deliverMarkupIfChanged(pageID: pageID)
        if pageID == focusedPageID { publishUndoAvailability() }
    }

    func paperMarkupViewControllerDidBeginDrawing(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        guard isReaderModeEnabled == false,
            let pageID = pageIDByController[ObjectIdentifier(paperMarkupViewController)] else {
            return
        }
        if activeTableTarget != nil { clearActiveTableTarget() }
        setFocusedPage(pageID, fromDirectInteraction: true)
        callbacks.interactionBegan(pageID)
    }

    func paperMarkupViewControllerDidChangeSelection(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        guard isReaderModeEnabled == false,
            hasAppliedInitialViewport,
            let pageID = pageIDByController[ObjectIdentifier(paperMarkupViewController)] else {
            return
        }
        guard pagesPreparingInsertionHistory.contains(pageID) == false else { return }
        setFocusedPage(pageID, fromDirectInteraction: true)
        publishUndoAvailability()
    }

    func paperMarkupViewControllerDidChangeContentVisibleFrame(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        guard isReaderModeEnabled == false,
            let pageID = pageIDByController[ObjectIdentifier(paperMarkupViewController)],
            let host = hostsByPageID[pageID],
            host.isApplyingGeometry == false else { return }
        lockPaperViewport(for: host)
    }
}

extension PaperCanvasViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if isThreeFingerHistoryGesture(gestureRecognizer) {
            return isReaderModeEnabled == false
                && UIAccessibility.isVoiceOverRunning == false
        }
        guard gestureRecognizer === tableSelectionTapGestureRecognizer
            || gestureRecognizer === tableHoverGestureRecognizer else { return true }
        return isReaderModeEnabled == false
            && UIAccessibility.isVoiceOverRunning == false
            && regionSelectionInteractionSnapshot == nil
            && appliedToolState?.activeTool != .laserPointer
            && scrollView.isZooming == false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === tableSelectionTapGestureRecognizer
            || gestureRecognizer === tableHoverGestureRecognizer else { return true }
        guard isReaderModeEnabled == false,
            UIAccessibility.isVoiceOverRunning == false,
            regionSelectionInteractionSnapshot == nil,
            appliedToolState?.activeTool != .laserPointer,
            scrollView.isZooming == false else { return false }

        var touchedView = touch.view
        while let candidate = touchedView {
            if candidate is UIControl { return false }
            touchedView = candidate.superview
        }

        if gestureRecognizer === tableHoverGestureRecognizer {
            return touch.type == .indirectPointer
        }
        switch touch.type {
        case .indirectPointer:
            return true
        case .direct:
            return inputMode == .pencilOnly
        default:
            return false
        }
    }


    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if isThreeFingerHistoryGesture(gestureRecognizer)
            || isThreeFingerHistoryGesture(otherGestureRecognizer) {
            return false
        }
        return gestureRecognizer === tableSelectionTapGestureRecognizer
            || gestureRecognizer === tableHoverGestureRecognizer
    }
}

@MainActor
private final class CanvasTableInteractionOverlayView:
    UIView,
    UIGestureRecognizerDelegate,
    UIContextMenuInteractionDelegate
{
    private enum AdditionDirection {
        case row
        case column
    }

    struct Capabilities: Equatable {
        let canAddRow: Bool
        let canAddColumn: Bool
        let canRemoveRow: Bool
        let canRemoveColumn: Bool
        let canDelete: Bool
        let canMoveUp: Bool
        let canMoveDown: Bool
        let canMoveLeft: Bool
        let canMoveRight: Bool
        let canIncreaseWidth: Bool
        let canDecreaseWidth: Bool
        let canIncreaseHeight: Bool
        let canDecreaseHeight: Bool

        static let none = Capabilities(
            canAddRow: false,
            canAddColumn: false,
            canRemoveRow: false,
            canRemoveColumn: false,
            canDelete: false,
            canMoveUp: false,
            canMoveDown: false,
            canMoveLeft: false,
            canMoveRight: false,
            canIncreaseWidth: false,
            canDecreaseWidth: false,
            canIncreaseHeight: false,
            canDecreaseHeight: false
        )

    }

    var onAddRow: (() -> Void)?
    var onAddColumn: (() -> Void)?
    var onRemoveRow: (() -> Void)?
    var onRemoveColumn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onTransformBegan: ((CanvasTableTransformKind, CGPoint) -> Void)?
    var onTransformChanged: ((CanvasTableTransformKind, CGPoint) -> Void)?
    var onTransformEnded: ((CanvasTableTransformKind, CGPoint) -> Void)?
    var onTransformCancelled: (() -> Void)?
    var onResizeStep: ((CGSize) -> Bool)?

    private let hoveredTableLayer = CAShapeLayer()
    private let hoveredCellLayer = CAShapeLayer()
    private let selectedTableLayer = CAShapeLayer()
    private let selectedCellLayer = CAShapeLayer()
    private let resizeHandle = UIButton(type: .system)
    private let resizeGripView = UIView()
    private lazy var resizePanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleResizePan(_:)))

    private lazy var bodyMovePanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleMovePan(_:)))

    private var capabilities = Capabilities.none
    private(set) var selectedTableFrame: CGRect?
    private var transformPreviewIsActive = false
    private var allowsDirectBodyTransform = false

    var controlsAreVisible: Bool {
        resizeHandle.isHidden == false
    }

    var visibleAccessibilityControls: [Any] {
        resizeHandle.isHidden ? [] : [resizeHandle]
    }

    var visibleAffordanceIdentifiers: [String] {
        guard resizeHandle.isHidden == false,
            let identifier = resizeHandle.accessibilityIdentifier else { return [] }
        return [identifier]
    }

    var transformControlFrames: (move: CGRect?, resize: CGRect?) {
        (
            nil,
            resizeHandle.isHidden ? nil : resizeHandle.frame
        )
    }

    var transformAccessibilityActionNames: (move: [String], resize: [String]) {
        (
            [],
            resizeHandle.accessibilityCustomActions?.map(\.name) ?? []
        )
    }

    var resizeGripFrames: (visual: CGRect?, hit: CGRect?) {
        guard resizeHandle.isHidden == false else { return (nil, nil) }
        return (
            resizeGripView.convert(resizeGripView.bounds, to: self),
            resizeHandle.frame
        )
    }

    var contextActionNames: [String] {
        flattenedActionNames(in: tableActionsMenu().children)
    }

    var hasContextInteraction: Bool {
        interactions.contains { $0 is UIContextMenuInteraction }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        clipsToBounds = false

        for shapeLayer in [
            hoveredTableLayer,
            hoveredCellLayer,
            selectedCellLayer,
            selectedTableLayer,
        ] {
            shapeLayer.fillColor = nil
            shapeLayer.lineJoin = .round
            shapeLayer.actions = [
                "path": NSNull(),
                "strokeColor": NSNull(),
                "fillColor": NSNull(),
                "hidden": NSNull(),
            ]
            layer.addSublayer(shapeLayer)
        }
        hoveredTableLayer.lineWidth = 1.5
        hoveredTableLayer.lineDashPattern = [4, 3]
        hoveredCellLayer.lineWidth = 1
        selectedCellLayer.lineWidth = 1.5
        selectedTableLayer.lineWidth = 2

        configureResizeHandle()
        configureTransformGesture(resizePanGesture)
        configureTransformGesture(bodyMovePanGesture)
        resizeHandle.addGestureRecognizer(resizePanGesture)
        addGestureRecognizer(bodyMovePanGesture)
        addInteraction(UIContextMenuInteraction(delegate: self))

        resizeGripView.isUserInteractionEnabled = false
        resizeGripView.isAccessibilityElement = false
        resizeGripView.layer.borderWidth = 2
        resizeGripView.layer.shadowColor = UIColor.black.cgColor
        resizeGripView.layer.shadowOpacity = 0.14
        resizeGripView.layer.shadowRadius = 1.5
        resizeGripView.layer.shadowOffset = CGSize(width: 0, height: 1)
        resizeHandle.addSubview(resizeGripView)
        addSubview(resizeHandle)
        setControlsHidden(true)
        updateColors()
    }

    func update(
        selectedTableFrame: CGRect?,
        selectedCellFrame: CGRect?,
        hoveredTableFrame: CGRect?,
        hoveredCellFrame: CGRect?,
        capabilities: Capabilities,
        allowsDirectBodyTransform: Bool,
        sizeValue: String?
    ) {
        guard transformPreviewIsActive == false else { return }
        self.selectedTableFrame = selectedTableFrame
        self.capabilities = capabilities
        self.allowsDirectBodyTransform = allowsDirectBodyTransform
        resizeHandle.accessibilityValue = sizeValue
        selectedTableLayer.path = selectedTableFrame.map {
            CGPath(rect: $0.insetBy(dx: -2, dy: -2), transform: nil)
        }
        selectedTableLayer.isHidden = selectedTableFrame == nil
        selectedCellLayer.path = selectedCellFrame.map {
            CGPath(rect: $0.insetBy(dx: 1, dy: 1), transform: nil)
        }
        selectedCellLayer.isHidden = selectedCellFrame == nil
        let visibleHoveredTableFrame = hoveredTableFrame == selectedTableFrame
            ? nil
            : hoveredTableFrame
        hoveredTableLayer.path = visibleHoveredTableFrame.map {
            CGPath(rect: $0.insetBy(dx: -1, dy: -1), transform: nil)
        }
        hoveredTableLayer.isHidden = visibleHoveredTableFrame == nil
        hoveredCellLayer.path = hoveredCellFrame.map {
            CGPath(rect: $0.insetBy(dx: 1, dy: 1), transform: nil)
        }
        hoveredCellLayer.isHidden = hoveredCellFrame == nil
        let hasSelection = selectedTableFrame != nil
        setControlsHidden(hasSelection == false)
        rebuildTransformAccessibilityActions()
        setNeedsLayout()
    }

    func prioritizeTransforms(over navigationPanGesture: UIPanGestureRecognizer) {
        navigationPanGesture.require(toFail: bodyMovePanGesture)
        navigationPanGesture.require(toFail: resizePanGesture)
    }

    func beginTransformPreview(
        frame: CGRect,
        sizeValue: String
    ) {
        transformPreviewIsActive = true
        selectedCellLayer.isHidden = true
        hoveredTableLayer.isHidden = true
        hoveredCellLayer.isHidden = true
        updateTransformPreview(
            frame: frame,
            sizeValue: sizeValue
        )
    }

    func updateTransformPreview(
        frame: CGRect,
        sizeValue: String
    ) {
        selectedTableFrame = frame
        selectedTableLayer.path = CGPath(
            rect: frame.insetBy(dx: -2, dy: -2),
            transform: nil
        )
        selectedTableLayer.isHidden = false
        resizeHandle.accessibilityValue = sizeValue
        setNeedsLayout()
        layoutIfNeeded()
    }

    func endTransformPreview() {
        transformPreviewIsActive = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shapeLayer in [
            hoveredTableLayer,
            hoveredCellLayer,
            selectedCellLayer,
            selectedTableLayer,
        ] {
            shapeLayer.frame = bounds
        }
        guard let selectedTableFrame else { return }
        let safeBounds = bounds.insetBy(dx: 8, dy: 8)
        let transformHandleSize = CGSize(width: 44, height: 44)
        resizeHandle.frame = controlFrame(
            centeredAt: CGPoint(x: selectedTableFrame.maxX, y: selectedTableFrame.maxY),
            size: transformHandleSize,
            constrainedTo: safeBounds
        )
        let gripDimension: CGFloat = 14
        resizeGripView.frame = CGRect(
            x: (resizeHandle.bounds.width - gripDimension) / 2,
            y: (resizeHandle.bounds.height - gripDimension) / 2,
            width: gripDimension,
            height: gripDimension
        )
        resizeGripView.layer.cornerRadius = gripDimension / 2
    }

    private func controlFrame(
        centeredAt center: CGPoint,
        size: CGSize,
        constrainedTo bounds: CGRect
    ) -> CGRect {
        var origin = CGPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }


    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, isHidden == false, alpha > 0.01 else { return nil }
        if event?.allTouches?.first?.type == .pencil { return nil }
        for control in [resizeHandle]
        where control.isHidden == false && control.isEnabled {
            let localPoint = control.convert(point, from: self)
            if let hit = control.hitTest(localPoint, with: event) { return hit }
        }
        let touchType = event?.allTouches?.first?.type
        let canTransformTableBody = touchType == .indirectPointer
            || allowsDirectBodyTransform
        if let selectedTableFrame,
            selectedTableFrame.contains(point),
            canTransformTableBody {
            return self
        }
        return nil
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    private func configureResizeHandle() {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        resizeHandle.configuration = configuration
        resizeHandle.accessibilityLabel = "Resize table"
        resizeHandle.accessibilityIdentifier = "canvas.table.resize"
        resizeHandle.accessibilityHint = "Drag the corner grip to resize the table. Use actions to change its width or height."
        resizeHandle.largeContentTitle = "Resize table"
        resizeHandle.largeContentImage = UIImage(systemName: "circle.fill")
        resizeHandle.showsLargeContentViewer = true
        resizeHandle.isPointerInteractionEnabled = true
    }

    private func configureTransformGesture(_ recognizer: UIPanGestureRecognizer) {
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
    }

    private func rebuildTransformAccessibilityActions() {
        var resizeActions: [UIAccessibilityCustomAction] = []
        if capabilities.canIncreaseWidth {
            resizeActions.append(transformAction(name: "Increase width", control: resizeHandle) {
                self.onResizeStep?(CGSize(width: 1, height: 0)) ?? false
            })
        }
        if capabilities.canDecreaseWidth {
            resizeActions.append(transformAction(name: "Decrease width", control: resizeHandle) {
                self.onResizeStep?(CGSize(width: -1, height: 0)) ?? false
            })
        }
        if capabilities.canIncreaseHeight {
            resizeActions.append(transformAction(name: "Increase height", control: resizeHandle) {
                self.onResizeStep?(CGSize(width: 0, height: 1)) ?? false
            })
        }
        if capabilities.canDecreaseHeight {
            resizeActions.append(transformAction(name: "Decrease height", control: resizeHandle) {
                self.onResizeStep?(CGSize(width: 0, height: -1)) ?? false
            })
        }
        resizeHandle.accessibilityCustomActions = resizeActions
    }

    private func transformAction(
        name: String,
        control: UIView,
        perform: @escaping () -> Bool
    ) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { _ in
            let succeeded = perform()
            if succeeded {
                UIAccessibility.post(notification: .layoutChanged, argument: control)
            }
            return succeeded
        }
    }

    private static func tableAdditionIcon(for direction: AdditionDirection) -> UIImage {
        let iconSize = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: iconSize)
        let image = renderer.image { context in
            let drawingContext = context.cgContext
            drawingContext.setStrokeColor(UIColor.label.cgColor)
            drawingContext.setLineWidth(1.5)
            drawingContext.setLineCap(.round)
            drawingContext.setLineJoin(.round)

            let gridFrame: CGRect
            let highlightedSection: CGRect
            let plusCenter: CGPoint
            switch direction {
            case .row:
                gridFrame = CGRect(x: 2.5, y: 2.5, width: 19, height: 13)
                highlightedSection = CGRect(
                    x: gridFrame.minX + 0.75,
                    y: gridFrame.midY + 0.75,
                    width: gridFrame.width - 1.5,
                    height: gridFrame.height / 2 - 1.5
                )
                plusCenter = CGPoint(x: gridFrame.midX, y: 20.5)
            case .column:
                gridFrame = CGRect(x: 2.5, y: 2.5, width: 13, height: 19)
                highlightedSection = CGRect(
                    x: gridFrame.midX + 0.75,
                    y: gridFrame.minY + 0.75,
                    width: gridFrame.width / 2 - 1.5,
                    height: gridFrame.height - 1.5
                )
                plusCenter = CGPoint(x: 20.5, y: gridFrame.midY)
            }
            drawingContext.setFillColor(UIColor.label.withAlphaComponent(0.18).cgColor)
            drawingContext.fill(highlightedSection)
            drawingContext.stroke(gridFrame)
            drawingContext.beginPath()
            drawingContext.move(to: CGPoint(x: gridFrame.midX, y: gridFrame.minY))
            drawingContext.addLine(to: CGPoint(x: gridFrame.midX, y: gridFrame.maxY))
            drawingContext.move(to: CGPoint(x: gridFrame.minX, y: gridFrame.midY))
            drawingContext.addLine(to: CGPoint(x: gridFrame.maxX, y: gridFrame.midY))
            drawingContext.strokePath()
            let plusArmLength: CGFloat = 2.75
            drawingContext.setLineWidth(1.75)
            drawingContext.beginPath()
            drawingContext.move(
                to: CGPoint(x: plusCenter.x - plusArmLength, y: plusCenter.y)
            )
            drawingContext.addLine(
                to: CGPoint(x: plusCenter.x + plusArmLength, y: plusCenter.y)
            )
            drawingContext.move(
                to: CGPoint(x: plusCenter.x, y: plusCenter.y - plusArmLength)
            )
            drawingContext.addLine(
                to: CGPoint(x: plusCenter.x, y: plusCenter.y + plusArmLength)
            )
            drawingContext.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private func setControlsHidden(_ hidden: Bool) {
        resizeHandle.isHidden = hidden
    }

    @objc private func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
        handleTransformPan(recognizer, kind: .move)
    }

    @objc private func handleResizePan(_ recognizer: UIPanGestureRecognizer) {
        handleTransformPan(recognizer, kind: .resize)
    }

    private func handleTransformPan(
        _ recognizer: UIPanGestureRecognizer,
        kind: CanvasTableTransformKind
    ) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            onTransformBegan?(kind, location)
        case .changed:
            onTransformChanged?(kind, location)
        case .ended:
            onTransformEnded?(kind, location)
        case .cancelled, .failed:
            onTransformCancelled?()
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === bodyMovePanGesture else { return true }
        guard let selectedTableFrame else { return false }
        return selectedTableFrame.contains(gestureRecognizer.location(in: self))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === bodyMovePanGesture else { return true }
        var candidate = touch.view
        while let view = candidate, view !== self {
            if view is UIControl { return false }
            candidate = view.superview
        }
        return true
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard transformPreviewIsActive == false,
            let selectedTableFrame,
            selectedTableFrame.contains(location) else { return nil }
        return UIContextMenuConfiguration(
            identifier: "canvas.table.actions" as NSString,
            previewProvider: nil
        ) { [weak self] _ in
            self?.tableActionsMenu() ?? UIMenu(children: [])
        }
    }

    private func tableActionsMenu() -> UIMenu {
        let addRow = UIAction(
            title: "Add Row",
            image: Self.tableAdditionIcon(for: .row)
        ) { [weak self] _ in
            self?.onAddRow?()
        }
        addRow.attributes = capabilities.canAddRow ? [] : .disabled
        let addColumn = UIAction(
            title: "Add Column",
            image: Self.tableAdditionIcon(for: .column)
        ) { [weak self] _ in
            self?.onAddColumn?()
        }
        addColumn.attributes = capabilities.canAddColumn ? [] : .disabled
        let removeRow = UIAction(
            title: "Remove Last Row",
            image: UIImage(systemName: "rectangle.split.1x2")
        ) { [weak self] _ in
            self?.onRemoveRow?()
        }
        removeRow.attributes = capabilities.canRemoveRow ? [] : .disabled
        let removeColumn = UIAction(
            title: "Remove Last Column",
            image: UIImage(systemName: "rectangle.split.2x1")
        ) { [weak self] _ in
            self?.onRemoveColumn?()
        }
        removeColumn.attributes = capabilities.canRemoveColumn ? [] : .disabled
        let delete = UIAction(
            title: "Delete Table",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.onDelete?()
        }
        delete.attributes = capabilities.canDelete ? .destructive : [.destructive, .disabled]
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [addRow, addColumn]),
            UIMenu(options: .displayInline, children: [removeRow, removeColumn]),
            delete,
        ])
    }

    private func flattenedActionNames(in elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let action = element as? UIAction {
                return [action.title]
            }
            if let menu = element as? UIMenu {
                return flattenedActionNames(in: menu.children)
            }
            return []
        }
    }

    private func updateColors() {
        let accent = tintColor ?? .systemBlue
        hoveredTableLayer.strokeColor = accent.withAlphaComponent(0.56).cgColor
        hoveredCellLayer.strokeColor = accent.withAlphaComponent(0.46).cgColor
        hoveredCellLayer.fillColor = accent.withAlphaComponent(0.08).cgColor
        selectedCellLayer.strokeColor = accent.withAlphaComponent(0.72).cgColor
        selectedCellLayer.fillColor = accent.withAlphaComponent(0.16).cgColor
        selectedTableLayer.strokeColor = accent.withAlphaComponent(0.96).cgColor
        resizeGripView.backgroundColor = accent
        resizeGripView.layer.borderColor = UIColor.systemBackground.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}

@MainActor
private final class CanvasTableAccessibilityElement: UIAccessibilityElement {
    let pageID: UUID
    let tableID: UUID
    var onActivate: (() -> Bool)?
    var onAddRow: (() -> Bool)?
    var onAddColumn: (() -> Bool)?
    var onRemoveRow: (() -> Bool)?
    var onRemoveColumn: (() -> Bool)?
    var onDelete: (() -> Bool)?
    var onMoveStep: ((CGSize) -> Bool)?

    init(
        accessibilityContainer container: Any,
        pageID: UUID,
        tableID: UUID
    ) {
        self.pageID = pageID
        self.tableID = tableID
        super.init(accessibilityContainer: container)
        updateMovementActions()
    }

    func updateMovementActions(
        canMoveUp: Bool = false,
        canMoveDown: Bool = false,
        canMoveLeft: Bool = false,
        canMoveRight: Bool = false
    ) {
        var actions = [
        UIAccessibilityCustomAction(
            name: "Add table row",
            target: self,
            selector: #selector(addRow)
        ),
        UIAccessibilityCustomAction(
            name: "Add table column",
            target: self,
            selector: #selector(addColumn)
        ),
        UIAccessibilityCustomAction(
            name: "Remove last table row",
            target: self,
            selector: #selector(removeRow)
        ),
        UIAccessibilityCustomAction(
            name: "Remove last table column",
            target: self,
            selector: #selector(removeColumn)
        ),
        UIAccessibilityCustomAction(
            name: "Delete table",
            target: self,
            selector: #selector(deleteTable)
        ),
        ]
        if canMoveUp {
            actions.append(UIAccessibilityCustomAction(
                name: "Move up",
                target: self,
                selector: #selector(moveUp)
            ))
        }
        if canMoveDown {
            actions.append(UIAccessibilityCustomAction(
                name: "Move down",
                target: self,
                selector: #selector(moveDown)
            ))
        }
        if canMoveLeft {
            actions.append(UIAccessibilityCustomAction(
                name: "Move left",
                target: self,
                selector: #selector(moveLeft)
            ))
        }
        if canMoveRight {
            actions.append(UIAccessibilityCustomAction(
                name: "Move right",
                target: self,
                selector: #selector(moveRight)
            ))
        }
        accessibilityCustomActions = actions
    }

    override func accessibilityActivate() -> Bool {
        onActivate?() ?? false
    }

    @objc private func addRow() -> Bool {
        onAddRow?() ?? false
    }

    @objc private func addColumn() -> Bool {
        onAddColumn?() ?? false
    }

    @objc private func removeRow() -> Bool {
        onRemoveRow?() ?? false
    }

    @objc private func removeColumn() -> Bool {
        onRemoveColumn?() ?? false
    }

    @objc private func deleteTable() -> Bool {
        onDelete?() ?? false
    }

    @objc private func moveUp() -> Bool {
        onMoveStep?(CGSize(width: 0, height: -1)) ?? false
    }

    @objc private func moveDown() -> Bool {
        onMoveStep?(CGSize(width: 0, height: 1)) ?? false
    }

    @objc private func moveLeft() -> Bool {
        onMoveStep?(CGSize(width: -1, height: 0)) ?? false
    }

    @objc private func moveRight() -> Bool {
        onMoveStep?(CGSize(width: 1, height: 0)) ?? false
    }

    #if DEBUG
    func performAddRowForTesting() -> Bool { addRow() }
    func performAddColumnForTesting() -> Bool { addColumn() }
    #endif
}

private enum CanvasTableGrowthAxis {
        case rows
        case columns
    }

    @MainActor
    private final class CanvasContactGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private var trackedTouches: Set<ObjectIdentifier> = []
        var onContactBegan: (() -> Void)?
        var onContactEnded: (() -> Void)?
        var shouldTrackDirectTouches: () -> Bool = { false }
        var hasActiveContact: Bool { trackedTouches.isEmpty == false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            let wasEmpty = trackedTouches.isEmpty
            for touch in touches where shouldTrack(touch) {
                trackedTouches.insert(ObjectIdentifier(touch))
            }
            guard trackedTouches.isEmpty == false else { return }
            state = wasEmpty ? .began : .changed
            if wasEmpty { onContactBegan?() }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if trackedTouches.isEmpty == false { state = .changed }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finish(touches)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finish(touches)
        }
        override func reset() {
            trackedTouches.removeAll()
            super.reset()
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            shouldTrack(touch)
        }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        private func shouldTrack(_ touch: UITouch) -> Bool {
            (touch.type == .direct && shouldTrackDirectTouches())
                || touch.type == .pencil
        }
        private func finish(_ touches: Set<UITouch>) {
            let hadContact = trackedTouches.isEmpty == false
            for touch in touches {
                trackedTouches.remove(ObjectIdentifier(touch))
            }
            if trackedTouches.isEmpty {
                state = .ended
                onContactEnded?()
            } else {
                state = .changed
            }
        }
    }

    /// The live paper surface sits beside (and beneath) PaperKit rather than inside
    /// it. During a pinch the comparatively expensive PaperKit hierarchy can stay
    /// in its bounded temporary raster without filtering thin rules and dots out
    /// of the background presentation.
final class PaperPageDecorationView: UIView {
    private struct TemplateLayerConfiguration: Equatable {
        let template: CanvasPaperTemplate
        let logicalPageSize: CGSize
        let renderScale: CGFloat
        let visibleLogicalRect: CGRect?
        let dotDiameter: CGFloat
    }

    private let templateLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private var templateLayerConfiguration: TemplateLayerConfiguration?
    private(set) var isRenderingActive: Bool
    private(set) var isOverlayPresentationActive = false

    var template: CanvasPaperTemplate {
        didSet {
            guard oldValue != template else { return }
            refreshSurfaceAppearance()
            invalidateTemplateLayer()
        }
    }

    var pageBackground: CanvasPageBackground {
        didSet {
            guard oldValue != pageBackground else { return }
            refreshSurfaceAppearance()
            invalidateTemplateLayer()
        }
    }

    var renderScale: CGFloat = CanvasConstants.defaultZoomScale {
        didSet {
            guard oldValue != renderScale else { return }
            invalidateTemplateLayer()
        }
    }

    var visibleLogicalRect: CGRect? {
        didSet {
            guard oldValue != visibleLogicalRect else { return }
            invalidateTemplateLayer()
        }
    }

    var presentationScale: CGFloat = CanvasConstants.defaultZoomScale {
        didSet {
            let oldDiameter = max(1.8, 1.2 / max(oldValue, 0.1))
            let newDiameter = max(1.8, 1.2 / max(presentationScale, 0.1))
            guard abs(oldDiameter - newDiameter) > 0.01 else { return }
            invalidateTemplateLayer()
        }
    }

    init(
        template: CanvasPaperTemplate,
        pageBackground: CanvasPageBackground,
        startsRenderingActive: Bool = true
    ) {
        self.template = template
        self.pageBackground = pageBackground
        isRenderingActive = startsRenderingActive
        super.init(frame: .zero)
        isOpaque = true
        isUserInteractionEnabled = false
        refreshSurfaceAppearance()
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.withAlphaComponent(0.28).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.masksToBounds = false

        templateLayer.fillColor = nil
        templateLayer.strokeColor = CanvasPaperTemplateArtwork.ruleColor(for: template.tone)
        templateLayer.lineCap = .round
        templateLayer.lineJoin = .round
        templateLayer.actions = [
            "path": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
        ]
        guideLayer.fillColor = nil
        guideLayer.strokeColor = CanvasPaperTemplateArtwork.guideColor(for: template.tone)
        guideLayer.lineCap = .round
        guideLayer.lineJoin = .round
        guideLayer.actions = [
            "path": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
        ]
        layer.insertSublayer(templateLayer, at: 0)
        layer.insertSublayer(guideLayer, above: templateLayer)
    }

    func setRenderingActive(_ isActive: Bool) {
        guard isRenderingActive != isActive else { return }
        isRenderingActive = isActive
        invalidateTemplateLayer()
    }

    /// PaperKit remains the normal owner of paged backgrounds. Freeform uses
    /// this transparent sibling above the live editor to supply only the tiled
    /// vector paper pattern.
    func setOverlayPresentationActive(_ isActive: Bool) {
        guard isOverlayPresentationActive != isActive else { return }
        isOverlayPresentationActive = isActive
        refreshSurfaceAppearance()
        refreshChromeAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        templateLayer.frame = bounds
        guideLayer.frame = bounds
        updateTemplateLayerIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        templateLayer.contentsScale = scale
        guideLayer.contentsScale = scale
    }

    private func refreshSurfaceAppearance() {
        if isOverlayPresentationActive {
            isOpaque = false
            backgroundColor = .clear
        } else {
            isOpaque = true
            backgroundColor = pageBackground.isImported ? .white : template.tone.uiColor
        }
    }

    private func refreshChromeAppearance() {
        layer.borderWidth = isOverlayPresentationActive ? 0 : 0.5
        layer.shadowOpacity = isOverlayPresentationActive ? 0 : 0.10
    }

    private func invalidateTemplateLayer() {
        templateLayerConfiguration = nil
        setNeedsLayout()
        guard isRenderingActive,
            pageBackground == .paper,
            template.style != .blank else {
            templateLayer.path = nil
            guideLayer.path = nil
            return
        }
    }

    private func updateTemplateLayerIfNeeded() {
        guard isRenderingActive,
            pageBackground == .paper,
            template.style != .blank,
            bounds.width.isFinite,
            bounds.height.isFinite,
            bounds.width > 0,
            bounds.height > 0,
            renderScale.isFinite,
            renderScale > 0 else {
            templateLayer.path = nil
            guideLayer.path = nil
            templateLayerConfiguration = nil
            return
        }
        if let visibleLogicalRect,
            visibleLogicalRect.isNull || visibleLogicalRect.isEmpty {
            templateLayer.path = nil
            guideLayer.path = nil
            templateLayerConfiguration = nil
            return
        }
        let logicalPageSize = CGSize(
            width: bounds.width / renderScale,
            height: bounds.height / renderScale
        )
        let dotDiameter = max(1.8, 1.2 / max(presentationScale, 0.1))
        let configuration = TemplateLayerConfiguration(
            template: template,
            logicalPageSize: logicalPageSize,
            renderScale: renderScale,
            visibleLogicalRect: visibleLogicalRect,
            dotDiameter: dotDiameter
        )
        guard configuration != templateLayerConfiguration else { return }
        let artwork = CanvasPaperTemplateArtwork.paths(
            for: template,
            pageSize: logicalPageSize,
            visibleRect: visibleLogicalRect,
            dotDiameter: dotDiameter
        )
        var transform = CGAffineTransform(
            scaleX: renderScale,
            y: renderScale
        )
        templateLayer.path = artwork.pattern.copy(using: &transform)
        guideLayer.path = artwork.guides.copy(using: &transform)
        let ruleColor = CanvasPaperTemplateArtwork.ruleColor(for: template.tone)
        guideLayer.strokeColor = CanvasPaperTemplateArtwork.guideColor(for: template.tone)
        if artwork.fillsPattern {
            templateLayer.fillColor = ruleColor
            templateLayer.strokeColor = nil
        } else {
            templateLayer.fillColor = nil
            templateLayer.strokeColor = ruleColor
        }
        templateLayer.lineWidth = max(0.7, 0.7 * renderScale)
        guideLayer.lineWidth = max(1, renderScale)
        templateLayerConfiguration = configuration
    }

    #if DEBUG
    var hasTemplateLayerForTesting: Bool {
        templateLayer.path != nil || guideLayer.path != nil
    }
    var templateLayerIdentityForTesting: ObjectIdentifier? {
        ObjectIdentifier(templateLayer)
    }
    var templateLayerCountForTesting: Int {
        hasTemplateLayerForTesting ? 1 : 0
    }
    #endif
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}

/// Immutable input for CATiledLayer's background-queue callbacks. Each draw
/// computes only the lattice primitives intersecting that tile. This avoids a
/// single multi-million-element path as a freeform board expands.
final class CanvasPaperTemplateDrawingSource: @unchecked Sendable {
        private struct AxisLattice {
            let first: CGFloat
            let spacing: CGFloat
            let lastIndex: Int

            static func centered(
                in range: ClosedRange<CGFloat>,
                spacing: CGFloat,
                minimumEdgeGap: CGFloat = 0
            ) -> AxisLattice? {
                guard spacing.isFinite,
                    spacing > 0,
                    minimumEdgeGap.isFinite,
                    minimumEdgeGap >= 0,
                    range.lowerBound.isFinite,
                    range.upperBound.isFinite,
                    range.lowerBound <= range.upperBound else { return nil }
                let availableLength = range.upperBound - range.lowerBound - (minimumEdgeGap * 2)
                guard availableLength.isFinite,
                    availableLength >= 0,
                    availableLength / spacing < CGFloat(Int.max) else { return nil }
                let intervalCount = Int(floor(availableLength / spacing))
                let occupiedLength = CGFloat(intervalCount) * spacing
                let remainder = (availableLength - occupiedLength) / 2
                return AxisLattice(
                    first: range.lowerBound + minimumEdgeGap + remainder,
                    spacing: spacing,
                    lastIndex: intervalCount
                )
            }

            func indices(intersecting range: ClosedRange<CGFloat>, padding: CGFloat) -> ClosedRange<Int>? {
                guard range.lowerBound.isFinite,
                    range.upperBound.isFinite,
                    range.lowerBound <= range.upperBound,
                    padding.isFinite,
                    padding >= 0 else { return nil }
                let rawFirstIndex = ceil((range.lowerBound - padding - first) / spacing)
                let rawFinalIndex = floor((range.upperBound + padding - first) / spacing)
                guard rawFirstIndex.isFinite,
                    rawFinalIndex.isFinite else { return nil }
                let firstIndex = max(Int(rawFirstIndex), 0)
                let finalIndex = min(Int(rawFinalIndex), lastIndex)
                guard firstIndex <= finalIndex else { return nil }
                return firstIndex...finalIndex
        }

        func position(at index: Int) -> CGFloat {
            first + CGFloat(index) * spacing
        }
    }

    private static let maximumPrimitivesPerTile = 24_000
    private let template: CanvasPaperTemplate
    private let pageSize: CGSize
    private let renderScale: CGFloat
    init(
        template: CanvasPaperTemplate,
        pageSize: CGSize,
        renderScale: CGFloat
    ) {
        self.template = template
        self.pageSize = pageSize
        self.renderScale = renderScale
    }

    nonisolated func draw(in context: CGContext) {
        guard template.style != .blank,
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width > 0,
            pageSize.height > 0,
            renderScale.isFinite,
            renderScale > 0 else { return }
        let nativePageBounds = CGRect(origin: .zero, size: CGSize(width: pageSize.width * renderScale, height: pageSize.height * renderScale))
        let nativeClip = context.boundingBoxOfClipPath.intersection(nativePageBounds)
        guard nativeClip.isNull == false, nativeClip.isEmpty == false else { return }
        let logicalClip = CGRect(
            x: nativeClip.minX / renderScale,
            y: nativeClip.minY / renderScale,
            width: nativeClip.width / renderScale,
            height: nativeClip.height / renderScale
        )
        let transform = context.ctm
        let deviceScale = max(
            hypot(transform.a, transform.c),
            hypot(transform.b, transform.d)
        )
        let authoredPixelsPerPoint = renderScale * max(deviceScale, 1)
        let ruleWidth = min(
            max(0.7, 0.85 / max(authoredPixelsPerPoint, 0.0001)),
            template.density.spacing * 0.12
        )
        let dotDiameter = min(
            max(1.8, 1.25 / max(authoredPixelsPerPoint, 0.0001)),
            template.density.spacing * 0.22
        )
        let guideWidth = min(
            max(1, 1 / max(authoredPixelsPerPoint, 0.0001)),
            template.density.spacing * 0.16
        )
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: nativeClip)
        context.scaleBy(x: renderScale, y: renderScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch template.style {
        case .blank:
            break
        case .ruled:
            drawHorizontalRules(
                in: context,
                lattice: AxisLattice.centered(
                    in: 0...pageSize.height,
                    spacing: template.density.spacing
                ),
                clip: logicalClip,
                fromX: 0,
                toX: pageSize.width,
                lineWidth: ruleWidth
            )
        case .grid:
            drawHorizontalRules(
                in: context,
                lattice: AxisLattice.centered(
                    in: 0...pageSize.height,
                    spacing: template.density.spacing
                ),
                clip: logicalClip,
                fromX: 0,
                toX: pageSize.width,
                lineWidth: ruleWidth
            )
            drawVerticalRules(
                in: context,
                lattice: AxisLattice.centered(
                    in: 0...pageSize.width,
                    spacing: template.density.spacing
                ),
                clip: logicalClip,
                fromY: 0,
                toY: pageSize.height,
                lineWidth: ruleWidth
            )
        case .dotted:
            drawDots(in: context, clip: logicalClip, diameter: dotDiameter)
        case .cornell:
            let bodyEnd = min(CanvasPaperTemplateGeometry.cornellSummaryY, pageSize.height)
            let lattice = CanvasPaperTemplateGeometry.cornellHeaderY <= bodyEnd
                ? AxisLattice.centered(
                    in: CanvasPaperTemplateGeometry.cornellHeaderY...bodyEnd,
                    spacing: template.density.spacing,
                    minimumEdgeGap: template.density.spacing / 2
                )
                : nil
            drawHorizontalRules(
                in: context,
                lattice: lattice,
                clip: logicalClip,
                fromX: CanvasPaperTemplateGeometry.cornellCueX,
                toX: pageSize.width,
                lineWidth: ruleWidth
            )
            drawCornellGuides(in: context, clip: logicalClip, lineWidth: guideWidth)
        case .music:
            drawMusicStaffs(in: context, clip: logicalClip, lineWidth: ruleWidth)
        }
    }

    private nonisolated func drawHorizontalRules(
        in context: CGContext,
        lattice: AxisLattice?,
        clip: CGRect,
        fromX: CGFloat,
        toX: CGFloat,
        lineWidth: CGFloat
    ) {
        guard clip.maxX >= fromX,
            clip.minX <= toX,
            let lattice,
            let indices = lattice.indices(
                intersecting: clip.minY...clip.maxY,
                padding: lineWidth
            ) else { return }
        context.beginPath()
        for index in indices {
            let y = lattice.position(at: index)
            context.move(to: CGPoint(x: fromX, y: y))
            context.addLine(to: CGPoint(x: toX, y: y))
        }
        context.setStrokeColor(CanvasPaperTemplateArtwork.ruleColor(for: template.tone))
        context.setLineWidth(lineWidth)
        context.strokePath()
    }

    private nonisolated func drawVerticalRules(
        in context: CGContext,
        lattice: AxisLattice?,
        clip: CGRect,
        fromY: CGFloat,
        toY: CGFloat,
        lineWidth: CGFloat
    ) {
        guard clip.maxY >= fromY,
            clip.minY <= toY,
            let lattice,
            let indices = lattice.indices(
                intersecting: clip.minX...clip.maxX,
                padding: lineWidth
            ) else { return }
        context.beginPath()
        for index in indices {
            let x = lattice.position(at: index)
            context.move(to: CGPoint(x: x, y: fromY))
            context.addLine(to: CGPoint(x: x, y: toY))
        }
        context.setStrokeColor(CanvasPaperTemplateArtwork.ruleColor(for: template.tone))
        context.setLineWidth(lineWidth)
        context.strokePath()
    }

    private nonisolated func drawDots(
        in context: CGContext,
        clip: CGRect,
        diameter: CGFloat
    ) {
        let radius = diameter / 2
        guard let horizontal = AxisLattice.centered(
            in: 0...pageSize.width,
            spacing: template.density.spacing
        ), let vertical = AxisLattice.centered(
            in: 0...pageSize.height,
            spacing: template.density.spacing
        ), let xIndices = horizontal.indices(
            intersecting: clip.minX...clip.maxX,
            padding: radius
        ), let yIndices = vertical.indices(
            intersecting: clip.minY...clip.maxY,
            padding: radius
        ) else { return }
        let yCount = yIndices.upperBound - yIndices.lowerBound + 1
        let xCount = xIndices.upperBound - xIndices.lowerBound + 1
        guard xCount <= Self.maximumPrimitivesPerTile / max(yCount, 1) else { return }
        context.setFillColor(CanvasPaperTemplateArtwork.ruleColor(for: template.tone))
        for yIndex in yIndices {
            let y = vertical.position(at: yIndex)
            for xIndex in xIndices {
                let x = horizontal.position(at: xIndex)
                context.fillEllipse(
                    in: CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: diameter,
                        height: diameter
                    )
                )
            }
        }
    }


    /// Draw only staffs that overlap the requested CATiledLayer tile. The
    /// number of generated primitives therefore stays proportional to the
    /// visible tile, even when a freeform board has expanded far beyond the
    /// initial 4,096-point surface.
    private nonisolated func drawMusicStaffs(
        in context: CGContext,
        clip: CGRect,
        lineWidth: CGFloat
    ) {
        let lineSpacing = CanvasPaperTemplateGeometry.musicStaffLineSpacing(
            for: template.density
        )
        let staffHeight = lineSpacing
            * CGFloat(CanvasPaperTemplateGeometry.musicStaffLineCount - 1)
        guard pageSize.height >= staffHeight,
            let lattice = AxisLattice.centered(
                in: 0...(pageSize.height - staffHeight),
                spacing: CanvasPaperTemplateGeometry.musicStaffStride(
                    for: template.density
                )
            ),
            let indices = lattice.indices(
                intersecting: (clip.minY - staffHeight)...clip.maxY,
                padding: lineWidth
            ) else { return }

        let staffCount = indices.upperBound - indices.lowerBound + 1
        guard staffCount <= Self.maximumPrimitivesPerTile
            / CanvasPaperTemplateGeometry.musicStaffLineCount else { return }

        context.beginPath()
        for staffIndex in indices {
            let top = lattice.position(at: staffIndex)
            for lineIndex in 0..<CanvasPaperTemplateGeometry.musicStaffLineCount {
                let y = top + CGFloat(lineIndex) * lineSpacing
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: pageSize.width, y: y))
            }
        }
        context.setStrokeColor(CanvasPaperTemplateArtwork.ruleColor(for: template.tone))
        context.setLineWidth(lineWidth)
        context.strokePath()
    }

    private nonisolated func drawCornellGuides(
        in context: CGContext,
    clip: CGRect,
    lineWidth: CGFloat
) {
    let headerY = CanvasPaperTemplateGeometry.cornellHeaderY
    let cueX = CanvasPaperTemplateGeometry.cornellCueX
    let summaryY = CanvasPaperTemplateGeometry.cornellSummaryY
    context.beginPath()
    if (clip.minY - 1...clip.maxY + 1).contains(headerY) {
        context.move(to: CGPoint(x: 0, y: headerY))
        context.addLine(to: CGPoint(x: pageSize.width, y: headerY))
    }
    if (clip.minX - 1...clip.maxX + 1).contains(cueX) {
        context.move(to: CGPoint(x: cueX, y: headerY))
        context.addLine(to: CGPoint(x: cueX, y: summaryY))
    }
    if (clip.minY - 1...clip.maxY + 1).contains(summaryY) {
        context.move(to: CGPoint(x: 0, y: summaryY))
        context.addLine(to: CGPoint(x: pageSize.width, y: summaryY))
    }
    context.setStrokeColor(CanvasPaperTemplateArtwork.guideColor(for: template.tone))
    context.setLineWidth(lineWidth)
    context.strokePath()
}
}

/// CATiledLayer keeps the paper pattern bounded to visible tiles and retains a
/// lower-detail presentation while Core Animation requests sharper zoom tiles.
final class CanvasPaperTemplateTiledLayer: CATiledLayer {
/// The outer canvas can magnify the stable native paper surface
/// by at most 15x (1,000% zoom over the smallest native basis).
/// Four doubled levels cover that range without retaining the unused
/// 32x/64x tile pyramids that previously amplified memory pressure during
/// repeated pinch gestures.
private static let supportedMagnificationDetailLevels = 4
private let drawingSourceLock = NSLock()
private var drawingSource: CanvasPaperTemplateDrawingSource?

init(drawingSource: CanvasPaperTemplateDrawingSource) {
    self.drawingSource = drawingSource
    super.init()
    tileSize = CGSize(width: 512, height: 512)
    levelsOfDetail = 1
    levelsOfDetailBias = Self.supportedMagnificationDetailLevels - 1
    drawsAsynchronously = true
    isOpaque = false
    // Blank-to-pattern changes create and insert this layer after its
    // frame has already been assigned. CATiledLayer does not consistently
    // request that first tile pass on insertion, so explicitly seed it and
    // keep later bounds changes invalidating the visible tiles.
    needsDisplayOnBoundsChange = true
    setNeedsDisplay()
}

override init(layer: Any) {
    drawingSource = (layer as? CanvasPaperTemplateTiledLayer)?
    .currentDrawingSource()
    super.init(layer: layer)
}
func update(drawingSource: CanvasPaperTemplateDrawingSource) {
    drawingSourceLock.lock()
    self.drawingSource = drawingSource
    drawingSourceLock.unlock()
    setNeedsDisplay()
}

private nonisolated func currentDrawingSource() -> CanvasPaperTemplateDrawingSource? {

        drawingSourceLock.lock()
        defer { drawingSourceLock.unlock() }
        return drawingSource
    }

    nonisolated override func draw(in context: CGContext) {
        currentDrawingSource()?.draw(in: context)
    }

    override class func fadeDuration() -> CFTimeInterval { 0 }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}

final class PaperPageContentView: UIView {
    private struct TiledTemplateConfiguration: Equatable {
        let template: CanvasPaperTemplate
        let pageSize: CGSize
    }

    /// The initial 4,096-point freeform board is a stable ~21K-dot vector at
    /// the densest normal template and displays synchronously. Larger expanded
    /// boards retain the bounded tile fallback rather than allocating a path
    /// proportional to their full area.
    private static let tiledTemplateDimensionThreshold: CGFloat = 4_096

    private var importedBackgroundView: CanvasImportedPageBackgroundView?
    private var tiledTemplateLayer: CanvasPaperTemplateTiledLayer?
    private var tiledTemplateConfiguration: TiledTemplateConfiguration?
    private let patternLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let tableSurfaceView = CanvasTableSurfaceView()
    private let rendersPaperTemplate: Bool
    private(set) var isRenderingActive: Bool

    var geometry: CanvasPageGeometry {
        didSet {
            tableSurfaceView.pageBounds = CGRect(origin: .zero, size: geometry.displaySize)
            refreshBackgroundImage()
            setNeedsLayout()
        }
    }

    var pageBackground: CanvasPageBackground {
        didSet {
            guard oldValue != pageBackground else { return }
            tableSurfaceView.paperTone = effectiveTablePaperTone
            refreshBackgroundImage()
            setNeedsLayout()
        }
    }

    var template: CanvasPaperTemplate {
        didSet {
            guard oldValue != template else { return }
            tableSurfaceView.paperTone = effectiveTablePaperTone
            refreshSurfaceAppearance()
            setNeedsLayout()
        }
    }

    var tables: [CanvasTable] {
        didSet {
            guard oldValue != tables else { return }
            tableSurfaceView.tables = tables
            tableSurfaceView.layer.displayIfNeeded()
        }
    }

    init(
        template: CanvasPaperTemplate,
        geometry: CanvasPageGeometry = CanvasPageGeometry(),
        background: CanvasPageBackground = .paper,
        tables: [CanvasTable] = [],
        rendersPaperTemplate: Bool = true,
        startsRenderingActive: Bool = true
    ) {
        self.template = template
        self.geometry = geometry
        pageBackground = background
        self.tables = tables
        self.rendersPaperTemplate = rendersPaperTemplate
        isRenderingActive = startsRenderingActive
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        refreshSurfaceAppearance()

        patternLayer.fillColor = nil
        patternLayer.strokeColor = CanvasPaperTemplateArtwork.ruleColor(for: template.tone)
        patternLayer.lineWidth = 0.7
        patternLayer.lineCap = .round
        patternLayer.lineJoin = .round
        patternLayer.actions = [
            "path": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
        ]

        guideLayer.fillColor = nil
        guideLayer.strokeColor = CanvasPaperTemplateArtwork.guideColor(for: template.tone)
        guideLayer.lineWidth = 1
        guideLayer.lineCap = .round
        guideLayer.lineJoin = .round
        guideLayer.actions = [
            "path": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
        ]

        layer.addSublayer(patternLayer)
        layer.addSublayer(guideLayer)
        tableSurfaceView.isUserInteractionEnabled = false
        tableSurfaceView.backgroundColor = .clear
        tableSurfaceView.isOpaque = false
        tableSurfaceView.tables = tables
        addSubview(tableSurfaceView)
        tableSurfaceView.pageBounds = CGRect(origin: .zero, size: geometry.displaySize)
        tableSurfaceView.paperTone = effectiveTablePaperTone
        refreshBackgroundImage()
    }

    func setRenderingActive(_ isActive: Bool) {
        guard isRenderingActive != isActive else { return }
        isRenderingActive = isActive
        if isActive {
            refreshBackgroundImage()
            setNeedsLayout()
        } else {
            // Removing the tiled view releases its tile cache and prepared
            // PDF/image source when the page leaves the render window.
            importedBackgroundView?.removeFromSuperview()
            importedBackgroundView = nil
            tiledTemplateLayer?.removeFromSuperlayer()
            tiledTemplateLayer = nil
            tiledTemplateConfiguration = nil
            patternLayer.path = nil
            guideLayer.path = nil
            tableSurfaceView.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        importedBackgroundView?.frame = bounds
        tableSurfaceView.frame = bounds
        tableSurfaceView.contentScaleFactor = contentScaleFactor
        tableSurfaceView.isHidden = isRenderingActive == false
        patternLayer.frame = bounds
        guideLayer.frame = bounds
        tiledTemplateLayer?.frame = bounds
        patternLayer.contentsScale = contentScaleFactor
        guideLayer.contentsScale = contentScaleFactor
        tiledTemplateLayer?.contentsScale = contentScaleFactor
        rebuildPaths()
    }

    private func rebuildPaths() {
        guard isRenderingActive, rendersPaperTemplate else {
            tiledTemplateLayer = nil
            tiledTemplateConfiguration = nil
            patternLayer.path = nil
            guideLayer.path = nil
            return
        }
        guard pageBackground == .paper else {
            tiledTemplateLayer?.removeFromSuperlayer()
            tiledTemplateLayer = nil
            tiledTemplateConfiguration = nil
            patternLayer.path = nil
            guideLayer.path = nil
            return
        }
        guard template.style != .blank else {
            tiledTemplateLayer?.removeFromSuperlayer()
            tiledTemplateLayer = nil
            tiledTemplateConfiguration = nil
            patternLayer.path = nil
            guideLayer.path = nil
            return
        }
        if max(bounds.width, bounds.height) > Self.tiledTemplateDimensionThreshold {
            patternLayer.path = nil
            guideLayer.path = nil
            let configuration = TiledTemplateConfiguration(
                template: template,
                pageSize: bounds.size
            )
            if configuration == tiledTemplateConfiguration {
                tiledTemplateLayer?.frame = bounds
                tiledTemplateLayer?.contentsScale = contentScaleFactor
                return
            }
            let drawingSource = CanvasPaperTemplateDrawingSource(
                template: template,
                pageSize: bounds.size,
                renderScale: 1
            )
        if let tiledTemplateLayer {
            tiledTemplateLayer.update(drawingSource: drawingSource)
            tiledTemplateLayer.frame = bounds
            tiledTemplateLayer.contentsScale = contentScaleFactor
        } else {
            let replacement = CanvasPaperTemplateTiledLayer(
                drawingSource: drawingSource
            )
            replacement.frame = bounds
            replacement.contentsScale = contentScaleFactor
            layer.insertSublayer(replacement, at: 0)
            tiledTemplateLayer = replacement
        }
        tiledTemplateConfiguration = configuration
        return
    }

        tiledTemplateLayer?.removeFromSuperlayer()
        tiledTemplateLayer = nil
        tiledTemplateConfiguration = nil
        let artwork = CanvasPaperTemplateArtwork.paths(
            for: template,
            pageSize: bounds.size
        )
        let ruleColor = CanvasPaperTemplateArtwork.ruleColor(for: template.tone)
        guideLayer.strokeColor = CanvasPaperTemplateArtwork.guideColor(for: template.tone)
        if artwork.fillsPattern {
            patternLayer.fillColor = ruleColor
            patternLayer.strokeColor = nil
        } else {
            patternLayer.fillColor = nil
            patternLayer.strokeColor = ruleColor
        }
        patternLayer.path = artwork.pattern
        guideLayer.path = artwork.guides
    }

    private func refreshBackgroundImage() {
        guard isRenderingActive else {
            importedBackgroundView?.removeFromSuperview()
            return
        }
        if pageBackground == .paper {
            importedBackgroundView?.removeFromSuperview()
            importedBackgroundView = nil
            refreshSurfaceAppearance()
        } else {
            refreshSurfaceAppearance()
            importedBackgroundView?.removeFromSuperview()
            let backgroundView = CanvasImportedPageBackgroundView(
                background: pageBackground,
                geometry: geometry
            )
            importedBackgroundView = backgroundView
            if let backgroundView = backgroundView {
                backgroundView.frame = bounds
                insertSubview(backgroundView, at: 0)
            }
        }
    }
    private func refreshSurfaceAppearance() {
        if pageBackground.isImported {
            isOpaque = true
            backgroundColor = .white
        } else {
            isOpaque = true
            backgroundColor = template.tone.uiColor
        }
    }

    private var effectiveTablePaperTone: CanvasPaperTone? {
        pageBackground.isImported ? nil : template.tone
    }

    var patternPathBoundsForTesting: CGRect {
        patternLayer.path?.boundingBoxOfPath ?? .null
    }

    var patternPathForTesting: CGPath? {
        patternLayer.path
    }
    var guidePathBoundsForTesting: CGRect {
        guideLayer.path?.boundingBoxOfPath ?? .null
    }

    #if DEBUG
    var hasImportedBackgroundViewForTesting: Bool {
        importedBackgroundView != nil
    }

    var usesTiledTemplateLayerForTesting: Bool {
        tiledTemplateLayer != nil
    }

    var importedBackgroundUsesTiledLayerForTesting: Bool {
        importedBackgroundView?.usesBackgroundSafeTiledLayerForTesting == true
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}

private final class CanvasTableSurfaceView: UIView {
    var tables: [CanvasTable] = [] {
        didSet {
            guard oldValue != tables else { return }
            setNeedsDisplay()
        }
    }

    var pageBounds: CGRect = .zero {
        didSet {
            guard oldValue != pageBounds else { return }
            setNeedsDisplay()
        }
    }

    var paperTone: CanvasPaperTone? {
        didSet {
            guard oldValue != paperTone else { return }
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard tables.isEmpty == false,
        pageBounds.width.isFinite,
        pageBounds.height.isFinite,
        pageBounds.width > 0,
        pageBounds.height > 0,
        bounds.width > 0,
        bounds.height > 0,
        let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.scaleBy(
            x: bounds.width / pageBounds.width,
            y: bounds.height / pageBounds.height
        )
        CanvasTableArtwork.draw(
            tables: tables,
            in: context,
            pageBounds: pageBounds,
            paperTone: paperTone
        )
        context.restoreGState()
    }
}

private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 0.01
        && abs(lhs.minY - rhs.minY) < 0.01
        && abs(lhs.width - rhs.width) < 0.01
        && abs(lhs.height - rhs.height) < 0.01
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
