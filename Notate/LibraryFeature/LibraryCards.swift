Warning: truncated output (original token count: 23812)
Total output lines: 2517

import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The library grid has one calm alignment lane, but the artwork inside that
/// lane must retain the physical proportion of the thing it represents.
/// In particular, page-based items must never inherit the canvas' 4:3 crop.
enum LibraryArtworkSilhouette: Equatable, Sendable {
    case finderFolder
    case portraitPage
    case landscapeBoard
    case sourceDocument

    static func resolve(for kind: LibraryItemKind) -> Self {
        switch kind {
        case .folder: .finderFolder
        case .notebook: .portraitPage
        case .canvas: .landscapeBoard
        case .legacyTypedNote, .importedDocument, .attachment: .sourceDocument
        }
    }

    var preferredAspectRatio: CGFloat? {
        return switch self {
        case .finderFolder: NotateDesign.Library.Shelf.folderAspectRatio
        case .portraitPage: NotateDesign.Library.Shelf.notebookAspectRatio
        case .landscapeBoard: CanvasConstants.freeformLibraryAspectRatio
        case .sourceDocument: nil
        }
    }
}

enum LibraryArtworkGeometry {
    static func aspectFitSize(source: CGSize, inside bounds: CGSize) -> CGSize {
        guard source.width.isFinite,
            source.height.isFinite,
            bounds.width.isFinite,
            bounds.height.isFinite,
            source.width > 0,
            source.height > 0,
            bounds.width > 0,
            bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

/// A semantic, file-type-specific fallback for attachments that Notate cannot
/// render as editable PDF/image documents. The file extension is deliberately
/// only a secondary signal because document providers often supply a richer
/// Uniform Type Identifier than the visible filename.
enum LibraryFileFallbackKind: Equatable, Sendable {
    case pdf
    case image
    case audio
    case video
    case archive
    case spreadsheet
    case presentation
    case text
    case document
    case generic

    static func resolve(
        contentTypeIdentifier: String?,
        filename: String?
    ) -> Self {
        let contentType = contentTypeIdentifier.flatMap(UTType.init)
        let fileExtension = filename
            .map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            ?? ""

        if contentType?.conforms(to: .pdf) == true || fileExtension == "pdf" {
            return .pdf
        }
        if contentType?.conforms(to: .image) == true
            || ["avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
            .contains(fileExtension) {
            return .image
        }
        if contentType?.conforms(to: .audio) == true
            || ["aac", "aiff", "flac", "m4a", "mp3", "ogg", "wav"]
            .contains(fileExtension) {
            return .audio
        }
        if contentType?.conforms(to: .movie) == true
            || ["avi", "m4v", "mkv", "mov", "mp4"].contains(fileExtension) {
            return .video
        }
        if contentType?.conforms(to: .archive) == true
            || ["7z", "bz2", "gz", "rar", "tar", "zip"].contains(fileExtension) {
            return .archive
        }
        if contentType?.conforms(to: .spreadsheet) == true
            || ["csv", "numbers", "ods", "xls", "xlsx"].contains(fileExtension) {
            return .spreadsheet
        }
        if contentType?.conforms(to: .presentation) == true
            || ["key", "odp", "ppt", "pptx"].contains(fileExtension) {
            return .presentation
        }
        if contentType?.conforms(to: .text) == true
            || ["html", "json", "md", "rtf", "txt", "xml", "yaml", "yml"]
            .contains(fileExtension) {
            return .text
        }
        if ["doc", "docx", "odt", "pages"].contains(fileExtension) {
            return .document
        }
        return .generic
    }
}

private extension LibraryFileFallbackKind {
    var symbolName: String {
        switch self {
        case .pdf: "doc.text.fill"
        case .image: "photo.fill"
        case .audio: "waveform"
        case .video: "play.rectangle.fill"
        case .archive: "archivebox.fill"
        case .spreadsheet: "tablecells.fill"
        case .presentation: "rectangle.on.rectangle.angled"
        case .text: "text.document.fill"
        case .document: "doc.fill"
        case .generic: "paperclip"
        }
    }

    var accentColor: Color {
        switch self {
        case .pdf: .red
        case .image: .indigo
        case .audio: .purple
        case .video: .pink
        case .archive: .brown
        case .spreadsheet: .green
        case .presentation: .orange
        case .text: .blue
        case .document: .teal
        case .generic: .secondary
        }
    }

    func shortLabel(filename: String?) -> String {
        let fileExtension = filename
            .map { URL(fileURLWithPath: $0).pathExtension.uppercased() }
            .flatMap { value in value.isEmpty ? nil : String(value.prefix(5)) }
        if let fileExtension { return fileExtension }
        return switch self {
        case .pdf: "PDF"
        case .image: "IMAGE"
        case .audio: "AUDIO"
        case .video: "VIDEO"
        case .archive: "ZIP"
        case .spreadsheet: "SHEET"
        case .presentation: "SLIDES"
        case .text: "TEXT"
        case .document: "DOC"
        case .generic: "FILE"
        }
    }
}

/// The small, immutable input needed by a Finder-style folder peek. Capping
/// this value before view construction keeps folder cards cheap in lazy grids
/// and prevents nested folder previews from recursively expanding their trees.
struct LibraryFolderPreviewItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: LibraryItemKind
    let title: String
    let coverChoice: LibraryCoverChoice
    let previewGeneration: Int64
    let sourceFilename: String?
    let sourceContentTypeIdentifier: String?
    let folderSettings: LibraryFolderSettings?

    init(item: LibraryItemRecord) {
        id = item.id
        kind = item.kind
        title = item.name
        coverChoice = item.coverChoice
        previewGeneration = item.previewGeneration
        sourceFilename = item.sourceFilename
        sourceContentTypeIdentifier = item.sourceContentTypeIdentifier
        folderSettings = item.folderSettings
    }
}

@MainActor
enum LibraryFolderPreviewPolicy {
    static let maximumItemCount = 3

    static func previewItems(
        for folderID: UUID,
        candidates: [LibraryItemRecord]
    ) -> [LibraryFolderPreviewItem] {
        candidates.lazy
            .filter {
                $0.parentID == folderID
                    && $0.isTrashed == false
                    && $0.kind.isLegacyLibraryItem == false
            }
            .sorted { lhs, rhs in
                if lhs.activityDate != rhs.activityDate {
                    return lhs.activityDate > rhs.activityDate
                }
                if lhs.manualOrder != rhs.manualOrder {
                    return lhs.manualOrder < rhs.manualOrder
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(maximumItemCount)
            .map(LibraryFolderPreviewItem.init(item:))
    }
}

private func libraryEditorTransitionItemID(
    for item: LibraryItemRecord,
    in scope: LibraryScope
) -> UUID? {
    guard scope != .trash else { return nil }
    return switch item.kind {
    case .notebook, .canvas, .importedDocument, .attachment:
        item.id
    case .folder, .legacyTypedNote:
        nil
    }
}

struct LibraryGridCard: View {
    let item: LibraryItemRecord
    let isSelected: Bool
    let isSelectionMode: Bool
    let session: LibraryAppSession
    let folderNavigationNamespace: Namespace.ID
    let itemTransitionNamespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    @State private var restoresFocusAfterSheet = false

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .center, spacing: NotateDesign.Library.Shelf.labelSpacing) {
                ZStack(alignment: .topTrailing) {
                    LibraryItemArtwork(
                        item: item,
                        folderTitle: nil,
                        folderItemCount: session.cachedFolderItemCount(for: item),
                        placesFolderGlyphOnFront: item.kind == .folder,
                        folderPreviewItems: session.folderArtworkPreviewItems(for: item),
                        thumbnailStore: session.thumbnailStore
                    )
                    .aspectRatio(NotateDesign.Library.Shelf.artworkAspectRatio, contentMode: .fit)
                    .notateFolderGeometryTransition(
                        itemID: folderTransitionItemID,
                        in: folderNavigationNamespace,
                        isSource: true
                    )
                    .notateEditorGeometryTransition(
                        itemID: editorTransitionItemID,
                        in: itemTransitionNamespace,
                        isSource: true
                    )
                    .accessibilityHidden(true)
                    .overlay(alignment: .topLeading) {
                        if item.payloadState != .ready {
                            payloadBadge
                                .frame(width: 26, height: 26)
                                .background(.regularMaterial, in: Circle())
                                .padding(7)
                        }
                    }

                    if isSelectionMode {
                        NotateAppGlyph(
                            kind: .select,
                            tint: NotateLibraryDesign.accent,
                            isSelected: isSelected,
                            size: 24
                        )
                        .padding(4)
                        .notateBadgeSurface(in: Circle())
                        .padding(10)
                        .accessibilityHidden(true)
                    } else if item.isFavorite {
                        GeometryReader { proxy in
                            NotateAppGlyph(
                                kind: .favorite,
                                tint: NotateDesign.Palette.favorite,
                                isSelected: true,
                                size: 13
                            )
                            .frame(width: 24, height: 24)
                            .notateBadgeSurface(in: Circle())
                            .position(
                                x: proxy.size.width * favoriteBadgeXRatio,
                                y: favoriteBadgeY(in: proxy.size)
                            )
                        }
                        .accessibilityHidden(true)
                    }
                }

                VStack(spacing: NotateDesign.Library.Shelf.metadataSpacing) {
                    Text(item.name)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Color(uiColor: .label))
                        .tint(Color(uiColor: .label))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.center)
                        .fixedSize(
                            horizontal: false,
                            vertical: dynamicTypeSize.isAccessibilitySize
                        )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: dynamicTypeSize.isAccessibilitySize
                            ? nil : NotateDesign.Library.Shelf.titleHeight,
                        alignment: .top
                    )
                    .padding(.horizontal, 2)

                    if item.kind == .folder {
                        if let itemCount = session.cachedFolderItemCount(for: item) {
                            Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                                .font(.caption)
                                .foregroundStyle(Color(uiColor: .secondaryLabel))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        Text(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.vertical, 3)
            }
            .notateLibraryCardSurface(
                isSelected: isSelected,
                showsBackground: false
            )
            .contentShape(RoundedRectangle(cornerRadius: NotateLibraryDesign.Radius.card))
            .buttonStyle(LibraryCardPressStyle(reduceMotion: reduceMotion))
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity
                    )
            )
            .accessibilityIdentifier("library.item.\(item.id.uuidString)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityFocused($isAccessibilityFocused)
            .modifier(
                LibraryItemInteractionModifier(
                    item: item,
                    isSelected: isSelected,
                    session: session
                )
            )
            .onChange(of: session.sheet?.id) { _, sheetID in
                updateSheetFocusRestoration(sheetID: sheetID)
            }
        }
    }

