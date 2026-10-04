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
    static func artworkFitBounds(inside bounds: CGSize, inset: CGFloat = NotateDesign.Library.Shelf.artworkInset) -> CGSize {
        let scaledInset = inset * min(bounds.width, bounds.height)
            / 184
        return CGSize(width: max(0, bounds.width - scaledInset * 2),
                      height: max(0, bounds.height - scaledInset * 2))
    }

    static func folderSize(inside bounds: CGSize) -> CGSize {
        let shelf = NotateDesign.Library.Shelf.self
        let width = min(max(0, bounds.width) * shelf.folderWidthFraction,
                        artworkFitBounds(inside: bounds).height * shelf.folderAspectRatio)
        return CGSize(width: width, height: width / shelf.folderAspectRatio)
    }

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

                    .notateEditorGeometryTransition(
                        itemID: editorTransitionItemID,
                        in: itemTransitionNamespace,
                        isSource: true
                    )
                    .accessibilityHidden(true)
                    .overlayPreferenceValue(LibraryArtworkBoundsKey.self) { anchors in
                        GeometryReader { proxy in
                            // Nested thumbnail fitting can produce a smaller
                            // surface than its outer physical-format frame.
                            let bounds = anchors.map { proxy[$0] }
                                .min { $0.width * $0.height < $1.width * $1.height }
                                ?? CGRect(origin: .zero, size: proxy.size)
                            if item.payloadState != .ready {
                                payloadBadge
                                    .frame(width: 26, height: 26)
                                    .background(.regularMaterial, in: Circle())
                                    .position(x: bounds.minX + 20, y: bounds.minY + 20)
                            }
                            if isSelectionMode {
                                NotateAppGlyph(kind: .select,
                                               tint: NotateLibraryDesign.accent,
                                               isSelected: isSelected, size: 24)
                                    .padding(4)
                                    .notateBadgeSurface(in: Circle())
                                    .position(x: bounds.maxX - 16, y: bounds.minY + 16)
                            } else if item.isFavorite {
                                NotateAppGlyph(kind: .favorite,
                                               tint: NotateDesign.Palette.favorite,
                                               isSelected: true, size: 13)
                                    .frame(width: 24, height: 24)
                                    .notateBadgeSurface(in: Circle())
                                    .position(x: bounds.maxX - 12, y: bounds.minY + 12)
                            }
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
                    .frame(maxWidth: .infinity, alignment: .top)
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

private struct LibraryItemActionButtons: View {
    let item: LibraryItemRecord
    let session: LibraryAppSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if session.scope == .trash {
            Button {
                withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.removal) {
                    session.actions.restoreItems([item.id])
                }
            } label: {
                LibraryMenuActionLabel(
                    title: "Restore",
                    systemImage: "arrow.uturn.backward"
                )
            }
            Button(role: .destructive) {
                session.requestPermanentDeletion([item.id])
            } label: {
                LibraryMenuActionLabel(
                    title: "Delete Permanently",
                    systemImage: "trash",
                    isDestructive: true
                )
            }
        } else if item.payloadState != .ready {
            Button(role: .destructive) {
                session.actions.moveToTrash([item.id])
            } label: {
                LibraryMenuActionLabel(
                    title: "Move to Trash",
                    systemImage: "trash",
                    isDestructive: true
                )
            }
        } else {
            Button {
                if item.kind == .folder {
                    withAnimation(reduceMotion ? nil : NotateLibraryDesign.Motion.navigation) {
                        session.open(item)
                    }
                } else {
                    session.open(item)
                }
            } label: {
                LibraryMenuActionLabel(
                    title: "Open",
                    systemImage: "arrow.up.forward.app"
                )
            }
            Button {
                session.namePrompt = LibraryNamePrompt(
                    target: .rename(itemID: item.id),
                    draftName: item.name
                )
            } label: {
                LibraryMenuActionLabel(title: "Rename", systemImage: "pencil")
            }
            Button {
                session.actions.toggleFavorite(item.id)
            } label: {
                LibraryMenuActionLabel(
                    title: item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: item.isFavorite ? "star.slash" : "star"
                )
            }
            Button {
                session.sheet = .tagAssignment(itemID: item.id)
            } label: {
                LibraryMenuActionLabel(title: "Tags…", systemImage: "tag")
            }
            if item.kind == .folder {
                Button {
                    session.actions.duplicateItem(item.id)
                } label: {
                    LibraryMenuActionLabel(
                        title: "Duplicate",
                        systemImage: "plus.square.on.square"
                    )
                }
                Button {
                    session.sheet = .move(itemIDs: [item.id])
                } label: {
                    LibraryMenuActionLabel(title: "Move…", systemImage: "folder")
                }
                Button {
                    session.sheet = .folderAppearance(itemID: item.id)
                } label: {
                    LibraryMenuActionLabel(
                        title: "Change Appearance",
                        systemImage: "paintpalette"
                    )
                }
            } else {
                Button {
                    session.sheet = .move(itemIDs: [item.id])
                } label: {
                    LibraryMenuActionLabel(title: "Move…", systemImage: "folder")
                }
                Button {
                    session.actions.duplicateItem(item.id)
                } label: {
                    LibraryMenuActionLabel(
                        title: "Duplicate",
                        systemImage: "plus.square.on.square"
                    )
                }
                Button {
                    session.sheet = .coverPicker(itemID: item.id)
                } label: {
                    LibraryMenuActionLabel(
                        title: "Set Cover",
                        systemImage: "photo.on.rectangle.angled"
                    )
                }
            }
            Divider()
            Button(role: .destructive) {
                session.actions.moveToTrash([item.id])
            } label: {
                LibraryMenuActionLabel(
                    title: "Move to Trash",
                    systemImage: "trash",
                    isDestructive: true
                )
            }
        }
    }
}

