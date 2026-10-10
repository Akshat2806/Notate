import Observation
import PaperKit
import UIKit

public struct CanvasAutosaveTiming: Sendable {
    public var trailingDelay: Duration
    public var forcedDelay: Duration
    public var preferencesDelay: Duration

    public init(
        trailingDelay: Duration = .milliseconds(750),
        forcedDelay: Duration = .seconds(5),
        preferencesDelay: Duration = .milliseconds(300)
    ) {
        self.trailingDelay = trailingDelay
        self.forcedDelay = forcedDelay
        self.preferencesDelay = preferencesDelay
    }
}

public enum CanvasPageDeletionError: Error, LocalizedError, Equatable {
    case unavailable
    case pageNotFound
    case solePage
    case operationInProgress
    case removalRejected
    case checkpointFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "This page cannot be deleted until its notebook storage is ready."
        case .pageNotFound:
            "The page is no longer available."
        case .solePage:
            "A document must keep at least one page."
        case .operationInProgress:
            "This page is already being deleted."
        case .removalRejected:
            "The page changed before it could be deleted. Please try again."
        case let .checkpointFailed(description):
            "The permanent deletion was not safely stored, so Notate restored the page. \(description)"
        }
    }
}

public struct CanvasVerifiedInsertionReceipt: Equatable, Sendable {
    public let pageID: UUID
    public let controllerAcceptanceSequence: UInt64
    public let verifiedGeneration: Int64
}

public enum CanvasDurableInsertionError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case operationInProgress
    case controller(PaperCanvasInsertionCommitError)
    case captureFailed
    case generationDidNotAdvance
    case checkpointFailed(String)
    case verificationMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The live canvas is not ready for this insertion."
        case .operationInProgress:
            "Another insertion is still being safely stored. Try again in a moment."
        case let .controller(error):
            error.localizedDescription
        case .captureFailed:
            "The insertion was accepted, but the live canvas could not be captured safely."
        case .generationDidNotAdvance:
            "The insertion did not reach the document save pipeline."
        case let .checkpointFailed(description):
            "The insertion could not be safely stored. \(description)"
        case .verificationMismatch:
            "The saved document could not verify the inserted content."
        }
    }
}

@MainActor
@Observable
public final class CanvasEditorModel {
    private struct DeferredControllerInsertion {
        let insertion: CanvasInsertion
        let pageID: UUID
    }

    private struct ControllerPresentationState: Equatable {
        let pageID: UUID
        let viewport: CanvasViewportState
    }

    /// A controller handoff normally spans only a few MainActor turns. Keep the
    /// recovery queue intentionally small because one entry can retain a decoded
    /// image; overflow is rejected visibly instead of creating unbounded memory.
    private static let maximumDeferredControllerInsertionCount = 8
    private static let maximumDeferredControllerImageCount = 1
    private static let maximumDeferredControllerImageBytes = 128 * 1_024 * 1_024

    /// Mirrors the Canvas Core persistence limits. A mutation that would
    /// exceed them is refused up front; once accepted it could never be saved.
    private static let maximumPageCount = 1_000
    private static let maximumImagePageCount = 60

    /// A short, user-facing reason an action was declined. The editor shows it
    /// in an alert and clears it.
    public var actionNotice: String?

    public enum LaunchState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    public enum SaveState: Equatable {
        case saved
        case saving
        case retrying(String)
        case failed(String)
    }

    public private(set) var launchState: LaunchState = .loading
    public private(set) var saveState: SaveState = .saved
    /// Changes with each editor model so a reused navigation destination can
    /// restart its view-scoped initial load for the replacement session.
    @ObservationIgnored public let loadSessionID = UUID()
    public private(set) var toolState = CanvasToolState()
    public private(set) var overlay: CanvasOverlay = .none
    public private(set) var inputMode: CanvasInputMode = .pencilOnly
    public private(set) var pageLayout: CanvasPageLayoutPreferences = .default
    public private(set) var readerPreferences: CanvasReaderPreferences = .default
    public private(set) var isReaderMode = false
    public private(set) var isReaderModeTransitioning = false
    public private(set) var readerViewportSize: CGSize = .zero
    public private(set) var readerPages: [CanvasPageSnapshot] = []
    public private(set) var readerCurrentPageID: UUID?
    public private(set) var preferredGeometryTool: CanvasGeometryTool = .ruler
    public private(set) var activeGeometryTool: CanvasGeometryTool?
    public var isRulerActive: Bool { activeGeometryTool == .ruler }
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var pageCount = 1
    public private(set) var currentPageNumber = 1
    public private(set) var currentPaperTemplate: CanvasPaperTemplate = .default
    public private(set) var currentZoomPercent = 100
    public private(set) var currentZoomScale = CanvasConstants.defaultZoomScale
    public private(set) var isZoomInteractionActive = false
    public private(set) var boundaryPagePull: CanvasBoundaryPagePull?
    public private(set) var imageWandRequest: CanvasImageWandRequest?
    public private(set) var isImageWandSelectionActive = false
    /// True while a one-shot generated image is being serialized and then
    /// committed to Canvas Core. Page topology/rotation controls use this to
    /// avoid building replacements from a pre-insertion snapshot.
    public private(set) var isDurableInsertionInFlight = false
    /// Advances only after Canvas Core has atomically committed and verified a
    /// document snapshot. Library views observe this to refresh derived data.
    public private(set) var verifiedCheckpointGeneration: Int64 = 0
    /// Published from the same immutable snapshot as
    /// `verifiedCheckpointGeneration`, immediately before the generation
    /// advances. Consumers should match `generation` to the snapshot they load.
    public private(set) var latestVerifiedIndexDelta: CanvasVerifiedIndexDelta?
    /// Metadata for the verified generation. Keep markup in the live editor or
    /// durable store instead of retaining a second decoded notebook snapshot.
    public private(set) var latestVerifiedIndexPageCount = 0
    public let documentKind: LibraryItemKind

    @ObservationIgnored public private(set) var initialPages: [CanvasPageSnapshot]
    @ObservationIgnored public private(set) var initialPageID: UUID
    @ObservationIgnored public private(set) var initialMarkup: PaperMarkup
    @ObservationIgnored public private(set) var viewport = CanvasViewportState()

    @ObservationIgnored private let checkpointStore: (any CanvasCoreCheckpointing)?
    @ObservationIgnored private let preferencesStore: CanvasPreferencesStore?
    @ObservationIgnored private let autosaveTiming: CanvasAutosaveTiming
    @ObservationIgnored private let constructionFailure: String?
    @ObservationIgnored private var deletedPageArchiver: (
        @MainActor (CanvasPageSnapshot, Int) async throws -> UUID
    )?
    @ObservationIgnored private var deletedPageArchiveRollback: (
        @MainActor (UUID) async throws -> Void
    )?

    @ObservationIgnored private weak var canvasController: (any PaperCanvasCommanding)?
#if DEBUG || NOTATE_INK_PROFILING
    var nativePinchDiagnosticForTesting: String {
        (canvasController as? PaperCanvasViewController)?.nativePinchDiagnosticForTesting
            ?? "canvas controller unavailable"
    }
#endif
    @ObservationIgnored private var pages: [CanvasPageSnapshot]
    @ObservationIgnored private var cachedPageIndices: [UUID: Int]?
    @ObservationIgnored private var currentPageID: UUID
    @ObservationIgnored private var pageContentRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var isInkContactActive = false
    @ObservationIgnored private var hasDeferredInkCheckpoint = false
    @ObservationIgnored private var pendingProgrammaticFocusPageID: UUID?
    @ObservationIgnored private var isApplyingPageOverviewMutation = false
    @ObservationIgnored private var isApplyingPageLayout = false
    @ObservationIgnored private var pageTrashMutationsInFlight: Set<UUID> = []
    @ObservationIgnored private var authorizedPageTrashRemovalID: UUID?
    @ObservationIgnored private var generation: Int64 = 0
    @ObservationIgnored private var committedGeneration: Int64 = 0
    @ObservationIgnored private var lastVerifiedIndexPageIDs: [UUID] = []
    @ObservationIgnored private var lastVerifiedIndexContentRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var lastVerifiedIndexGeneration: Int64 = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var activeLoadAttemptID: UUID?
    @ObservationIgnored private var isImageAndSelectionActive = false
    @ObservationIgnored private var previousAccessoryTool: CanvasTool = .eraser
    @ObservationIgnored private var inFlightGenerations: Set<Int64> = []
    @ObservationIgnored private var checkpointCompletionWaiters: [
        Int64: [CheckedContinuation<Void, Never>]
    ] = [:]
    @ObservationIgnored private var detachedControllerDrainTask: Task<Bool, Never>?
    @ObservationIgnored private var detachedControllerDrainSequence: UInt64 = 0
    @ObservationIgnored private var canvasControllerIsSnapshotReady = true
    @ObservationIgnored private var requiresControllerReconciliation = false
    @ObservationIgnored private var isAwaitingControllerReattachment = false
    @ObservationIgnored private var deferredControllerInsertions: [
        DeferredControllerInsertion
    ] = []
    @ObservationIgnored private var deferredControllerImageCount = 0
    @ObservationIgnored private var deferredControllerImageBytes = 0

    @ObservationIgnored private var trailingSaveTask: Task<Void, Never>?
    @ObservationIgnored private var forcedSaveTask: Task<Void, Never>?
    @ObservationIgnored private var preferencesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var trailingSaveToken: UInt64 = 0
    @ObservationIgnored private var forcedSaveToken: UInt64 = 0
    @ObservationIgnored private var preferencesSaveToken: UInt64 = 0
    /// A lifecycle flush may reach PaperKit while a Pencil/finger contact or
    /// controller handoff still owns newer authored state. Keep that failed-
    /// closed boundary explicit so cancelling the ordinary timers never turns
    /// into a permanent loss of the last generation.
    @ObservationIgnored private var requiresDeferredCheckpointRetry = false
    @ObservationIgnored private var transientCheckpointFailureCount = 0
    @ObservationIgnored private var isCheckpointRetryPending = false
    /// One fully-armed pull-to-add-page release that arrived while the canvas
    /// was briefly busy (for example the scrolling finger still counted as
    /// contact in Draw-with-Finger mode). It is applied at most once, and only
    /// if the person is still at that edge and has not started drawing.
    @ObservationIgnored private var pendingBoundaryInsertion: CanvasPageBoundary?

    /// A deliberate, zero-pull way to add a page: after you scroll while on the
    /// last page, an "Add Page" button appears for a few seconds. It is never
    /// shown while writing, so a resting palm can't reach it.
    public private(set) var showsAddPageAffordance = false
    @ObservationIgnored private var addPageAffordanceDeadline = Date.distantPast
    @ObservationIgnored private var addPageAffordanceTask: Task<Void, Never>?
    @ObservationIgnored private var lastAddPageAt = Date.distantPast

    public static func live() -> CanvasEditorModel {
        do {
            return CanvasEditorModel(
                checkpointStore: try CanvasCoreStore.live(),
                preferencesStore: try CanvasPreferencesStore.live(),
                documentKind: .notebook
            )
        } catch {
            return CanvasEditorModel(
                checkpointStore: nil,
                preferencesStore: nil,
                constructionFailure: error.localizedDescription,
                documentKind: .notebook
            )
        }
    }

    public static func live(
        itemID: UUID,
        documentKind: LibraryItemKind = .notebook,
        storageRootURL: URL? = nil
    ) -> CanvasEditorModel {
        do {
            let checkpointStore: CanvasCoreStore
            let preferencesStore: CanvasPreferencesStore
            if let storageRootURL {
                checkpointStore = CanvasCoreStore(rootURL: storageRootURL)
                preferencesStore = CanvasPreferencesStore(rootURL: storageRootURL)
            } else {
                checkpointStore = try CanvasCoreStore.live(itemID: itemID)
                preferencesStore = try CanvasPreferencesStore.live(itemID: itemID)
            }
            return CanvasEditorModel(
                checkpointStore: checkpointStore,
                preferencesStore: preferencesStore,
                documentKind: documentKind
            )
        } catch {
            return CanvasEditorModel(
                checkpointStore: nil,
                preferencesStore: nil,
                constructionFailure: error.localizedDescription,
                documentKind: documentKind
            )
        }
    }

    init(
        checkpointStore: (any CanvasCoreCheckpointing)?,
        preferencesStore: CanvasPreferencesStore?,
        autosaveTiming: CanvasAutosaveTiming = CanvasAutosaveTiming(),
        constructionFailure: String? = nil,
        documentKind: LibraryItemKind = .notebook
    ) {
        let pageID = UUID()
        let markup = Self.blankMarkup(for: documentKind)
        self.checkpointStore = checkpointStore
        self.preferencesStore = preferencesStore
        self.autosaveTiming = autosaveTiming
        self.constructionFailure = constructionFailure
        self.documentKind = documentKind
        let page = CanvasPageSnapshot(
            id: pageID,
            markup: markup,
            viewport: Self.initialViewport(for: documentKind),
            paperTemplate: NotatePreferences.defaultPaperTemplate
        )
        initialPages = [page]
        initialPageID = pageID
        initialMarkup = markup
        pages = [page]
        currentPageID = pageID
        pageContentRevisions[page.id] = 0
        lastVerifiedIndexPageIDs = [page.id]
        lastVerifiedIndexContentRevisions[page.id] = 0
        readerPages = []
        readerCurrentPageID = nil
    }

