import CoreTransferable
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A single semantic treatment for labels bridged into UIKit-backed menus.
///
/// Menu images otherwise inherit the app accent tint while their neighboring
/// text uses the system label color. Keeping both branches explicitly
/// monochrome makes the glyph read as part of the action instead of as a
/// second, blue affordance. Destructive actions opt into the system red pair.
struct LibraryMenuActionLabel: View {
    let title: String
    let systemImage: String
    var isDestructive = false

    private var color: Color {
        isDestructive ? .red : .primary
    }

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(color)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(color)
        }
        .foregroundStyle(color)
        .tint(color)
    }
}

enum LibraryScope: Hashable, Sendable {
    case home
    case favorites
    case recent
    case tag(UUID)
    case trash
    case settings
    case folder(UUID)

}

enum LibraryViewStyle: String, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    var id: Self { self }
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    var title: String { self == .grid ? "Grid" : "List" }
}

struct LibraryScopeBrowsingState {
    var viewStyle: LibraryViewStyle = .grid
    var scrollPositionID: UUID?
}

enum LibraryAddKind: String, CaseIterable, Identifiable, Sendable {
    case quickNote
    case notebook
    case folder
    case documents

    var id: Self { self }

    var title: String {
        switch self {
        case .quickNote: "Quick Note"
        case .notebook: "Notebook"
        case .folder: "Folder"
        case .documents: "Import Files"
        }
    }

    var subtitle: String {
        switch self {
        case .quickNote: "Start writing in a blank notebook"
        case .notebook: "A page-based space for writing"
        case .folder: "Group related work"
        case .documents: "Bring in PDFs, images, and other files"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .quickNote: "Create Quick Note"
        case .notebook: "Create Notebook"
        case .folder: "Create Folder"
        case .documents: "Import files and photos"
        }
    }

    var systemImage: String {
        switch self {
        case .quickNote: "square.and.pencil"
        case .notebook: "book.closed"
        case .folder: "folder"
        case .documents: "tray.and.arrow.down"
        }
    }
}

struct LibraryColorDraft: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    // Shared tag and settings colors remain independent from the brighter folder swatches.
    static let blue = LibraryColorDraft(red: 0.55, green: 0.78, blue: 1.00)
    static let coral = LibraryColorDraft(red: 0.96, green: 0.48, blue: 0.43)
    static let amber = LibraryColorDraft(red: 0.94, green: 0.67, blue: 0.24)
    static let mint = LibraryColorDraft(red: 0.33, green: 0.75, blue: 0.59)
    static let violet = LibraryColorDraft(red: 0.58, green: 0.46, blue: 0.88)
    static let rose = LibraryColorDraft(red: 0.89, green: 0.43, blue: 0.67)

    static let folderDefault = folderBlue
    static let folderBlue = LibraryColorDraft(red: 0.12, green: 0.46, blue: 0.96)
    static let folderYellow = LibraryColorDraft(red: 1.00, green: 0.84, blue: 0.27)
    static let folderOrange = LibraryColorDraft(red: 0.99, green: 0.48, blue: 0.20)
    static let folderRed = LibraryColorDraft(red: 0.94, green: 0.25, blue: 0.29)
    static let folderGreen = LibraryColorDraft(red: 0.52, green: 0.78, blue: 0.27)
    static let folderTeal = LibraryColorDraft(red: 0.08, green: 0.73, blue: 0.70)
    static let folderViolet = LibraryColorDraft(red: 0.56, green: 0.38, blue: 0.93)
    static let folderPink = LibraryColorDraft(red: 0.93, green: 0.36, blue: 0.68)
    static let folderRose = LibraryColorDraft(red: 0.92, green: 0.32, blue: 0.48)
    // Retain the earlier name for toolbar creation shortcuts.
    static let folderAmber = folderOrange
    static let folderPalette: [LibraryColorDraft] = [
        .folderBlue,
        .folderYellow,
        .folderOrange,
        .folderRed,
        .folderGreen,
        .folderTeal,
        .folderViolet,
        .folderPink,
        .folderRose,
    ]

    static let palette: [LibraryColorDraft] = [.blue, .coral, .amber, .mint, .violet, .rose]
}

struct LibraryNamePrompt: Identifiable, Sendable {
    enum Target: Sendable {
        case rename(itemID: UUID)
    }