struct LibraryItemArtwork: View {
    let item: LibraryItemRecord
    var folderTitle: String? = nil
    var folderItemCount: Int? = nil
    var placesFolderGlyphOnFront = false
    let folderPreviewItems: [LibraryFolderPreviewItem]
    let thumbnailStore: LibraryAutomaticThumbnailStore

    init(
        item: LibraryItemRecord,
        folderTitle: String? = nil,
        folderItemCount: Int? = nil,
        placesFolderGlyphOnFront: Bool = false,
        folderPreviewItems: [LibraryFolderPreviewItem] = [],
        thumbnailStore: LibraryAutomaticThumbnailStore = .shared
    ) {
        self.item = item
        self.folderTitle = folderTitle
        self.folderItemCount = folderItemCount
        self.placesFolderGlyphOnFront = placesFolderGlyphOnFront
        self.folderPreviewItems = folderPreviewItems
        self.thumbnailStore = thumbnailStore
    }

    @ViewBuilder
    var body: some View {
        switch LibraryArtworkSilhouette.resolve(for: item.kind) {
        case .finderFolder:
            LibraryFolderArtwork(
                symbolName: item.folderSettings?.symbolName ?? "basketball",
                color: (item.folderSettings?.color ?? .folderBlue).swiftUIColor,
                title: folderTitle,
                itemCount: folderItemCount,
                showsBackdrop: false,
                placesGlyphOnFront: placesFolderGlyphOnFront,
                previewItems: folderPreviewItems,
                thumbnailStore: thumbnailStore
            )
            .accessibilityHidden(true)
        case .portraitPage:
            LibraryShelfArtwork(aspectRatio: NotateDesign.Library.Shelf.notebookAspectRatio) {
                LibraryNonFolderArtwork(item: item, thumbnailStore: thumbnailStore)
            }
            .accessibilityHidden(true)
        case .landscapeBoard:
            LibraryShelfArtwork(aspectRatio: CanvasConstants.freeformLibraryAspectRatio) {
                LibraryNonFolderArtwork(item: item, thumbnailStore: thumbnailStore)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    }
            }
            .accessibilityHidden(true)
        case .sourceDocument:
            // Durable previews retain their authored aspect ratio. There is no
            // landscape backing plate behind a portrait PDF or photograph.
            LibraryNonFolderArtwork(item: item, thumbnailStore: thumbnailStore)
                .accessibilityHidden(true)
        }
    }
}