    @ViewBuilder
    private var payloadBadge: some View {
        switch item.payloadState {
        case .creating, .importing:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(item.payloadState == .creating ? "Creating" : "Importing")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(NotateDesign.Palette.error)
                .accessibilityLabel("Import failed")
        case .missing:
            Image(systemName: "questionmark.folder.fill")
                .foregroundStyle(NotateDesign.Palette.warning)
                .accessibilityLabel("Content missing")
        case .ready:
            EmptyView()
        }
    }

    private func favoriteBadgeY(in size: CGSize) -> CGFloat {
        guard item.kind == .folder else { return 16 }
        let shelf = NotateDesign.Library.Shelf.self
        let folderWidth = min(size.width * shelf.folderWidthFraction,
                              size.height * shelf.folderAspectRatio)
        let folderHeight = folderWidth / shelf.folderAspectRatio
        return size.height - folderHeight + folderHeight * 0.25
    }

    private var favoriteBadgeXRatio: CGFloat {
        switch item.kind {
        case .notebook, .importedDocument: 0.78
        case .folder: 0.86
        case .legacyTypedNote, .canvas, .attachment: 0.94
        }
    }

    private var accessibilityLabel: String {
        "\(item.name)\(item.isFavorite ? ", Favorite" : "")"
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isSelectionMode {
            values.append(isSelected ? "Selected" : "Not selected")
        }
        switch item.payloadState {
        case .ready:
            break
        case .creating:
            values.append("Creating")
        case .importing:
            values.append("Importing")
        case .failed:
            values.append("Import failed")
        case .missing:
            values.append("Content missing")
        }
        if item.kind == .folder {
            if let itemCount = session.cachedFolderItemCount(for: item) {
                values.append("\(itemCount) \(itemCount == 1 ? "item" : "items")")
            }
        }
        return values.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if isSelectionMode { return "Double-tap to change selection" }
        if session.scope == .trash { return "Double-tap to restore" }
        return item.payloadState == .ready
            ? "Double-tap to open"
            : "Double-tap for status"
    }