    let target: Target
    var draftName: String

    var id: String {
        switch target {
        case let .rename(itemID):
            "rename-\(itemID.uuidString)"
        }
    }

    var title: String {
        switch target {
        case .rename: "Rename"
        }
    }

    var placeholder: String {
        switch target {
        case .rename: "Name"
        }
    }

    var confirmationTitle: String {
        switch target {
        case .rename: "Rename"
        }
    }

    var message: String {
        switch target {
        case .rename: "Enter a new name for this item."
        }
    }
}

struct LibraryFolderDraft: Sendable {
    var name: String
    var color: LibraryColorDraft
    var symbolName: String
}

struct LibraryNotebookDraft: Sendable {
    var name: String
    var coverChoice: LibraryCoverChoice
    var customCover: LibraryCustomCoverDraft? = nil
}

struct LibraryCustomCoverDraft: Sendable {
    let data: Data
    let canvasSourceRelativePath: String

    init(data: Data, identifier: UUID = UUID()) {
        self.data = data
        canvasSourceRelativePath = "NotateCovers/custom-\(identifier.uuidString).png"
    }

    var itemRelativePath: String {
        "Sources/\(canvasSourceRelativePath)"
    }
}

struct LibraryTagDraft: Sendable {
    var name: String
    var color: LibraryColorDraft
}

struct LibraryCuratedCover: Identifiable, Hashable, Sendable {
    enum Motif: Hashable, Sendable {
        case compositionSpeckle
        case orchardSprig
        case candyStripe
    }

    struct Palette: Hashable, Sendable {
        let top: LibraryRGBAColor
        let bottom: LibraryRGBAColor
        let spine: LibraryRGBAColor
        let pattern: LibraryRGBAColor
        let ink: LibraryRGBAColor
    }

    let preset: LibraryCoverPreset
    let title: String
    let subtitle: String
    let motif: Motif
    let palette: Palette

    var id: LibraryCoverPreset { preset }