/// Physical formats share one shelf envelope and bottom edge. Supply a width /
/// height ratio (including A5 or a landscape quick note); never crop to the lane.
struct LibraryShelfArtwork<Content: View>: View {
    let aspectRatio: CGFloat
    let content: Content

    init(aspectRatio: CGFloat, @ViewBuilder content: () -> Content) {
        self.aspectRatio = aspectRatio
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let inset = NotateDesign.Library.Shelf.artworkInset
            let size = LibraryArtworkGeometry.aspectFitSize(
                source: CGSize(width: aspectRatio, height: 1),
                inside: LibraryArtworkGeometry.artworkFitBounds(inside: proxy.size)
            )
            content
                .frame(width: size.width, height: size.height)
                .libraryArtworkBounds()
                .position(x: proxy.size.width / 2,
                          y: proxy.size.height - inset - size.height / 2)
        }
    }
}

private struct LibraryNonFolderArtwork: View {
    let item: LibraryItemRecord
    let thumbnailStore: LibraryAutomaticThumbnailStore

    private var generatedFallback: LibraryGeneratedTitleFallback {
        LibraryGeneratedTitleFallback(kind: item.kind, title: item.name)
    }

    private var coverResolution: LibraryArtworkResolution {
        LibraryArtworkResolver.resolve(
            coverChoice: item.coverChoice,
            thumbnailData: nil,
            generatedFallback: generatedFallback
        )
    }

    var body: some View {
        switch coverResolution {
        case .automaticThumbnail, .generatedTitle:
            LibraryAutomaticThumbnail(
                itemID: item.id,
                previewGeneration: item.previewGeneration,
                generatedFallback: generatedFallback,
                thumbnailStore: thumbnailStore
            ) {
                if item.kind == .canvas {
                    // A blank canvas should still read as a miniature working
                    // board. Its title already lives below the artwork, so an
                    // additional in-preview title would compete with both the
                    // composition and the real preview that replaces it.
                    LibraryCanvasArtwork()
                } else if item.kind == .notebook {
                    LibraryGeneratedTitleArtwork(fallback: generatedFallback) {
                        fallbackArtwork
                    }
                } else {
                    LibraryShelfArtwork(aspectRatio: NotateDesign.Library.Shelf.notebookAspectRatio) {
                        LibraryGeneratedTitleArtwork(fallback: generatedFallback) {
                            fallbackArtwork
                        }
                    }
                }
            }
        case .explicitCover(.customAsset):
            // Custom covers are durable page-one images. Reuse the verified
            // preview pipeline so cards never decode full-resolution source
            // photos while scrolling.
            LibraryAutomaticThumbnail(
                itemID: item.id,
                previewGeneration: item.previewGeneration,
                generatedFallback: generatedFallback,
                thumbnailStore: thumbnailStore
            ) {
                if LibraryArtworkSilhouette.resolve(for: item.kind) == .sourceDocument {
                    LibraryShelfArtwork(aspectRatio: NotateDesign.Library.Shelf.notebookAspectRatio) {
                        LibraryCustomCoverPlaceholder(title: item.name)
                    }
                } else {
                    LibraryCustomCoverPlaceholder(title: item.name)
                }
            }
        case let .explicitCover(choice):
            // A deliberate cover choice always wins over a generated page
            // thumbnail, even when a thumbnail is already cached on disk.
            if item.kind == .canvas {
                LibraryCoverArtwork(choice: choice, title: item.name)
                    .aspectRatio(
                        LibraryArtworkSilhouette.landscapeBoard.preferredAspectRatio,
                        contentMode: .fill
                    )
                    .clipped()
            } else if LibraryArtworkSilhouette.resolve(for: item.kind) == .sourceDocument {
                LibraryShelfArtwork(aspectRatio: NotateDesign.Library.Shelf.notebookAspectRatio) {
                    LibraryNotebookArtwork(coverChoice: choice, title: item.name, verticalPadding: 0)
                }
            } else {
                LibraryNotebookArtwork(coverChoice: choice, title: item.name, verticalPadding: 0)
            }
        }
    }