    private func activate() {
        if isSelectionMode {
            withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.selection) {
                session.toggleSelection(item.id)
            }
        } else if session.scope == .trash {
            withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.removal) {
                session.actions.restoreItems([item.id])
            }
        } else if item.kind == .folder {
            withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.navigation) {
                session.open(item)
            }
        } else {
            // NavigationStack owns document motion. A second transaction here
            // competes with the native forward and button-driven reverse zoom.
            session.open(item)
        }
    }

    private var folderTransitionItemID: UUID? {
        item.kind == .folder && session.scope != .trash ? item.id : nil
    }

    private var editorTransitionItemID: UUID? {
        libraryEditorTransitionItemID(for: item, in: session.scope)
    }

    private func updateSheetFocusRestoration(sheetID: String?) {
        if sheetID != nil,
            let sheet = session.sheet,
            librarySheet(sheet, targets: item.id) {
            restoresFocusAfterSheet = true
        } else if sheetID == nil, restoresFocusAfterSheet {
            restoresFocusAfterSheet = false
            isAccessibilityFocused = true
        }
    }
}

struct LibraryListRow: View {
    let item: LibraryItemRecord
    let isSelected: Bool
    let isSelectionMode: Bool
    let session: LibraryAppSession
    let folderNavigationNamespace: Namespace.ID
    let itemTransitionNamespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    @State private var restoresFocusAfterSheet = false

