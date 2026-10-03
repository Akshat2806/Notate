import PhotosUI
import SwiftUI
import UIKit

enum CanvasPageOverviewDeletionFocus {
    static func pageID(
        afterDeletingPageNumber pageNumber: Int,
        in document: CanvasDocumentSnapshot
    ) -> UUID? {
        guard document.pages.isEmpty == false else { return nil }
        let requestedIndex = pageNumber > 1 ? pageNumber - 1 : 0
        let nearestIndex = min(
            requestedIndex,
            document.pages.count - 1
        )
        return document.pages[nearestIndex].id
    }
}

struct CanvasPageOverviewButton: View {
    @Bindable var model: CanvasEditorModel

    @State private var presentation: CanvasPageOverviewPresentation?
    @State private var preparationError: String?
    @AccessibilityFocusState private var isOverviewButtonFocused: Bool

    var body: some View {
        Button(action: presentOverview) {
            NotateCompactGlassIconLabel(systemImage: "square.grid.2x2")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All Pages")
        .accessibilityHint("Shows a grid of pages in this notebook")
        .accessibilityFocused($isOverviewButtonFocused)
        .help("All Pages")
        .sheet(item: $presentation) { presentation in
            CanvasPageOverviewSheet(
                document: presentation.document,
                onSelect: { pageID in
                    model.goToPageFromOverview(id: pageID)
                },
                onDuplicate: { pageID in
                    model.duplicatePageFromOverview(id: pageID)
                },
                onRotate: { pageID, direction in
                    model.rotatePageFromOverview(id: pageID, direction: direction)
                },
                onMove: { pageID, destinationIndex in
                    model.movePageFromOverview(id: pageID, to: destinationIndex)
                },
                onAddImagePage: { data, suggestedName in
                    try model.addImagePageFromOverview(
                        data: data,
                        suggestedName: suggestedName
                    )
                },
                onAddPage: { position in
                    model.addPage(at: position)
                    return model.preparePageOverviewSnapshot()
                },
                onDelete: { pageID in
                    try await model.deletePagePermanentlyFromOverview(id: pageID)
                }
            )
            .presentationSizing(.page)
        }
        .onChange(of: presentation?.id) { previousID, currentID in
            guard previousID != nil, currentID == nil else { return }
            Task { @MainActor in
                await Task.yield()
                isOverviewButtonFocused = true
            }
        }
        .alert(
            "Pages Unavailable",
            isPresented: Binding(
                get: { preparationError != nil },
                set: { if $0 == false { preparationError = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { preparationError = nil }
            },
            message: {
                Text(preparationError ?? "The pages couldn't be prepared for preview.")
            }
        )
    }

    private func presentOverview() {
        model.handle(.dismissOverlay)
        Task { @MainActor in
            guard let document = await model.preparePageOverviewSnapshotWhenReady() else {
                preparationError = "The live canvas couldn't be captured safely. Please try again."
                return
            }
            presentation = CanvasPageOverviewPresentation(document: document)
        }
    }
}

private struct CanvasPageOverviewPresentation: Identifiable {
    let id = UUID()
    let document: CanvasDocumentSnapshot
}

struct CanvasPageOverviewSheet: View {
    @State private var document: CanvasDocumentSnapshot
    @State private var pendingDeletion: CanvasPageDeletionRequest?
    @State private var actionError: String?
    @State private var dropTargetPageID: UUID?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingPhotoPage = false
    @AccessibilityFocusState private var focusedPageID: UUID?

    let onSelect: @MainActor (UUID) -> Void
    let onDuplicate: @MainActor (UUID) -> CanvasDocumentSnapshot?
    let onRotate: @MainActor (UUID, CanvasPageRotationDirection) -> CanvasDocumentSnapshot?
    let onMove: @MainActor (UUID, Int) -> CanvasDocumentSnapshot?
    let onAddImagePage: @MainActor (Data, String?) throws -> CanvasDocumentSnapshot?
    let onAddPage: @MainActor (CanvasPageInsertionPosition) -> CanvasDocumentSnapshot?
    let onDelete: @MainActor (UUID) async throws -> CanvasDocumentSnapshot

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let columns = [
        GridItem(
            .adaptive(minimum: 152, maximum: 180),
            spacing: NotateDesign.Spacing.section,
            alignment: .top
        ),
    ]

    init(
        document: CanvasDocumentSnapshot,
        onSelect: @escaping @MainActor (UUID) -> Void,
        onDuplicate: @escaping @MainActor (UUID) -> CanvasDocumentSnapshot?,
        onRotate: @escaping @MainActor (UUID, CanvasPageRotationDirection) -> CanvasDocumentSnapshot?,
        onMove: @escaping @MainActor (UUID, Int) -> CanvasDocumentSnapshot?,
        onAddImagePage: @escaping @MainActor (Data, String?) throws -> CanvasDocumentSnapshot?,
        onAddPage: @escaping @MainActor (CanvasPageInsertionPosition) -> CanvasDocumentSnapshot?,
        onDelete: @escaping @MainActor (UUID) async throws -> CanvasDocumentSnapshot
    ) {
        _document = State(initialValue: document)
        self.onSelect = onSelect
        self.onDuplicate = onDuplicate
        self.onRotate = onRotate
        self.onMove = onMove
        self.onAddImagePage = onAddImagePage
        self.onAddPage = onAddPage
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: columns,
                        alignment: .leading,
                        spacing: NotateDesign.Spacing.page
                    ) {
                        ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                            pageCell(page, number: index + 1)
                                .id(page.id)
                        }
                    }
                    .padding(NotateDesign.Spacing.page)
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onAppear {
                    proxy.scrollTo(document.currentPageID, anchor: .center)
                }
                .onChange(of: document.currentPageID) { _, pageID in
                    withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
                        proxy.scrollTo(pageID, anchor: .center)
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("All Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Start", systemImage: "doc.badge.plus") {
                            addPage(at: .start)
                        }
                        Button("After Current Page", systemImage: "doc.badge.plus") {
                            addPage(at: .afterCurrent)
                        }
                        Button("End", systemImage: "doc.badge.plus") {
                            addPage(at: .end)
                        }
                    } label: {
                        Label("Add Page", systemImage: "plus")
                    }
                    .menuOrder(.fixed)
                    .accessibilityHint("Choose where to insert the new page")
                }
                ToolbarItem(placement: .secondaryAction) {
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        Label("Add Photo Page", systemImage: "photo.badge.plus")
                    }
                    .opacity(isLoadingPhotoPage ? 0 : 1)
                    .overlay {
                        if isLoadingPhotoPage {
                            ProgressView()
                                .accessibilityLabel("Adding Photo Page")
                        }
                    }
                    .disabled(isLoadingPhotoPage)
                    .accessibilityHint("Adds the selected photo as a new annotatable page")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close All Pages")
                }
            }
            .confirmationDialog(
                "Delete Page?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if $0 == false { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { request in
                Button("Delete Permanently", role: .destructive) {
                    deletePage(request)
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text("Page \(request.number) and everything on it will be deleted permanently. This can't be undone.")
            }
            .alert(
                "Page Action Unavailable",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if $0 == false { actionError = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) { actionError = nil }
                },
                message: {
                    Text(actionError ?? "The page couldn't be changed. Please try again.")
                }
            )
            .onChange(of: selectedPhotoItem) { _, selectedItem in
                guard let selectedItem else { return }
                loadPhotoPage(from: selectedItem)
            }
        }
    }

    private func pageCell(_ page: CanvasPageSnapshot, number: Int) -> some View {
        let isCurrent = page.id == document.currentPageID
        let pageShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let labelColor = Color.secondary

        return VStack(spacing: 2) {
            Button {
                onSelect(page.id)
                dismiss()
            } label: {
                CanvasPageThumbnail(page: page)
                    .aspectRatio(
                        page.displaySize.width / page.displaySize.height,
                        contentMode: .fit
                    )
                    .frame(maxWidth: .infinity)
                    .clipShape(pageShape)
                    .overlay {
                        pageShape.strokeBorder(
                            Color.black.opacity(
                                colorSchemeContrast == .increased ? 0.28 : 0.14
                            ),
                            lineWidth: 1
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(NotateDesign.Palette.accent, in: Circle())
                                .padding(6)
                                .accessibilityHidden(true)
                        }
                    }
                    .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                    .accessibilityHidden(true)
            }
            .buttonStyle(NotatePressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel("Page \(number)")
            .accessibilityValue(isCurrent ? "Current page" : "")
            .accessibilityHint("Navigates to this page and closes All Pages")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityFocused($focusedPageID, equals: page.id)
            .accessibilityActions {
                if number > 1 {
                    Button("Move Earlier") {
                        movePage(page.id, to: number - 2)
                    }
                }
                if number < document.pages.count {
                    Button("Move Later") {
                        movePage(page.id, to: number)
                    }
                }
            }

            HStack(spacing: 0) {
                Menu {
                    Button {
                        onSelect(page.id)
                        dismiss()
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }

                    Button {
                        duplicatePage(page.id, number: number)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                    Button {
                        rotatePage(page.id, direction: .left, number: number)
                    } label: {
                        Label("Rotate Left", systemImage: "rotate.left")
                    }
                    .disabled(page.supportsLosslessQuarterTurn == false)

                    Button {
                        rotatePage(page.id, direction: .right, number: number)
                    } label: {
                        Label("Rotate Right", systemImage: "rotate.right")
                    }
                    .disabled(page.supportsLosslessQuarterTurn == false)

                    if page.supportsLosslessQuarterTurn == false {
                        Label("Rotation locks after editing", systemImage: "lock")
                    }

                    Divider()

                    Button(role: .destructive) {
                        pendingDeletion = CanvasPageDeletionRequest(
                            pageID: page.id,
                            number: number
                        )
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                    .disabled(document.pages.count == 1)
                } label: {
                    HStack(spacing: 4) {
                        Text("\(number)")
                            .font(.headline.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)

                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(labelColor)
                    .frame(
                        minWidth: NotateDesign.Control.standard,
                        minHeight: NotateDesign.Control.standard
                    )
                    .contentShape(Rectangle())
                }
                .menuOrder(.fixed)
                .menuIndicator(.hidden)
                .accessibilityLabel("Actions for Page \(number)")
                .accessibilityHint("Shows actions for this page")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scaleEffect(dropTargetPageID == page.id ? 1.025 : 1)
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.selection,
            value: dropTargetPageID == page.id
        )
        .draggable(page.id.uuidString) {
            CanvasPageThumbnail(page: page)
                .aspectRatio(
                    page.displaySize.width / page.displaySize.height,
                    contentMode: .fit
                )
                .frame(width: 112)
                .clipShape(pageShape)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        }
        .dropDestination(for: String.self) { itemIDs, _ in
            guard let itemID = itemIDs.first,
                  let sourceID = UUID(uuidString: itemID),
                  sourceID != page.id,
                  let destinationIndex = document.pages.firstIndex(where: {
                      $0.id == page.id
                  }) else { return false }
            return movePage(sourceID, to: destinationIndex)
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTargetPageID = page.id
            } else if dropTargetPageID == page.id {
                dropTargetPageID = nil
            }
        }
    }

    private func duplicatePage(_ pageID: UUID, number: Int) {
        guard let updatedDocument = onDuplicate(pageID) else {
            actionError = "The page couldn't be duplicated. Please try again."
            return
        }
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
            document = updatedDocument
        }
        moveAccessibilityFocus(
            to: updatedDocument.currentPageID,
            announcement: "Page \(number) duplicated as Page \(number + 1)."
        )
    }

    private func rotatePage(
        _ pageID: UUID,
        direction: CanvasPageRotationDirection,
        number: Int
    ) {
        guard let updatedDocument = onRotate(pageID, direction) else {
            actionError = "Page \(number) couldn't be rotated. Please try again."
            return
        }
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
            document = updatedDocument
        }
        moveAccessibilityFocus(
            to: pageID,
            announcement: "Page \(number) rotated \(direction == .left ? "left" : "right")."
        )
    }

    @discardableResult
    private func movePage(_ pageID: UUID, to destinationIndex: Int) -> Bool {
        guard let sourceIndex = document.pages.firstIndex(where: { $0.id == pageID }),
              sourceIndex != destinationIndex else { return false }
        guard let updatedDocument = onMove(pageID, destinationIndex) else {
            actionError = "The page couldn't be moved. Please try again."
            return false
        }

        dropTargetPageID = nil
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
            document = updatedDocument
        }
        let updatedNumber = updatedDocument.pages.firstIndex(where: { $0.id == pageID })
            .map { $0 + 1 } ?? destinationIndex + 1
        moveAccessibilityFocus(
            to: pageID,
            announcement: "Page moved to position \(updatedNumber)."
        )
        return true
    }

    private func addPage(at position: CanvasPageInsertionPosition) {
        guard let updatedDocument = onAddPage(position) else {
            actionError = "A new page couldn't be added. Please try again."
            return
        }
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
            document = updatedDocument
        }
        let insertedNumber = updatedDocument.pages.firstIndex {
            $0.id == updatedDocument.currentPageID
        }.map { $0 + 1 } ?? updatedDocument.pages.count
        moveAccessibilityFocus(
            to: updatedDocument.currentPageID,
            announcement: "Page \(insertedNumber) added."
        )
    }

    private func loadPhotoPage(from item: PhotosPickerItem) {
        guard isLoadingPhotoPage == false else { return }
        isLoadingPhotoPage = true
        Task { @MainActor in
            defer {
                selectedPhotoItem = nil
                isLoadingPhotoPage = false
            }
            do {
                guard let transfer = try await item.loadTransferable(
                    type: CanvasImageTransfer.self
                ) else {
                    actionError = "The selected photo couldn't be loaded. Please try another image."
                    return
                }
                defer { transfer.discard() }
                let data = try await CanvasImageIngestor.shared.validatedOriginalData(
                    fileURL: transfer.fileURL
                )
                guard let updatedDocument = try onAddImagePage(data, "Photo") else {
                    actionError = "The photo page couldn't be added. Please try again."
                    return
                }
                withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
                    document = updatedDocument
                }
                moveAccessibilityFocus(
                    to: updatedDocument.currentPageID,
                    announcement: "Photo added as Page \(updatedDocument.pages.count)."
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func deletePage(_ request: CanvasPageDeletionRequest) {
        pendingDeletion = nil
        Task { @MainActor in
            do {
                let updatedDocument = try await onDelete(request.pageID)
                guard let focusPageID = CanvasPageOverviewDeletionFocus.pageID(
                    afterDeletingPageNumber: request.number,
                    in: updatedDocument
                ) else {
                    // The editor currently preserves a final page, but keep the
                    // presentation boundary defensive: a future persistence or
                    // callback regression must not turn an invalid empty result
                    // into a negative array index on the main actor.
                    actionError = "A note must keep at least one page. Nothing was deleted."
                    return
                }
                withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
                    document = updatedDocument
                }
                moveAccessibilityFocus(
                    to: focusPageID,
                    announcement: "Page \(request.number) deleted permanently."
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func moveAccessibilityFocus(to pageID: UUID, announcement: String) {
        Task { @MainActor in
            await Task.yield()
            focusedPageID = pageID
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }
}

private struct CanvasPageDeletionRequest: Identifiable {
    let pageID: UUID
    let number: Int

    var id: UUID { pageID }
}