    @ViewBuilder
    private var fallbackArtwork: some View {
        switch item.kind {
        case .folder:
            LibraryFolderArtwork(
                symbolName: item.folderSettings?.symbolName ?? "basketball",
                color: (item.folderSettings?.color ?? .folderBlue).swiftUIColor
            )
        case .notebook:
            LibraryAutomaticNotebookArtwork()
        case .canvas:
            LibraryCanvasArtwork()
        case .legacyTypedNote, .importedDocument, .attachment:
            LibraryFileTypeArtwork(
                filename: item.sourceFilename,
                contentTypeIdentifier: item.sourceContentTypeIdentifier
            )
        }
    }
}

private struct LibraryAutomaticThumbnail<Placeholder: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let itemID: UUID
    let previewGeneration: Int64
    let generatedFallback: LibraryGeneratedTitleFallback
    let thumbnailStore: LibraryAutomaticThumbnailStore
    let placeholder: Placeholder

    @State private var thumbnailImage: UIImage?

    init(
        itemID: UUID,
        previewGeneration: Int64,
        generatedFallback: LibraryGeneratedTitleFallback,
        thumbnailStore: LibraryAutomaticThumbnailStore,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.itemID = itemID
        self.previewGeneration = previewGeneration
        self.generatedFallback = generatedFallback
        self.thumbnailStore = thumbnailStore
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let thumbnailImage {
                loadedArtwork(thumbnailImage)
                    .transition(.opacity)
            } else {
                placeholder
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.content,
            value: thumbnailImage != nil
        )
        .task(id: LibraryThumbnailRequest(
            itemID: itemID,
            previewGeneration: previewGeneration
        )) {
            let data = await thumbnailStore.data(for: itemID)
            guard Task.isCancelled == false else { return }
            guard let data else {
                thumbnailImage = nil
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                LibraryBoundedImageDecoder.downsampledImage(
                    from: data,
                    policy: .durableThumbnail
                )
            }.value
            guard Task.isCancelled == false else { return }
            thumbnailImage = decoded
        }
    }

    @ViewBuilder
    private func loadedArtwork(_ image: UIImage) -> some View {
        switch LibraryArtworkSilhouette.resolve(for: generatedFallback.kind) {
        case .landscapeBoard:
            LibraryFittedThumbnailArtwork(image: image, inset: 0)
        case .portraitPage:
            LibraryFittedThumbnailArtwork(image: image, inset: 0)
        case .sourceDocument:
            LibraryFittedThumbnailArtwork(image: image)
        case .finderFolder:
            // Folder previews are generated by the live Finder-style artwork,
            // never by a page thumbnail.
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        }
    }
}

private struct LibraryFittedThumbnailArtwork: View {
    let image: UIImage
    var inset: CGFloat = NotateDesign.Library.Shelf.artworkInset

    var body: some View {
        GeometryReader { proxy in
            let availableSize = LibraryArtworkGeometry.artworkFitBounds(inside: proxy.size, inset: inset)
            let fittedSize = LibraryArtworkGeometry.aspectFitSize(
                source: image.size,
                inside: availableSize
            )

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: fittedSize.width, height: fittedSize.height)
                .libraryArtworkBounds()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.11), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 6, y: 4)
                .position(x: proxy.size.width / 2, y: proxy.size.height - inset - fittedSize.height / 2)
        }
    }
}

enum LibraryArtworkResolution: Equatable {
    case explicitCover(LibraryCoverChoice)
    case automaticThumbnail
    case generatedTitle(LibraryGeneratedTitleFallback)
}

