import ImagePlayground
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct CanvasChromeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Keeps the canvas picker and the two editor action clusters in separate
/// layout corridors. When the canvas becomes narrower (for example in iPad
/// multitasking), the chrome moves to two rows before
/// those corridors can overlap.
enum CanvasEditorChromeLayout {
    private static let outerHorizontalPadding: CGFloat = 16
    /// Back, pages, reader, and more share the row with the tool pill.
    private static let navigationClusterWidth =
        (4 * NotateDesign.Control.minimumHitTarget)
        + CanvasToolPicker.preferredHistoryWidth
        + (7 * NotateDesign.Spacing.compact)

    static func usesStackedLayout(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool
    ) -> Bool {
        isAccessibilitySize || availableWidth < minimumSingleRowWidth
    }

    static var minimumSingleRowWidth: CGFloat {
        CanvasToolPicker.preferredPillWidth
            + navigationClusterWidth
            + (2 * outerHorizontalPadding)
    }
}

/// Serializes large image decode/insert pipelines and gives lifecycle saves a
/// task they can cancel and drain. At most one decoded image can be retained by
/// editor-owned import work at a time.
@MainActor
final class CanvasEditorMediaTaskGate {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    func submit(_ operation: @escaping @MainActor () async -> Void) {
        generation &+= 1
        let submittedGeneration = generation
        let precedingTask = task
        precedingTask?.cancel()
        task = Task { @MainActor [weak self] in
            defer { self?.finish(generation: submittedGeneration) }
            await precedingTask?.value
            guard Task.isCancelled == false else { return }
            await operation()
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        generation &+= 1
        let pendingTask = task
        task = nil
        pendingTask?.cancel()
        return pendingTask
    }

    private func finish(generation completedGeneration: UInt64) {
        guard generation == completedGeneration else { return }
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

struct CanvasEditorView: View {
    private enum AccessibilityFocus: Hashable {
        case recoveryFailure
    }

    @Bindable var model: CanvasEditorModel
    let item: LibraryItemRecord
    let onRename: @MainActor (String) throws -> Void
    let onClose: (@MainActor () -> Void)?
    let onVerifiedCheckpoint: (@MainActor () async -> Void)?
    let flushesOnDisappear: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityFocus?
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importError: String?
    @State private var imageWandError: String?
    @State private var imageWandSelection: CanvasRegionSelectionContext?
    @State private var isImageWandPresented = false
    @State private var lifecycleFlushTask: Task<Void, Never>?
    @State private var mediaTaskGate = CanvasEditorMediaTaskGate()
    @State private var topChromeHeight: CGFloat =
        CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight

    private var importErrorPresentation: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { isPresented in
                if isPresented == false { importError = nil }
            }
        )
    }

    private var imageWandErrorPresentation: Binding<Bool> {
        Binding(
            get: { imageWandError != nil },
            set: { isPresented in
                if isPresented == false { imageWandError = nil }
            }
        )
    }

    init(
        model: CanvasEditorModel,
        item: LibraryItemRecord,
        onRename: @escaping @MainActor (String) throws -> Void,
        onClose: (@MainActor () -> Void)? = nil,
        onVerifiedCheckpoint: (@MainActor () async -> Void)? = nil,
        flushesOnDisappear: Bool = true
    ) {
        self.model = model
        self.item = item
        self.onRename = onRename
        self.onClose = onClose
        self.onVerifiedCheckpoint = onVerifiedCheckpoint
        self.flushesOnDisappear = flushesOnDisappear
    }