    public var canGoToPreviousPage: Bool {
        supportsPageStack && currentPageNumber > 1
    }

    public var canGoToNextPage: Bool {
        supportsPageStack && currentPageNumber < pageCount
    }

    public var documentMode: CanvasDocumentMode {
        documentKind == .canvas ? .freeform : .paged
    }

    public var supportsPageStack: Bool { documentMode == .paged }

    public var allowsAuthoring: Bool {
        launchState == .ready
            && isReaderMode == false
            && isReaderModeTransitioning == false
            && isDurableInsertionInFlight == false
            && isCheckpointRetryPending == false
    }

    public var resolvedReaderPageLayout: CanvasPageLayoutPreferences {
        readerPreferences.resolvedPageLayout(for: readerViewportSize)
    }

    public func resolvedReaderPageTransition(
        reduceMotion: Bool
    ) -> CanvasReaderPageTransition {
        readerPreferences.resolvedPageTransition(
            for: readerViewportSize,
            reduceMotion: reduceMotion
        )
    }

    /// Reader Mode is session-only. Its presentation preferences are persisted,
    /// but reopening a document always returns to the familiar editing surface.
    @discardableResult
    public func enterReaderMode() async -> Bool {
        guard supportsPageStack,
            launchState == .ready,
            isReaderMode == false,
            isReaderModeTransitioning == false,
            isDurableInsertionInFlight == false,
            pageTrashMutationsInFlight.isEmpty else { return false }

        var initiallyLockedController: (any PaperCanvasCommanding)?
        var entryCommitted = false
        isReaderModeTransitioning = true
        // Reader is read-only: close any open tool panel and Add button.
        overlay = .none
        hideAddPageAffordance()
        defer {
            isReaderModeTransitioning = false
            if entryCommitted == false {
                _ = initiallyLockedController?.setReaderModeEnabled(false)
                if let canvasController,
                    initiallyLockedController.map({
                        ObjectIdentifier($0) != ObjectIdentifier(canvasController)
                    }) ?? true {
                    _ = canvasController.setReaderModeEnabled(false)
                }
            }
        }
        overlay = .none
        if isImageWandSelectionActive { cancelImageWandSelection() }
        guard await finishPendingControllerWorkForSnapshot(),
            captureLatestControllerDocumentIfNeeded() else { return false }

        initiallyLockedController = canvasController
        guard initiallyLockedController?.setReaderModeEnabled(true) ?? true else {
            return false
        }
        // Ending a native text edit can publish its final markup synchronously
        // or on the next main-actor turn. Capture once more after the native
        // controller is locked so Reader never freezes the pre-commit value.
        await Task.yield()
        guard canvasController?.setReaderModeEnabled(true) ?? true,
              await finishPendingControllerWorkForSnapshot(),
              captureLatestControllerDocumentIfNeeded(),
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty else {
            return false
        }
        readerPages = pages
        readerCurrentPageID = currentPageID
        overlay = .none
        isReaderMode = true
        entryCommitted = true
        return true
    }

    public func exitReaderMode() {
        guard isReaderMode else { return }
        let targetPageID = readerCurrentPageID ?? currentPageID
        let controller = canvasController
        // Clear the model barrier before the locked controller aligns itself so
        // its synchronous focus/viewport acknowledgement is accepted. SwiftUI
        // cannot expose the editor until this main-actor method returns and the
        // controller is unlocked below.
        isReaderMode = false
        readerPages.removeAll(keepingCapacity: false)
        readerCurrentPageID = nil
        pendingProgrammaticFocusPageID = nil
        if pages.contains(where: { $0.id == targetPageID }) {
            pendingProgrammaticFocusPageID = targetPageID
            controller?.scrollToPage(id: targetPageID, animated: false)
            // Some transitional protocol conformers do not publish focus after
            // a nonanimated scroll. Never let their unacknowledged token reject
            // the next genuine page interaction.
            if pendingProgrammaticFocusPageID == targetPageID {
                pendingProgrammaticFocusPageID = nil
            }
        }
        _ = controller?.setReaderModeEnabled(false)
    }

    public func toggleReaderMode() async {
        if isReaderMode {
            exitReaderMode()
        } else {
            _ = await enterReaderMode()
        }
    }

    public func setReaderViewportSize(_ size: CGSize) {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width >= 0,
              size.height >= 0,
              readerViewportSize != size else { return }
        readerViewportSize = size
    }

    public func setReaderPreferences(_ preferences: CanvasReaderPreferences) {
        guard readerPreferences != preferences else { return }
        readerPreferences = preferences
        persistPreferencesSoon()
    }

    /// Records Reader navigation without waking the hidden live canvas. Exit
    /// aligns that controller once, preserving its undo stack and page viewport.
    public func readerDidNavigate(to pageID: UUID) {
        guard isReaderMode,
              pageIndex(for: pageID) != nil else { return }
        readerCurrentPageID = pageID
        setFocusedPage(pageID, documentDidChange: false)
    }

    public var currentPageHasImportedBackground: Bool {
        guard let index = indexOfCurrentPage else { return false }
        return pages[index].background.isImported
    }

    public var currentPageDisplaySize: CGSize {
        guard let index = indexOfCurrentPage else {
            return CanvasConstants.a4PortraitSize
        }
        return pages[index].displaySize
    }

    /// Returns only the densest current page for the opt-in profiling fixture.
    /// Avoids retaining or copying a second full notebook snapshot just to
    /// select one handwritten source page.
    @available(iOS 27.0, *)
    func mostHandwrittenPageForDeveloperStress() -> (page: CanvasPageSnapshot, pageNumber: Int)? {
        guard let entry = pages.enumerated().max(by: {
            $0.element.markup.subelements.strokes.count
                < $1.element.markup.subelements.strokes.count
        }) else { return nil }
        return (entry.element, entry.offset + 1)
    }

    public var callbacks: PaperCanvasCallbacks {
        PaperCanvasCallbacks(
            markupChanged: { [weak self] pageID, markup in
                self?.paperMarkupDidChange(markup, on: pageID)
            },
            pageReplaced: { [weak self] page in
                self?.paperPageDidReplace(page)
            },
            paperTemplateChanged: { [weak self] pageID, template in
                self?.paperTemplateDidChange(template, on: pageID)
            },
            paperTemplatesChanged: { [weak self] templates in
                self?.paperTemplatesDidChange(templates)
            },
            interactionBegan: { [weak self] pageID in
                self?.drawingInteractionDidBegin(on: pageID)
            },
            undoAvailabilityChanged: { [weak self] pageID, canUndo, canRedo in
                guard self?.currentPageID == pageID else { return }
                self?.canUndo = canUndo
                self?.canRedo = canRedo
            },
            viewportChanged: { [weak self] pageID, viewport in
                self?.viewportDidChange(viewport, on: pageID)
            },
            focusedPageChanged: { [weak self] pageID in
                self?.focusedPageDidChange(pageID)
            },
            snapshotContactEnded: { [weak self] in
                self?.snapshotContactDidEnd()
            },
            programmaticInsertionFailed: { [weak self] error in
                self?.programmaticInsertionDidFail(error)
            },
            presentationInteractionBegan: { [weak self] in
                self?.presentationInteractionDidBegin()
            },
            zoomInteractionChanged: { [weak self] isActive in
                self?.zoomInteractionDidChange(isActive)
            },
            boundaryPullChanged: { [weak self] pull in
                self?.boundaryPullDidChange(pull)
            },
            boundaryPageInsertionRequested: { [weak self] boundary in
                self?.boundaryPageInsertionWasRequested(at: boundary)
            },
            imageWandSelectionCompleted: { [weak self] request in
                self?.isImageWandSelectionActive = false
                self?.imageWandRequest = request
            },
            pencilPreferredActionRequested: { [weak self] action in
                self?.handlePencilPreferredAction(action)
            }
        )
    }

    func handlePencilPreferredAction(_ action: UIPencilPreferredAction) {
        guard allowsAuthoring else { return }
        switch action {
        case .switchEraser:
            select(toolState.activeTool == .eraser ? previousAccessoryTool : .eraser)
            overlay = .none
        case .switchPrevious:
            select(previousAccessoryTool)
            overlay = .none
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            let tool = toolState.activeTool
            guard tool.supportsOptions else {
                overlay = .none
                return
            }
            toggleOptions(for: tool)
        case .ignore, .runSystemShortcut:
            break
        @unknown default:
            break
        }
    }

    public func start() async {
        guard hasStarted == false else { return }
        hasStarted = true
        await loadCanvas()
    }

    public func retryRecovery() async {
        launchState = .loading
        await loadCanvas()
    }

    public func attachCanvasController(_ controller: any PaperCanvasCommanding) {
        canvasController = controller
        isAwaitingControllerReattachment = false
        pendingProgrammaticFocusPageID = nil
        controller.applyToolState(toolState)
        controller.applyInputMode(inputMode)
        controller.setCheckpointRetryPending(isCheckpointRetryPending)
        let shouldLockForReader = isReaderMode || isReaderModeTransitioning
        let readerLockAccepted = controller.setReaderModeEnabled(shouldLockForReader)
        if isReaderMode, readerLockAccepted == false {
            // A replacement controller that cannot prove its read-only state
            // must make Reader disappear rather than exposing an editable
            // surface under read-only chrome.
            isReaderMode = false
        }
        controller.setPageLayout(pageLayout)
        controller.setGeometryTool(activeGeometryTool)
        if detachedControllerDrainTask != nil {
            // This controller was created from a SwiftUI value that can still
            // predate the retiring controller's accepted insertion. Prevent
            // it from accepting edits until the drain can hydrate it.
            controller.setDocumentSynchronizationPending(true)
            canvasControllerIsSnapshotReady = false
            requiresControllerReconciliation = true
        } else if requiresControllerReconciliation {
            canvasControllerIsSnapshotReady = synchronizeAttachedControllerWithModel()
        } else {
            canvasControllerIsSnapshotReady = true
        }
    }

    public func detachCanvasController(_ controller: any PaperCanvasCommanding) {
        guard let canvasController,
            ObjectIdentifier(canvasController) == ObjectIdentifier(controller) else { return }
        requiresControllerReconciliation = true
        isAwaitingControllerReattachment = true
        let requiresDetachedDrain = controller.hasPendingProgrammaticInsertions
        if requiresDetachedDrain {
            beginDetachedControllerDrain(controller)
        } else if isReaderMode == false, isReaderModeTransitioning == false {
            _ = captureLatestControllerDocumentIfNeeded()
        }
        controller.setDocumentSynchronizationPending(false)
        if requiresDetachedDrain == false {
            controller.completeDismantle()
        }
        pendingProgrammaticFocusPageID = nil
        isZoomInteractionActive = false
        boundaryPagePull = nil
        imageWandRequest = nil
        self.canvasController = nil
        canvasControllerIsSnapshotReady = true
    }

    /// Installs the application-owned archive boundary used by All Pages.
    /// Archiving completes before the live page is removed, so a failed file
    /// write or catalog transaction leaves the document untouched.
    public func configureDeletedPageArchiver(
        _ archiver: @escaping @MainActor (CanvasPageSnapshot, Int) async throws -> UUID,
        rollback: @escaping @MainActor (UUID) async throws -> Void
    ) {
        deletedPageArchiver = archiver
        deletedPageArchiveRollback = rollback
    }