    static let curated: [LibraryCuratedCover] = [
        LibraryCuratedCover(
            preset: .softLinen,
            title: "Rose Composition",
            subtitle: "Soft rose with sparse composition marks",
            motif: .compositionSpeckle,
            palette: Palette(
                top: LibraryRGBAColor(red: 0.94, green: 0.68, blue: 0.79),
                bottom: LibraryRGBAColor(red: 0.94, green: 0.68, blue: 0.79),
                spine: LibraryRGBAColor(red: 0.67, green: 0.35, blue: 0.50),
                pattern: LibraryRGBAColor(red: 1.00, green: 0.94, blue: 0.84),
                ink: LibraryRGBAColor(red: 0.31, green: 0.20, blue: 0.25)
            )
        ),
        LibraryCuratedCover(
            preset: .blueprint,
            title: "Mint Orchard",
            subtitle: "Soft mint with simple orchard sprigs",
            motif: .orchardSprig,
            palette: Palette(
                top: LibraryRGBAColor(red: 0.78, green: 0.90, blue: 0.80),
                bottom: LibraryRGBAColor(red: 0.78, green: 0.90, blue: 0.80),
                spine: LibraryRGBAColor(red: 0.44, green: 0.65, blue: 0.51),
                pattern: LibraryRGBAColor(red: 0.96, green: 0.90, blue: 0.59),
                ink: LibraryRGBAColor(red: 0.20, green: 0.34, blue: 0.25)
            )
        ),
        LibraryCuratedCover(
            preset: .warmPaper,
            title: "Lavender Stripe",
            subtitle: "Lavender with crisp blush stripes",
            motif: .candyStripe,
            palette: Palette(
                top: LibraryRGBAColor(red: 0.86, green: 0.79, blue: 0.93),
                bottom: LibraryRGBAColor(red: 0.86, green: 0.79, blue: 0.93),
                spine: LibraryRGBAColor(red: 0.57, green: 0.45, blue: 0.70),
                pattern: LibraryRGBAColor(red: 0.96, green: 0.78, blue: 0.86),
                ink: LibraryRGBAColor(red: 0.29, green: 0.23, blue: 0.36)
            )
        ),
        LibraryCuratedCover(
            preset: .skyComposition,
            title: "Sky Composition",
            subtitle: "Airy blue with cream composition marks",
            motif: .compositionSpeckle,
            palette: Palette(
                top: LibraryRGBAColor(red: 0.70, green: 0.86, blue: 0.98),
                bottom: LibraryRGBAColor(red: 0.70, green: 0.86, blue: 0.98),
                spine: LibraryRGBAColor(red: 0.35, green: 0.61, blue: 0.82),
                pattern: LibraryRGBAColor(red: 1.00, green: 0.96, blue: 0.82),
                ink: LibraryRGBAColor(red: 0.18, green: 0.30, blue: 0.40)
            )
        ),
        LibraryCuratedCover(
            preset: .peachOrchard,
            title: "Peach Orchard",
            subtitle: "Warm peach with quiet botanical marks",
            motif: .orchardSprig,
            palette: Palette(
                top: LibraryRGBAColor(red: 1.00, green: 0.80, blue: 0.72),
                bottom: LibraryRGBAColor(red: 1.00, green: 0.80, blue: 0.72),
                spine: LibraryRGBAColor(red: 0.88, green: 0.51, blue: 0.43),
                pattern: LibraryRGBAColor(red: 0.99, green: 0.93, blue: 0.58),
                ink: LibraryRGBAColor(red: 0.42, green: 0.25, blue: 0.21)
            )
        ),
        LibraryCuratedCover(
            preset: .butterStripe,
            title: "Butter Stripe",
            subtitle: "Soft yellow with clean ivory bands",
            motif: .candyStripe,
            palette: Palette(
                top: LibraryRGBAColor(red: 1.00, green: 0.90, blue: 0.61),
                bottom: LibraryRGBAColor(red: 1.00, green: 0.90, blue: 0.61),
                spine: LibraryRGBAColor(red: 0.82, green: 0.65, blue: 0.25),
                pattern: LibraryRGBAColor(red: 1.00, green: 0.97, blue: 0.86),
                ink: LibraryRGBAColor(red: 0.40, green: 0.33, blue: 0.16)
            )
        ),
        LibraryCuratedCover(
            preset: .aquaComposition,
            title: "Aqua Composition",
            subtitle: "Clear aqua with fine notebook flecks",
            motif: .compositionSpeckle,
            palette: Palette(
                top: LibraryRGBAColor(red: 0.67, green: 0.91, blue: 0.91),
                bottom: LibraryRGBAColor(red: 0.67, green: 0.91, blue: 0.91),
                spine: LibraryRGBAColor(red: 0.32, green: 0.67, blue: 0.69),
                pattern: LibraryRGBAColor(red: 0.98, green: 0.98, blue: 0.84),
                ink: LibraryRGBAColor(red: 0.17, green: 0.35, blue: 0.36)
            )
        ),
        LibraryCuratedCover(
            preset: .periwinkleOrchard,
            title: "Periwinkle Orchard",
            subtitle: "Cool periwinkle with subtle sprigs",
            motif: .orchardSprig,
            palette: Palette(
                top: LibraryRGBAColor(red: 0.75, green: 0.80, blue: 1.00),
                bottom: LibraryRGBAColor(red: 0.75, green: 0.80, blue: 1.00),
                spine: LibraryRGBAColor(red: 0.48, green: 0.53, blue: 0.82),
                pattern: LibraryRGBAColor(red: 0.95, green: 0.90, blue: 0.64),
                ink: LibraryRGBAColor(red: 0.25, green: 0.27, blue: 0.45)
            )
        ),
    ]
}

enum LibrarySheetDestination: Identifiable {
    case newTag
    case editTag(tagID: UUID)
    case newFolder(parentID: UUID?)
    case newNotebook(parentID: UUID?)
    case folderAppearance(itemID: UUID)
    case coverPicker(itemID: UUID)
    case tagAssignment(itemID: UUID)
    case move(itemIDs: Set<UUID>)

    var id: String {
        switch self {
        case .newTag: "new-tag"
        case let .editTag(tagID): "edit-tag-\(tagID.uuidString)"
        case let .newFolder(parentID): "new-folder-\(parentID?.uuidString ?? "root")"
        case let .newNotebook(parentID): "new-notebook-\(parentID?.uuidString ?? "root")"
        case let .folderAppearance(itemID): "folder-appearance-\(itemID.uuidString)"
        case let .coverPicker(itemID): "cover-\(itemID.uuidString)"
        case let .tagAssignment(itemID): "tags-\(itemID.uuidString)"
        case let .move(itemIDs): "move-\(itemIDs.map(\.uuidString).sorted().joined())"
        }
    }
}