/// The final, file-independent artwork input after explicit covers and valid
/// durable previews have both been ruled out. Keeping the item kind and title
/// in the resolution makes it impossible for a non-folder card to silently
/// fall back to an unrelated stock cover.
struct LibraryGeneratedTitleFallback: Equatable, Hashable, Sendable {
    let kind: LibraryItemKind
    let title: String

    init(kind: LibraryItemKind, title: String) {
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfLibraryBlank ?? kind.title
    }
}

/// Keeps cover precedence and preview validation independent from SwiftUI's
/// asynchronous loading lifecycle, so a broken durable preview can never
/// displace either a deliberate cover or the generated title fallback.
enum LibraryArtworkResolver {
    static func resolve(
        coverChoice: LibraryCoverChoice,
        thumbnailData: Data?,
        generatedFallback: LibraryGeneratedTitleFallback
    ) -> LibraryArtworkResolution {
        guard coverChoice == .automatic else {
            return .explicitCover(coverChoice)
        }
        guard let thumbnailData, isValidThumbnailData(thumbnailData) else {
            return .generatedTitle(generatedFallback)
        }
        return .automaticThumbnail
    }

    static func isValidThumbnailData(_ data: Data) -> Bool {
        LibraryBoundedImageDecoder.metadata(
            for: data,
            policy: .durableThumbnail
        ) != nil
    }
}

struct LibraryImageDecodePolicy: Sendable {
    let maximumEncodedByteCount: Int
    let maximumSourcePixelDimension: Int
    let maximumSourcePixelCount: Int
    let maximumDecodedPixelDimension: Int

    static let durableThumbnail = LibraryImageDecodePolicy(
        maximumEncodedByteCount: 8 * 1_024 * 1_024,
        maximumSourcePixelDimension: 4_096,
        maximumSourcePixelCount: 16_777_216,
        maximumDecodedPixelDimension: 1_024
    )

    static let customCover = LibraryImageDecodePolicy(
        maximumEncodedByteCount: LibraryAssetReadLimits.customCoverEncodedByteCount,
        maximumSourcePixelDimension: 32_768,
        maximumSourcePixelCount: 160_000_000,
        maximumDecodedPixelDimension: 1_024
    )
}

struct LibraryImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
}

/// ImageIO can inspect dimensions without allocating the full raster. Only
/// metadata-safe payloads reach the thumbnail API, which performs one bounded
/// decode suitable for library cards and cover-picker tiles.
enum LibraryBoundedImageDecoder {
    static func metadata(for data: Data, policy: LibraryImageDecodePolicy) -> LibraryImageMetadata? {
        guard data.isEmpty == false,
            data.count <= policy.maximumEncodedByteCount else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            options as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else { return nil }
        let status = CGImageSourceGetStatusAtIndex(source, 0)
        guard status != .statusInvalidData,
            status != .statusUnexpectedEOF else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            options as CFDictionary
        ) as? [CFString: Any],
            let width = positiveInteger(properties[kCGImagePropertyPixelWidth]),
            let height = positiveInteger(properties[kCGImagePropertyPixelHeight]),
            width <= policy.maximumSourcePixelDimension,
            height <= policy.maximumSourcePixelDimension else { return nil }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard overflow == false,
            pixelCount <= policy.maximumSourcePixelCount else { return nil }
        return LibraryImageMetadata(pixelWidth: width, pixelHeight: height)
    }

    static func downsampledImage(
        from data: Data,
        policy: LibraryImageDecodePolicy
    ) -> UIImage? {
        guard metadata(for: data, policy: policy) != nil else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: policy.maximumDecodedPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ), image.width <= policy.maximumDecodedPixelDimension,
            image.height <= policy.maximumDecodedPixelDimension else { return nil }
        return UIImage(cgImage: image)
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let integer = number.int64Value
        guard integer > 0, UInt64(integer) <= UInt64(Int.max) else { return nil }
        return Int(integer)
    }
}