    var body: some View {
        HStack(spacing: NotateDesign.Spacing.compact) {
            Button(action: activate) {
                HStack(spacing: NotateDesign.Spacing.control) {
                    if isSelectionMode {
                        NotateAppGlyph(
                            kind: .select,
                            tint: NotateDesign.accent,
                            isSelected: isSelected,
                            size: 23
                        )
                        .accessibilityHidden(true)
                    }

                    LibraryItemArtwork(
                        item: item,
                        folderItemCount: session.cachedFolderItemCount(for: item),
                        folderPreviewItems: session.folderArtworkPreviewItems(for: item),
                        thumbnailStore: session.thumbnailStore
                    )
                    .frame(
                        width: dynamicTypeSize.isAccessibilitySize ? 60 : 74,
                        height: dynamicTypeSize.isAccessibilitySize ? 48 : 56
                    )
                    .notateFolderGeometryTransition(
                        itemID: folderTransitionItemID,
                        in: folderNavigationNamespace,
                        isSource: true
                    )
                    .notateEditorGeometryTransition(
                        itemID: editorTransitionItemID,
                        in: itemTransitionNamespace,
                        isSource: true
                    )
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.name)
                                .font(.system(.headline, weight: .semibold))
                                .foregroundStyle(Color(uiColor: .label))
                                .tint(Color(uiColor: .label))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            if item.isFavorite {
                                NotateAppGlyph(
                                    kind: .favorite,
                                    tint: NotateDesign.Palette.favorite,
                                    isSelected: true,
                                    size: 15
                                )
                                .accessibilityHidden(true)
                            }
                        }
                        if item.kind == .folder {
                            if let itemCount = session.cachedFolderItemCount(for: item) {
                                Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            }
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: NotateDesign.Spacing.content)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityIdentifier("library.item.\(item.id.uuidString)")
            .accessibilityFocused($isAccessibilityFocused)
            .modifier(
                LibraryItemInteractionModifier(
                    item: item,
                    isSelected: isSelected,
                    session: session
                )
            )

            if isSelectionMode == false {
                Menu {
                    LibraryItemActionButtons(item: item, session: session)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                        .notateMinimumHitTarget()
                }
                .accessibilityLabel("More actions for \(item.name)")
            }
        }
        .padding(.horizontal, NotateDesign.Spacing.control)
        .padding(.vertical, NotateDesign.Spacing.compact)
        .notateLibraryCardSurface(isSelected: isSelected)
        .contentShape(Rectangle())
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity,
                    removal: .opacity.combined(with: .scale(scale: 0.98))
                )
        )
        .onChange(of: session.sheet?.id) { _, sheetID in
            updateSheetFocusRestoration(sheetID: sheetID)
        }
    }

    private var listMetadata: String {
        var parts: [String] = []
        if session.showsFolderPath {
            parts.append(session.folderPath(for: item))
        }
        parts.append(item.kind.libraryTitle)
        if item.kind == .folder {
            if let itemCount = session.cachedFolderItemCount(for: item) {
                parts.append("\(itemCount) item\(itemCount == 1 ? "" : "s")")
            }
        } else if item.pageCount > 0 {
            parts.append("\(item.pageCount) page\(item.pageCount == 1 ? "" : "s")")
        }
        parts.append("Modified \(modifiedDescription)")
        return parts.joined(separator: " · ")
    }

    private var modifiedDescription: String {
        item.modifiedAt.formatted(.relative(presentation: .named))
    }

    private var accessibilityLabel: String {
        "\(item.name)\(item.isFavorite ? ", Favorite" : "")"
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isSelectionMode {
            values.append(isSelected ? "Selected" : "Not selected")
        }
        if item.isFavorite {
            values.append("Favorite")
        }
        switch item.payloadState {
        case .ready:
            break
        case .creating:
            values.append("Creating")
        case .importing:
            values.append("Importing")
        case .failed:
            values.append("Import failed")
        case .missing:
            values.append("Content missing")
        }
        return values.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if isSelectionMode { return "Double-tap to change selection" }
        if session.scope == .trash { return "Double-tap to restore" }
        return item.payloadState == .ready
            ? "Double-tap to open"
            : "Double-tap for status"
    }

    private func activate() {
        if isSelectionMode {
            withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.selection) {
                session.toggleSelection(item.id)
            }
        } else if session.scope == .trash {
            withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.removal) {
                session.actions.restoreItems([item.id])
            }
        } else if item.kind == .folder {
            withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.navigation) {
                session.open(item)
            }
        } else {
            session.open(item)
        }
    }

    private var folderTransitionItemID: UUID? {
        item.kind == .folder && session.scope != .trash ? item.id : nil
    }

    private var editorTransitionItemID: UUID? {
        libraryEditorTransitionItemID(for: item, in: session.scope)
    }

    private func updateSheetFocusRestoration(sheetID: String?) {
        if sheetID != nil,
            let sheet = session.sheet,
            librarySheet(sheet, targets: item.id) {
            restoresFocusAfterSheet = true
        } else if sheetID == nil, restoresFocusAfterSheet {
            restoresFocusAfterSheet = false
            isAccessibilityFocused = true
        }
    }
}

private func librarySheet(_ destination: LibrarySheetDestination, targets itemID: UUID) -> Bool {
    switch destination {
    case let .folderAppearance(targetID),
        let .coverPicker(targetID),
        let .tagAssignment(targetID):
        targetID == itemID
    case let .move(itemIDs):
        itemIDs.count == 1 && itemIDs.contains(itemID)
    case .newTag, .editTag, .newFolder, .newNotebook:
        false
    }
}

/// Keeps active-library drag, drop, Favorite, and Move affordances out of
/// Trash and away from incomplete payloads. A trashed card has exactly two
/// recovery actions and its primary activation restores the item.
private struct LibraryItemInteractionModifier: ViewModifier {
    let item: LibraryItemRecord
    let isSelected: Bool
    let session: LibraryAppSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if session.canMutate == false && session.scope == .trash {
            content.disabled(true)
        } else if session.canMutate == false {
            content
        } else if session.isSelectionMode {
            content
        } else if session.scope == .trash {
            content
                .contextMenu { LibraryItemActionButtons(item: item, session: session) }
                .accessibilityAction(named: "Restore") {
                    withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.removal) {
                        session.actions.restoreItems([item.id])
                    }
                }
                .accessibilityAction(named: "Delete") {
                    session.requestPermanentDeletion([item.id])
                }
        } else if session.canUseActiveItemActions(for: item) {
            content
                .contextMenu { LibraryItemActionButtons(item: item, session: session) }
                .draggable(dragPayload)
                .modifier(LibraryFolderDropTarget(item: item, session: session))
                .accessibilityAction(
                    named: item.isFavorite ? "Remove from Favorites" : "Add to Favorites"
                ) {
                    session.actions.toggleFavorite(item.id)
                }
                .accessibilityAction(named: "Move") {
                    session.sheet = .move(itemIDs: [item.id])
                }
        } else {
            content
                .contextMenu { LibraryItemActionButtons(item: item, session: session) }
                .accessibilityAction(named: "Move to Trash") {
                    session.actions.moveToTrash([item.id])
                }
        }
    }

    private var dragPayload: LibraryDragPayload {
        let ids = isSelected ? session.selectedItemIDs : [item.id]
        return LibraryDragPayload(itemIDs: Array(ids))
    }
}

private struct LibraryCardPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && reduceMotion == false ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.feedback,
                value: configuration.isPressed
            )
    }
}

private struct LibraryFolderDropTarget: ViewModifier {
    let item: LibraryItemRecord
    let session: LibraryAppSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if item.kind == .folder && session.canUseActiveItemActions(for: item) {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: NotateLibraryDesign.Radius.card)
                        .strokeBorder(
                            NotateLibraryDesign.accent.opacity(isTargeted ? 0.82 : 0),
                            lineWidth: 2
                        )
                }
                .scaleEffect(isTargeted && reduceMotion == false ? 1.018 : 1)
                .animation(
                    reduceMotion ? nil : NotateDesign.Motion.selection,
                    value: isTargeted
                )
                .dropDestination(for: LibraryDragPayload.self) { payloads, _ in
                    let ids = Set(payloads.flatMap(\.itemIDs))
                    guard ids.isEmpty == false, ids.contains(item.id) == false else { return false }
                    var didMove = false
                    withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.removal) {
                        didMove = session.actions.moveItems(ids, item.id)
                    }
                    return didMove
                } isTargeted: { targeted in
                    isTargeted = targeted
                }
        } else {
            content
        }
    }
}