@MainActor
struct LibraryUIActions {
    var openItem: (LibraryItemRecord) -> Void = { _ in }
    var importDocuments: (UUID?) -> Void = { _ in }
    var createFolder: (UUID?, LibraryFolderDraft) -> Void = { _, _ in }
    var createNotebook: (UUID?, LibraryNotebookDraft) -> Void = { _, _ in }
    var renameItem: (UUID, String) -> Void = { _, _ in }
    var updateFolder: (UUID, LibraryFolderDraft) -> Void = { _, _ in }
    var setCover: (UUID, LibraryCoverChoice, LibraryCustomCoverDraft?) -> Void = { _, _, _ in }
    var toggleFavorite: (UUID) -> Void = { _ in }
    var duplicateItem: (UUID) -> Void = { _ in }
    var moveItems: (Set<UUID>, UUID?) -> Bool = { _, _ in false }
    var moveToTrash: (Set<UUID>) -> Void = { _ in }
    var restoreItems: (Set<UUID>) -> Void = { _ in }
    var deletePermanently: (Set<UUID>) -> Void = { _ in }
    var restoreDeletedPage: (UUID) -> Void = { _ in }
    var deleteDeletedPagePermanently: (UUID) -> Void = { _ in }
    var createTag: (LibraryTagDraft) -> Void = { _ in }
    var updateTag: (UUID, LibraryTagDraft) -> Void = { _, _ in }
    var deleteTag: (UUID) -> Void = { _ in }
    /// Parameters are tag identifier, then item identifier.
    var assignTag: (UUID, UUID) -> Void = { _, _ in }
    /// Parameters are tag identifier, then item identifier.
    var removeTag: (UUID, UUID) -> Void = { _, _ in }
}

@MainActor
@Observable
final class LibraryAppSession {
    let repository: LibraryRepository
    let actions: LibraryUIActions
    @ObservationIgnored let thumbnailStore: LibraryAutomaticThumbnailStore
    @ObservationIgnored private let currentDate: () -> Date
    @ObservationIgnored private let mutationAllowed: () -> Bool

    var scope: LibraryScope = .home
    private var scopeBrowsingStates: [LibraryScope: LibraryScopeBrowsingState] = [:]
    var viewStyle: LibraryViewStyle {
        get { scopeBrowsingStates[scope]?.viewStyle ?? .grid }
        set { scopeBrowsingStates[scope, default: LibraryScopeBrowsingState()].viewStyle = newValue }
    }
    var scrollPositionID: UUID? {
        get { scopeBrowsingStates[scope]?.scrollPositionID }
        set {
            scopeBrowsingStates[scope, default: LibraryScopeBrowsingState()].scrollPositionID = newValue
        }
    }
    var sortField: LibrarySortField = .activity
    var sortOrder: LibrarySortDirection = .descending
    var recentPeriod: LibraryRecentPeriod = .thirtyDays
    var searchQuery = "" {
        didSet {
            // Items filtered out by a new search must not stay selected, or a
            // bulk Trash/Move would act on notes the person can no longer see.
            guard isSelectionMode, selectedItemIDs.isEmpty == false else { return }
            selectedItemIDs.formIntersection(selectableItemIDs)
        }
    }
    var isSearchExpanded = false
    var isAddPanelPresented = false
    var isSelectionMode = false
    var selectedItemIDs: Set<UUID> = []
    var sheet: LibrarySheetDestination?
    var namePrompt: LibraryNamePrompt?
    var pendingPermanentDeletion: Set<UUID>?
    var alertMessage: String?

    init(
        repository: LibraryRepository,
        actions: LibraryUIActions? = nil,
        thumbnailStore: LibraryAutomaticThumbnailStore? = nil,
        mutationAllowed: @escaping () -> Bool = { true },
        currentDate: @escaping () -> Date = { .now }
    ) {
        self.repository = repository
        self.actions = actions ?? LibraryUIActions()
        self.thumbnailStore = thumbnailStore ?? .shared
        self.mutationAllowed = mutationAllowed
        self.currentDate = currentDate
    }

    var canMutate: Bool { mutationAllowed() }