private struct LibraryThumbnailRequest: Hashable {
    let itemID: UUID
    let previewGeneration: Int64
}

actor LibraryAutomaticThumbnailStore {
    private struct CacheEntry {
        let identity: LibraryRegularFileIdentity
        let data: Data
    }

    static let shared = LibraryAutomaticThumbnailStore(
        libraryRoot: NotateUITestLaunchConfiguration.isEnabled
            ? NotateUITestLaunchConfiguration.isolatedLibraryRoot
            : nil
    )

    private static let defaultMaximumCachedItemCount = 96
    private static let defaultMaximumCachedByteCount = 32 * 1_024 * 1_024

    private var cache: [UUID: CacheEntry] = [:]
    private var cacheRecency: [UUID] = []
    private var cachedByteCount = 0
    private let libraryRoot: URL?
    private let maximumCachedItemCount: Int
    private let maximumCachedByteCount: Int
    private let maximumEncodedByteCount: Int

    init(
        libraryRoot: URL? = nil,
        maximumCachedItemCount: Int = defaultMaximumCachedItemCount,
        maximumCachedByteCount: Int = defaultMaximumCachedByteCount,
        maximumEncodedByteCount: Int = LibraryImageDecodePolicy.durableThumbnail.maximumEncodedByteCount
    ) {
        self.libraryRoot = libraryRoot?.standardizedFileURL
        self.maximumCachedItemCount = max(1, maximumCachedItemCount)
        self.maximumCachedByteCount = max(1, maximumCachedByteCount)
        self.maximumEncodedByteCount = max(1, maximumEncodedByteCount)
    }

    func data(for itemID: UUID) -> Data? {
        guard let root = resolvedLibraryRoot(),
            let url = thumbnailURL(for: itemID, libraryRoot: root) else {
            removeCachedItem(itemID)
            return nil
        }

        guard let identity = try? LibraryBoundedFileReader.identity(
            at: url,
            inside: root,
            maximumByteCount: maximumEncodedByteCount
        ) else {
            removeCachedItem(itemID)
            return nil
        }

        if let cached = cache[itemID], cached.identity == identity {
            markRecentlyUsed(itemID)
            return cached.data
        }

        guard let boundedRead = try? LibraryBoundedFileReader.read(
            at: url,
            inside: root,
            maximumByteCount: maximumEncodedByteCount
        ), LibraryArtworkResolver.isValidThumbnailData(boundedRead.data) else {
            removeCachedItem(itemID)
            return nil
        }

        cache(boundedRead.data, identity: identity, for: itemID)
        return boundedRead.data
    }

    func invalidate(itemIDs: Set<UUID>) {
        for itemID in itemIDs {
            removeCachedItem(itemID)
        }
    }

    #if DEBUG
    var cachedItemIDsForTesting: Set<UUID> {
        Set(cache.keys)
    }

    var cachedByteCountForTesting: Int {
        cachedByteCount
    }
    #endif

    private func markRecentlyUsed(_ itemID: UUID) {
        cacheRecency.removeAll { $0 == itemID }
        cacheRecency.append(itemID)
        while cacheRecency.count > maximumCachedItemCount
            || cachedByteCount > maximumCachedByteCount {
            let evictedID = cacheRecency.removeFirst()
            if let evicted = cache.removeValue(forKey: evictedID) {
                cachedByteCount -= evicted.data.count
            }
        }
    }

    private func cache(
        _ data: Data,
        identity: LibraryRegularFileIdentity,
        for itemID: UUID
    ) {
        removeCachedItem(itemID)
        guard data.count <= maximumCachedByteCount else { return }
        cache[itemID] = CacheEntry(identity: identity, data: data)
        cachedByteCount += data.count
        markRecentlyUsed(itemID)
    }

    private func removeCachedItem(_ itemID: UUID) {
        if let removed = cache.removeValue(forKey: itemID) {
            cachedByteCount -= removed.data.count
        }
        cacheRecency.removeAll { $0 == itemID }
    }

    private func resolvedLibraryRoot() -> URL? {
        if let libraryRoot { return libraryRoot }
        guard let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return applicationSupport
            .appendingPathComponent("NotateLibrary", isDirectory: true)
            .standardizedFileURL
    }

    private func thumbnailURL(for itemID: UUID, libraryRoot: URL) -> URL? {
        guard itemID.uuidString.isEmpty == false else { return nil }
        return libraryRoot
            .appendingPathComponent("Items", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("library.png", isDirectory: false)
    }
}

/// Original, semantic fallback artwork used only when no explicit cover or
/// verified durable preview exists. The card already presents the item name
/// and kind as scalable text, so this thumbnail stays purely illustrative and
/// never creates a second, fixed-size copy of that information.
private struct LibraryGeneratedTitleArtwork<Background: View>: View {
    let fallback: LibraryGeneratedTitleFallback
    let background: Background

    init(
        fallback: LibraryGeneratedTitleFallback,
        @ViewBuilder background: () -> Background
    ) {
        self.fallback = fallback
        self.background = background()
    }

    var body: some View {
        ZStack {
            background
            LinearGradient(
                colors: [
                    .clear,
                    Color(uiColor: .systemBackground).opacity(0.42),
                    Color(uiColor: .systemBackground).opacity(0.92),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            Image(systemName: fallback.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(14)
                .accessibilityHidden(true)
        }
    }
}

/// A clean, blank page for Automatic mode. Curated covers remain explicit
/// choices; a new notebook starts as an unruled sheet in either appearance.
private struct LibraryAutomaticNotebookArtwork: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(uiColor: .systemBackground)
        .aspectRatio(595 / 842, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.7)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.28 : 0.12),
            radius: 7,
            y: 4
        )
    }
}