private struct…7812 tokens truncated…tside `body`, so unrelated view updates cannot repeatedly rebuild the
/// same `UIImage` and stall nearby control animations.
private struct LibraryDecodedCoverImage<Placeholder: View>: View {
    let imageData: Data?
    let cacheKey: String
    let placeholder: Placeholder

    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        imageData: Data?,
        cacheKey: String,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.imageData = imageData
        self.cacheKey = cacheKey
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.content,
            value: image != nil
        )
        .task(id: request) {
            image = nil
            guard let imageData else { return }
            let request = request
            let decoded = await Task.detached(priority: .userInitiated) {
                LibraryDecodedCoverImageCache.shared.image(
                    for: imageData,
                    cacheKey: request.resolvedCacheKey
                )
            }.value
            guard Task.isCancelled == false else { return }
            image = decoded
        }
    }

    private var request: LibraryDecodedCoverImageRequest {
        LibraryDecodedCoverImageRequest(
            cacheKey: cacheKey,
            byteCount: imageData?.count ?? 0
        )
    }
}

private struct LibraryDecodedCoverImageRequest: Hashable {
    let cacheKey: String
    let byteCount: Int

    var resolvedCacheKey: NSString {
        "\(cacheKey)#\(byteCount)" as NSString
    }
}

private final class LibraryDecodedCoverImageCache: @unchecked Sendable {
    static let shared = LibraryDecodedCoverImageCache()

    private let images = NSCache<NSString, UIImage>()

    private init() {
        images.countLimit = 24
        images.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for data: Data, cacheKey: NSString) -> UIImage? {
        if let cached = images.object(forKey: cacheKey) {
            return cached
        }
        guard let decoded = LibraryBoundedImageDecoder.downsampledImage(
            from: data,
            policy: .customCover
        ) else { return nil }
        let decodedCost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        images.setObject(decoded, forKey: cacheKey, cost: decodedCost)
        return decoded
    }
}

private struct LibraryPhysicalCoverArtwork: View {
    let cover: LibraryCuratedCover
    let title: String?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cornerRadius = min(max(size.width * 0.052, 7), 13)
            let spineWidth = min(max(size.width * 0.105, 11), 25)
            ZStack {
                cover.palette.top.coverColor
                LibraryCuratedCoverPattern(cover: cover)
                Rectangle()
                    .fill(cover.palette.spine.coverColor)
                    .frame(width: spineWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(.white.opacity(0.42))
                    .frame(width: max(1, size.width * 0.007))
                    .offset(x: spineWidth / 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.89))
                    .frame(width: max(2.5, size.width * 0.025))
                    .padding(.vertical, 0.42 * cornerRadius)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                LibraryCoverTitlePlaque(title: title, ink: cover.palette.ink.coverColor)
                    .frame(
                        width: size.width * 0.61,
                        height: min(max(size.height * 0.155, 38), 72)
                    )
                    .position(x: size.width * 0.56, y: size.height * 0.35)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.11), lineWidth: 0.8)
            }
        }
    }
}

private struct LibraryCuratedCoverPattern: View {
    let cover: LibraryCuratedCover