    var parentID: UUID? {
        if case let .folder(id) = scope { id } else { nil }
    }

    var scopeTitle: String {
        switch scope {
        case .home: "Home"
        case .favorites: "Favorites"
        case .recent: "Recent"
        case let .tag(id): repository.tags.first(where: { $0.id == id })?.name ?? "Tag"
        case .trash: "Trash"
        case .settings: "Settings"
        case let .folder(id): repository.item(id: id)?.name ?? "Folder"
        }
    }

    var visibleItems: [LibraryItemRecord] {
        let source: [LibraryItemRecord]
        switch scope {
        case .home:
            source = repository.rootItems(sort: librarySort)
        case .favorites:
            source = repository.favorites(sort: librarySort)
        case .recent:
            source = repository.recentItems(
                activeSince: recentPeriod.cutoff(relativeTo: currentDate()),
                sort: librarySort
            )
        case let .tag(id):
            source = repository.items(taggedWith: id, sort: librarySort)
        case .trash:
            source = repository.trashedItems(sort: librarySort)
        case .settings:
            source = []
        case let .folder(id):
            source = repository.children(of: id, sort: librarySort)
        }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return source }

        switch scope {
        case .home:
            // Home search is intentionally global so work nested several
            // folders deep is still one quick search away.
            return repository.search(trimmed, sort: librarySort)
        case let .folder(id):
            return repository.search(
                trimmed,
                within: id,
                includeDescendants: true,
                sort: librarySort
            )
        case .favorites, .recent, .tag, .trash:
            return repository.search(trimmed, among: source, sort: librarySort)
        case .settings:
            return []
        }
    }

    var visibleDeletedPages: [DeletedPageRecord] {
        guard scope == .trash else { return [] }
        let pages = repository.deletedPages()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return pages }
        return pages.filter { record in
            (record.title?.localizedStandardContains(trimmed) ?? false)
            || (repository.item(id: record.ownerItemID)?.name
                .localizedStandardContains(trimmed) ?? false)
        }
    }

    var breadcrumbItems: [LibraryItemRecord] {
        guard case let .folder(folderID) = scope else { return [] }
        var result: [LibraryItemRecord] = []
        var cursor = repository.item(id: folderID)
        var visited: Set<UUID> = []

        while let item = cursor, visited.insert(item.id).inserted {
            result.append(item)
            cursor = item.parentID.flatMap(repository.item(id:))
        }
        return result.reversed()
    }

    var currentFolderDepth: Int {
        breadcrumbItems.count
    }

    var canCreateFolder: Bool {
        currentFolderDepth < LibraryRepository.maximumFolderDepth
    }

    var canCreateContent: Bool {
        guard canMutate else { return false }
        switch scope {
        case .home, .folder:
            return true
        case .favorites, .recent, .tag, .trash, .settings:
            return false
        }
    }

    func canUseActiveItemActions(for item: LibraryItemRecord) -> Bool {
        scope != .trash && item.isTrashed == false && item.payloadState == .ready
    }

    var canMoveSelectedItems: Bool {
        selectedItemIDs.isEmpty == false
        && selectedItemIDs.allSatisfy { id in
            guard let item = repository.item(id: id) else { return false }
            return canUseActiveItemActions(for: item)
        }
    }

    var selectableItemIDs: Set<UUID> {
        Set(visibleItems.map(\.id))
    }

    var allVisibleItemsSelected: Bool {
        let visibleIDs = selectableItemIDs
        return visibleIDs.isEmpty == false && visibleIDs.isSubset(of: selectedItemIDs)
    }

    var showsFolderPath: Bool {
        switch scope {
        case .recent, .tag:
            true
        default:
            false
        }
    }

    /// A stable, human-readable location for flattened scopes such as Recent and Tags.
    /// The item name is intentionally omitted because the card already shows it.
    func folderPath(for item: LibraryItemRecord) -> String {
        var names: [String] = []
        var parentID = item.parentID
        var visited: Set<UUID> = [item.id]

        while let id = parentID,
              visited.insert(id).inserted,
              let parent = repository.item(id: id) {
            names.append(parent.name)
            parentID = parent.parentID
        }

        return (["Home"] + names.reversed()).joined(separator: " / ")
    }

    /// Active folders summarize their direct children. Trash only surfaces a
    /// subtree's root card, so its count describes everything recoverable with
    /// that folder rather than incorrectly showing zero active children.
    func folderItemCount(for item: LibraryItemRecord) -> Int {
        guard item.kind == .folder else { return 0 }
        if let trashGroupID = item.trashMetadata?.trashGroupID {
            return repository.subtree(
                of: item.id,
                includingRoot: false,
                includeTrashed: true
            )
            .filter { descendant in
                descendant.trashMetadata?.trashGroupID == trashGroupID
            }
            .count
        }
        return repository.children(of: item.id).count
    }

    /// Folder card rendering must never fetch from SwiftData. Counts appear
    /// only after the corresponding child catalog is already cached; the full
    /// count API remains available for explicit folder editing actions.
    func cachedFolderItemCount(for item: LibraryItemRecord) -> Int? {
        guard item.kind == .folder else { return nil }
        if let trashGroupID = item.trashMetadata?.trashGroupID {
            return repository.cachedTrashSubtreeCount(
                of: item.id,
                trashGroupID: trashGroupID
            )
        }
        return repository.cachedChildCount(of: item.id)
    }

    func selectScope(_ newScope: LibraryScope) {
        scope = newScope
        searchQuery = ""
        isSearchExpanded = false
        selectedItemIDs.removeAll()
        isSelectionMode = false
        isAddPanelPresented = false
        pendingPermanentDeletion = nil
    }

    func open(_ item: LibraryItemRecord) {
        guard item.isTrashed == false else {
            alertMessage = "Restore this item before opening it."
            return
        }
        guard item.payloadState == .ready else {
            alertMessage = payloadUnavailableMessage(for: item.payloadState)
            return
        }
        guard canMutate else {
            // Folder browsing is read-only and safe during recovery. Opening a
            // document or touching its activity metadata must wait until the
            // catalog and its assets are coherent.
            if item.kind == .folder {
                selectScope(.folder(item.id))
            }
            return
        }
        if item.kind == .folder {
            do {
                try repository.markOpened(id: item.id)
                selectScope(.folder(item.id))
            } catch {
                alertMessage = error.localizedDescription
            }
        } else {
            actions.openItem(item)
        }
    }

    private func payloadUnavailableMessage(for state: LibraryPayloadState) -> String {
        switch state {
        case .creating:
            "This item is still being created."
        case .importing:
            "This item is still being imported."
        case .failed:
            "This item could not be prepared and cannot be opened."
        case .missing:
            "This item's local content is missing and cannot be opened."
        case .ready:
            "This item is ready."
        }
    }

    func toggleSelection(_ id: UUID) {
        guard selectableItemIDs.contains(id) else { return }
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    func beginSelection() {
        guard selectableItemIDs.isEmpty == false else { return }
        selectedItemIDs.removeAll()
        isAddPanelPresented = false
        isSelectionMode = true
    }

    func toggleSelectAllVisibleItems() {
        let visibleIDs = selectableItemIDs
        guard visibleIDs.isEmpty == false else { return }
        if visibleIDs.isSubset(of: selectedItemIDs) {
            selectedItemIDs.subtract(visibleIDs)
        } else {
            selectedItemIDs.formUnion(visibleIDs)
        }
    }

    func requestPermanentDeletion(_ itemIDs: Set<UUID>) {
        guard itemIDs.isEmpty == false else { return }
        pendingPermanentDeletion = itemIDs
    }

    func confirmPermanentDeletion() {
        guard let itemIDs = pendingPermanentDeletion, itemIDs.isEmpty == false else { return }
        pendingPermanentDeletion = nil
        actions.deletePermanently(itemIDs)
        clearSelection()
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
        isSelectionMode = false
    }

    private var librarySort: LibrarySort {
        LibrarySort(field: sortField, direction: sortOrder)
    }
}

extension LibrarySortDirection: Identifiable {
    public var id: Self { self }

    var title: String { self == .descending ? "Descending" : "Ascending" }

    var systemImage: String {
        self == .descending ? "arrow.down" : "arrow.up"
    }
}

struct LibraryDragPayload: Codable, Transferable, Sendable {
    let itemIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .notateLibraryItems)
    }
}

extension UTType {
    static let notateLibraryItems = UTType(
        exportedAs: "com.akshatsrivastava.notate.library-items",
        conformingTo: .data
    )
}