private extension LibraryGeneratedTitleFallback {
    var symbolName: String {
        switch kind {
        case .folder: "folder"
        case .notebook: "book.closed"
        case .legacyTypedNote: "doc"
        case .canvas: "scribble.variable"
        case .importedDocument: "doc.richtext"
        case .attachment: "paperclip"
        }
    }

    var accentColor: Color {
        switch kind {
        case .folder, .notebook: NotateLibraryDesign.accent
        case .legacyTypedNote: .secondary
        case .canvas: .indigo
        case .importedDocument: .orange
        case .attachment: .teal
        }
    }
}

struct LibraryNotebookArtwork: View {
    let coverChoice: LibraryCoverChoice
    var title: String? = nil
    var verticalPadding: CGFloat = 3

    var body: some View {
        LibraryCoverArtwork(choice: coverChoice, title: title)
            .aspectRatio(2 / 3, contentMode: .fit)
            .padding(.vertical, verticalPadding)
            .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
    }
}

struct LibraryCoverArtwork: View {
    let choice: LibraryCoverChoice
    var title: String? = nil
    var customImageData: Data? = nil

    var body: some View {
        Group {
            switch choice {
            case .automatic:
                LibraryNoCoverArtwork()
            case .noCover:
                LibraryNoCoverArtwork()
            case let .preset(preset):
                if let cover = LibraryCuratedCover.curated.first(where: { $0.preset == preset }) {
                    LibraryPhysicalCoverArtwork(cover: cover, title: title)
                } else {
                    LibraryNoCoverArtwork()
                }
            case .customAsset:
                LibraryDecodedCoverImage(
                    imageData: customImageData,
                    cacheKey: customImageCacheKey
                ) {
                    LibraryCustomCoverPlaceholder(title: title)
                }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: NotateDesign.Radius.option,
                style: .continuous
            )
        )
    }

    private var customImageCacheKey: String {
        guard case let .customAsset(relativePath) = choice else {
            return "library-cover"
        }
        return relativePath
    }
}