    public func handle(_ intent: CanvasToolbarIntent) {
        guard isReaderMode == false, isReaderModeTransitioning == false else {
            if case .dismissOverlay = intent { overlay = .none }
            return
        }
        if case .tapTool = intent, isImageWandSelectionActive {
            // Wand is a one-shot mode rather than a persistent drawing tool.
            // Choosing any ordinary tool is its native-feeling escape route;
            // no floating cancel control needs to cover the page.
            cancelImageWandSelection()
        }

        switch intent {
        case .undo:
            canvasController?.undo()

        case .redo:
            canvasController?.redo()

        case let .tapTool(tool):
            // First tap selects; tapping the selected tool again opens its
            // panel. (Style changes inside the panel use `.showOptions`.)
            if toolState.activeTool == tool {
                toggleOptions(for: tool)
            } else {
                select(tool)
                overlay = .none
            }

        case let .showOptions(tool):
            guard tool.supportsOptions else {
                overlay = .none
                return
            }
            if toolState.activeTool != tool {
                select(tool)
            }
            overlay = .toolOptions(tool)

        case let .setWidth(tool, width):
            guard CanvasToolState.widthPresets(for: tool).contains(where: {
                abs($0 - width) < 0.001
            }), var configuration = toolState.configuration(for: tool) else { return }
            guard abs(configuration.width - width) >= 0.001 else { return }
            configuration.width = width
            toolState.configurations[tool] = configuration
            applyToolIfActive(tool)
            persistPreferencesSoon()

        case let .setColor(tool, color):
            guard tool != .lasso, tool != .eraser,
                color.isValid,
                var configuration = toolState.configuration(for: tool) else { return }
            var normalizedColor = color
            normalizedColor.alpha = tool == .highlighter ? 0.45 : 1
            guard configuration.color != normalizedColor else { return }
            configuration.color = normalizedColor
            toolState.configurations[tool] = configuration
            applyToolIfActive(tool)
            persistPreferencesSoon()

        case let .setEraserMode(mode):
            guard toolState.eraserMode != mode else { return }
            toolState.eraserMode = mode
            applyToolIfActive(.eraser)
            persistPreferencesSoon()

        case let .setLaserPointerStyle(style):
            guard toolState.laserPointerStyle != style else { return }
            toolState.laserPointerStyle = style
            applyToolIfActive(.laserPointer)
            persistPreferencesSoon()

        case .toggleInsert:
            overlay = overlay == .insert
                || overlay == .shapes
                || overlay == .tableSizePicker
                ? .none
                : .insert

        case .tapGeometryToolSlot:
            toggleGeometryTool(.ruler)

        case let .toggleGeometryTool(tool):
            toggleGeometryTool(tool)

        case .toggleRuler:
            toggleGeometryTool(.ruler)

        case .showShapes:
            overlay = .shapes

        case .dismissOverlay:
            overlay = .none

        case .insertText:
            overlay = .none
            submitProgrammaticInsertion(.text)

        case let .insertShape(shape):
            overlay = .none
            submitProgrammaticInsertion(.shape(shape))

        case .showTableSizePicker:
            overlay = .tableSizePicker

        case let .insertTable(size):
            guard size.isValid else { return }
            overlay = .none
            submitProgrammaticInsertion(.table(size))

        case .requestImageWand, .requestPhoto, .requestFile:
            // Presentation belongs to CanvasEditorView. The active drawing tool
            // is intentionally unaffected by either request.
            break
        }
    }

    public func insertImage(_ image: CGImage) {
        guard isReaderMode == false, isReaderModeTransitioning == false else { return }
        overlay = .none
        submitProgrammaticInsertion(.image(image))
    }

    /// Photo and file imports use a durable acknowledgement rather than
    /// treating acceptance by PaperKit as completion. The returned generation
    /// is backed by the exact controller receipt in a verified Canvas Core
    /// snapshot, so callers can surface a truthful success or failure.
    @discardableResult
    public func insertImageDurably(
        _ image: CGImage
    ) async throws -> CanvasVerifiedInsertionReceipt {
        guard isReaderMode == false, isReaderModeTransitioning == false else {
            throw CanvasDurableInsertionError.unavailable
        }
        overlay = .none
        return try await commitProgrammaticInsertion(
            .image(image),
            on: currentPageID
        )
    }

    public func beginImageWandSelection() {
        guard launchState == .ready,
            isReaderMode == false,
            isReaderModeTransitioning == false else { return }
        overlay = .none
        imageWandRequest = nil
        isImageWandSelectionActive = true
        canvasController?.beginImageWandSelection(checkpointGeneration: generation)
    }

    public func cancelImageWandSelection() {
        isImageWandSelectionActive = false
        imageWandRequest = nil
        canvasController?.cancelImageWandSelection()
    }

    public func consumeImageWandRequest(id: UUID) {
        guard imageWandRequest?.id == id else { return }
        imageWandRequest = nil
    }

    @discardableResult
    public func insertImage(
        _ image: CGImage,
        frame: CGRect,
        onPageID pageID: UUID? = nil,
        expectedGeneration: Int64? = nil
    ) -> Bool {
        guard allowsAuthoring,
            canvasControllerIsSnapshotReady,
            expectedGeneration.map({ $0 == generation }) ?? true,
            frame.isNull == false,
            frame.isInfinite == false,
            frame.width.isFinite,
            frame.height.isFinite,
            frame.width > 0,
            frame.height > 0,
            let canvasController else { return false }
        if let pageID {
            guard pages.contains(where: { $0.id == pageID }) else { return false }
            if currentPageID != pageID {
                setFocusedPage(pageID, documentDidChange: false)
                pendingProgrammaticFocusPageID = pageID
            }
            canvasController.navigateToPageRegion(
                pageID: pageID,
                pageBounds: frame,
                animated: false
            )
        }
        canvasController.performInsertion(.positionedImage(image, frame: frame))
        return true
    }

    /// Inserts a one-shot generated image only after the controller has
    /// serialized the immutable before/after states and published the changed
    /// markup back to Canvas Core. Callers may safely consume their request
    /// only when this returns true.
    @discardableResult
    public func insertImageAndWait(
        _ image: CGImage,
        frame: CGRect,
        onPageID pageID: UUID? = nil,
        expectedGeneration: Int64? = nil
    ) async -> Bool {
        guard allowsAuthoring,
            canvasControllerIsSnapshotReady,
            expectedGeneration.map({ $0 == generation }) ?? true,
            frame.isNull == false,
            frame.isInfinite == false,
            frame.width.isFinite,
            frame.height.isFinite,
            frame.width > 0,
            frame.height > 0 else { return false }
        let targetPageID = pageID ?? currentPageID
        if let pageID {
            guard pages.contains(where: { $0.id == pageID }) else { return false }
            if currentPageID != pageID {
                setFocusedPage(pageID, documentDidChange: false)
                pendingProgrammaticFocusPageID = pageID
            }
            canvasController?.navigateToPageRegion(
                pageID: pageID,
                pageBounds: frame,
                animated: false
            )
        }
        do {
            _ = try await commitProgrammaticInsertion(
                .positionedImage(image, frame: frame),
                on: targetPageID
            )
            return true
        } catch {
            return false
        }
    }

