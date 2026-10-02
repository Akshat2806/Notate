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
        case .finderFolder: 1.42
        case .portraitPage: 3 / 4
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
                    && $0.payloadState == .ready
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

private extension LibraryAppSession {
    func folderPreviewItems(for item: LibraryItemRecord) -> [LibraryFolderPreviewItem] {
        guard item.kind == .folder, scope != .trash else { return [] }
        return LibraryFolderPreviewPolicy.previewItems(
            for: item.id,
            candidates: repository.items
        )
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
    @ScaledMetric(relativeTo: .caption2) private var metadataFontSize: CGFloat = 11
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    @State private var restoresFocusAfterSheet = false

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .center, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    LibraryItemArtwork(
                        item: item,
                        folderPreviewItems: session.folderPreviewItems(for: item),
                        thumbnailStore: session.thumbnailStore
                    )
                    .aspectRatio(4 / 3, contentMode: .fit)
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
                                y: 16
                            )
                        }
                        .accessibilityHidden(true)
                    }
                }

                VStack(alignment: .center, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color(uiColor: .label))
                            .tint(Color(uiColor: .label))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .multilineTextAlignment(.center)
                            .fixedSize(
                                horizontal: false,
                                vertical: dynamicTypeSize.isAccessibilitySize
                            )
                        payloadBadge
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Text(metadata)
                        .font(.system(size: metadataFontSize))
                        .foregroundStyle(.primary.opacity(0.72))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.center)
                        .fixedSize(
                            horizontal: false,
                            vertical: dynamicTypeSize.isAccessibilitySize
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 2)
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

    private var metadata: String {
        var parts: [String] = []
        if session.showsFolderPath {
            parts.append(session.folderPath(for: item))
        }
        parts.append(item.kind.libraryTitle)
        if item.kind == .folder {
            let itemCount = session.folderItemCount(for: item)
            parts.append("\(itemCount) \(itemCount == 1 ? "item" : "items")")
        } else if item.pageCount > 0 {
            let pageCount = item.pageCount
            parts.append("\(pageCount) \(pageCount == 1 ? "page" : "pages")")
        }
        parts.append(modifiedAtDescription)
        return parts.joined(separator: " . ")
    }

    private var favoriteBadgeXRatio: CGFloat {
        switch item.kind {
        case .notebook, .importedDocument: 0.78
        case .folder: 0.86
        case .legacyTypedNote, .canvas, .attachment: 0.94
        }
    }

    private var modifiedAtDescription: String {
        if abs(Date.now.timeIntervalSince(item.modifiedAt)) < 60 {
            return "now"
        }
        return item.modifiedAt.formatted(
            .relative(presentation: .numeric, unitsStyle: .abbreviated)
        )
    }

    private var accessibilityLabel: String {
        "\(item.name), \(metadata)\(item.isFavorite ? ", Favorite" : "")"
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
                        folderPreviewItems: session.folderPreviewItems(for: item),
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
                                .font(.system(.headline, design: .rounded).weight(.semibold))
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
                        Text(listMetadata)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        if dynamicTypeSize.isAccessibilitySize {
                            Text("Modified \(modifiedDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: NotateDesign.Spacing.content)

                    if dynamicTypeSize.isAccessibilitySize == false {
                        Text(modifiedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
        if session.showsFolderPath {
            return session.folderPath(for: item)
        }
        guard item.kind == .folder else { return item.kind.libraryTitle }
        let itemCount = session.folderItemCount(for: item)
        return "Folder · \(itemCount) item\(itemCount == 1 ? "" : "s")"
    }

    private var modifiedDescription: String {
        item.modifiedAt.formatted(.relative(presentation: .named))
    }

    private var accessibilityLabel: String {
        "\(item.name), \(listMetadata), modified \(modifiedDescription)"
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
        if session.isSelectionMode {
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
    let folderPreviewItems: [LibraryFolderPreviewItem]
    let thumbnailStore: LibraryAutomaticThumbnailStore

    init(
        item: LibraryItemRecord,
        folderPreviewItems: [LibraryFolderPreviewItem] = [],
        thumbnailStore: LibraryAutomaticThumbnailStore = .shared
    ) {
        self.item = item
        self.folderPreviewItems = folderPreviewItems
        self.thumbnailStore = thumbnailStore
    }

    @ViewBuilder
    var body: some View {
        switch LibraryArtworkSilhouette.resolve(for: item.kind) {
        case .finderFolder:
            LibraryFolderArtwork(
                symbolName: item.folderSettings?.symbolName ?? "folder",
                color: (item.folderSettings?.color ?? .folderBlue).swiftUIColor,
                showsBackdrop: false,
                previewItems: folderPreviewItems,
                thumbnailStore: thumbnailStore
            )
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
        case .portraitPage:
            ZStack {
                Color.clear
                LibraryNonFolderArtwork(item: item, thumbnailStore: thumbnailStore)
                    .aspectRatio(
                        LibraryArtworkSilhouette.portraitPage.preferredAspectRatio,
                        contentMode: .fit
                    )
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)
            }
        case .landscapeBoard:
            LibraryNonFolderArtwork(item: item, thumbnailStore: thumbnailStore)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
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
                } else {
                    LibraryGeneratedTitleArtwork(fallback: generatedFallback) {
                        fallbackArtwork
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
                LibraryCustomCoverPlaceholder(title: item.name)
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
            } else {
                LibraryNotebookArtwork(coverChoice: choice, title: item.name)
            }
        }
    }

    @ViewBuilder
    private var fallbackArtwork: some View {
        switch item.kind {
        case .folder:
            LibraryFolderArtwork(
                symbolName: item.folderSettings?.symbolName ?? "folder",
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
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        case .portraitPage, .sourceDocument:
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

    var body: some View {
        GeometryReader { proxy in
            let availableSize = CGSize(
                width: max(0, proxy.size.width - 6),
                height: max(0, proxy.size.height - 6)
            )
            let fittedSize = LibraryArtworkGeometry.aspectFitSize(
                source: image.size,
                inside: availableSize
            )

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: fittedSize.width, height: fittedSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.11), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 6, y: 4)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
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

/// Pixel-derived layout metrics for the bundled 483 x 362 Finder folder.
/// Keeping the lip, foreground repaint, preview exposure, and glyph placement
/// tied to the same source geometry prevents child previews from leaking over
/// the folder's front pocket when card sizes change.
private enum LibraryFolderAssetMetrics {
    static let seamRatio: CGFloat = 104 / 362
    static let frontMaskStartRatio: CGFloat = 102 / 362
    static let bodyBottomRatio: CGFloat = 322 / 362
    static let glyphCenterRatio: CGFloat = (seamRatio + bodyBottomRatio) / 2
    static let previewWidthRatio: CGFloat = 0.235
    static let previewHeightRatio: CGFloat = 0.46
    static let previewExposedHeightRatio: CGFloat = 0.16
}

struct LibraryFolderArtwork: View {
    let symbolName: String
    let color: Color
    var showsBackdrop = true
    var previewItems: [LibraryFolderPreviewItem] = []
    var thumbnailStore: LibraryAutomaticThumbnailStore = .shared

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let folderAspect: CGFloat = 4 / 3
            let folderWidth = min(proxy.size.width * 0.96, proxy.size.height * folderAspect)
            let folderHeight = folderWidth / folderAspect
            let iconSize = min(folderWidth, folderHeight) * 0.17
            let folderOrigin = CGPoint(
                x: (proxy.size.width - folderWidth) / 2,
                y: (proxy.size.height - folderHeight) / 2
            )
            let folderCenter = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let frontTop = folderOrigin.y
                + folderHeight * LibraryFolderAssetMetrics.seamRatio

            ZStack {
                if showsBackdrop {
                    Color(uiColor: .secondarySystemGroupedBackground)
                }

                tintedFolderImage
                    .frame(width: folderWidth, height: folderHeight)
                    .position(folderCenter)

                if previewItems.isEmpty == false {
                    LibraryFolderPreviewStack(
                        items: Array(previewItems.prefix(
                            LibraryFolderPreviewPolicy.maximumItemCount
                        )),
                        folderWidth: folderWidth,
                        folderHeight: folderHeight,
                        centerX: proxy.size.width / 2,
                        frontTop: frontTop,
                        thumbnailStore: thumbnailStore
                    )
                }

                // Repaint only the front pocket above the live previews so
                // child covers appear physically tucked inside the bundled
                // Finder-style folder rather than floating over it.
                tintedFolderImage
                    .frame(width: folderWidth, height: folderHeight)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(
                            height: folderHeight
                                * (1 - LibraryFolderAssetMetrics.frontMaskStartRatio)
                        )
                    }
                    .position(folderCenter)

                folderGlyph(size: iconSize)
                    .position(
                        x: proxy.size.width / 2,
                        y: folderOrigin.y
                            + folderHeight * LibraryFolderAssetMetrics.glyphCenterRatio
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var tintedFolderImage: some View {
        ZStack {
            Image("NotateFinderFolder")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(color)
            Image("NotateFinderFolder")
                .resizable()
                .interpolation(.high)
                .saturation(0)
                .blendMode(colorScheme == .dark ? .screen : .softLight)
                .opacity(colorScheme == .dark ? 0.18 : 0.13)
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func folderGlyph(size: CGFloat) -> some View {
        NotateFolderGlyph(
            symbolName: symbolName,
            tint: folderGlyphForeground,
            isSelected: true,
            size: size,
            fallbackForeground: folderGlyphForeground
        )
        .accessibilityHidden(true)
    }

    private var folderGlyphForeground: Color {
        let resolved = UIColor(color).resolvedColor(
            with: UITraitCollection(
                userInterfaceStyle: colorScheme == .dark ? .dark : .light
            )
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return colorScheme == .dark ? .white : .black
        }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return (luminance > 0.58 ? Color.black : Color.white).opacity(0.78)
    }
}

/// At most three direct children sit between the folder's back and front
/// layers. These are intentionally small, clipped samples—not nested cards—so
/// a scrolling grid performs a bounded amount of asynchronous image work.
private struct LibraryFolderPreviewStack: View {
    let items: [LibraryFolderPreviewItem]
    let folderWidth: CGFloat
    let folderHeight: CGFloat
    let centerX: CGFloat
    let frontTop: CGFloat
    let thumbnailStore: LibraryAutomaticThumbnailStore

    var body: some View {
        let tileWidth = folderWidth * LibraryFolderAssetMetrics.previewWidthRatio
        let tileHeight = folderHeight * LibraryFolderAssetMetrics.previewHeightRatio
        let exposedHeight = folderHeight * LibraryFolderAssetMetrics.previewExposedHeightRatio

        ZStack {
            ForEach(items) { item in
                let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
                LibraryFolderPreviewArtwork(item: item, thumbnailStore: thumbnailStore)
                    .frame(width: tileWidth, height: tileHeight)
                    .rotationEffect(.degrees(rotation(at: index)))
                    .offset(x: horizontalOffset(at: index))
                    .frame(width: folderWidth, height: tileHeight)
                    .position(
                        x: centerX,
                        y: frontTop + tileHeight / 2 - exposedHeight
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func horizontalOffset(at index: Int) -> CGFloat {
        switch items.count {
        case 1:
            return 0
        case 2:
            return index == 0 ? -folderWidth * 0.105 : folderWidth * 0.105
        default:
            return CGFloat(index - 1) * folderWidth * 0.17
        }
    }

    private func rotation(at index: Int) -> Double {
        switch items.count {
        case 1:
            return 0
        case 2:
            return index == 0 ? -5 : 5
        default:
            return [-7, 0, 7][min(index, 2)]
        }
    }
}

private struct LibraryFolderPreviewArtwork: View {
    let item: LibraryFolderPreviewItem
    let thumbnailStore: LibraryAutomaticThumbnailStore

    @State private var thumbnailImage: UIImage?

    var body: some View {
        Group {
            if item.kind == .folder {
                folderFallback
            } else if case .customAsset = item.coverChoice,
                let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else if item.coverChoice != .automatic {
                LibraryCoverArtwork(choice: item.coverChoice, title: nil)
                    .scaledToFill()
            } else if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else {
                semanticFallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
        .task(id: LibraryThumbnailRequest(
            itemID: item.id,
            previewGeneration: item.previewGeneration
        )) {
            let needsThumbnail: Bool
            if case .customAsset = item.coverChoice {
                needsThumbnail = true
            } else {
                needsThumbnail = item.coverChoice == .automatic
            }
            guard item.kind != .folder, needsThumbnail else {
                thumbnailImage = nil
                return
            }
            thumbnailImage = nil
            let data = await thumbnailStore.data(for: item.id)
            guard Task.isCancelled == false else { return }
            thumbnailImage = data.flatMap(UIImage.init(data:))
        }
    }

    private var folderFallback: some View {
        let folderColor = item.folderSettings?.color ?? .folderBlue
        let color = folderColor.swiftUIColor
        return ZStack {
            color.opacity(0.92)
            NotateFolderGlyph(
                symbolName: item.folderSettings?.symbolName ?? "folder",
                tint: folderColor.folderGlyphForeground,
                isSelected: true,
                size: 18,
                fallbackForeground: folderColor.folderGlyphForeground
            )
        }
    }

    @ViewBuilder
    private var semanticFallback: some View {
        switch item.kind {
        case .folder:
            folderFallback
        case .notebook:
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(NotateLibraryDesign.accent)
            }
        case .legacyTypedNote:
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        case .canvas,
            .importedDocument,
            .attachment:
            let fallback = LibraryFileFallbackKind.resolve(
                contentTypeIdentifier: item.sourceContentTypeIdentifier,
                filename: item.sourceFilename
            )
            ZStack {
                fallback.accentColor.opacity(0.12)
                Image(systemName: fallback.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(fallback.accentColor)
            }
        }
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

/// A neutral notebook silhouette for Automatic mode. It intentionally avoids
/// resembling any curated cover, since those are explicit user choices.
private struct LibraryAutomaticNotebookArtwork: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .leading) {
            Color(uiColor: .secondarySystemBackground)
            Canvas { context, size in
                let spacing = max(size.height / 12, 7)
                var rules = Path()
                for y in stride(
                    from: spacing * 1.6,
                    through: size.height - spacing,
                    by: spacing
                ) {
                    rules.move(to: CGPoint(x: spacing, y: y))
                    rules.addLine(to: CGPoint(x: size.width - spacing, y: y))
                }
                context.stroke(
                    rules,
                    with: .color(.secondary.opacity(colorScheme == .dark ? 0.20 : 0.14)),
                    lineWidth: 0.7
                )
            }
            Rectangle()
                .fill(NotateLibraryDesign.accent.opacity(colorScheme == .dark ? 0.58 : 0.44))
                .frame(width: 4)
                .padding(.vertical, 10)
                .padding(.leading, 8)
        }
        .aspectRatio(595 / 842, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.7)
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

    var body: some View {
        LibraryCoverArtwork(choice: coverChoice, title: title)
            .aspectRatio(3 / 4, contentMode: .fit)
            .padding(.vertical, 3)
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
                LibraryAutomaticCoverArtwork(title: title)
            case let .preset(preset):
                if let cover = LibraryCuratedCover.curated.first(where: { $0.preset == preset }) {
                    LibraryPhysicalCoverArtwork(cover: cover, title: title)
                } else {
                    LibraryAutomaticCoverArtwork(title: title)
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