private struct LibraryNoCoverArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color(red: 0.97, green: 0.96, blue: 0.92)
                Rectangle()
                    .fill(Color(red: 0.72, green: 0.70, blue: 0.63).opacity(0.54))
                    .frame(width: max(1, size.width * 0.012))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "book.closed")
                    .font(.system(size: min(max(size.width * 0.22, 22), 42), weight: .light))
                    .foregroundStyle(Color(red: 0.47, green: 0.48, blue: 0.43).opacity(0.66))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Decodes a user-selected cover once per stable view identity and reuses the
/// result when picker/card views are recreated. Decoding is deliberately kept
/// outside `body`, so unrelated view updates cannot repeatedly rebuild the
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
            ZStack {
                if let image = LibraryCoverArtAtlas.image(for: cover.preset) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [cover.palette.top.coverColor, cover.palette.bottom.coverColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                if let displayTitle = title?.nilIfLibraryBlank {
                    Text(displayTitle)
                        .font(.system(size: min(max(size.width * 0.056, 8), 13), weight: .semibold))
                        .foregroundStyle(cover.palette.ink.coverColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.62)
                        .frame(width: size.width * 0.54, height: size.height * 0.13)
                        .position(x: size.width * 0.50, y: size.height * labelCenterY)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.11), lineWidth: 0.8)
            }
        }
    }

    private var labelCenterY: CGFloat {
        switch cover.preset {
        case .softLinen, .blueprint, .warmPaper: 0.36
        case .skyComposition: 0.42
        case .peachOrchard, .butterStripe: 0.39
        case .aquaComposition, .periwinkleOrchard: 0.28
        }
    }
}

@MainActor
private enum LibraryCoverArtAtlas {
    private static var cache: [LibraryCoverPreset: UIImage] = [:]

    static func image(for preset: LibraryCoverPreset) -> UIImage? {
        if let cached = cache[preset] { return cached }
        let location = location(for: preset)
        guard let atlas = UIImage(named: location.assetName)?.cgImage,
              atlas.width.isMultiple(of: 2) else { return nil }
        let cellWidth = atlas.width / 2
        let rect = CGRect(
            x: CGFloat(location.column * cellWidth),
            y: 0,
            width: CGFloat(cellWidth),
            height: CGFloat(atlas.height)
        )
        guard let crop = atlas.cropping(to: rect) else { return nil }
        let image = UIImage(cgImage: crop, scale: 1, orientation: .up)
        cache[preset] = image
        return image
    }

    private static func location(
        for preset: LibraryCoverPreset
    ) -> (assetName: String, column: Int) {
        switch preset {
        case .softLinen: ("NotebookCoverHeartsStripe", 0)
        case .blueprint: ("NotebookCoverHeartsStripe", 1)
        case .warmPaper: ("NotebookCoverBlueStripeBow", 0)
        case .skyComposition: ("NotebookCoverBlueStripeBow", 1)
        case .peachOrchard: ("NotebookCoverCompositionGrid", 0)
        case .butterStripe: ("NotebookCoverCompositionGrid", 1)
        case .aquaComposition: ("NotebookCoverBlushSandstone", 0)
        case .periwinkleOrchard: ("NotebookCoverBlushSandstone", 1)
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
        GeometryReader { proxy in
            let layout = LibraryShelfLayout(availableWidth: proxy.size.width,
                                           horizontalPadding: 28,
                                           zoom: NotateDesign.Library.Shelf.comfortableZoom)
            ScrollView {
                LazyVGrid(columns: layout.columns,
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
        }
        .background(NotateDesign.Palette.background)
    }

    private func tile<Artwork: View>(title: String, metadata: String,
                                     @ViewBuilder artwork: () -> Artwork) -> some View {
        VStack(spacing: NotateDesign.Library.Shelf.labelSpacing) {
            artwork().aspectRatio(NotateDesign.Library.Shelf.artworkAspectRatio, contentMode: .fit)
                .frame(width: NotateDesign.Library.Shelf.comfortableEnvelope)
            VStack(spacing: NotateDesign.Library.Shelf.metadataSpacing) {
                Text(title).font(.subheadline.weight(.medium))
                    .lineLimit(2)
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