    var body: some View {
        Canvas { context, size in
            switch cover.motif {
            case .compositionSpeckle:
                drawCompositionSpeckles(in: context, size: size)
            case .orchardSprig:
                drawOrchardSprigs(in: context, size: size)
            case .candyStripe:
                drawCandyStripes(in: context, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawCompositionSpeckles(in context: GraphicsContext, size: CGSize) {
        guard size.width.isFinite,
            size.height.isFinite,
            size.width > 0,
            size.height > 0 else { return }
        let columns = Int(min(max(size.width / 23, 5), 8))
        let rows = Int(min(max(size.height / 25, 7), 11))
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        let color = cover.palette.pattern.coverColor.opacity(0.66)
        for row in 0..<rows {
            for column in 0..<columns {
                let seed = (row * 41 + column * 67 + row * column * 13) % 97
                let x = (CGFloat(column) + 0.24 + CGFloat(seed % 5) * 0.11) * cellWidth
                let y = (CGFloat(row) + 0.22 + CGFloat(seed % 7) * 0.075) * cellHeight
                let length = min(max(cellWidth * 0.20, 2.2), 5.0)
                let bend = CGFloat((seed % 3) - 1) * min(1.8, cellHeight * 0.12)
                var fleck = Path()
                if seed.isMultiple(of: 2) {
                    fleck.move(to: CGPoint(x: x - length / 2, y: y))
                    fleck.addQuadCurve(
                        to: CGPoint(x: x + length / 2, y: y + bend),
                        control: CGPoint(x: x, y: y - bend - 1)
                    )
                } else {
                    fleck.move(to: CGPoint(x: x, y: y - length / 2))
                    fleck.addQuadCurve(
                        to: CGPoint(x: x + bend, y: y + length / 2),
                        control: CGPoint(x: x - bend - 1, y: y)
                    )
                }
                context.stroke(
                    fleck,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
                )
                if seed.isMultiple(of: 7) {
                    let diameter = min(max(cellWidth * 0.10, 1.1), 2.1)
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: x + length * 0.54,
                                y: y - diameter / 2,
                                width: diameter,
                                height: diameter
                            )
                        ),
                        with: .color(color.opacity(0.72))
                    )
                }
            }
        }
    }

    private func drawOrchardSprigs(in context: GraphicsContext, size: CGSize) {
        guard size.width.isFinite,
            size.height.isFinite,
            size.width > 0,
            size.height > 0 else { return }
        let columns = Int(min(max(size.width / 38, 3), 5))
        let rows = Int(min(max(size.height / 42, 4), 7))
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        let leaf = cover.palette.pattern.coverColor.opacity(0.62)
        let stem = cover.palette.ink.coverColor.opacity(0.30)
        for row in 0..<rows {
            for column in 0..<columns {
                let seed = (row * 29 + column * 43 + row * column * 7) % 31
                let stagger = row.isMultiple(of: 2) ? cellWidth * 0.12 : -cellWidth * 0.12
                let center = CGPoint(
                    x: (CGFloat(column) + 0.50) * cellWidth + stagger,
                    y: (CGFloat(row) + 0.50) * cellHeight
                )
                let direction: CGFloat = seed.isMultiple(of: 2) ? 1 : -1
                let stemLength = min(max(cellHeight * 0.27, 6), 12)
                var stemPath = Path()
                stemPath.move(
                    to: CGPoint(
                        x: center.x - direction * stemLength * 0.34,
                        y: center.y + stemLength * 0.48
                    )
                )
                stemPath.addLine(
                    to: CGPoint(
                        x: center.x + direction * stemLength * 0.34,
                        y: center.y - stemLength * 0.48
                    )
                )
                context.stroke(
                    stemPath,
                    with: .color(stem),
                    style: StrokeStyle(lineWidth: 0.9, lineCap: .round)
                )
                let leafWidth = min(max(cellWidth * 0.20, 4.2), 8.0)
                let leafHeight = leafWidth * 0.66
                let firstLeaf = CGRect(
                    x: center.x - leafWidth * 0.92,
                    y: center.y - leafHeight * 0.88,
                    width: leafWidth,
                    height: leafHeight
                )
                let secondLeaf = CGRect(
                    x: center.x + leafWidth * 0.02,
                    y: center.y - leafHeight * 0.02,
                    width: leafWidth,
                    height: leafHeight
                )
                context.fill(Path(ellipseIn: firstLeaf), with: .color(leaf))
                context.fill(Path(ellipseIn: secondLeaf), with: .color(leaf.opacity(0.82)))
                if seed.isMultiple(of: 4) {
                    let blossom = min(max(cellWidth * 0.13, 2.8), 5.2)
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: center.x - blossom / 2,
                                y: center.y - stemLength * 0.70,
                                width: blossom,
                                height: blossom
                            )
                        ),
                        with: .color(Color.white.opacity(0.68))
                    )
                }
            }
        }
    }

    private func drawCandyStripes(in context: GraphicsContext, size: CGSize) {
        guard size.width.isFinite,
            size.height.isFinite,
            size.width > 0,
            size.height > 0 else { return }
        let stripeWidth = min(max(size.width / 8.8, 10), 24)
        let count = Int(min(max(size.width / stripeWidth, 5) + 1, 12))
        let stripe = cover.palette.pattern.coverColor.opacity(0.42)
        for index in 0..<count {
            let x = CGFloat(index) * stripeWidth * 1.58
            context.fill(
                Path(
                    CGRect(
                        x: x,
                        y: 0,
                        width: stripeWidth,
                        height: size.height
                    )
                ),
                with: .color(stripe)
            )
        }
    }
}

private struct LibraryCoverTitlePlaque: View {
    let title: String?
    let ink: Color

