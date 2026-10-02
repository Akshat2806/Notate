import SwiftUI
import UIKit

struct LibraryBrowserView: View {
    let session: LibraryAppSession
    let itemTransitionNamespace: Namespace.ID?

    @Namespace private var folderNavigationNamespace
    @State private var shouldRestoreAddFocus = false
    @State private var confirmsEmptyTrash = false
    @State private var isAddPanelLaunchingDestination = false
    @AccessibilityFocusState private var isAddButtonAccessibilityFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NotateLibraryDesign.warmBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                LibraryBrowserHeader(
                    session: session,
                    folderNavigationNamespace: folderNavigationNamespace
                )
                browserContent
            }

        if showsAttachedAddPanel {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(perform: dismissAddPanel)
                .accessibilityHidden(true)

            LibraryAddPanel(
                session: session,
                presentation: .attached,
                onChooseKind: prepareForAddKind
            )
            .notatePanelSurface()
            .padding(.trailing, horizontalSizeClass == .compact ? 18 : 26)
            .padding(
                .bottom,
                22
                    + NotateLibraryDesign.floatingActionSize
                    + NotateDesign.Spacing.control
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .scale(scale: 0.96, anchor: .bottomTrailing)
                        .combined(with: .opacity)
            )
            .zIndex(1)
        }

        if session.isSelectionMode {
            selectionActions
        } else if session.canCreateContent {
            addControls
        }
    }
        // The Library owns stable in-content chrome. Keeping the system bars
        // hidden prevents selection from reflowing the split view or placing
        // its actions inside the collapsible sidebar column.
        .toolbarVisibility(.hidden, for: .navigationBar, .bottomBar)
        .sheet(isPresented: compactAddPanelBinding) {
            LibraryAddPanel(
                session: session,
                presentation: .sheet,
                onChooseKind: prepareForAddKind
            )
            .presentationSizing(.fitted)
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
        }
        .onChange(of: session.isAddPanelPresented) { _, isPresented in
            if isPresented == false {
                if isAddPanelLaunchingDestination {
                    isAddPanelLaunchingDestination = false
                    return
                }
                restoreAddFocusWhenReady()
            }
        }
        .onChange(of: session.sheet?.id) { _, destinationID in
            if destinationID == nil {
                restoreAddFocusWhenReady()
            }
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        if session.visibleItems.isEmpty && session.visibleDeletedPages.isEmpty {
            LibraryEmptyStateView(
                scope: session.scope,
                searchQuery: session.searchQuery,
                onPrimaryAction: primaryEmptyAction,
                onNewNotebook: session.canCreateContent
                    ? { session.sheet = .newNotebook(parentID: session.parentID) }
                    : nil,
                onImportDocument: session.canCreateContent
                    ? { session.actions.importDocuments(session.parentID) }
                    : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.scope == .trash {
            VStack(spacing: 0) {
                trashBanner
                trashContent
            }
        } else {
            switch session.viewStyle {
            case .grid:
                if dynamicTypeSize.isAccessibilitySize {
                    list
                } else {
                    grid
                }
            case .list:
                list
            }
        }
    }

    private var trashBanner: some View {
        HStack(spacing: NotateDesign.Spacing.control) {
            Text("Items in Trash are deleted after 30 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if session.visibleItems.isEmpty == false {
                Button("Empty Trash", role: .destructive) {
                    confirmsEmptyTrash = true
                }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("library.trash.empty")
            }
        }
        .padding(.horizontal, NotateDesign.Spacing.page)
        .padding(.vertical, NotateDesign.Spacing.compact)
        .confirmationDialog(
            "Permanently delete everything in Trash?",
            isPresented: $confirmsEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                session.actions.deletePermanently(Set(session.visibleItems.map(\.id)))
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder
    private var trashContent: some View {
        switch session.viewStyle {
        case .grid:
            if dynamicTypeSize.isAccessibilitySize {
                trashList
            } else {
                trashGrid
            }
        case .list:
            trashList
        }
    }

    private var trashGrid: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: gridColumns(for: proxy.size.width),
                    alignment: gridAlignment,
                    spacing: NotateDesign.Spacing.page
                ) {
                    if session.visibleItems.isEmpty == false {
                        Section {
                            ForEach(session.visibleItems) { item in
                                LibraryGridCard(
                                    item: item,
                                    isSelected: session.selectedItemIDs.contains(item.id),
                                    isSelectionMode: session.isSelectionMode,
                                    session: session,
                                    folderNavigationNamespace: folderNavigationNamespace,
                                    itemTransitionNamespace: itemTransitionNamespace
                                )
                            }
                        } header: {
                            trashSectionHeader("Items")
                        }
                    }

                    if session.visibleDeletedPages.isEmpty == false {
                        Section {
                            ForEach(session.visibleDeletedPages) { page in
                                LibraryDeletedPageCard(record: page, session: session)
                            }
                        } header: {
                            trashSectionHeader("Pages")
                        }
                    }
                }
                .padding(.horizontal, gridHorizontalPadding)
                .padding(.top, NotateDesign.Spacing.page)
                .padding(.bottom, 112)
                .frame(maxWidth: NotateLibraryDesign.contentMaximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private var trashList: some View {
        List {
            if session.visibleItems.isEmpty == false {
                Section("Items") {
                    ForEach(session.visibleItems) { item in
                        LibraryListRow(
                            item: item,
                            isSelected: session.selectedItemIDs.contains(item.id),
                            isSelectionMode: session.isSelectionMode,
                            session: session,
                            folderNavigationNamespace: folderNavigationNamespace,
                            itemTransitionNamespace: itemTransitionNamespace
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }

            if session.visibleDeletedPages.isEmpty == false {
                Section("Pages") {
                    ForEach(session.visibleDeletedPages) { page in
                        LibraryDeletedPageRow(record: page, session: session)
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 100, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func trashSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, NotateDesign.Spacing.tight)
            .accessibilityAddTraits(.isHeader)
    }

    private var grid: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: gridColumns(for: proxy.size.width),
                    alignment: gridAlignment,
                    spacing: NotateDesign.Spacing.page
                ) {
                    ForEach(session.visibleItems) { item in
                        LibraryGridCard(
                            item: item,
                            isSelected: session.selectedItemIDs.contains(item.id),
                            isSelectionMode: session.isSelectionMode,
                            session: session,
                            folderNavigationNamespace: folderNavigationNamespace,
                            itemTransitionNamespace: itemTransitionNamespace
                        )
                    }
                }
                .padding(.horizontal, gridHorizontalPadding)
                .padding(.top, NotateDesign.Spacing.page)
                .padding(.bottom, 112)
                .frame(maxWidth: NotateLibraryDesign.contentMaximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private var gridHorizontalPadding: CGFloat {
        horizontalSizeClass == .compact ? NotateDesign.Spacing.content : 28
    }

    private var gridAlignment: HorizontalAlignment {
        dynamicTypeSize.isAccessibilitySize ? .center : .leading
    }

    private func gridColumns(for totalWidth: CGFloat) -> [GridItem] {
        let cappedWidth = min(totalWidth, NotateLibraryDesign.contentMaximumWidth)
        let contentWidth = max(0, cappedWidth - (gridHorizontalPadding * 2))
        let regularTwoColumnMinimum =
            (NotateLibraryDesign.cardMinimumWidth * 2) + NotateDesign.Spacing.section

        // Regular-width split-view columns can still be narrower than two
        // comfortable cards. Accessibility sizes also benefit from a single
        // reading column instead of compressed metadata.
        if dynamicTypeSize.isAccessibilitySize || contentWidth < regularTwoColumnMinimum {
            return [
                GridItem(
                    .fixed(
                        min(
                            contentWidth,
                            NotateLibraryDesign.accessibilityCardMaximumWidth
                        )
                    ),
                    spacing: 0,
                    alignment: .top
                ),
            ]
        }

        return [
            GridItem(
                .adaptive(
                    minimum: horizontalSizeClass == .compact
                    ? 164
                    : NotateLibraryDesign.cardMinimumWidth,
                    maximum: NotateLibraryDesign.cardMaximumWidth
                ),
                spacing: 22,
                alignment: .top
            ),
        ]
    }

    private var list: some View {
        List {
            ForEach(session.visibleItems) { item in
                LibraryListRow(
                    item: item,
                    isSelected: session.selectedItemIDs.contains(item.id),
                    isSelectionMode: session.isSelectionMode,
                    session: session,
                    folderNavigationNamespace: folderNavigationNamespace,
                    itemTransitionNamespace: itemTransitionNamespace
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(
                    EdgeInsets(
                        top: 5,
                        leading: NotateDesign.Spacing.section,
                        bottom: 5,
                        trailing: NotateDesign.Spacing.section
                    )
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 100, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var addControls: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            shouldRestoreAddFocus = true
            withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
                session.isAddPanelPresented.toggle()
            }
        } label: {
            NotateAppGlyph(
                kind: .add,
                tint: .white,
                isSelected: true,
                size: 23
            )
            .rotationEffect(
                .degrees(session.isAddPanelPresented ? 45 : 0)
            )
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.presentation,
                value: session.isAddPanelPresented
            )
            .frame(
                width: NotateLibraryDesign.floatingActionSize,
                height: NotateLibraryDesign.floatingActionSize
            )
            .notatePrimaryActionSurface(in: Circle())
        }
        .buttonStyle(LibraryFloatingAddButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(session.isAddPanelPresented ? "Close Add menu" : "Add")
        .accessibilityValue(session.isAddPanelPresented ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("library.add")
        .accessibilityFocused($isAddButtonAccessibilityFocused)
        .keyboardShortcut("n", modifiers: .command)
        .padding(.trailing, horizontalSizeClass == .compact ? 18 : 26)
        .padding(.bottom, 22)
        .zIndex(2)
    }

    private var showsAttachedAddPanel: Bool {
        usesAttachedAddPanel && session.isAddPanelPresented
    }

    private var usesAttachedAddPanel: Bool {
        horizontalSizeClass != .compact && dynamicTypeSize.isAccessibilitySize == false
    }

    private func dismissAddPanel() {
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
            session.isAddPanelPresented = false
        }
    }

    private var selectedItems: [LibraryItemRecord] {
        session.visibleItems.filter { session.selectedItemIDs.contains($0.id) }
    }

    private var selectionActions: some View {
        GlassEffectContainer(spacing: NotateDesign.Spacing.control) {
            HStack(spacing: NotateDesign.Spacing.control) {
                if session.scope == .trash {
                    selectionActionButton(
                        title: "Restore",
                        systemImage: "arrow.uturn.backward",
                        isDisabled: session.selectedItemIDs.isEmpty
                    ) {
                        let selectedIDs = session.selectedItemIDs
                        session.actions.restoreItems(selectedIDs)
                        session.clearSelection()
                    }
                } else {
                    let allFavorite = selectedItems.isEmpty == false
                        && selectedItems.allSatisfy(\.isFavorite)
                    selectionActionButton(
                        title: allFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: allFavorite ? "star.slash" : "star",
                        isDisabled: session.selectedItemIDs.isEmpty
                    ) {
                        // Bring every selected item to the same state rather
                        // than flipping each one independently.
                        for item in selectedItems where item.isFavorite == allFavorite {
                            session.actions.toggleFavorite(item.id)
                        }
                        session.clearSelection()
                    }
                    selectionActionButton(
                        title: "Duplicate",
                        systemImage: "plus.square.on.square",
                        isDisabled: selectedItems.contains { $0.kind != .folder } == false
                    ) {
                        for item in selectedItems where item.kind != .folder {
                            session.actions.duplicateItem(item.id)
                        }
                        session.clearSelection()
                    }
                    selectionActionButton(
                        title: "Move",
                        systemImage: "folder",
                        isDisabled: session.canMoveSelectedItems == false
                    ) {
                        session.sheet = .move(itemIDs: session.selectedItemIDs)
                    }
                }

                selectionActionButton(
                    title: session.scope == .trash ? "Delete Permanently" : "Move to Trash",
                    systemImage: "trash",
                    isDestructive: true,
                    isDisabled: session.selectedItemIDs.isEmpty
                ) {
                    if session.scope == .trash {
                        session.requestPermanentDeletion(session.selectedItemIDs)
                    } else {
                        let selectedIDs = session.selectedItemIDs
                        session.actions.moveToTrash(selectedIDs)
                        session.clearSelection()
                    }
                }
            }
        }
        .padding(.trailing, horizontalSizeClass == .compact ? 18 : 26)
        .padding(.bottom, 22)
        .accessibilityElement(children: .contain)
    }

    private func selectionActionButton(
        title: String,
        systemImage: String,
        isDestructive: Bool = false,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isDestructive ? Color.red : NotateLibraryDesign.accent)
                .frame(
                    width: NotateLibraryDesign.floatingActionSize,
                    height: NotateLibraryDesign.floatingActionSize
                )
                .notateInteractiveGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel(title)
    }

    private var compactAddPanelBinding: Binding<Bool> {
        Binding(
            get: {
                usesAttachedAddPanel == false && session.isAddPanelPresented
            },
            set: { isPresented in
                if isPresented == false {
                    session.isAddPanelPresented = false
                }
            }
        )
    }

    private func primaryEmptyAction() {
        if session.searchQuery.isEmpty == false {
            session.searchQuery = ""
            return
        }

        if session.canCreateContent == false {
            withAnimation(reduceMotion ? nil : NotateDesign.Motion.navigation) {
                session.selectScope(.home)
            }
        } else {
            session.sheet = .newNotebook(parentID: session.parentID)
        }
    }

    private func restoreAddFocusWhenReady() {
        guard shouldRestoreAddFocus, session.sheet == nil else { return }
        shouldRestoreAddFocus = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            isAddButtonAccessibilityFocused = true
        }
    }

    private func prepareForAddKind(_ kind: LibraryAddKind) {
        isAddPanelLaunchingDestination = true
        if kind == .documents {
            // The system importer is owned by the app coordinator, outside
            // this view's presentation state. Let that modal manage focus.
            shouldRestoreAddFocus = false
        }
    }
}

private struct LibraryFloatingAddButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && reduceMotion == false ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.feedback,
                value: configuration.isPressed
            )
    }
}

private struct LibraryDeletedPageCard: View {
    let record: DeletedPageRecord
    let session: LibraryAppSession

    @State private var confirmsPermanentDeletion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : NotateDesign.Motion.removal) {
                session.actions.restoreDeletedPage(record.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        Image(systemName: "doc.text.image")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(NotateLibraryDesign.accent)
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(NotateLibraryDesign.accent)
                            .padding(10)
                    }

                Text(record.title ?? "Deleted page")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(ownerDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session.isSelectionMode == false {
                actions
            }
        }
        .allowsHitTesting(session.isSelectionMode == false)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(session.isSelectionMode)
        .accessibilityIdentifier("library.deleted-page.restore")
        .accessibilityLabel("\(record.title ?? "Deleted page"), \(ownerDescription)")
        .accessibilityHint("Double-tap to restore")
        .confirmationDialog(
            "Delete This Page Permanently?",
            isPresented: $confirmsPermanentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                session.actions.deleteDeletedPagePermanently(record.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the page archive and cannot be undone.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            withAnimation(reduceMotion ? nil : NotateDesign.Motion.removal) {
                session.actions.restoreDeletedPage(record.id)
            }
        } label: {
            LibraryMenuActionLabel(
                title: "Restore",
                systemImage: "arrow.uturn.backward"
            )
        }
        Button(role: .destructive) {
            confirmsPermanentDeletion = true
        } label: {
            LibraryMenuActionLabel(
                title: "Delete Permanently",
                systemImage: "trash",
                isDestructive: true
            )
        }
    }

    private var ownerDescription: String {
        let owner = session.repository.item(id: record.ownerItemID)?.name ?? "Missing document"
        return "From \(owner) · \(record.deletedAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct LibraryDeletedPageRow: View {
    let record: DeletedPageRecord
    let session: LibraryAppSession

    @State private var confirmsPermanentDeletion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: NotateDesign.Spacing.control) {
            Image(systemName: "doc.text.image")
                .font(.title3)
                .foregroundStyle(NotateLibraryDesign.accent)
                .frame(width: 38, height: 44)
                .background(NotateLibraryDesign.accent.opacity(0.10), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title ?? "Deleted page")
                    .font(.body.weight(.medium))
                Text(ownerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(record.title ?? "Deleted page"), \(ownerName)")
            Spacer()
            if session.isSelectionMode == false {
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    withAnimation(reduceMotion ? nil : NotateDesign.Motion.removal) {
                        session.actions.restoreDeletedPage(record.id)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .notateMinimumHitTarget()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmsPermanentDeletion = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .notateMinimumHitTarget()
            }
        }
        .confirmationDialog(
            "Delete This Page Permanently?",
            isPresented: $confirmsPermanentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                session.actions.deleteDeletedPagePermanently(record.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the page archive and cannot be undone.")
        }
    }

    private var ownerName: String {
        "From \(session.repository.item(id: record.ownerItemID)?.name ?? "Missing document")"
    }
}

private struct LibraryBrowserHeader: View {
    let session: LibraryAppSession
    let folderNavigationNamespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topControls

            title
                .padding(.top, 2)

            if session.isSearchExpanded == false {
                HStack(spacing: NotateDesign.Spacing.control) {
                    Spacer(minLength: 0)
                    libraryTools
                }
                .frame(minHeight: NotateLibraryDesign.minimumHitTarget)
                .padding(.top, NotateDesign.Spacing.compact)
            }
        }
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 18 : 28)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(NotateLibraryDesign.warmBackground)
    }

    private var topControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NotateDesign.Spacing.control) {
                LibraryRevealSidebarButton()
                if session.breadcrumbItems.isEmpty == false {
                    breadcrumbs
                }
                Spacer(minLength: NotateDesign.Spacing.control)
                searchControl
            }
            .frame(minHeight: 46)

            VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                LibraryRevealSidebarButton()
                if session.breadcrumbItems.isEmpty == false {
                    breadcrumbs
                }
                HStack {
                    Spacer(minLength: 0)
                    searchControl
                }
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    folderHeaderArtwork
                    titleText
                }

                VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
                    folderHeaderArtwork
                    titleText
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var folderHeaderArtwork: some View {
        if let folderHeaderItem {
            LibraryItemArtwork(item: folderHeaderItem)
                .frame(width: 50, height: 35)
                .notateFolderGeometryTransition(
                    itemID: folderHeaderItem.id,
                    in: folderNavigationNamespace,
                    isSource: false
                )
                .accessibilityHidden(true)
        }
    }

    private var titleText: some View {
        Text(session.scopeTitle)
            .font(.largeTitle.weight(.bold))
            .fontDesign(.serif)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.78)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("library.header.title")
    }

    @ViewBuilder
    private var breadcrumbs: some View {
        if session.breadcrumbItems.isEmpty == false {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    Button("Home") {
                        selectScope(.home)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NotateLibraryDesign.accent)
                    .notateMinimumHitTarget()

                    ForEach(session.breadcrumbItems) { item in
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)

                        Button(item.name) {
                            selectScope(.folder(item.id))
                        }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(item.id == session.parentID ? .semibold : .regular))
                        .foregroundStyle(item.id == session.parentID ? .primary : .secondary)
                        .notateMinimumHitTarget()
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: NotateLibraryDesign.minimumHitTarget)
        }
    }

    /// "3 selected" with a Select All toggle, so bulk actions never act on a
    /// count the person has to guess.
    private var selectionSummary: some View {
        HStack(spacing: NotateDesign.Spacing.control) {
            Text(
                session.selectedItemIDs.isEmpty
                    ? "Select items"
                    : "\(session.selectedItemIDs.count) selected"
            )
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityIdentifier("library.selection.count")

            Button(session.allVisibleItemsSelected ? "Deselect All" : "Select All") {
                session.toggleSelectAllVisibleItems()
            }
            .font(.subheadline.weight(.medium))
            .disabled(session.selectableItemIDs.isEmpty)
            .accessibilityIdentifier("library.selection.select-all")
            .keyboardShortcut("a", modifiers: .command)
        }
        .padding(.trailing, NotateDesign.Spacing.compact)
    }

    private var libraryTools: some View {
        HStack(spacing: NotateDesign.Spacing.tight) {
            if session.isSelectionMode {
                selectionSummary
            }
            if session.scope == .recent {
                Menu {
                    Picker("Time Range", selection: Binding(
                        get: { session.recentPeriod },
                        set: { period in
                            session.recentPeriod = period
                            session.clearSelection()
                        }
                    )) {
                        ForEach(LibraryRecentPeriod.allCases) { period in
                            LibraryMenuActionLabel(
                                title: period.title,
                                systemImage: "calendar"
                            )
                            .tag(period)
                        }
                    }
                } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) {
                            NotateAppGlyph(kind: .recent, tint: Color.primary, size: 18)
                            Text(session.recentPeriod.title)
                                .lineLimit(1)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .notateMinimumHitTarget()

                        NotateAppGlyph(kind: .recent, tint: Color.primary, size: 18)
                            .notateMinimumHitTarget()
                    }
                }
                .accessibilityLabel("Recent Time Range")
                .accessibilityValue(session.recentPeriod.title)
                .accessibilityIdentifier("library.recent-period")
            }

            Menu {
                Picker("Sort by", selection: Binding(
                    get: { session.sortField },
                    set: { session.sortField = $0 }
                )) {
                    LibraryMenuActionLabel(title: "Date Modified", systemImage: "clock")
                        .tag(LibrarySortField.activity)
                    LibraryMenuActionLabel(title: "Name", systemImage: "textformat")
                        .tag(LibrarySortField.name)
                    LibraryMenuActionLabel(title: "Created", systemImage: "calendar")
                        .tag(LibrarySortField.created)
                    LibraryMenuActionLabel(
                        title: "Type",
                        systemImage: "square.grid.3x1.folder.badge.plus"
                    )
                    .tag(LibrarySortField.type)
                }

                Divider()

                Picker("Order", selection: Binding(
                    get: { session.sortOrder },
                    set: { session.sortOrder = $0 }
                )) {
                    ForEach(LibrarySortDirection.allCases) { order in
                        LibraryMenuActionLabel(
                            title: order.title,
                            systemImage: order.systemImage
                        )
                        .tag(order)
                    }
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        NotateAppGlyph(kind: .filter, tint: Color.primary, size: 18)
                        Text(sortTitle)
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .notateMinimumHitTarget()

                    NotateAppGlyph(kind: .filter, tint: Color.primary, size: 18)
                        .notateMinimumHitTarget()
                }
            }
            .accessibilityLabel("Sort")
            .accessibilityValue(sortAccessibilityValue)

            Menu {
                Picker("View", selection: Binding(
                    get: { session.viewStyle },
                    set: { session.viewStyle = $0 }
                )) {
                    ForEach(LibraryViewStyle.allCases) { style in
                        LibraryMenuActionLabel(
                            title: style.title,
                            systemImage: style.systemImage
                        )
                        .tag(style)
                    }
                }
            } label: {
                NotateAppGlyph(
                    kind: session.viewStyle == .grid ? .grid : .list,
                    tint: Color.primary,
                    size: 20
                )
                .notateMinimumHitTarget()
            }
            .accessibilityLabel("View Style")
            .accessibilityValue(session.viewStyle.title)
            .accessibilityIdentifier("library.view-style")

            if session.selectableItemIDs.isEmpty == false {
                Button {
                    withAnimation(reduceMotion ? nil : NotateDesign.Motion.selection) {
                        if session.isSelectionMode {
                            session.clearSelection()
                        } else {
                            session.beginSelection()
                        }
                    }
                } label: {
                    NotateSelectableAppGlyph(
                        kind: .select,
                        selectedTint: NotateLibraryDesign.accent,
                        isSelected: session.isSelectionMode,
                        size: 20
                    )
                    .notateMinimumHitTarget()
                }
                .accessibilityLabel(session.isSelectionMode ? "Done Selecting" : "Select Items")
                .accessibilityHint(
                    session.isSelectionMode
                        ? "Finish choosing items"
                        : "Choose multiple items"
                )
                .accessibilityIdentifier("library.selection-toggle")
            }
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
    }

    @ViewBuilder
    private var searchControl: some View {
        if session.isSearchExpanded {
            HStack(spacing: NotateDesign.Spacing.compact) {
                NotateAppGlyph(kind: .search, size: 18)
                TextField("Search \(session.scopeTitle)", text: Binding(
                    get: { session.searchQuery },
                    set: { session.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .writingToolsBehavior(.disabled)
                .focused($isSearchFocused)
                .accessibilityIdentifier("library.search")
                .frame(minWidth: 168, idealWidth: 236, maxWidth: 286)
                .onSubmit { isSearchFocused = false }

                Button {
                    withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
                        session.searchQuery = ""
                        session.isSearchExpanded = false
                        isSearchFocused = false
                    }
                } label: {
                    NotateAppGlyph(kind: .close, size: 17)
                        .notateMinimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Search")
            }
            .padding(.leading, 15)
            .notateInteractiveGlass(in: Capsule())
            .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .trailing).combined(with: .opacity))
        } else {
            Button {
                withAnimation(reduceMotion ? nil : NotateDesign.Motion.presentation) {
                    session.isSearchExpanded = true
                }
                isSearchFocused = true
            } label: {
                NotateCompactGlassGlyphLabel(
                    kind: .search,
                    tint: NotateLibraryDesign.accent,
                    glyphSize: 19
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search \(session.scopeTitle)")
            .keyboardShortcut("f", modifiers: .command)
        }
    }

    private var folderHeaderItem: LibraryItemRecord? {
        guard case let .folder(folderID) = session.scope,
              let folder = session.repository.item(id: folderID) else {
            return nil
        }
        return folder
    }

    private func selectScope(_ scope: LibraryScope) {
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.navigation) {
            session.selectScope(scope)
        }
    }

    private var subtitle: String? {
        if session.searchQuery.isEmpty == false {
            let count = session.visibleItems.count + session.visibleDeletedPages.count
            return "\(count) result\(count == 1 ? "" : "s")"
        }
        if case .folder = session.scope {
            return "Folder level \(session.currentFolderDepth) of \(LibraryRepository.maximumFolderDepth)"
        }
        if session.scope == .recent {
            return session.recentPeriod.title
        }
        return nil
    }

    private var sortTitle: String {
        switch session.sortField {
        case .activity: "Date Modified"
        case .name: "Name"
        case .created: "Created"
        case .type: "Type"
        }
    }

    private var sortAccessibilityValue: String {
        let field: String
        switch session.sortField {
        case .activity: field = "Date Modified"
        case .name: field = "Name"
        case .created: field = "Created"
        case .type: field = "Type"
        }
        return "\(field), \(session.sortOrder.title)"
    }
}

private enum LibraryAddPanelPresentation: Equatable {
    case attached
    case sheet
}

private struct LibraryAddPanel: View {
    let session: LibraryAppSession
    let presentation: LibraryAddPanelPresentation
    let onChooseKind: (LibraryAddKind) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .attached:
            panelContent
                .padding(NotateDesign.Spacing.control)
                .frame(width: 272)
        case .sheet:
            panelContent
                .padding(.horizontal, NotateDesign.Spacing.section)
                .padding(.top, NotateDesign.Spacing.content)
                .padding(.bottom, NotateDesign.Spacing.page)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
            if presentation == .sheet {
                HStack(spacing: NotateDesign.Spacing.control) {
                    Text("Add to Library")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button {
                        session.isAddPanelPresented = false
                    } label: {
                        NotateCompactGlassGlyphLabel(kind: .close, glyphSize: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }

            VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 7 : 3) {
                ForEach(availableKinds) { kind in
                    addRow(kind)
                }
            }

            if session.canCreateFolder == false {
                Label("Folder limit reached", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Folder nesting limit reached at level five")
            }
        }
        .accessibilityAction(.escape) {
            session.isAddPanelPresented = false
        }
    }

    private var availableKinds: [LibraryAddKind] {
        [
            .quickNote,
            .notebook,
            .folder,
            .documents,
        ].filter { kind in
            kind != .folder || session.canCreateFolder
        }
    }

    private func addRow(_ kind: LibraryAddKind) -> some View {
        let tint = rowTint(for: kind)

        return Button {
            onChooseKind(kind)
            session.isAddPanelPresented = false
            switch kind {
            case .quickNote:
                session.actions.createNotebook(
                    session.parentID,
                    LibraryNotebookDraft(
                        name: "Quick Note",
                        coverChoice: .automatic,
                        customCover: nil
                    )
                )
            case .notebook:
                session.sheet = .newNotebook(parentID: session.parentID)
            case .folder:
                session.sheet = .newFolder(parentID: session.parentID)
            case .documents:
                session.actions.importDocuments(session.parentID)
            }
        } label: {
            HStack(spacing: 12) {
                NotateAppGlyph(
                    kind: glyphKind(for: kind),
                    tint: tint,
                    isSelected: true,
                    size: 21
                )
                .frame(
                    width: 40,
                    height: 40
                )
                .background(
                    tint.opacity(colorScheme == .dark ? 0.24 : 0.14),
                    in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
                .overlay {
                    if colorSchemeContrast == .increased {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(tint.opacity(0.58), lineWidth: 1)
                    }
                }

                Text(kind.title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(
                        colorSchemeContrast == .increased
                            ? Color.primary
                            : Color.primary.opacity(0.90)
                    )
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: NotateDesign.Spacing.compact)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, NotateDesign.Spacing.compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(kind.accessibilityLabel)
        .accessibilityHint(kind.subtitle)
    }

    private func glyphKind(for kind: LibraryAddKind) -> NotateAppGlyphKind {
        switch kind {
        case .quickNote: .quickNote
        case .notebook: .notebook
        case .folder: .folder
        case .documents: .importDocument
        }
    }

    private func rowTint(for kind: LibraryAddKind) -> Color {
        switch kind {
        case .quickNote:
            Color(red: 0.56, green: 0.34, blue: 0.82)
        case .notebook:
            Color(red: 0.20, green: 0.46, blue: 0.96)
        case .folder:
            Color(red: 0.90, green: 0.34, blue: 0.43)
        case .documents:
            Color(red: 0.12, green: 0.53, blue: 0.93)
        }
    }
}