    var body: some View {
        GeometryReader { geometry in
            canvasSurface(
                availableSize: geometry.size
            )
            .onAppear {
                model.setReaderViewportSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, size in
                model.setReaderViewportSize(size)
            }
        }
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive || phase == .background {
                // Inactive (Control Center, app switcher peek) saves without
                // killing an in-flight import; only a real background cancels it.
                startLifecycleFlush(cancelsMedia: phase == .background)
            } else if phase == .active {
                Task { await model.retryPendingLifecycleCheckpoint() }
            }
        }
        .onChange(of: model.verifiedCheckpointGeneration) { oldGeneration, newGeneration in
            guard newGeneration > oldGeneration else { return }
            if let onVerifiedCheckpoint {
                Task { await onVerifiedCheckpoint() }
            }
        }
        .onChange(of: model.imageWandRequest?.id) { _, requestID in
            guard let request = model.imageWandRequest,
                  request.id == requestID else { return }
            imageWandSelection = request.selection
            isImageWandPresented = true
        }
        .onChange(of: model.launchState) { _, state in
            handleLaunchAccessibility(state)
        }
        .onChange(of: model.saveState) { _, state in
            announceSaveFailureIfNeeded(state)
        }
        .onDisappear {
            cancelImageWand()
            if flushesOnDisappear {
                startLifecycleFlush()
            } else {
                mediaTaskGate.cancel()
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            mediaTaskGate.submit { await importPhoto(item) }
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhoto,
            matching: .images,
            preferredItemEncoding: .current
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .imagePlaygroundSheet(
            isPresented: $isImageWandPresented,
            // Keep the prompt empty so circling opens the selected artwork as
            // the starting point. The person can describe a transformation in
            // Image Playground or continue without an app-supplied prompt.
            concepts: [],
            sourceImage: imageWandSourceImage,
            onCompletion: acceptImageWandResult,
            onCancellation: cancelImageWand
        )
        .alert(
            "Couldn't Complete That",
            isPresented: Binding(
                get: { model.actionNotice != nil },
                set: { if $0 == false { model.actionNotice = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.actionNotice = nil } },
            message: { Text(model.actionNotice ?? "") }
        )
        .alert(
            "Image Could Not Be Added",
            isPresented: importErrorPresentation,
            actions: {
                Button("OK", role: .cancel) { importError = nil }
            },
            message: {
                Text(importError ?? "The selected image could not be read.")
            }
        )
        .alert(
            "Wand",
            isPresented: imageWandErrorPresentation,
            actions: {
                Button("OK", role: .cancel) { imageWandError = nil }
            },
            message: {
                Text(imageWandError ?? "Wand is unavailable right now.")
            }
        )
    }

    private func canvasSurface(
        availableSize: CGSize
    ) -> some View {
        ZStack {
            workspaceColor
                .ignoresSafeArea()

            if model.launchState == .ready {
                PaperCanvasRepresentable(
                    initialPages: model.initialPages,
                    initialPageID: model.initialPageID,
                    initialViewport: model.viewport,
                    initialInputMode: model.inputMode,
                    initialPageLayout: model.pageLayout,
                    documentMode: model.documentMode,
                    topChromeHeight: topChromeHeight,
                    callbacks: model.callbacks,
                    onAttach: model.attachCanvasController,
                    onDetach: model.detachCanvasController
                )
                .ignoresSafeArea()
                .allowsHitTesting(model.allowsAuthoring)
                .accessibilityHidden(
                    model.isReaderMode || model.isReaderModeTransitioning
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Canvas workspace")
                .accessibilityIdentifier("canvas.workspace")
            }

            if model.isReaderMode {
                CanvasReaderView(
                    pages: model.readerPages,
                    currentPageID: model.readerCurrentPageID,
                    preferences: model.readerPreferences,
                    reduceMotion: reduceMotion,
                    onPageChanged: model.readerDidNavigate
                )
                .transition(.opacity)
                .zIndex(2)
            } else {
                boundaryPagePullChrome
            }

            if model.launchState == .loading {
                ProgressView("Opening paper…")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .notatePanelSurface()
                    .accessibilityLabel("Opening paper")
                    .accessibilityAddTraits(.isModal)
            }

            if case let .failed(message) = model.launchState {
                recoveryFailure(message)
            }
        }
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.spatial,
            value: model.boundaryPagePull != nil
        )
        .overlay(alignment: .top) {
            // Editing controls wait for a ready canvas, but Back must always
            // work or a failed recovery would trap the person in the note.
            topChrome(availableWidth: availableSize.width)
            .disabled(model.isReaderModeTransitioning)
            .allowsHitTesting(model.isReaderModeTransitioning == false)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.supportsPageStack, model.pageCount > 1,
               model.isReaderMode == false, model.launchState == .ready {
                pageIndicator
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.allowsAuthoring {
                CanvasZoomControl(model: model)
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: NotateDesign.Spacing.compact) {
                if model.isImageWandSelectionActive {
                    imageWandPrompt
                }
                statusChrome
            }
        }
        .onPreferenceChange(CanvasChromeHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0,
                  abs(topChromeHeight - height) > 0.5 else { return }
            topChromeHeight = height
        }
    }

    @ViewBuilder
    private func topChrome(availableWidth: CGFloat) -> some View {
        let isStacked = CanvasEditorChromeLayout.usesStackedLayout(
            availableWidth: availableWidth,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )

        VStack(spacing: NotateDesign.Spacing.compact) {
            editorIdentityAndActions(isStacked: isStacked)
            if model.isReaderMode == false {
                if isStacked {
                    toolPicker(placement: .pill, isStacked: true)
                }
                if model.overlay != .none {
                    toolPicker(placement: .options, isStacked: isStacked)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CanvasChromeHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
        .accessibilityIdentifier("canvas.top.chrome")
    }

    private func toolPicker(
        placement: CanvasToolPicker.Placement,
        isStacked: Bool
    ) -> some View {
        CanvasToolPicker(
            toolState: model.toolState,
            overlay: model.overlay,
            preferredGeometryTool: model.preferredGeometryTool,
            activeGeometryTool: model.activeGeometryTool,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            usesCompactLayout: isStacked,
            placement: placement,
            onIntent: handleToolbarIntent
        )
        .disabled(model.launchState != .ready)
    }

    private func editorIdentityAndActions(isStacked: Bool) -> some View {
        GlassEffectContainer(spacing: NotateDesign.Spacing.compact) {
            HStack(spacing: NotateDesign.Spacing.compact) {
                if let onClose {
                    Button {
                        // Begin the native reverse transition on touch. The
                        // application coordinator owns the one durable flush
                        // after the pop has completed.
                        onClose()
                    } label: {
                        NotateCompactGlassIconLabel(systemImage: "chevron.backward")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("editor.navigation.back")
                    .accessibilityLabel("Back to Library")
                    .accessibilityHint("Saves this document and returns to the library")
                }
                if model.supportsPageStack {
                    if model.isReaderMode == false {
                        CanvasPageOverviewButton(model: model)
                    }
                }
                Spacer(minLength: NotateDesign.Spacing.compact)
                if model.isReaderMode == false, isStacked == false {
                    toolPicker(placement: .pill, isStacked: false)
                    Spacer(minLength: NotateDesign.Spacing.compact)
                }
                if model.isReaderMode == false {
                    toolPicker(placement: .history, isStacked: isStacked)
                }
                if model.supportsPageStack {
                    readerButton
                }
                CanvasMoreButton(
                    model: model,
                    item: item,
                    onRename: onRename
                )
            }
        }
    }

    /// Wand is a one-shot mode, so it announces itself and offers a way out
    /// without covering the page.
    private var imageWandPrompt: some View {
        HStack(spacing: NotateDesign.Spacing.control) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(NotateDesign.Palette.accent)
            Text("Circle what you want to transform")
                .font(.subheadline.weight(.medium))
            Button("Cancel") { cancelImageWand() }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("canvas.wand.cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .notateGlassSurface(shape: Capsule())
        .padding(.bottom, 24)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.wand.prompt")
    }

    /// Orientation without chrome: which page of the note is in view.
    private var pageIndicator: some View {
        Text("\(model.currentPageNumber) / \(model.pageCount)")
            .font(.footnote.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .notateGlassSurface(shape: Capsule())
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(model.currentPageNumber) of \(model.pageCount)")
            .accessibilityIdentifier("canvas.page.indicator")
    }

    private var readerButton: some View {
        Button {
            Task { await model.toggleReaderMode() }
        } label: {
            NotateCompactGlassIconLabel(
                systemImage: model.isReaderMode ? "eye.fill" : "eye"
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isReaderModeTransitioning)
        .accessibilityIdentifier("canvas.reader.toggle")
        .accessibilityLabel(
            model.isReaderMode ? "Exit Reader Mode" : "Enter Reader Mode"
        )
        .accessibilityHint(
            model.isReaderMode
                ? "Returns to editing on the current page"
                : "Opens a read-only view of this note"
        )
    }

    private var workspaceColor: Color {
        Color(uiColor: CanvasConstants.workspaceBackground(for: model.documentMode))
    }

    @ViewBuilder
    private var statusChrome: some View {
        if case let .failed(message) = model.saveState {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NotateDesign.Spacing.control) {
                    saveFailureMessage(message, lineLimit: 2)
                    retrySaveButton
                }

                VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
                    saveFailureMessage(message, lineLimit: nil)
                    retrySaveButton
                }
            }
            .font(.footnote)
            .padding(NotateDesign.Spacing.control)
            .background(
                NotateDesign.Palette.background,
                in: .rect(cornerRadius: NotateDesign.Radius.control)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.control,
                    style: .continuous
                )
                .stroke(
                    NotateDesign.Palette.error.opacity(0.52),
                    lineWidth: NotateDesign.Hairline.standardWidth
                )
            }
            .padding(.horizontal, NotateDesign.Spacing.section)
            .padding(
                .bottom,
                NotateDesign.Control.standard + NotateDesign.Spacing.spacious
            )
            .accessibilityElement(children: .contain)
            .transition(
                reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
            )
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.presentation,
                value: model.saveState
            )
        }
    }

    private func saveFailureMessage(_ message: String, lineLimit: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotateDesign.Spacing.compact) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(NotateDesign.Palette.error)
                .accessibilityHidden(true)
            Text("Changes are not safely stored. \(message)")
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var retrySaveButton: some View {
        Button("Retry") {
            Task { await model.retrySave() }
        }
        .fontWeight(.semibold)
    }

    @ViewBuilder
    private var boundaryPagePullChrome: some View {
        if let pull = model.boundaryPagePull {
            Group {
                if model.pageLayout.scrollDirection == .horizontal {
                    HStack {
                        if pull.boundary == .start {
                            CanvasBoundaryPageIndicator(pull: pull)
                            Spacer()
                        } else {
                            Spacer()
                            CanvasBoundaryPageIndicator(pull: pull)
                        }
                    }
                    .padding(.horizontal, CanvasConstants.pageGap)
                        .padding(
                            .top,
                            topChromeHeight
                    )
                } else {
                    VStack {
                        if pull.boundary == .start {
                            CanvasBoundaryPageIndicator(pull: pull)
                            Spacer()
                        } else {
                            Spacer()
                            CanvasBoundaryPageIndicator(pull: pull)
                        }
                    }
                    .padding(
                        .top,
                        topChromeHeight
                            + CanvasConstants.firstPageToolbarGap / 2
                    )
                    .padding(.bottom, CanvasConstants.pageGap)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.92))
            )
        }
    }

    private func recoveryFailure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(NotateDesign.Palette.error)
                .accessibilityHidden(true)
            Text("Canvas Recovery Needed")
                .font(.headline)
                .accessibilityFocused($accessibilityFocus, equals: .recoveryFailure)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Notate preserved both unreadable checkpoints instead of replacing them with blank paper.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await model.retryRecovery() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 420)
        .padding(24)
        .notatePanelSurface()
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func handleToolbarIntent(_ intent: CanvasToolbarIntent) {
        switch intent {
        case .requestImageWand:
            model.handle(.dismissOverlay)
            beginImageWand()
        case .requestPhoto:
            model.handle(.dismissOverlay)
            isPhotoPickerPresented = true
        case .requestFile:
            model.handle(.dismissOverlay)
            isFileImporterPresented = true
        default:
            model.handle(intent)
        }
    }

    private func beginImageWand() {
        guard supportsImagePlayground else {
            imageWandError = "Image Playground requires a compatible iPad with image generation enabled in Apple Intelligence settings."
            return
        }
        model.beginImageWandSelection()
        UIAccessibility.post(
            notification: .announcement,
            argument: "Wand. Circle a sketch or region to open Image Playground."
        )
    }

    private var imageWandSourceImage: Image? {
        guard let thumbnail = imageWandSelection?.thumbnail else { return nil }
        return Image(decorative: thumbnail, scale: 1)
    }

    private func acceptImageWandResult(at temporaryURL: URL) {
        guard let selection = imageWandSelection,
              let requestID = model.imageWandRequest?.id else {
            cancelImageWand()
            return
        }
        isImageWandPresented = false

        mediaTaskGate.submit {
            do {
                let imported = try await CanvasImageIngestor.shared.ingest(
                    fileURL: temporaryURL
                )
                guard await model.insertImageAndWait(
                    imported.image,
                    frame: selection.pageBounds,
                    onPageID: selection.pageID,
                    expectedGeneration: selection.checkpointGeneration
                ) else {
                    throw CanvasImageWandError.staleSelection
                }
                model.consumeImageWandRequest(id: requestID)
                imageWandSelection = nil
            } catch where Task.isCancelled {
                return
            } catch {
                // Retain the request unless the model accepted the insertion.
                // This prevents an async decode failure or stale checkpoint
                // from being mistaken for a completed one-shot Wand action.
                imageWandSelection = nil
                imageWandError = error.localizedDescription
            }
        }
    }

    private func cancelImageWand() {
        isImageWandPresented = false
        imageWandSelection = nil
        model.cancelImageWandSelection()
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let transfer = try await item.loadTransferable(
                type: CanvasImageTransfer.self
            ) else {
                throw CanvasImageIngestionError.unreadableSource
            }
            defer { transfer.discard() }
            let imported = try await CanvasImageIngestor.shared.ingest(
                fileURL: transfer.fileURL
            )
            _ = try await model.insertImageDurably(imported.image)
        } catch where Task.isCancelled {
            return
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            mediaTaskGate.submit { await importFile(at: url) }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importFile(at url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let imported = try await CanvasImageIngestor.shared.ingest(fileURL: url)
            _ = try await model.insertImageDurably(imported.image)
        } catch where Task.isCancelled {
            return
        } catch {
            importError = error.localizedDescription
        }
    }

    private func startLifecycleFlush(cancelsMedia: Bool = true) {
        guard lifecycleFlushTask == nil else { return }
        // Ask for background time before anything is awaited, so a slow
        // import cannot eat the window the save needs.
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Canvas lifecycle flush"
        ) {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        let pendingMediaTask = cancelsMedia ? mediaTaskGate.cancel() : nil
        lifecycleFlushTask = Task {
            // Save first; the cancelled import only needs to wind down.
            await model.flushForLifecycle()
            await pendingMediaTask?.value
            lifecycleFlushTask = nil
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
    }

    private func handleLaunchAccessibility(_ state: CanvasEditorModel.LaunchState) {
        guard case let .failed(message) = state else {
            if accessibilityFocus == .recoveryFailure {
                accessibilityFocus = nil
            }
            return
        }

        Task { @MainActor in
            await Task.yield()
            accessibilityFocus = .recoveryFailure
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: "Canvas recovery needed. \(message)"
            )
        }
    }

    private func announceSaveFailureIfNeeded(_ state: CanvasEditorModel.SaveState) {
        guard case let .failed(message) = state,
              UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: "Changes are not safely stored. \(message). Retry is available."
        )
    }
}

private struct CanvasBoundaryPageIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let pull: CanvasBoundaryPagePull

    var body: some View {
        HStack(spacing: NotateDesign.Spacing.compact) {
            ring
            // Words make the gesture self-explanatory; they change no
            // thresholds and are hidden from VoiceOver (Add Page is the
            // accessible route).
            Text(pull.isArmed ? "Release to add page" : "Pull to add page")
                .font(.footnote.weight(.medium))
                .foregroundStyle(pull.isArmed ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .notateGlassSurface(shape: Capsule())
                .contentTransition(.opacity)
        }
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.feedback,
            value: pull.isArmed
        )
        .accessibilityHidden(true)
    }

    private var ring: some View {
        let circle = Circle()

        return ZStack {
            circle
                .fill(pull.isArmed ? NotateDesign.Palette.accent : Color.clear)

            if pull.isArmed == false {
                circle
                    .stroke(Color.primary.opacity(0.18), lineWidth: 3)

                circle
                    .trim(from: 0, to: pull.progress)
                    .stroke(
                        NotateDesign.Palette.accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            if pull.isArmed {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .frame(width: 42, height: 42)
        .notateBadgeSurface(in: circle)
        .scaleEffect(reduceMotion ? 1 : (pull.isArmed ? 1.08 : 1))
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.feedback,
            value: pull.isArmed
        )
        .accessibilityHidden(true)
    }
}

private struct CanvasZoomControl: View {
    @Bindable var model: CanvasEditorModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @GestureState private var isScrubbing = false
    @State private var isVisible = false
    @State private var scrubOriginScale: CGFloat?
    @State private var hideTask: Task<Void, Never>?

    private let trackWidth: CGFloat = 74
    private let thumbDiameter: CGFloat = 10

    var body: some View {
        ZStack {
            keyboardShortcuts
            scrubber
        }
        .onAppear {
            if model.isZoomInteractionActive || voiceOverEnabled {
                reveal(autoHide: false)
            }
        }
        .onChange(of: model.isZoomInteractionActive) { _, isActive in
            if isActive {
                reveal(autoHide: false)
            } else if isScrubbing == false {
                scheduleHide()
            }
        }
        .onChange(of: model.currentZoomScale) { oldScale, newScale in
            guard oldScale != newScale else { return }
            reveal(autoHide: model.isZoomInteractionActive == false && isScrubbing == false)
        }
        .onChange(of: isScrubbing) { _, isActive in
            if isActive {
                reveal(autoHide: false)
            } else if model.isZoomInteractionActive == false {
                scrubOriginScale = nil
                scheduleHide()
            }
        }
        .onChange(of: voiceOverEnabled) { _, isEnabled in
            if isEnabled {
                reveal(autoHide: false)
            } else if model.isZoomInteractionActive == false && isScrubbing == false {
                scheduleHide()
            }
        }
        .onDisappear {
            if scrubOriginScale != nil {
                model.endZoomScrubbing()
                scrubOriginScale = nil
            }
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text("\(model.currentZoomPercent)%")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(model.currentZoomPercent)))
                .animation(
                    reduceMotion ? nil : NotateDesign.Motion.content,
                    value: model.currentZoomPercent
                )
                .frame(minWidth: 52, alignment: .trailing)

            zoomTrack
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .contentShape(.capsule)
        .notateGlassSurface(
            shape: Capsule(),
            reduceTransparency: reduceTransparency,
            isInteractive: true
        )
        .hoverEffect(.highlight)
        .gesture(scrubGesture)
        .opacity(controlIsVisible ? 1 : 0)
        .scaleEffect(
            reduceMotion ? 1 : (controlIsVisible ? 1 : 0.96),
            anchor: .bottomLeading
        )
        .offset(y: reduceMotion ? 0 : (controlIsVisible ? 0 : 5))
        .animation(visibilityAnimation, value: controlIsVisible)
        .allowsHitTesting(controlIsVisible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom")
        .accessibilityValue("\(model.currentZoomPercent) percent")
        .accessibilityHint("Drag left or right, or swipe with VoiceOver, to adjust magnification")
        .accessibilityHidden(controlIsVisible == false)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                model.zoomIn()
            case .decrement:
                model.zoomOut()
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: Text("Reset to 100 percent")) {
            model.resetZoom()
        }
        .accessibilityAction(named: Text("Minimum 50 percent")) {
            model.setZoomScale(CanvasConstants.absoluteZoomRange.lowerBound)
        }
        .help("Drag left or right to zoom")
    }

    private var zoomTrack: some View {
        GeometryReader { geometry in
            let position = CanvasZoom.scrubberPosition(for: model.currentZoomScale)
            let travel = max(geometry.size.width - thumbDiameter, 0)
            let thumbOffset = travel * position

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(contrast == .increased ? 0.36 : 0.18))
                    .frame(height: 3)

                Capsule()
                    .fill(.primary.opacity(contrast == .increased ? 0.82 : 0.55))
                    .frame(width: (thumbDiameter / 2) + thumbOffset, height: 3)

                Circle()
                    .fill(.primary)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbOffset)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .leading
            )
        }
        .frame(width: trackWidth, height: 20)
        .accessibilityHidden(true)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isScrubbing) { _, isActive, _ in
                isActive = true
            }
            .onChanged { value in
                let startScale: CGFloat
                if let scrubOriginScale {
                    startScale = scrubOriginScale
                } else {
                    startScale = model.currentZoomScale
                    scrubOriginScale = startScale
                    model.beginZoomScrubbing()
                    reveal(autoHide: false)
                }

                model.setZoomScale(
                    CanvasZoom.scale(
                        afterScrubbing: startScale,
                        horizontalTranslation: value.translation.width
                    )
                )
            }
            .onEnded { _ in
                model.endZoomScrubbing()
                scrubOriginScale = nil
                scheduleHide()
            }
    }

    private var keyboardShortcuts: some View {
        ZStack {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .clipped()
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var controlIsVisible: Bool {
        isVisible || voiceOverEnabled
    }

    private var visibilityAnimation: Animation? {
        reduceMotion ? NotateDesign.Motion.removal : NotateDesign.Motion.presentation
    }

    private func reveal(autoHide: Bool) {
        if isVisible == false {
            isVisible = true
        }
        if autoHide {
            scheduleHide()
        } else if hideTask != nil {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard voiceOverEnabled == false else { return }

        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard isScrubbing == false,
                  model.isZoomInteractionActive == false,
                  voiceOverEnabled == false else { return }
            isVisible = false
            hideTask = nil
        }
    }
}

private enum CanvasImageWandError: LocalizedError {
    case staleSelection

    var errorDescription: String? {
        "The selected canvas region changed before the generated image was ready. Please try Wand again."
    }
}