    private var displayTitle: String? {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfLibraryBlank
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: min(7, proxy.size.height * 0.15), style: .continuous)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.88))
                RoundedRectangle(cornerRadius: min(7, proxy.size.height * 0.15), style: .continuous)
                    .strokeBorder(ink.opacity(0.30), lineWidth: 0.9)
                    .padding(2.5)
                if let displayTitle {
                    // This duplicate is decorative; the card button below the cover
                    // owns the accessible title. Drawing it into the artwork keeps
                    // SwiftUI from assigning the entire patterned cover to a Text node
                    // during contrast analysis, while retaining the authored plaque.
                    Canvas { context, size in
                        let baseFontSize = min(max(size.width * 0.095, 8), 16)
                        let availableSize = CGSize(
                            width: size.width * 0.76,
                            height: size.height * 0.72
                        )
                        let estimatedTwoLineWidth = availableSize.width * 2
                        let estimatedTitleWidth = CGFloat(displayTitle.count) * baseFontSize * 0.56
                        let fittedFontSize = max(
                            baseFontSize * 0.58,
                            min(baseFontSize, baseFontSize * estimatedTwoLineWidth / max(estimatedTitleWidth, 1))
                        )
                        var resolvedTitle = context.resolve(
                            Text(displayTitle)
                                .font(
                                    .system(
                                        size: fittedFontSize,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                        )
                        resolvedTitle.shading = .color(
                            Color(red: 0.14, green: 0.11, blue: 0.13)
                        )
                        let measuredSize = resolvedTitle.measure(in: availableSize)
                        let drawingSize = CGSize(
                            width: min(measuredSize.width, availableSize.width),
                            height: min(measuredSize.height, availableSize.height)
                        )
                        context.draw(
                            resolvedTitle,
                            in: CGRect(
                                x: (size.width - drawingSize.width) / 2,
                                y: (size.height - drawingSize.height) / 2,
                                width: drawingSize.width,
                                height: drawingSize.height
                            )
                        )
                    }
                    .accessibilityHidden(true)
                } else {
                    VStack(spacing: max(4, proxy.size.height * 0.14)) {
                        Rectangle()
                            .fill(ink.opacity(0.38))
                        Rectangle().fill(ink.opacity(0.28))
                    }
                    .frame(width: proxy.size.width * 0.56)
                    .frame(height: max(6, proxy.size.height * 0.23))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LibraryAutomaticCoverArtwork: View {
    let title: String?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cornerRadius = min(max(size.width * 0.052, 7), 13)
            ZStack {
                Color(red: 0.985, green: 0.978, blue: 0.94)
                Canvas { context, canvasSize in
                    let spacing = min(max(canvasSize.height / 13, 9), 22)
                    var rules = Path()
                    for y in stride(
                        from: spacing * 2.2,
                        through: canvasSize.height - spacing * 0.65,
                        by: spacing
                    ) {
                        rules.move(to: CGPoint(x: spacing * 0.78, y: y))
                        rules.addLine(to: CGPoint(x: canvasSize.width - spacing * 0.55, y: y))
                    }
                    context.stroke(
                        rules,
                        with: .color(Color(red: 0.49, green: 0.67, blue: 0.81).opacity(0.24)),
                        lineWidth: 0.75
                    )
                }
                Rectangle()
                    .fill(Color(red: 0.89, green: 0.40, blue: 0.43).opacity(0.52))
                    .frame(width: max(1, size.width * 0.012))
                    .offset(x: size.width * 0.18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 5) {
                    Text("FIRST PAGE")
                        .font(.system(size: min(max(size.width * 0.055, 7), 11), weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Color(red: 0.27, green: 0.39, blue: 0.48).opacity(0.62))
                    if let displayTitle = title?.nilIfLibraryBlank {
                        Text(displayTitle)
                            .font(.system(size: min(max(size.width * 0.078, 8), 14), weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.24, green: 0.28, blue: 0.30))
                            .lineLimit(2)
                            .minimumScaleFactor(0.62)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, size.width * 0.20)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, size.height * 0.09)
                Rectangle()
                    .fill(Color(red: 0.91, green: 0.89, blue: 0.82))
                    .frame(width: max(2.5, size.width * 0.025))
                    .padding(.vertical, cornerRadius * 0.42)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.13), lineWidth: 0.8)
            }
        }
    }
}

private struct LibraryCustomCoverPlaceholder: View {
    let title: String?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2.weight(.regular))
                    .foregroundStyle(.secondary)
                Text(title?.nilIfLibraryBlank ?? "Custom cover")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 0.8)
        }
    }
}

private extension LibraryRGBAColor {
    var coverColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}












































private struct LibraryCanvasArtwork: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            drawDotField(context: &context, size: size)
            drawIdeaNote(context: &context, size: size)
            drawReferenceFrame(context: &context, size: size)
            drawConnector(context: &context, size: size)
        }
        .background(Color(uiColor: CanvasConstants.paperBackground))
    }

    private func drawDotField(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let spacing = max(min(size.width, size.height) * 0.072, 14)
        let diameter = max(min(size.width, size.height) * 0.005, 1)
        let inset = spacing * 0.72
        let color = Color.secondary.opacity(colorScheme == .dark ? 0.15 : 0.10)
        for x in stride(from: inset, to: size.width, by: spacing) {
            for y in stride(from: inset, to: size.height, by: spacing) {
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: x - diameter / 2,
                            y: y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                    ),
                    with: .color(color)
                )
            }
        }
    }

    private func drawIdeaNote(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let rect = CGRect(
            x: size.width * 0.13,
            y: size.height * 0.18,
            width: size.width * 0.25,
            height: size.height * 0.27
        )
        let shape = RoundedRectangle(
            cornerRadius: max(min(rect.width, rect.height) * 0.16, 5),
            style: .continuous
        ).path(in: rect)
        let accent = NotateLibraryDesign.accent
        context.fill(
            shape,
            with: .color(accent.opacity(colorScheme == .dark ? 0.20 : 0.12))
        )
        context.stroke(
            shape,
            with: .color(accent.opacity(colorScheme == .dark ? 0.42 : 0.24)),
            lineWidth: 0.8
        )
        let lineColor = Color.primary.opacity(colorScheme == .dark ? 0.36 : 0.24)
        for ratio in [0.40, 0.61] {
            var rule = Path()
            rule.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * ratio))
            rule.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * ratio))
            context.stroke(
                rule,
                with: .color(lineColor),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
            )
        }
    }

    private func drawReferenceFrame(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let rect = CGRect(
            x: size.width * 0.67,
            y: size.height * 0.19,
            width: size.width * 0.20,
            height: size.height * 0.25
        )
        let shape = RoundedRectangle(
            cornerRadius: max(min(rect.width, rect.height) * 0.14, 4),
            style: .continuous
        ).path(in: rect)
        let outline = Color.primary.opacity(colorScheme == .dark ? 0.40 : 0.28)
        context.fill(
            shape,
            with: .color(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.025))
        )
        context.stroke(shape, with: .color(outline), lineWidth: 1.1)
        var landscape = Path()
        landscape.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY - rect.height * 0.22))
        landscape.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.50))
        landscape.addLine(to: CGPoint(x: rect.minX + rect.width * 0.57, y: rect.minY + rect.height * 0.66))
        landscape.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.42))
        landscape.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY - rect.height * 0.22))
        context.stroke(
            landscape,
            with: .color(outline),
            style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawConnector(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let start = CGPoint(x: size.width * 0.25, y: size.height * 0.57)
        let end = CGPoint(x: size.width * 0.76, y: size.height * 0.55)
        var connector = Path()
        connector.move(to: start)
        connector.addCurve(
            to: end,
            control1: CGPoint(x: size.width * 0.37, y: size.height * 0.78),
            control2: CGPoint(x: size.width * 0.62, y: size.height * 0.34)
        )
        context.stroke(
            connector,
            with: .color(Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.58)),
            style: StrokeStyle(
                lineWidth: max(min(size.width, size.height) * 0.011, 1.8),
                lineCap: .round,
                lineJoin: .round
            )
        )
        let nodeDiameter = max(min(size.width, size.height) * 0.035, 6)
        let startNode = CGRect(
            x: start.x - nodeDiameter / 2,
            y: start.y - nodeDiameter / 2,
            width: nodeDiameter,
            height: nodeDiameter
        )
        let endNode = CGRect(
            x: end.x - nodeDiameter / 2,
            y: end.y - nodeDiameter / 2,
            width: nodeDiameter,
            height: nodeDiameter
        )
        context.fill(
            Path(ellipseIn: startNode),
            with: .color(Color(uiColor: CanvasConstants.paperBackground))
        )
        context.stroke(
            Path(ellipseIn: startNode),
            with: .color(Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.58)),
            lineWidth: 1.2
        )
        context.fill(
            Path(ellipseIn: endNode),
            with: .color(NotateLibraryDesign.accent.opacity(colorScheme == .dark ? 0.92 : 0.82))
        )
    }
}