    /// Internal command surface shared by durable imports and focused tests.
    /// Toolbar commands can remain one-tap synchronous, while snapshot/AI and
    /// lifecycle consumers still drain their accepted controller boundary.
    @discardableResult
    func commitProgrammaticInsertion(
        _ insertion: CanvasInsertion,
        on pageID: UUID
    ) async throws -> CanvasVerifiedInsertionReceipt {
        guard allowsAuthoring,
              pages.contains(where: { $0.id == pageID }) else {
            throw CanvasDurableInsertionError.unavailable
        }
        guard isDurableInsertionInFlight == false else {
            throw CanvasDurableInsertionError.operationInProgress
        }
        isDurableInsertionInFlight = true
        saveState = .saving
        defer { isDurableInsertionInFlight = false }

        do {
            guard await finishPendingControllerWorkForSnapshot(),
                  captureLatestControllerDocumentIfNeeded(),
                  let canvasController else {
                    throw CanvasDurableInsertionError.unavailable
            }
            let generationBeforeInsertion = generation
            let controllerReceipt: PaperCanvasInsertionReceipt
            do {
                controllerReceipt = try await canvasController
                    .performInsertionWithReceipt(insertion, on: pageID)
            } catch let error as PaperCanvasInsertionCommitError {
                throw CanvasDurableInsertionError.controller(error)
            } catch {
                // The command surface promises a typed commit result. Treat a
                // legacy/unexpected controller error as a host-validation
                // failure rather than leaking an unclassified error past the
                // UI's durable import contract.
                throw CanvasDurableInsertionError.controller(
                    .hostValidationFailed(error.localizedDescription)
                )
            }

            guard captureLatestControllerDocumentIfNeeded(),
                  let capturedPage = pages.first(where: { $0.id == pageID }),
                  Self.hasEquivalentAuthoredContent(
                    capturedPage,
                    controllerReceipt.page
                ) else {
                    throw CanvasDurableInsertionError.captureFailed
                }
            let insertionContentRevision = pageContentRevisions[pageID] ?? 0
            guard generation > generationBeforeInsertion else {
                throw CanvasDurableInsertionError.generationDidNotAdvance
            }
            let insertionGeneration = generation
            var verifiedGeneration: Int64?
            while verifiedGeneration == nil {
                verifiedGeneration = await checkpointLatest()
                guard verifiedGeneration == nil else { break }
                if case .retrying = saveState {
                    do {
                        try await Task.sleep(for: checkpointRetryDelay)
                    } catch {
                        throw CanvasDurableInsertionError.checkpointFailed(
                            "The insertion remains pending while its checkpoint retries."
                        )
                    }
                    continue
                }
                if case let .failed(description) = saveState {
                    throw CanvasDurableInsertionError.checkpointFailed(description)
                }
                throw CanvasDurableInsertionError.checkpointFailed(
                    "Canvas Core did not return a verified checkpoint."
                )
            }
            guard let verifiedGeneration else {
                throw CanvasDurableInsertionError.checkpointFailed(
                    "Canvas Core did not return a verified checkpoint."
                )
            }
            // The live capture was compared with the controller receipt before
            // saving. A verified generation at or after that capture makes the
            // accepted insertion durable without retaining a decoded notebook.
            guard verifiedGeneration >= insertionGeneration,
                  (lastVerifiedIndexContentRevisions[pageID] ?? 0) >= insertionContentRevision else {
                throw CanvasDurableInsertionError.verificationMismatch
            }
            return CanvasVerifiedInsertionReceipt(
                pageID: pageID,
                controllerAcceptanceSequence: controllerReceipt.acceptanceSequence,
                verifiedGeneration: verifiedGeneration
            )
        } catch let error as CanvasDurableInsertionError {
            if case .failed = saveState {
                // Retain the more specific Canvas Core failure.
            } else if case .retrying = saveState {
                // The accepted content remains in the live model and the
                // checkpoint retry timer remains armed after caller cancellation.
            } else {
                saveState = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func submitProgrammaticInsertion(_ insertion: CanvasInsertion) {
        guard allowsAuthoring,
              pages.contains(where: { $0.id == currentPageID }) else { return }
        let deferredInsertion = DeferredControllerInsertion(
            insertion: insertion,
            pageID: currentPageID
        )
        guard let canvasController else {
            // A valid detach can leave a brief nil-controller gap before
            // SwiftUI attaches the replacement. Preserve one-shot toolbar and
            // import commands only inside that bounded handoff; commands before
            // the first attachment or after terminal teardown remain no-ops.
            guard isAwaitingControllerReattachment else { return }
            enqueueDeferredControllerInsertion(deferredInsertion)
            return
        }
        guard canvasControllerIsSnapshotReady else {
            // A replacement controller can be visible while the retiring
            // controller finishes an accepted insertion. Preserve toolbar or
            // import command order without mutating that stale replacement.
            enqueueDeferredControllerInsertion(deferredInsertion)
            return
        }
        canvasController.performInsertion(insertion, on: currentPageID)
    }

    private func enqueueDeferredControllerInsertion(
        _ insertion: DeferredControllerInsertion
    ) {
        let imageBytes = Self.retainedImageByteCount(for: insertion.insertion)
        let imageCount = imageBytes == 0 ? 0 : 1
        let (retainedImageBytes, byteCountOverflowed) = deferredControllerImageBytes
            .addingReportingOverflow(imageBytes)
        guard deferredControllerInsertions.count
                < Self.maximumDeferredControllerInsertionCount,
            deferredControllerImageCount + imageCount
                <= Self.maximumDeferredControllerImageCount,
            byteCountOverflowed == false,
            retainedImageBytes <= Self.maximumDeferredControllerImageBytes else {
            saveState = .failed(
                "The canvas is still reconnecting, so the latest insertion was not accepted. Try again."
            )
            return
        }
        deferredControllerInsertions.append(insertion)
        deferredControllerImageCount += imageCount
        deferredControllerImageBytes = retainedImageBytes
    }

    private static func retainedImageByteCount(for insertion: CanvasInsertion) -> Int {
        let image: CGImage
        switch insertion {
        case let .image(value), let .positionedImage(value, _):
            image = value
        case .text, .shape, .table, .circle:
            return 0
        }
        let (byteCount, overflowed) = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        return overflowed ? .max : byteCount
    }

    private func drainDeferredControllerInsertionsIfPossible() {
        guard canvasControllerIsSnapshotReady,
              let canvasController,
              deferredControllerInsertions.isEmpty == false else { return }
        let insertions = deferredControllerInsertions
        deferredControllerInsertions.removeAll(keepingCapacity: true)
        deferredControllerImageCount = 0
        deferredControllerImageBytes = 0
        for deferred in insertions {
            guard pages.contains(where: { $0.id == deferred.pageID }) else {
                saveState = .failed(
                    "A queued insertion could not be restored because its page is no longer available."
                )
                continue
            }
            canvasController.performInsertion(
                deferred.insertion,
                on: deferred.pageID
            )
        }
    }

    private func toggleGeometryTool(_ tool: CanvasGeometryTool) {
        activeGeometryTool = activeGeometryTool == tool ? nil : tool
        overlay = .none
        canvasController?.setGeometryTool(activeGeometryTool)
    }

    public func setDrawWithFinger(_ enabled: Bool) {
        guard isReaderMode == false, isReaderModeTransitioning == false else { return }
        let mode: CanvasInputMode = enabled ? .pencilAndFinger : .pencilOnly
        guard inputMode != mode else { return }
        inputMode = mode
        canvasController?.applyInputMode(mode)
        persistPreferencesSoon()
    }

    /// Changes only the per-item presentation. The controller retains the
    /// focused authored page and its normalized anchor while it relays out the
    /// same snapshots, so this must never advance Canvas Core generation.
    public func setPageLayout(_ layout: CanvasPageLayoutPreferences) {
        let normalizedLayout = layout.singlePageOnly
        guard supportsPageStack, pageLayout != normalizedLayout else { return }
        pageLayout = normalizedLayout
        if isReaderMode == false, isReaderModeTransitioning == false {
            isApplyingPageLayout = true
            canvasController?.setPageLayout(normalizedLayout)
            isApplyingPageLayout = false
        }
        persistPreferencesSoon()
    }

    public func setZoomScale(_ requestedScale: CGFloat) {
        guard allowsAuthoring else { return }
        let scale = CanvasZoom.clampedScale(requestedScale)

        if let canvasController {
            let appliedScale = canvasController.setZoomScale(scale)
            updateZoomReadout(for: appliedScale)
        } else {
            updateZoomReadout(for: scale)
            guard abs(viewport.stackZoomScale - scale) > 0.0001 else { return }
            viewport = CanvasViewportState.stackViewport(
                zoomScale: scale,
                normalizedCenterX: CGFloat(viewport.normalizedCenterX),
                normalizedCenterY: CGFloat(viewport.normalizedCenterY)
            )
            updatePage(currentPageID, viewport: viewport)
            persistPreferencesSoon()
        }
    }

    public func beginZoomScrubbing() {
        guard allowsAuthoring else { return }
        canvasController?.beginZoomScrubbing()
    }

    public func endZoomScrubbing() {
        guard allowsAuthoring else { return }
        canvasController?.endZoomScrubbing()
    }

    public func zoomIn() {
        setZoomScale(CanvasZoom.increasedScale(from: viewport.stackZoomScale))
    }

    public func zoomOut() {
        setZoomScale(CanvasZoom.decreasedScale(from: viewport.stackZoomScale))
    }

    public func resetZoom() {
        setZoomScale(CanvasConstants.defaultZoomScale)
    }

    public func setCurrentPaperTemplate(_ template: CanvasPaperTemplate) {
        guard allowsAuthoring,
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty,
              let initialIndex = indexOfCurrentPage,
              pages[initialIndex].paperTemplate != template,
              captureLatestControllerDocumentIfNeeded(),
              let index = indexOfCurrentPage,
              pages[index].paperTemplate != template else { return }
        let page = pages[index]
        pages[index] = page.replacing(paperTemplate: template)
        currentPaperTemplate = template
        initialPages = pages
        canvasController?.setPaperTemplate(template, for: page.id)
        markDocumentChanged(changingPageIDs: [page.id])
    }

    public func setPaperTemplateForAllPages(_ template: CanvasPaperTemplate) {
        guard allowsAuthoring,
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty,
              captureLatestControllerDocumentIfNeeded() else { return }

        let targetPageIDs = Set(
            Self.paperTemplateTargetPageIDs(in: pages, template: template)
        )
        let pageIndices = pages.indices.filter { targetPageIDs.contains(pages[$0].id) }
        guard pageIndices.isEmpty == false else { return }

        let pageIDs = pageIndices.map { pages[$0].id }
        for index in pageIndices {
            pages[index] = pages[index].replacing(paperTemplate: template)
        }
        initialPages = pages

        if let currentIndex = indexOfCurrentPage {
            currentPaperTemplate = pages[currentIndex].paperTemplate
            updateLegacyInitialPage(to: pages[currentIndex])
        }

        canvasController?.setPaperTemplate(template, forPageIDs: pageIDs)
        markDocumentChanged(changingPageIDs: pageIDs)
    }

    static func paperTemplateTargetPageIDs(
        in pages: [CanvasPageSnapshot],
        template: CanvasPaperTemplate
    ) -> [UUID] {
        pages.compactMap { page in
            guard page.background.isImported == false,
                  page.paperTemplate != template else { return nil }
            return page.id
        }
    }

    private func declineIfPageLimitReached(addingImagePage: Bool = false) -> Bool {
        if pages.count >= Self.maximumPageCount {
            actionNotice = "This notebook has reached its limit of \(Self.maximumPageCount) pages."
            return true
        }
        if addingImagePage {
            let imagePages = pages.filter {
                if case .image = $0.background { return true }
                return false
            }.count
            if imagePages >= Self.maximumImagePageCount {
                actionNotice = "This notebook has reached its limit of \(Self.maximumImagePageCount) photo pages."
                return true
            }
        }
        return false
    }

    public func addPage(at position: CanvasPageInsertionPosition) {
        guard supportsPageStack,
              isReaderMode == false,
              isReaderModeTransitioning == false,
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty else { return }
        addPage(at: position, boundarySource: nil, animated: false)
    }

    /// Adds a user-selected photo as its own annotatable page. The original
    /// transferred bytes become an immutable background; PaperKit receives a
    /// new empty markup layer with matching authored geometry.
    @discardableResult
    public func addImagePageFromOverview(
        data: Data,
        suggestedName: String? = nil
    ) throws -> CanvasDocumentSnapshot? {
        guard supportsPageStack,
              allowsAuthoring,
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty,
              declineIfPageLimitReached(addingImagePage: true) == false,
              captureLatestControllerDocumentIfNeeded() else { return nil }
        let imageDocument = try CanvasDocumentImporter.makeImageSnapshot(
            data: data,
            suggestedName: suggestedName
        )
        guard let importedPage = imageDocument.pages.first else { return nil }

        let page = importedPage.replacing(viewport: viewport)
        let insertionIndex = pages.endIndex
        pages.append(page)
        cachedPageIndices = nil
        initialPages = pages
        setFocusedPage(page.id, documentDidChange: false)

        if let canvasController {
            pendingProgrammaticFocusPageID = page.id
            canvasController.insertPage(
                page,
                at: insertionIndex,
                scrollTo: true,
                animated: false
            )
        } else {
            updateLegacyInitialPage(to: page)
        }
        updatePagePositionState()
        markDocumentChanged(changingPageIDs: [page.id])
        return currentPageOverviewSnapshot()
    }

    private func addPage(
        at position: CanvasPageInsertionPosition,
        boundarySource: CanvasPageBoundary?,
        animated: Bool
    ) {
        guard allowsAuthoring,
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty,
              declineIfPageLimitReached() == false,
              captureLatestControllerDocumentIfNeeded(),
              let currentIndex = indexOfCurrentPage else { return }

        let insertionIndex: Int
        switch position {
        case .start:
            insertionIndex = 0
        case .afterCurrent:
            insertionIndex = currentIndex + 1
        case .end:
            insertionIndex = pages.endIndex
        }

        let inheritedPaperTemplate: CanvasPaperTemplate
        switch boundarySource {
        case .start:
            inheritedPaperTemplate = pages.first?.paperTemplate ?? currentPaperTemplate
        case .end:
            inheritedPaperTemplate = pages.last?.paperTemplate ?? currentPaperTemplate
        case nil:
            inheritedPaperTemplate = currentPaperTemplate
        }

        // A new page matches the page it is added beside (an imported Letter
        // or landscape page keeps its size) instead of snapping back to A4.
        let newPageSize = documentKind == .canvas
            ? nil
            : pages[currentIndex].displaySize
        let page = CanvasPageSnapshot(
            markup: newPageSize.map {
                PaperMarkup(bounds: CGRect(origin: .zero, size: $0))
            } ?? Self.blankMarkup(for: documentKind),
            viewport: viewport,
            paperTemplate: inheritedPaperTemplate
        )
        pages.insert(page, at: insertionIndex)
        cachedPageIndices = nil
        initialPages = pages
        setFocusedPage(page.id, documentDidChange: false)

        if let canvasController {
            pendingProgrammaticFocusPageID = page.id
            canvasController.insertPage(
                page,
                at: insertionIndex,
                scrollTo: true,
                animated: animated
            )
        } else {
            updateLegacyInitialPage(to: page)
        }
        markDocumentChanged(changingPageIDs: [page.id])
    }

    public func goToPreviousPage() {
        guard supportsPageStack, isReaderModeTransitioning == false else { return }
        if isReaderMode {
            guard let currentIndex = indexOfCurrentPage,
                  currentIndex > pages.startIndex else { return }
            revealPage(at: currentIndex - 1)
            return
        }
        guard captureLatestControllerDocumentIfNeeded(),
              let currentIndex = indexOfCurrentPage,
              currentIndex > pages.startIndex else { return }
        revealPage(at: currentIndex - 1)
    }

    public func goToNextPage() {
        guard supportsPageStack, isReaderModeTransitioning == false else { return }
        if isReaderMode {
            guard let currentIndex = indexOfCurrentPage,
                  currentIndex + 1 < pages.endIndex else { return }
            revealPage(at: currentIndex + 1)
            return
        }
        guard captureLatestControllerDocumentIfNeeded(),
              let currentIndex = indexOfCurrentPage,
              currentIndex + 1 < pages.endIndex else { return }
        revealPage(at: currentIndex + 1)
    }

    /// Jumps directly to a one-based page number. The page overview remains the
    /// visual navigation surface; this compact path is intended for long notes
    /// where a known page number is faster than scanning thumbnails.
    @discardableResult
    public func goToPage(number: Int) -> Bool {
        guard supportsPageStack,
              launchState == .ready,
              isReaderModeTransitioning == false,
              number > 0,
              number <= pages.count else { return false }
        if number == currentPageNumber { return true }
        guard isReaderMode || captureLatestControllerDocumentIfNeeded() else { return false }
        let index = number - 1
        revealPage(at: index)
        return true
    }

    /// Direct navigation from the immutable All Pages snapshot. Presenting the
    /// sheet already captured every live host, so tapping avoids a second full
    /// PaperKit snapshot.
    public func goToPageFromOverview(id: UUID) {
        guard supportsPageStack,
              launchState == .ready,
              isReaderModeTransitioning == false,
              let index = pages.firstIndex(where: { $0.id == id }) else { return }
        revealPage(at: index)
    }

    /// Duplicates the latest live value of a page immediately after its source.
    /// The copy receives a fresh stable identity and becomes the current page so
    /// the overview can make the result visible without dismissing itself.
    @discardableResult
    public func duplicatePageFromOverview(id: UUID) -> CanvasDocumentSnapshot? {
        guard supportsPageStack,
              allowsAuthoring,
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty,
              declineIfPageLimitReached() == false,
              captureLatestControllerDocumentIfNeeded(),
              let sourceIndex = pages.firstIndex(where: { $0.id == id }) else { return nil }

        let source = pages[sourceIndex]
        let duplicate = CanvasPageSnapshot(
            markup: source.markup,
            tables: source.tables.map { table in
                CanvasTable(
                    origin: table.origin,
                    rowCount: table.rowCount,
                    columnCount: table.columnCount,
                    cellSize: table.cellSize,
                    cornerRadius: table.cornerRadius
                )
            },
            viewport: source.viewport,
            paperTemplate: source.paperTemplate,
            geometry: source.geometry,
            background: source.background
        )
        let insertionIndex = sourceIndex + 1
        pages.insert(duplicate, at: insertionIndex)
        cachedPageIndices = nil
        initialPages = pages
        setFocusedPage(duplicate.id, documentDidChange: false)

        if let canvasController {
            pendingProgrammaticFocusPageID = duplicate.id
            canvasController.insertPage(
                duplicate,
                at: insertionIndex,
                scrollTo: true,
                animated: false
            )
        } else {
            updateLegacyInitialPage(to: duplicate)
        }
        updatePagePositionState()
        markDocumentChanged(changingPageIDs: [duplicate.id])
        return currentPageOverviewSnapshot()
    }

    /// Rotates an unannotated page without rewriting the immutable source.
    /// PaperKit's public content transform changes node frames but not their
    /// orientation state, which can reflow text and distort editable nodes.
    /// Once a page has annotations, the overview deliberately disables this
    /// operation instead of risking content loss.
    @discardableResult
    public func rotatePageFromOverview(
        id: UUID,
        direction: CanvasPageRotationDirection
    ) -> CanvasDocumentSnapshot? {
        guard supportsPageStack,
            allowsAuthoring,
            isDurableInsertionInFlight == false,
            pageTrashMutationsInFlight.isEmpty,
            captureLatestControllerDocumentIfNeeded(),
            let index = pages.firstIndex(where: { $0.id == id }) else { return nil }

        let source = pages[index]
        let oldSize = source.markup.bounds.size
        guard source.supportsLosslessQuarterTurn,
            oldSize.width > 0,
            oldSize.height > 0 else { return nil }

        let clockwise = direction == .right
        let geometry = source.geometry.rotated(clockwise: clockwise)
        let markup = PaperMarkup(bounds: CGRect(origin: .zero, size: geometry.displaySize))

        let rotated = source.replacing(
            markup: markup,
            viewport: source.viewport.rotated(clockwise: clockwise),
            geometry: geometry
        )
        pages[index] = rotated
        initialPages = pages
        if source.id == currentPageID {
            viewport = rotated.viewport
            updateZoomReadout(for: rotated.viewport.stackZoomScale)
            updateLegacyInitialPage(to: rotated)
            persistPreferencesSoon()
        }
        canvasController?.replacePage(rotated)
        updatePagePositionState()
        markDocumentChanged(changingPageIDs: [id])
        return currentPageOverviewSnapshot()
    }

    /// Moves one stable page identity to a final zero-based index. The live
    /// PaperKit controller validates and applies the complete ID order first,
    /// making the model/controller mutation atomic from the overview's point
    /// of view. Page hosts, imported backgrounds, and the focused page are not
    /// recreated or replaced.
    @discardableResult
    public func movePageFromOverview(
        id: UUID,
        to destinationIndex: Int
    ) -> CanvasDocumentSnapshot? {
        guard supportsPageStack,
            allowsAuthoring,
            isDurableInsertionInFlight == false,
            pageTrashMutationsInFlight.isEmpty,
            captureLatestControllerDocumentIfNeeded(),
            let sourceIndex = pages.firstIndex(where: { $0.id == id }),
            pages.indices.contains(destinationIndex) else { return nil }

        guard sourceIndex != destinationIndex else {
            return currentPageOverviewSnapshot()
        }

        var reorderedPages = pages
        let movedPage = reorderedPages.remove(at: sourceIndex)
        reorderedPages.insert(movedPage, at: destinationIndex)
        let orderedPageIDs = reorderedPages.map(\.id)

        if let canvasController {
            isApplyingPageOverviewMutation = true
            let didReorder = canvasController.reorderPages(
                orderedPageIDs,
                focusOn: currentPageID
            )
            isApplyingPageOverviewMutation = false
            guard didReorder else { return nil }
        }

        pages = reorderedPages
        cachedPageIndices = nil
        initialPages = pages
        if let currentIndex = indexOfCurrentPage {
            updateLegacyInitialPage(to: pages[currentIndex])
        }
        updatePagePositionState()
        markDocumentChanged(changingPageIDs: [])
        return currentPageOverviewSnapshot()
    }

    /// Removes a page while keeping at least one page in the document. Deleting
    /// the current page chooses its successor, or its predecessor at the end.
    @discardableResult
    public func deletePageFromOverview(id: UUID) -> CanvasDocumentSnapshot? {
        guard supportsPageStack,
            allowsAuthoring,
            isDurableInsertionInFlight == false,
            (pageTrashMutationsInFlight.isEmpty
                || authorizedPageTrashRemovalID == id),
            pages.count > 1,
            captureLatestControllerDocumentIfNeeded(),
            let removalIndex = pages.firstIndex(where: { $0.id == id }),
            pages.count > 1 else { return nil }

        let wasCurrentPage = currentPageID == id
        let replacementIndex = removalIndex == pages.index(before: pages.endIndex)
            ? pages.index(before: removalIndex)
            : pages.index(after: removalIndex)
        let replacementID = wasCurrentPage ? pages[replacementIndex].id : currentPageID

        if let canvasController {
            if wasCurrentPage { pendingProgrammaticFocusPageID = replacementID }
            isApplyingPageOverviewMutation = true
            let didRemovePage = canvasController.removePage(id: id, focusOn: replacementID)
            isApplyingPageOverviewMutation = false
            guard didRemovePage else {
                if wasCurrentPage { pendingProgrammaticFocusPageID = nil }
                return nil
            }
        }

        pages.remove(at: removalIndex)
        pageContentRevisions[id] = nil
        cachedPageIndices = nil
        initialPages = pages
        if currentPageID == id {
            setFocusedPage(replacementID, documentDidChange: false)
        } else {
            updatePagePositionState()
        }
        if let index = indexOfCurrentPage {
            updateLegacyInitialPage(to: pages[index])
        }
        pendingProgrammaticFocusPageID = nil
        markDocumentChanged(changingPageIDs: [])
        return currentPageOverviewSnapshot()
    }

    /// Permanently removes a page after its updated document has been verified
    /// on disk. If saving fails, restore the page and verify that recovery too.
    public func deletePagePermanentlyFromOverview(
        id: UUID
    ) async throws -> CanvasDocumentSnapshot {
        guard supportsPageStack else { throw CanvasPageDeletionError.solePage }
        guard launchState == .ready else { throw CanvasPageDeletionError.pageNotFound }
        guard allowsAuthoring else { throw CanvasPageDeletionError.operationInProgress }
        guard pages.count > 1 else { throw CanvasPageDeletionError.solePage }
        guard isDurableInsertionInFlight == false,
            pageTrashMutationsInFlight.isEmpty else {
            throw CanvasPageDeletionError.operationInProgress
        }
        guard pageTrashMutationsInFlight.insert(id).inserted else {
            throw CanvasPageDeletionError.operationInProgress
        }
        defer { pageTrashMutationsInFlight.remove(id) }
        guard captureLatestControllerDocumentIfNeeded(),
            let index = pages.firstIndex(where: { $0.id == id }) else {
            throw CanvasPageDeletionError.pageNotFound
        }

        let deletedPage = pages[index]
        let previouslyFocusedPageID = currentPageID
        guard pages.indices.contains(index), pages[index] == deletedPage else {
            throw CanvasPageDeletionError.removalRejected
        }
        authorizedPageTrashRemovalID = id
        let didRemovePage = deletePageFromOverview(id: id) != nil
        authorizedPageTrashRemovalID = nil
        guard didRemovePage else {
            throw CanvasPageDeletionError.removalRejected
        }
        let deletionGeneration = generation
        await checkpointLatest()
        await waitForCheckpoints(atOrAfter: deletionGeneration)
        if hasVerifiedCheckpoint(atOrAfter: deletionGeneration) {
            // Publish the page-free document once more so both recovery slots
            // no longer contain a pre-deletion copy of the page.
            markDocumentChanged(changingPageIDs: [])
            let recoveryGeneration = generation
            await checkpointLatest()
            await waitForCheckpoints(atOrAfter: recoveryGeneration)
            if hasVerifiedCheckpoint(atOrAfter: recoveryGeneration) {
                return currentPageOverviewSnapshot()
            }
        }

        let deletionFailureReason: String
        if case let .failed(message) = saveState {
            deletionFailureReason = message
        } else {
            deletionFailureReason = "The verified checkpoint did not advance."
        }
        restorePageAfterFailedDeletion(
            deletedPage,
            at: index,
            previouslyFocusedPageID: previouslyFocusedPageID
        )
        let restorationGeneration = generation
        await checkpointLatest()
        await waitForCheckpoints(atOrAfter: restorationGeneration)

        guard hasVerifiedCheckpoint(atOrAfter: restorationGeneration) else {
            let restorationFailureReason: String
            if case let .failed(message) = saveState {
                restorationFailureReason = message
            } else {
                restorationFailureReason = "The restored page could not be verified on disk."
            }
            throw CanvasPageDeletionError.checkpointFailed(restorationFailureReason)
        }
        throw CanvasPageDeletionError.checkpointFailed(deletionFailureReason)
    }

    private func restorePageAfterFailedDeletion(
        _ page: CanvasPageSnapshot,
        at requestedIndex: Int,
        previouslyFocusedPageID: UUID
    ) {
        guard pages.contains(where: { $0.id == page.id }) == false else { return }
        let insertionIndex = min(max(requestedIndex, 0), pages.endIndex)
        pages.insert(page, at: insertionIndex)
        cachedPageIndices = nil
        initialPages = pages
        isApplyingPageOverviewMutation = true
        canvasController?.insertPage(
            page,
            at: insertionIndex,
            scrollTo: previouslyFocusedPageID == page.id,
            animated: false
        )
        isApplyingPageOverviewMutation = false
        if pages.contains(where: { $0.id == previouslyFocusedPageID }) {
            setFocusedPage(previouslyFocusedPageID, documentDidChange: false)
        }
        updatePagePositionState()
        if let currentIndex = indexOfCurrentPage {
            updateLegacyInitialPage(to: pages[currentIndex])
        }
        pendingProgrammaticFocusPageID = nil
        markDocumentChanged(changingPageIDs: [page.id])
    }

    /// Captures every live PaperKit host before presenting page previews so
    /// thumbnails include the newest uncheckpointed stroke and paper choice.
    public func preparePageOverviewSnapshot() -> CanvasDocumentSnapshot? {
        guard supportsPageStack,
            launchState == .ready,
            isReaderModeTransitioning == false else { return nil }
        if isReaderMode { return currentPageOverviewSnapshot() }
        guard captureLatestControllerDocumentIfNeeded() else { return nil }
        return currentPageOverviewSnapshot()
    }

    /// Waits for any accepted app insertion to publish before freezing the
    /// All Pages document. The synchronous overload remains fail-closed for
    /// model mutations that cannot suspend.
    public func preparePageOverviewSnapshotWhenReady() async -> CanvasDocumentSnapshot? {
        guard supportsPageStack,
            launchState == .ready,
            isReaderModeTransitioning == false else { return nil }
        if isReaderMode { return currentPageOverviewSnapshot() }
        guard await finishPendingControllerWorkForSnapshot(),
            captureLatestControllerDocumentIfNeeded() else { return nil }
        return currentPageOverviewSnapshot()
    }

    /// Captures every live PaperKit host before presenting export choices so
    /// the immutable export document includes the newest stroke and template.
    public func prepareExportDocument() -> CanvasExportDocument? {
        guard launchState == .ready,
            isReaderModeTransitioning == false else { return nil }
        if isReaderMode { return CanvasExportDocument(pages: readerPages) }
        guard canvasController?.hasActiveSnapshotContact != true,
            captureLatestControllerDocumentIfNeeded() else { return nil }
        return CanvasExportDocument(pages: pages)
    }

    /// Establishes an insertion boundary before export so a toolbar, import,
    /// or drop insertion accepted just before the tap cannot be
    /// silently omitted from the immutable export document.
    public func prepareExportDocumentWhenReady() async -> CanvasExportDocument? {
        guard launchState == .ready,
            isReaderModeTransitioning == false else { return nil }
        if isReaderMode { return CanvasExportDocument(pages: readerPages) }
        guard canvasController?.hasActiveSnapshotContact != true,
            await finishPendingControllerWorkForSnapshot(),
            captureLatestControllerDocumentIfNeeded() else { return nil }
        return CanvasExportDocument(pages: pages)
    }

    public func retrySave() async {
        await checkpointLatest()
        await savePreferencesNow()
    }

    /// Re-enters a save boundary when the app becomes active. Timers can be
    /// suspended while backgrounded, so the scene transition is an explicit
    /// wake-up in addition to the live controller's contact-ended signal.
    public func retryPendingLifecycleCheckpoint() async {
        guard requiresDeferredCheckpointRetry || generation > committedGeneration else {
            return
        }
        await checkpointLatest()
    }

    public func flushForLifecycle() async {
        cancelSaveTimers()
        preferencesSaveTask?.cancel()
        preferencesSaveTask = nil

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CanvasCoreV2 flush")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        await checkpointLatest()
        var existingFailure: String?
        if case let .failed(description) = saveState {
            existingFailure = description
        }

        let terminalHandoffFailure = closeDeferredControllerHandoffIfNeeded()
        if terminalHandoffFailure != nil {
            // The first checkpoint deliberately failed closed while commands
            // were waiting for a replacement. Once terminal teardown rejects
            // those commands explicitly, persist any settled retiring-controller
            // insertion without pretending the rejected commands were saved.
            await checkpointLatest()
            // A successful second checkpoint supersedes the first failure.
            if case let .failed(description) = saveState {
                existingFailure = description
            } else {
                existingFailure = nil
            }
        }
        await savePreferencesNow()

        if case .failed = saveState {
            // A checkpoint failure is more actionable than a handoff rejection.
        } else if let existingFailure {
            saveState = .failed(existingFailure)
        } else if let terminalHandoffFailure {
            saveState = .failed(terminalHandoffFailure)
        }
    }

    /// A lifecycle flush with no replacement controller is the explicit
    /// terminal boundary for the handoff queue. Reject queued UI commands
    /// visibly and release any retained decoded images before final storage.
    private func closeDeferredControllerHandoffIfNeeded() -> String? {
        guard canvasController == nil else { return nil }
            isAwaitingControllerReattachment = false
        guard deferredControllerInsertions.isEmpty == false else { return nil }
        let rejectedCount = deferredControllerInsertions.count
        deferredControllerInsertions.removeAll(keepingCapacity: false)
        deferredControllerImageCount = 0
        deferredControllerImageBytes = 0
        let noun = rejectedCount == 1 ? "insertion" : "insertions"
        return "The canvas closed before \(rejectedCount) queued \(noun) could be accepted. Try again after reopening the note."
    }

    private func loadCanvas() async {
        guard let checkpointStore, let preferencesStore else {
            launchState = .failed(
                constructionFailure ?? "The Canvas Core storage location is unavailable."
            )
            return
        }

        let attemptID = UUID()
        activeLoadAttemptID = attemptID
        defer {
            if activeLoadAttemptID == attemptID {
                activeLoadAttemptID = nil
            }
        }

        async let documentResult = checkpointStore.load()
        async let storedPreferences = preferencesStore.load()
        let (document, preferences) = await (documentResult, storedPreferences)

        // SwiftUI cancels view-scoped tasks when an editor is dismissed or
        // replaced. Cancellation says nothing about checkpoint integrity, so
        // keep it out of the recovery screen and let a later appearance start
        // a fresh read.
        guard activeLoadAttemptID == attemptID else { return }
        if Task.isCancelled || document == .cancelled {
            hasStarted = false
            launchState = .loading
            return
        }

        // The preferences projection enforces Pen as the active launch tool
        // while retaining the remembered Pen and Brush family members.
        toolState = preferences.launchToolState
        inputMode = preferences.inputMode
        pageLayout = documentMode == .paged
            ? preferences.pageLayout.singlePageOnly
            : .default
        readerPreferences = preferences.readerPreferences
        isReaderMode = false
        isReaderModeTransitioning = false
        viewport = preferences.viewport
        updateZoomReadout(for: viewport.stackZoomScale)
        overlay = .none
        canUndo = false
        canRedo = false
        saveState = .saved

        switch document {
        case .newDocument:
            let initialViewport = Self.topAlignedViewport(
                Self.initialViewport(for: documentKind)
            )
            let page = CanvasPageSnapshot(
                markup: Self.blankMarkup(for: documentKind),
                viewport: initialViewport,
                paperTemplate: NotatePreferences.defaultPaperTemplate
            )
            pages = [page]
            cachedPageIndices = nil
            currentPageID = page.id
            initialPages = pages
            initialPageID = page.id
            initialMarkup = page.markup
            viewport = Self.topAlignedViewport(
                documentMode == .freeform ? initialViewport : preferences.viewport
            )
            updatePage(page.id, viewport: viewport)
            updatePagePositionState()
            generation = 0
            committedGeneration = 0
            pageContentRevisions = Dictionary(
                uniqueKeysWithValues: pages.map { ($0.id, 0) }
            )
            lastVerifiedIndexPageIDs = pages.map(\.id)
            lastVerifiedIndexContentRevisions = pageContentRevisions
            lastVerifiedIndexGeneration = 0
            latestVerifiedIndexDelta = nil
            verifiedCheckpointGeneration = 0
            latestVerifiedIndexPageCount = pages.count
            readerPages = []
            readerCurrentPageID = nil
            launchState = .ready

        case let .restored(snapshot):
            guard snapshot.pages.isEmpty == false,
                let restoredIndex = snapshot.pages.firstIndex(where: {
                    $0.id == snapshot.currentPageID
                }) else {
                    launchState = .failed("The saved document does not contain its current page.")
                    return
                }
            if documentMode == .freeform {
                let board = snapshot.pages[restoredIndex]
                pages = [board]
                cachedPageIndices = nil
                currentPageID = board.id
                let restoredViewport = board.viewport.usesFitPage
                    ? Self.initialViewport(for: documentKind)
                    : board.viewport
                viewport = Self.topAlignedViewport(restoredViewport)
            } else {
                pages = snapshot.pages
                currentPageID = preferences.currentPageID.flatMap { savedID in
                    snapshot.pages.first(where: { $0.id == savedID })?.id
                } ?? snapshot.currentPageID
                viewport = Self.topAlignedViewport(preferences.viewport)
            }
            cachedPageIndices = nil
            updateZoomReadout(for: viewport.stackZoomScale)
            updatePage(currentPageID, viewport: viewport)
            initialPages = pages
            initialPageID = currentPageID
            initialMarkup = pages[indexOfCurrentPage ?? pages.startIndex].markup
            updatePagePositionState()
            generation = snapshot.generation
            committedGeneration = snapshot.generation
            pageContentRevisions = Dictionary(
                uniqueKeysWithValues: pages.map { ($0.id, 0) }
            )
            lastVerifiedIndexPageIDs = snapshot.pages.map(\.id)
            lastVerifiedIndexContentRevisions = Dictionary(
                uniqueKeysWithValues: snapshot.pages.map { ($0.id, 0) }
            )
            lastVerifiedIndexGeneration = snapshot.generation
            latestVerifiedIndexDelta = nil
            verifiedCheckpointGeneration = snapshot.generation
            latestVerifiedIndexPageCount = snapshot.pages.count
            readerPages = []
            readerCurrentPageID = nil
            launchState = .ready

        case let .failed(error):
            launchState = .failed(error.localizedDescription)

        case .cancelled:
            hasStarted = false
            launchState = .loading
        }
    }

    private func select(_ tool: CanvasTool) {
        guard toolState.activeTool != tool else { return }
        previousAccessoryTool = toolState.activeTool
        let previousPenTool = toolState.preferredPenTool
        let previousBrushTool = toolState.preferredBrushTool
        toolState.activeTool = tool
        canvasController?.applyToolState(toolState)
        if previousPenTool != toolState.preferredPenTool
            || previousBrushTool != toolState.preferredBrushTool {
            persistPreferencesSoon()
        }
    }

    private func toggleOptions(for tool: CanvasTool) {
        guard tool.supportsOptions else {
            overlay = .none
            return
        }
        overlay = overlay == .toolOptions(tool) ? .none : .toolOptions(tool)
    }

    private func applyToolIfActive(_ tool: CanvasTool) {
        guard toolState.activeTool == tool else { return }
        canvasController?.applyToolState(toolState)
    }

    private func drawingInteractionDidBegin(on pageID: UUID) {
        guard isReaderMode == false, isReaderModeTransitioning == false else { return }
        isInkContactActive = true
        // PaperKit calls this after it has accepted Pencil-down. Dismissing the
        // overlay here cannot steal or shorten the first stroke.
        overlay = .none
        // Starting to write cancels any remembered pull-to-add-page release
        // and hides the Add Page button.
        pendingBoundaryInsertion = nil
        hideAddPageAffordance()
        pendingProgrammaticFocusPageID = nil
        setFocusedPage(pageID, documentDidChange: false)
    }

    private func presentationInteractionDidBegin() {
        guard isReaderMode == false, isReaderModeTransitioning == false else { return }
        overlay = .none
    }

    private var indexOfCurrentPage: Int? {
        pageIndex(for: currentPageID)
    }

    private func pageIndex(for id: UUID) -> Int? {
        if cachedPageIndices == nil {
            cachedPageIndices = Dictionary(
                uniqueKeysWithValues: pages.enumerated().map { ($0.element.id, $0.offset) }
            )
        }
        return cachedPageIndices?[id]
    }

    private func revealPage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        setFocusedPage(page.id, documentDidChange: false)
        if isReaderMode {
            readerCurrentPageID = page.id
            return
        }

        if let canvasController {
            pendingProgrammaticFocusPageID = page.id
            canvasController.scrollToPage(id: page.id, animated: true)
        } else {
            updateLegacyInitialPage(to: page)
        }
    }

    private func setFocusedPage(_ pageID: UUID, documentDidChange: Bool) {
        guard let index = pageIndex(for: pageID),
            currentPageID != pageID else { return }
        currentPageID = pageID
        updateLegacyInitialPage(to: pages[index])
        overlay = .none
        canUndo = false
        canRedo = false
        updatePagePositionState()
        if documentDidChange {
            markDocumentChanged(changingPageIDs: [])
        } else if documentMode == .paged {
            persistPreferencesSoon()
        }
    }

    private func updateLegacyInitialPage(to page: CanvasPageSnapshot) {
        initialPageID = page.id
        initialMarkup = page.markup
    }

    private func updatePage(_ id: UUID, viewport: CanvasViewportState) {
        guard let index = pageIndex(for: id) else { return }
        let page = pages[index]
        pages[index] = page.replacing(viewport: viewport)
        if id == currentPageID {
            currentPaperTemplate = pages[index].paperTemplate
            updateLegacyInitialPage(to: pages[index])
        }
    }

    private func updatePagePositionState() {
        cachedPageIndices = nil
        pageCount = max(pages.count, 1)
        currentPageNumber = indexOfCurrentPage.map { $0 + 1 } ?? 1
        currentPaperTemplate = indexOfCurrentPage.map { pages[$0].paperTemplate } ?? .default
    }

    private func currentPageOverviewSnapshot() -> CanvasDocumentSnapshot {
        CanvasDocumentSnapshot(
            pages: pages,
            currentPageID: currentPageID,
            viewport: viewport
        )
    }

    private func markDocumentChanged(changingPageIDs: [UUID]? = nil) {
        generation += 1
        for pageID in changingPageIDs ?? pages.map(\.id) {
            pageContentRevisions[pageID, default: 0] &+= 1
        }
        if saveState != .saving { saveState = .saving }
        if isInkContactActive {
            hasDeferredInkCheckpoint = true
            return
        }
        scheduleTrailingSave()
        ensureForcedSave()
    }

    private func snapshotContactDidEnd() {
        isInkContactActive = false
        applyPendingBoundaryInsertion()
        if hasDeferredInkCheckpoint {
            hasDeferredInkCheckpoint = false
            scheduleTrailingSave(after: .zero)
            ensureForcedSave()
            return
        }
        guard requiresDeferredCheckpointRetry || generation > committedGeneration else {
            return
        }
        // Replace the ordinary debounce with a zero-delay actor turn. The
        // controller invokes this only after publishing its final markup, but
        // yielding once lets any PaperKit delegate work already enqueued on the
        // main actor settle before snapshot capture begins.
        scheduleTrailingSave(after: .zero)
        ensureForcedSave()
    }

    private func programmaticInsertionDidFail(
        _ error: PaperCanvasInsertionCommitError
    ) {
        // The insertion was rolled back, so nothing is unsaved. Tell the person
        // once instead of leaving a sticky "not safely stored" banner.
        actionNotice = error.localizedDescription
    }

    private static func blankMarkup(for kind: LibraryItemKind) -> PaperMarkup {
        let size = kind == .canvas
            ? CanvasConstants.freeformInitialSize
            : CanvasConstants.a4PortraitSize
        return PaperMarkup(bounds: CGRect(origin: .zero, size: size))
    }

    private static func initialViewport(for kind: LibraryItemKind) -> CanvasViewportState {
        guard kind == .canvas else { return CanvasViewportState() }
        return CanvasViewportState.stackViewport(
            zoomScale: CanvasConstants.defaultZoomScale,
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5
        )
    }

    /// Each editor session opens at the top while retaining its saved zoom
    /// and horizontal position. Scrolling during the session remains normal.
    private static func topAlignedViewport(
        _ viewport: CanvasViewportState
    ) -> CanvasViewportState {
        var viewport = viewport
        viewport.normalizedCenterY = 0
        return viewport
    }

    private func paperMarkupDidChange(_ markup: PaperMarkup, on pageID: UUID) {
        guard isReaderMode == false,
            isReaderModeTransitioning == false,
            let index = pageIndex(for: pageID) else { return }
        let page = pages[index]
        pages[index] = page.replacing(markup: markup)
        if pageID == currentPageID {
            updateLegacyInitialPage(to: pages[index])
        }
        markDocumentChanged(changingPageIDs: [pageID])
    }

    /// Full-page replacements are used by rotation history because geometry,
    /// immutable background orientation, and PaperKit markup must move as one
    /// undoable value rather than as three loosely coordinated mutations.
    private func paperPageDidReplace(_ replacement: CanvasPageSnapshot) {
        guard isReaderMode == false,
            isReaderModeTransitioning == false,
            let index = pages.firstIndex(where: { $0.id == replacement.id }),
            pages[index] != replacement else { return }
        pages[index] = replacement
        initialPages = pages
        if replacement.id == currentPageID {
            currentPaperTemplate = replacement.paperTemplate
            updateLegacyInitialPage(to: replacement)
        }
        updatePagePositionState()
        markDocumentChanged(changingPageIDs: [replacement.id])
    }

    private func paperTemplateDidChange(
        _ template: CanvasPaperTemplate,
        on pageID: UUID
    ) {
        guard isReaderMode == false,
            isReaderModeTransitioning == false,
            let index = pages.firstIndex(where: { $0.id == pageID }),
            pages[index].paperTemplate != template else { return }
        let page = pages[index]
        pages[index] = page.replacing(paperTemplate: template)
        initialPages = pages
        if pageID == currentPageID {
            currentPaperTemplate = template
            updateLegacyInitialPage(to: pages[index])
        }
        markDocumentChanged(changingPageIDs: [pageID])
    }

    private func paperTemplatesDidChange(
        _ templates: [UUID: CanvasPaperTemplate]
    ) {
        guard isReaderMode == false,
              isReaderModeTransitioning == false else { return }

        var changedPageIDs: Set<UUID> = []
        for (pageID, template) in templates {
            guard let index = pages.firstIndex(where: { $0.id == pageID }),
                  pages[index].paperTemplate != template else { continue }
            pages[index] = pages[index].replacing(paperTemplate: template)
            changedPageIDs.insert(pageID)
        }
        guard changedPageIDs.isEmpty == false else { return }

        initialPages = pages
        if let index = indexOfCurrentPage,
           changedPageIDs.contains(pages[index].id) {
            currentPaperTemplate = pages[index].paperTemplate
            updateLegacyInitialPage(to: pages[index])
        }
        markDocumentChanged(changingPageIDs: Array(changedPageIDs))
    }

    private func focusedPageDidChange(_ pageID: UUID) {
        guard isReaderMode == false,
            isReaderModeTransitioning == false,
            pageIndex(for: pageID) != nil else { return }
        if let pendingProgrammaticFocusPageID {
            guard pageID == pendingProgrammaticFocusPageID else { return }
            self.pendingProgrammaticFocusPageID = nil
        }
        setFocusedPage(pageID, documentDidChange: false)
    }

    private func viewportDidChange(_ newViewport: CanvasViewportState, on pageID: UUID) {
        guard isReaderMode == false,
              isReaderModeTransitioning == false,
              newViewport.isValid,
              pageIndex(for: pageID) != nil else { return }
        if let pendingProgrammaticFocusPageID {
            guard pageID == pendingProgrammaticFocusPageID else { return }
            self.pendingProgrammaticFocusPageID = nil
        }

        setFocusedPage(pageID, documentDidChange: false)
        let viewportChanged = viewport != newViewport
        viewport = newViewport
        updateZoomReadout(for: newViewport.stackZoomScale)
        updatePage(pageID, viewport: newViewport)
        if viewportChanged {
            if documentMode == .freeform {
                markFreeformViewportChanged()
            }
            persistPreferencesSoon()
            revealAddPageAffordanceIfAtEnd()
        }
    }

    private func revealAddPageAffordanceIfAtEnd() {
        guard supportsPageStack,
              isReaderMode == false,
              currentPageNumber == pageCount,
              Date().timeIntervalSince(lastAddPageAt) > 1.5 else { return }
        addPageAffordanceDeadline = Date().addingTimeInterval(3)
        if showsAddPageAffordance == false { showsAddPageAffordance = true }
        guard addPageAffordanceTask == nil else { return }
        addPageAffordanceTask = Task { @MainActor [weak self] in
            while let self, Date() < self.addPageAffordanceDeadline {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            self?.showsAddPageAffordance = false
            self?.addPageAffordanceTask = nil
        }
    }

    private func hideAddPageAffordance() {
        addPageAffordanceDeadline = .distantPast
        if showsAddPageAffordance { showsAddPageAffordance = false }
    }

    /// Tapping the Add Page button that appears at the end of the note.
    public func addPageAtEndFromAffordance() {
        hideAddPageAffordance()
        lastAddPageAt = Date()
        guard supportsPageStack,
              isReaderMode == false,
              isReaderModeTransitioning == false,
              isDurableInsertionInFlight == false,
              pageTrashMutationsInFlight.isEmpty else { return }
        addPage(at: .end, boundarySource: nil, animated: true)
    }

    /// A freeform viewport is part of the board snapshot because it defines
    /// the region shown by the library preview and restored on reopen. Gesture
    /// callbacks can arrive every frame, so one pending generation and one
    /// existing trailing task are reused until the next checkpoint captures
    /// the latest settled viewport.
    private func markFreeformViewportChanged() {
        if generation <= committedGeneration || inFlightGenerations.contains(generation) {
            generation += 1
        }
        saveState = .saving
        if trailingSaveTask == nil {
            scheduleTrailingSave()
        }
        ensureForcedSave()
    }

    private func zoomInteractionDidChange(_ isActive: Bool) {
        guard isReaderMode == false, isReaderModeTransitioning == false else { return }
        guard isZoomInteractionActive != isActive else { return }
        isZoomInteractionActive = isActive
    }

    private func boundaryPullDidChange(_ pull: CanvasBoundaryPagePull?) {
        guard isReaderMode == false, isReaderModeTransitioning == false else {
            boundaryPagePull = nil
            return
        }
        guard supportsPageStack else {
            boundaryPagePull = nil
            return
        }
        guard boundaryPagePull != pull else { return }
        boundaryPagePull = pull
    }

    private func boundaryPageInsertionWasRequested(at boundary: CanvasPageBoundary) {
        guard supportsPageStack,
              isReaderMode == false,
              isReaderModeTransitioning == false else { return }
        boundaryPagePull = nil
        pendingBoundaryInsertion = nil
        if canvasIsBusyForBoundaryInsertion {
            // The pull itself was deliberate (it passed every gate in the
            // controller); only the canvas is momentarily busy. Remember the
            // request once and apply it as soon as the canvas settles.
            pendingBoundaryInsertion = boundary
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.applyPendingBoundaryInsertion()
            }
            return
        }
        performBoundaryInsertion(at: boundary)
    }

    /// Transient reasons `addPage` would silently decline. Permanent refusals
    /// (read-only, page limit) are not retried.
    private var canvasIsBusyForBoundaryInsertion: Bool {
        guard allowsAuthoring else { return false }
        return isDurableInsertionInFlight
            || pageTrashMutationsInFlight.isEmpty == false
            || detachedControllerDrainTask != nil
            || canvasControllerIsSnapshotReady == false
            || canvasController?.hasActiveSnapshotContact == true
    }

    private func performBoundaryInsertion(at boundary: CanvasPageBoundary) {
        lastAddPageAt = Date()
        hideAddPageAffordance()
        let position: CanvasPageInsertionPosition = boundary == .start ? .start : .end
        addPage(at: position, boundarySource: boundary, animated: true)
    }

    /// Applies the remembered release exactly once, or discards it. It never
    /// creates a page unless the person is still on the first/last page the
    /// pull started from and nothing else has taken over the canvas.
    private func applyPendingBoundaryInsertion() {
        guard let boundary = pendingBoundaryInsertion else { return }
        pendingBoundaryInsertion = nil
        let isStillAtBoundary = boundary == .start
            ? currentPageNumber == 1
            : currentPageNumber == pageCount
        guard isReaderMode == false,
              isReaderModeTransitioning == false,
              isStillAtBoundary,
              canvasIsBusyForBoundaryInsertion == false else { return }
        performBoundaryInsertion(at: boundary)
    }

    /// SwiftUI dismantling is synchronous, while PaperKit insertion history is
    /// not. Retain only the retiring controller until its already-accepted
    /// tail settles, then merge one authoritative snapshot into the model.
    /// Lifecycle flushes await this same task before creating a checkpoint.
    private func beginDetachedControllerDrain(
        _ controller: any PaperCanvasCommanding
    ) {
        let precedingDrain = detachedControllerDrainTask
        let presentationAtDetach = ControllerPresentationState(
            pageID: currentPageID,
            viewport: viewport
        )
        detachedControllerDrainSequence += 1
        let sequence = detachedControllerDrainSequence
        let task = Task { @MainActor [weak self, controller] in
            _ = await precedingDrain?.value
            let insertionTailSettled = await controller
                .finishPendingProgrammaticInsertions()
            defer { controller.completeDismantle() }
            guard let self else { return false }
            defer {
                if self.detachedControllerDrainSequence == sequence {
                    self.detachedControllerDrainTask = nil
                }
            }
            guard insertionTailSettled,
                  let snapshot = controller.snapshotDocument() else {
                self.releaseAttachedControllerSynchronizationBarrier()
                self.saveState = .failed(
                    "The live canvas closed before an accepted insertion could be captured."
                )
                return false
            }
            let currentPresentation = ControllerPresentationState(
                pageID: self.currentPageID,
                viewport: self.viewport
            )
            guard self.mergeControllerDocument(
                snapshot,
                preservingCurrentPresentation: currentPresentation != presentationAtDetach
            ) else {
                self.releaseAttachedControllerSynchronizationBarrier()
                return false
            }
            return self.synchronizeAttachedControllerWithModel()
        }
        detachedControllerDrainTask = task
    }

    @discardableResult
    private func synchronizeAttachedControllerWithModel() -> Bool {
        guard let controller = canvasController else {
            // The next representable may already have captured the pre-drain
            // value, so retain the reconciliation requirement across attach.
            requiresControllerReconciliation = true
            canvasControllerIsSnapshotReady = true
            return true
        }
        let synchronized = controller.synchronizeDocumentAfterAttachment(
            currentPageOverviewSnapshot()
        )
        controller.setDocumentSynchronizationPending(synchronized == false)
        canvasControllerIsSnapshotReady = synchronized
        requiresControllerReconciliation = synchronized == false
        if synchronized {
            drainDeferredControllerInsertionsIfPossible()
        }
        if synchronized == false {
            saveState = .failed(
                "The replacement canvas could not adopt the latest committed insertion."
            )
        }
        return synchronized
    }

    private func releaseAttachedControllerSynchronizationBarrier() {
        // The replacement still contains a pre-drain document. Keep it
        // noninteractive until a later stable snapshot retries reconciliation
        // or terminal teardown detaches it.
        canvasController?.setDocumentSynchronizationPending(true)
        canvasControllerIsSnapshotReady = false
        requiresControllerReconciliation = true
    }

    /// Establishes a stable controller boundary without forcing Pencil contact
    /// to end. A false result makes snapshot consumers fail closed and retry.
    private func finishPendingControllerWorkForSnapshot() async -> Bool {
        guard canvasController?.hasActiveSnapshotContact != true else { return false }
        if let detachedControllerDrainTask,
              await detachedControllerDrainTask.value == false {
            return false
        }
        guard canvasController?.hasActiveSnapshotContact != true else { return false }
        if requiresControllerReconciliation,
           canvasControllerIsSnapshotReady == false,
           canvasController != nil,
           synchronizeAttachedControllerWithModel() == false {
            return false
        }
        drainDeferredControllerInsertionsIfPossible()
        guard deferredControllerInsertions.isEmpty else { return false }
        guard let controller = canvasController else { return true }
        guard controller.hasActiveSnapshotContact == false else { return false }
        let identity = ObjectIdentifier(controller)
        guard await controller.finishPendingProgrammaticInsertions() else {
            return false
        }
        guard controller.hasActiveSnapshotContact == false else { return false }
        guard let currentController = canvasController else { return true }
        if ObjectIdentifier(currentController) != identity {
            return await finishPendingControllerWorkForSnapshot()
        }
        return currentController.hasActiveSnapshotContact == false
    }

    /// Reconciles only controller state that has not reached the model through
    /// its page-revision callbacks before creating an immutable save snapshot.
    /// Controller order is never trusted to replace the persisted page order.
    @discardableResult
    private func captureLatestControllerDocumentIfNeeded() -> Bool {
        // Reader owns an immutable session snapshot. The hidden live editor
        // intentionally remains on its entry page until exit, so consulting it
        // here would rewind Reader focus and manufacture a document mutation.
        if isReaderMode { return true }
        guard detachedControllerDrainTask == nil else { return false }
        guard deferredControllerInsertions.isEmpty else { return false }
        guard let canvasController else { return true }
        guard canvasControllerIsSnapshotReady else { return false }
        guard canvasController.hasActiveSnapshotContact == false else { return false }
        guard canvasController.hasPendingProgrammaticInsertions == false else {
            return false
        }
        // PaperKit publishes every accepted content mutation through its
        // delegate before the safe snapshot boundary. Once those page
        // revisions are delivered, the model already owns the authoritative
        // content; asking each mounted editor for a whole-document snapshot
        // after every stroke lift makes dense markup walk the main actor again.
        guard canvasController.hasPendingSnapshotReconciliation else { return true }

        if let snapshot = canvasController.snapshotDocument() {
            return mergeControllerDocument(snapshot)
        }

        // Transitional fallback for a single-page controller while all callers
        // migrate to the continuous-stack command surface.
        guard let snapshot = canvasController.snapshotActivePage(),
              let index = pages.firstIndex(where: { $0.id == snapshot.id }),
              snapshot.viewport.isValid else {
            saveState = .failed("The live canvas could not be captured safely.")
            return false
        }

        let storedPage = pages[index]
        let pageContentChanged = storedPage.markup != snapshot.markup
            || storedPage.tables != snapshot.tables
        pages[index] = storedPage.replacing(
            markup: snapshot.markup,
            tables: snapshot.tables,
            viewport: snapshot.viewport
        )
        initialPages = pages
        var viewportChanged = false
        if snapshot.id == currentPageID {
            viewportChanged = viewport != snapshot.viewport
            viewport = snapshot.viewport
            updateZoomReadout(for: snapshot.viewport.stackZoomScale)
            updateLegacyInitialPage(to: pages[index])
            if viewportChanged {
                persistPreferencesSoon()
            }
        }
        if pageContentChanged {
            markDocumentChanged(changingPageIDs: [snapshot.id])
        } else if viewportChanged, documentMode == .freeform {
            markFreeformViewportChanged()
        }
        return true
    }

    private func mergeControllerDocument(
        _ snapshot: CanvasDocumentSnapshot,
        preservingCurrentPresentation: Bool = false
    ) -> Bool {
        guard snapshot.viewport.isValid,
              pageIndex(for: snapshot.currentPageID) != nil,
              snapshot.pages.isEmpty == false else {
            saveState = .failed("The live canvas returned an invalid document snapshot.")
            return false
        }

        let snapshotIDs = snapshot.pages.map(\.id)
        guard Set(snapshotIDs).count == snapshotIDs.count,
              snapshotIDs.contains(snapshot.currentPageID),
              snapshotIDs.allSatisfy({ pageIndex(for: $0) != nil }),
              snapshot.pages.allSatisfy({ $0.viewport.isValid }) else {
            saveState = .failed("The live canvas returned inconsistent page identities.")
            return false
        }

        var changedPageIDs: [UUID] = []
        for livePage in snapshot.pages {
            guard let index = pageIndex(for: livePage.id) else {
                continue
            }
            let storedPage = pages[index]
            if storedPage.markup != livePage.markup
                || storedPage.tables != livePage.tables
                || storedPage.paperTemplate != livePage.paperTemplate
                || storedPage.geometry != livePage.geometry
                || storedPage.background != livePage.background {
                changedPageIDs.append(livePage.id)
                pages[index] = storedPage.replacing(
                    markup: livePage.markup,
                    tables: livePage.tables,
                    paperTemplate: livePage.paperTemplate,
                    geometry: livePage.geometry,
                    background: livePage.background
                )
            }
        }
        initialPages = pages

        var focusChanged = false
        var viewportChanged = false
        if preservingCurrentPresentation {
            // The retiring controller still owns its page's last viewport, but
            // a page/zoom choice made after detachment owns the live editor.
            // Update the retired page only when it is no longer current.
            if snapshot.currentPageID != currentPageID {
                updatePage(snapshot.currentPageID, viewport: snapshot.viewport)
            }
        } else {
            pendingProgrammaticFocusPageID = nil
            focusChanged = currentPageID != snapshot.currentPageID
            if focusChanged {
                setFocusedPage(snapshot.currentPageID, documentDidChange: false)
            }

            viewportChanged = viewport != snapshot.viewport
            viewport = snapshot.viewport
            updateZoomReadout(for: snapshot.viewport.stackZoomScale)
            updatePage(snapshot.currentPageID, viewport: snapshot.viewport)
            if viewportChanged {
                persistPreferencesSoon()
            }
        }

        if changedPageIDs.isEmpty == false || focusChanged {
            markDocumentChanged(changingPageIDs: changedPageIDs)
        } else if viewportChanged, documentMode == .freeform {
            markFreeformViewportChanged()
        }
        return true
    }

    private func updateZoomReadout(for scale: CGFloat) {
        let resolvedScale = CanvasZoom.clampedScale(scale)
        if currentZoomScale != resolvedScale {
            currentZoomScale = resolvedScale
        }

        let percent = CanvasZoom.percentage(for: resolvedScale)
        if currentZoomPercent != percent {
            currentZoomPercent = percent
        }
    }

    private func scheduleTrailingSave(after delay: Duration? = nil) {
        trailingSaveTask?.cancel()
        trailingSaveToken &+= 1
        let token = trailingSaveToken
        trailingSaveTask = Task { @MainActor [weak self, autosaveTiming] in
            do {
                try await Task.sleep(for: delay ?? autosaveTiming.trailingDelay)
            } catch {
                return
            }

            guard Task.isCancelled == false else { return }
            await self?.fireTrailingSave(token: token)
        }
    }
    private func ensureForcedSave() {
        guard forcedSaveTask == nil else { return }
        forcedSaveToken &+= 1
        let token = forcedSaveToken
        forcedSaveTask = Task { @MainActor [weak self, autosaveTiming] in
            do {
                try await Task.sleep(for: autosaveTiming.forcedDelay)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            await self?.fireForcedSave(token: token)
        }
    }

    private func fireTrailingSave(token: UInt64) async {
        guard token == trailingSaveToken else { return }
        trailingSaveTask = nil
        await checkpointLatest()
    }

    private func fireForcedSave(token: UInt64) async {
        guard token == forcedSaveToken else { return }
        forcedSaveTask = nil
        await checkpointLatest()
        // Transient failures own their bounded-backoff retry timer. Permanent
        // failures wait for an edit or an explicit retry so invalid content is
        // not repeatedly re-encoded.
        if case .failed = saveState { return }
        if case .retrying = saveState { return }
        if generation > committedGeneration {
            ensureForcedSave()
        }
    }

    @discardableResult
    private func checkpointLatest() async -> Int64? {
        guard isReaderModeTransitioning == false else {
            retainDeferredCheckpointRetry()
            return nil
        }
        if isReaderMode == false {
            guard await finishPendingControllerWorkForSnapshot() else {
                retainDeferredCheckpointRetry()
                return nil
            }
            guard captureLatestControllerDocumentIfNeeded() else {
                retainDeferredCheckpointRetry()
                return nil
            }
        }
        requiresDeferredCheckpointRetry = false
        guard let checkpointStore else { return nil }
        guard generation > committedGeneration else {
            saveState = .saved
            cancelSaveTimers()
            return committedGeneration
        }

        // One complete checkpoint owns the editor's serialization/verification
        // working set. A newer generation waits without capturing another
        // full notebook, then captures the latest state after publication.
        // This also coalesces timer, explicit-save and lifecycle requests.
        if let inFlightGeneration = inFlightGenerations.min() {
            await waitForCheckpointCompletion(of: inFlightGeneration)
            guard generation > committedGeneration else {
                return committedGeneration
            }
            if case .retrying = saveState {
                return nil
            }
            guard case .failed = saveState else {
                return await checkpointLatest()
            }
            return nil
        }
        let snapshotGeneration = generation
        let snapshotPageContentRevisions = pageContentRevisions
        let snapshot = CanvasCoreSnapshot(
            generation: snapshotGeneration,
            pages: pages,
            currentPageID: currentPageID
        )
        inFlightGenerations.insert(snapshotGeneration)
        saveState = .saving
        defer {
            finishCheckpointAttempt(for: snapshotGeneration)
        }

        do {
            let verifiedSnapshot = try await checkpointStore
                .checkpointAndReturnVerifiedSnapshot(snapshot)
            transientCheckpointFailureCount = 0
            isCheckpointRetryPending = false
            canvasController?.setCheckpointRetryPending(false)
            committedGeneration = max(committedGeneration, snapshotGeneration)
            publishVerifiedIndexDelta(
                for: verifiedSnapshot,
                pageContentRevisions: snapshotPageContentRevisions
            )
            verifiedCheckpointGeneration = max(
                verifiedCheckpointGeneration,
                snapshotGeneration
            )

            if committedGeneration >= generation {
                saveState = .saved
                cancelSaveTimers()
            } else {
                scheduleTrailingSave()
                ensureForcedSave()
            }
            latestVerifiedIndexPageCount = verifiedSnapshot.pages.count
            return verifiedSnapshot.generation
        } catch is CancellationError {
            if generation > committedGeneration {
                retainDeferredCheckpointRetry()
            }
        } catch let error as CanvasCoreStoreError where error.isSupersededCheckpoint {
            if generation > committedGeneration {
                scheduleTrailingSave()
                ensureForcedSave()
            }
        } catch let error as CanvasCoreStoreError where error.isTransientCheckpointFailure {
            transientCheckpointFailureCount += 1
            isCheckpointRetryPending = true
            canvasController?.setCheckpointRetryPending(true)
            saveState = .retrying(error.localizedDescription)
            forcedSaveTask?.cancel()
            forcedSaveTask = nil
            scheduleTrailingSave(after: checkpointRetryDelay)
        } catch {
            if snapshotGeneration >= generation {
                isCheckpointRetryPending = false
                canvasController?.setCheckpointRetryPending(false)
                saveState = .failed(error.localizedDescription)
            }
        }
        return nil
    }

    private func retainDeferredCheckpointRetry() {
        requiresDeferredCheckpointRetry = true
        if case .failed = saveState {
            // Preserve a more actionable storage/controller failure while the
            // retry remains armed in the background.
        } else {
            saveState = .saving
        }
        scheduleTrailingSave()
        ensureForcedSave()
    }

    private var checkpointRetryDelay: Duration {
        let exponent = min(max(transientCheckpointFailureCount - 1, 0), 5)
        let seconds = min(30, 1 << exponent)
        return .seconds(seconds)
    }

    /// Advances the index baseline only for a newly verified snapshot. The
    /// method is deliberately synchronous so actor reentrancy cannot separate
    /// delta publication, baseline replacement, and generation observation.
    private func publishVerifiedIndexDelta(
        for snapshot: CanvasCoreSnapshot,
        pageContentRevisions: [UUID: UInt64]
    ) {
        guard snapshot.generation > lastVerifiedIndexGeneration else { return }
        let currentIDs = snapshot.pages.map(\.id)
        let currentPageContentRevisions = Dictionary(
            uniqueKeysWithValues: currentIDs.map { pageID in
                (pageID, pageContentRevisions[pageID] ?? 0)
            }
        )
        latestVerifiedIndexDelta = CanvasPageRevisionDelta.make(
            baseGeneration: lastVerifiedIndexGeneration,
            generation: snapshot.generation,
            previousPageIDs: lastVerifiedIndexPageIDs,
            previousContentRevisions: lastVerifiedIndexContentRevisions,
            currentPageIDs: currentIDs,
            currentContentRevisions: currentPageContentRevisions
        )

        latestVerifiedIndexPageCount = currentIDs.count
        lastVerifiedIndexPageIDs = currentIDs
        lastVerifiedIndexContentRevisions = currentPageContentRevisions
        lastVerifiedIndexGeneration = snapshot.generation
    }

    private static func hasEquivalentAuthoredContent(
        _ lhs: CanvasPageSnapshot,
        _ rhs: CanvasPageSnapshot
    ) -> Bool {
        lhs.markup == rhs.markup
            && lhs.tables == rhs.tables
            && lhs.paperTemplate == rhs.paperTemplate
            && lhs.geometry == rhs.geometry
            && lhs.background == rhs.background
    }

    private func waitForCheckpointCompletion(of generation: Int64) async {
        guard inFlightGenerations.contains(generation) else { return }
        await withCheckedContinuation { continuation in
            checkpointCompletionWaiters[generation, default: []].append(continuation)
        }
    }

    /// Waits until no checkpoint captured at or after `generation` can still
    /// alter the durable deletion/restoration decision. Callers run on the
    /// main actor, so once the loop observes an empty set they can synchronously
    /// mutate page topology before another checkpoint begins.
    private func waitForCheckpoints(atOrAfter generation: Int64) async {
        while let inFlightGeneration = inFlightGenerations
            .filter({ $0 >= generation })
            .min() {
            await waitForCheckpointCompletion(of: inFlightGeneration)
        }
    }

    private func hasVerifiedCheckpoint(atOrAfter generation: Int64) -> Bool {
        committedGeneration >= generation
            && verifiedCheckpointGeneration >= generation
    }

    private func finishCheckpointAttempt(for generation: Int64) {
        inFlightGenerations.remove(generation)
        let waiters = checkpointCompletionWaiters.removeValue(forKey: generation) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelSaveTimers() {
        trailingSaveToken &+= 1
        forcedSaveToken &+= 1
        trailingSaveTask?.cancel()
        forcedSaveTask?.cancel()
        trailingSaveTask = nil
        forcedSaveTask = nil
    }

    private func persistPreferencesSoon() {
        preferencesSaveToken &+= 1
        guard preferencesSaveTask == nil else { return }
        preferencesSaveTask = Task { @MainActor [weak self] in
            await self?.runPreferencesSaveDebounce()
        }
    }
    /// Keeps one trailing-edge worker alive while pan/zoom callbacks arrive.
    /// Replacing a Task for every gesture frame briefly retains every cancelled
    /// task until suspension unwinds and creates avoidable allocation pressure.
    private func runPreferencesSaveDebounce() async {
        var observedToken = preferencesSaveToken
        while Task.isCancelled == false {
            do {
                try await Task.sleep(for: autosaveTiming.preferencesDelay)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            guard observedToken == preferencesSaveToken else {
                observedToken = preferencesSaveToken
                continue
            }
            preferencesSaveTask = nil
            await savePreferencesNow()
            return
        }
        preferencesSaveTask = nil
    }

    private func savePreferencesNow() async {
        guard let preferencesStore else { return }
        let preferences = CanvasPreferences(
            toolState: toolState,
            inputMode: inputMode,
            viewport: viewport,
            pageLayout: pageLayout,
            readerPreferences: readerPreferences,
            currentPageID: currentPageID
        )
        do {
            try await preferencesStore.save(preferences)
        } catch {
            // A preference failure must not interrupt writing or imply that the
            // PaperKit document failed to save. The next change retries it.
        }
    }
}

private extension CanvasCoreStoreError {
    var isSupersededCheckpoint: Bool {
        switch self {
        case .staleGeneration, .staleCheckpointToken:
            true
        default:
            false
        }
    }
}