private struct LibraryFileTypeArtwork: View {
    let filename: String?
    let contentTypeIdentifier: String?

    @Environment(\.colorScheme) private var colorScheme

    private var fallback: LibraryFileFallbackKind {
        LibraryFileFallbackKind.resolve(
            contentTypeIdentifier: contentTypeIdentifier,
            filename: filename
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    fallback.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.16),
                    Color(uiColor: .secondarySystemBackground),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(fallback.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.13))
                    Image(systemName: fallback.symbolName)
                        .font(.system(size: 31, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(fallback.accentColor)
                }
                .frame(width: 64, height: 64)
                Text(fallback.shortLabel(filename: filename))
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(fallback.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        fallback.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        in: Capsule()
                    )

                if let filename {
                    Text(filename)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A restrained folded corner keeps the fallback recognizably
            // file-like without impersonating a real content preview.
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 28, y: 0))
                path.addLine(to: CGPoint(x: 28, y: 28))
                path.closeSubpath()
            }
            .fill(Color(uiColor: .systemBackground).opacity(0.72))
            .frame(width: 28, height: 28)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.11), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.13), radius: 6, y: 4)
        .padding(.vertical, 3)
        .padding(.horizontal, 12)
    }
}



private extension LibraryItemKind {
    var libraryTitle: String {
        switch self {
        case .folder: "Folder"
        case .notebook: "Notebook"
        case .legacyTypedNote: "Legacy Item"
        case .canvas: "Legacy Canvas"
        case .importedDocument: "Document"
        case .attachment: "Attachment"
        }
    }
}

#if DEBUG
/// Future sheet formats are visual samples here, not new catalog item kinds.
#Preview("Library shelf · mixed formats", traits: .fixedLayout(width: 920, height: 720)) {
    LibraryShelfDesignPreview()
}

private struct LibraryShelfDesignPreview: View {
    private let samples = [
        LibraryItemRecord(name: "Personal", kind: .folder, folderSettings: .init(
            color: .init(red: 0.91, green: 0.31, blue: 0.62), symbolName: "basketball")),
        LibraryItemRecord(name: "Study", kind: .folder, folderSettings: .init(
            color: .init(red: 0.96, green: 0.70, blue: 0.12))),
        LibraryItemRecord(name: "Morning pages", kind: .notebook,
                          coverChoice: .preset(.softLinen)),
        LibraryItemRecord(name: "Reading notes", kind: .importedDocument,
                          sourceFilename: "Reading.pdf", sourceContentTypeIdentifier: "com.adobe.pdf")
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: 4),
                      spacing: NotateDesign.Library.Shelf.rowSpacing) {
                ForEach(samples) { item in
                    tile(title: item.name, metadata: item.kind == .folder ? "3 items" : "Today") {
                        LibraryItemArtwork(item: item, placesFolderGlyphOnFront: true)
                    }
                }
                tile(title: "A5 sheet", metadata: "Format example") {
                    LibraryShelfArtwork(aspectRatio: NotateDesign.Library.Shelf.aSeriesAspectRatio) {
                        sheetSample(color: .white)
                    }
                }
                tile(title: "Quick note", metadata: "Format example") {
                    LibraryShelfArtwork(aspectRatio: 4 / 3) {
                        sheetSample(color: Color(red: 1, green: 0.94, blue: 0.70))
                    }
                }
            }
            .padding(28)
        }
        .background(NotateDesign.Palette.background)
    }

    private func tile<Artwork: View>(title: String, metadata: String,
                                     @ViewBuilder artwork: () -> Artwork) -> some View {
        VStack(spacing: NotateDesign.Library.Shelf.labelSpacing) {
            artwork().aspectRatio(NotateDesign.Library.Shelf.artworkAspectRatio, contentMode: .fit)
            VStack(spacing: NotateDesign.Library.Shelf.metadataSpacing) {
                Text(title).font(.subheadline.weight(.medium))
                    .frame(height: NotateDesign.Library.Shelf.titleHeight, alignment: .top)
                Text(metadata).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sheetSample(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(color)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.2), lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}
#endif
