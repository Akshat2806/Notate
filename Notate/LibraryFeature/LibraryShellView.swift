import SwiftUI

struct LibraryShellView: View {
    @State private var session: LibraryAppSession
    private let itemTransitionNamespace: Namespace.ID?
    @State private var splitVisibility: NavigationSplitViewVisibility = .automatic
    @State private var prefersCollapsedSidebar = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        repository: LibraryRepository,
        actions: LibraryUIActions = LibraryUIActions(),
        itemTransitionNamespace: Namespace.ID? = nil
    ) {
        _session = State(initialValue: LibraryAppSession(repository: repository, actions: actions))
        self.itemTransitionNamespace = itemTransitionNamespace
    }

    init(
        session: LibraryAppSession,
        itemTransitionNamespace: Namespace.ID? = nil
    ) {
        _session = State(initialValue: session)
        self.itemTransitionNamespace = itemTransitionNamespace
    }

    var body: some View {
        @Bindable var session = session

        shellContent
        .background(NotateLibraryDesign.warmBackground)
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.navigation,
            value: showsCollapsedRail
        )
        .onAppear {
            // `.automatic` may choose detail-only when an iPad first launches
            // in portrait, which leaves neither the expanded sidebar nor our
            // explicit rail visible. Resolve the initial regular-width state
            // immediately; subsequent changes still follow the user's toggle.
            splitVisibility = horizontalSizeClass == .compact
                ? .automatic
                : (prefersCollapsedSidebar ? .detailOnly : .all)
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            splitVisibility = newValue == .compact
                ? .automatic
                : (prefersCollapsedSidebar ? .detailOnly : .all)
        }
        .tint(NotateLibraryDesign.accent)
        .sheet(item: $session.sheet) { destination in
            sheet(for: destination)
        }
        .alert(
            session.namePrompt?.title ?? "Name",
            isPresented: Binding(
                get: { session.namePrompt != nil },
                set: { if $0 == false { session.namePrompt = nil } }
            )
        ) {
            TextField(
                session.namePrompt?.placeholder ?? "Name",
                text: Binding(
                    get: { session.namePrompt?.draftName ?? "" },
                    set: { session.namePrompt?.draftName = $0 }
                )
            )
            Button("Cancel", role: .cancel) {
                session.namePrompt = nil
            }
            Button(session.namePrompt?.confirmationTitle ?? "Done") {
                guard let prompt = session.namePrompt else { return }
                let name = prompt.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.isEmpty == false else { return }
                switch prompt.target {
                case let .rename(itemID):
                    session.actions.renameItem(itemID, name)
                }
                session.namePrompt = nil
            }
            .disabled(
                session.namePrompt?.draftName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ?? true
            )
        } message: {
            Text(session.namePrompt?.message ?? "Enter a name.")
        }
        .alert(
            "That Didn't Work",
            isPresented: Binding(
                get: { session.alertMessage != nil },
                set: { if $0 == false { session.alertMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { session.alertMessage = nil }
            },
            message: {
                Text(session.alertMessage ?? "Please try again.")
            }
        )
        .alert(
            "Delete Permanently?",
            isPresented: Binding(
                get: { session.pendingPermanentDeletion != nil },
                set: { isPresented in
                    if isPresented == false {
                        session.pendingPermanentDeletion = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                session.pendingPermanentDeletion = nil
            }
            Button("Delete Permanently", role: .destructive) {
                session.confirmPermanentDeletion()
            }
        } message: {
            Text(permanentDeleteMessage)
        }
    }

    @ViewBuilder
    private var shellContent: some View {
        if horizontalSizeClass == .compact {
            NavigationSplitView(columnVisibility: $splitVisibility) {
                LibrarySidebar(
                    session: session,
                    presentation: .expanded,
                    allowsPresentationToggle: false,
                    onTogglePresentation: {}
                )
            } detail: {
                detailContent
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            HStack(spacing: 0) {
                LibrarySidebar(
                    session: session,
                    presentation: prefersCollapsedSidebar ? .rail : .expanded,
                    allowsPresentationToggle: true,
                    onTogglePresentation: toggleSidebarPresentation
                )
                .frame(
                    width: prefersCollapsedSidebar
                        ? NotateLibraryDesign.sidebarRailWidth
                        : expandedSidebarWidth
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .leading).combined(with: .opacity)
                )

                detailContent
            }
        }
    }

    private var detailContent: some View {
        Group {
            if session.scope == .settings {
                LibrarySettingsView()
            } else {
                LibraryBrowserView(
                    session: session,
                    itemTransitionNamespace: itemTransitionNamespace
                )
            }
        }
    }

    private var showsCollapsedRail: Bool {
        horizontalSizeClass != .compact && prefersCollapsedSidebar
    }

    private var expandedSidebarWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? NotateLibraryDesign.accessibilitySidebarWidth
            : NotateLibraryDesign.sidebarWidth
    }

    private func toggleSidebarPresentation() {
        guard horizontalSizeClass != .compact else { return }
        let willCollapse = prefersCollapsedSidebar == false
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.navigation) {
            prefersCollapsedSidebar = willCollapse
        }
    }

    @ViewBuilder
    private func sheet(for destination: LibrarySheetDestination) -> some View {
        switch destination {
        case .newTag:
            LibraryTagEditor(title: "New Tag") { draft in
                session.actions.createTag(draft)
            }
            .presentationSizing(.form)

        case let .editTag(tagID):
            if let tag = session.repository.tags.first(where: { $0.id == tagID }) {
                LibraryTagEditor(
                    title: "Edit Tag",
                    initialName: tag.name,
                    initialColor: LibraryColorDraft(tag.color)
                ) { draft in
                    session.actions.updateTag(tagID, draft)
                }
                .presentationSizing(.form)
            }

        case let .newFolder(parentID):
            LibraryFolderEditor(title: "New Folder") { draft in
                session.actions.createFolder(parentID, draft)
            }
            .presentationSizing(.form)

        case let .newNotebook(parentID):
            LibraryNotebookEditor(title: "New Notebook") { draft in
                session.actions.createNotebook(parentID, draft)
            }
            .presentationSizing(.form)

        case let .folderAppearance(itemID):
            if let item = session.repository.item(id: itemID) {
                LibraryFolderEditor(
                    title: "Folder Appearance",
                    initialName: item.name,
                    initialColor: LibraryColorDraft(item.folderSettings?.color ?? .folderBlue),
                    initialSymbolName: item.folderSettings?.symbolName ?? "folder"
                ) { draft in
                    session.actions.updateFolder(itemID, draft)
                }
                .presentationSizing(.form)
            }

        case let .coverPicker(itemID):
            if let item = session.repository.item(id: itemID) {
                LibraryCoverPicker(
                    initialChoice: item.coverChoice,
                    itemID: item.id,
                    thumbnailStore: session.thumbnailStore
                ) { choice, customCover in
                    session.actions.setCover(itemID, choice, customCover)
                }
                .presentationSizing(.page)
            }

        case let .tagAssignment(itemID):
            if let item = session.repository.item(id: itemID) {
                LibraryTagAssignmentSheet(
                    repository: session.repository,
                    item: item,
                    onAssign: session.actions.assignTag,
                    onRemove: session.actions.removeTag,
                    onCreateTag: session.actions.createTag
                )
                .presentationSizing(.form)
            }

        case let .move(itemIDs):
            LibraryMoveSheet(
                repository: session.repository,
                movingItemIDs: itemIDs
            ) { parentID in
                if session.actions.moveItems(itemIDs, parentID) {
                    session.clearSelection()
                }
            }
            .presentationSizing(.form)
        }
    }

    private var permanentDeleteMessage: String {
        let itemCount = session.pendingPermanentDeletion?.count ?? 0
        if itemCount == 1 {
            return "This item and everything inside it will be deleted immediately. This can't be undone."
        }
        return "These \(itemCount) items and everything inside them will be deleted immediately. This can't be undone."
    }
}

private enum LibrarySidebarPresentation {
    case expanded
    case rail
}

private struct LibrarySidebar: View {
    let session: LibraryAppSession
    let presentation: LibrarySidebarPresentation
    let allowsPresentationToggle: Bool
    let onTogglePresentation: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isRail: Bool { presentation == .rail }

    var body: some View {
        ZStack {
            NotateLibraryDesign.sidebarBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                sidebarHeader

                ScrollView {
                    VStack(spacing: isRail ? 5 : 6) {
                        sidebarRow(.home, title: "Home", glyph: .home)
                        sidebarRow(.favorites, title: "Favorites", glyph: .favorite)
                        sidebarRow(.recent, title: "Recent", glyph: .recent)

                        if isRail {
                            railTagSection
                        } else {
                            expandedTagSection
                        }
                    }
                }
                .padding(.horizontal, isRail ? 7 : 14)
                .padding(.bottom, 18)
                // The tag region owns every flexible point between the fixed
                // header and footer. Explicitly claiming that space prevents
                // the footer from following short content into the middle of
                // the sidebar after a size-class or window-height change.
                .frame(maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)
                // During rubber-banding, ScrollView content can render beyond
                // its proposed bounds. Keep tag rows out of the pinned footer.
                .clipped()
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("library.sidebar.scroll")

                VStack(spacing: 0) {
                    Divider()
                        .opacity(0.24)

                    VStack(spacing: isRail ? 5 : 6) {
                        sidebarRow(.trash, title: "Trash", glyph: .trash)
                        sidebarRow(.settings, title: "Settings", glyph: .settings)
                    }
                    .padding(.horizontal, isRail ? 7 : 14)
                    .padding(.vertical, 9)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(NotateLibraryDesign.sidebarBackground)
                .zIndex(1)
                // The rail and expanded sidebar share one animated width. Clip the
                // foreground hierarchy to that width so labels, tag hit regions,
                // and the pinned footer can never paint or receive taps in the
                // detail column while the sidebar is expanding or collapsing.
                .clipped()
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: NotateDesign.Spacing.compact) {
            Spacer(minLength: 0)

            if allowsPresentationToggle {
                Button(action: onTogglePresentation) {
                    NotateCompactGlassGlyphLabel(
                        kind: .sidebar,
                        tint: .primary,
                        glyphSize: 19
                    )
                }
                .buttonStyle(NotatePressButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(isRail ? "Expand Sidebar" : "Collapse Sidebar")
                .accessibilityHint(
                    isRail
                        ? "Shows sidebar labels and tag details"
                        : "Shows a compact icon-only sidebar"
                )
                .accessibilityIdentifier("library.sidebar-toggle")
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
        .frame(height: 54)
        .padding(.horizontal, isRail ? 10 : 13)
    }

    private var expandedTagSection: some View {
        VStack(spacing: NotateDesign.Spacing.tight) {
            HStack {
                Text("Tags")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.76))
                Spacer()
                Button {
                    session.sheet = .newTag
                } label: {
                    NotateAppGlyph(kind: .add, tint: NotateLibraryDesign.accent, size: 18)
                        .notateMinimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Tag")
            }
            .frame(height: NotateDesign.Control.standard)
            .padding(.horizontal, NotateDesign.Spacing.control)

            ForEach(sidebarTags) { tag in
                tagRow(tag)
            }
        }
        .padding(.top, NotateDesign.Spacing.content)
        .padding(.bottom, NotateDesign.Spacing.control)
    }

    private var railTagSection: some View {
        VStack(spacing: 6) {
            Divider()
                .padding(.vertical, NotateDesign.Spacing.compact)

            ForEach(sidebarTags) { tag in
                tagRow(tag)
            }

            Button {
                session.sheet = .newTag
            } label: {
                NotateAppGlyph(kind: .add, tint: NotateLibraryDesign.accent, size: 18)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Tag")

            Divider()
                .padding(.vertical, NotateDesign.Spacing.compact)
        }
    }

    private func tagRow(_ tag: TagRecord) -> some View {
        let scope = LibraryScope.tag(tag.id)
        return Button {
            selectScope(scope)
        } label: {
            if isRail {
                NotateSelectableAppGlyph(
                    kind: .tag,
                    selectedTint: session.scope == scope ? .primary : tag.color.swiftUIColor,
                    keepsTintWhenUnselected: true,
                    isSelected: session.scope == scope,
                    size: 22
                )
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: NotateDesign.Radius.navigationRow,
                        style: .continuous
                    )
                )
                .modifier(
                    LibrarySidebarSelectionModifier(
                        isSelected: session.scope == scope,
                        tint: tag.color.swiftUIColor
                    )
                )
            } else {
                HStack(
                    alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
                    spacing: NotateDesign.Spacing.control
                ) {
                    NotateSelectableAppGlyph(
                        kind: .tag,
                        selectedTint: session.scope == scope ? .primary : tag.color.swiftUIColor,
                        keepsTintWhenUnselected: true,
                        isSelected: session.scope == scope,
                        size: 18
                    )
                    .frame(width: 22)

                    Text(tag.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .fixedSize(
                            horizontal: false,
                            vertical: dynamicTypeSize.isAccessibilitySize
                        )
                        .layoutPriority(1)

                    Spacer(minLength: NotateDesign.Spacing.compact)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 13)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: NotateDesign.Radius.navigationRow,
                        style: .continuous
                    )
                )
                .modifier(
                    LibrarySidebarSelectionModifier(
                        isSelected: session.scope == scope,
                        tint: tag.color.swiftUIColor
                    )
                )
            }
        }
        .buttonStyle(LibrarySidebarButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(tag.name)
        .accessibilityHint("Filters the library by this tag")
        .accessibilityIdentifier("library.sidebar.tag.\(tag.id.uuidString)")
        .accessibilityAddTraits(session.scope == scope ? .isSelected : [])
        .contextMenu {
            if LibraryPresetTag.resolve(tagID: tag.id) == nil {
                Button {
                    session.sheet = .editTag(tagID: tag.id)
                } label: {
                    LibraryMenuActionLabel(title: "Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    withAnimation(reduceMotion ? nil : NotateDesign.Motion.removal) {
                        session.actions.deleteTag(tag.id)
                    }
                } label: {
                    LibraryMenuActionLabel(
                        title: "Delete Tag",
                        systemImage: "trash",
                        isDestructive: true
                    )
                }
            }
        }
    }

    private var sidebarTags: [TagRecord] {
        let presetTags = LibraryPresetTag.allCases.compactMap { preset in
            session.repository.tags.first { tag in
                tag.id == preset.id
                    || tag.normalizedName == LibraryItemRecord.normalize(preset.title)
            }
        }
        let presetIDs = Set(presetTags.map(\.id))
        return presetTags + session.repository.tags.filter { presetIDs.contains($0.id) == false }
    }

    private func sidebarRow(
        _ scope: LibraryScope,
        title: String,
        glyph: NotateAppGlyphKind
    ) -> some View {
        Button {
            selectScope(scope)
        } label: {
            sidebarLabel(scope: scope, title: title, glyph: glyph)
        }
        .buttonStyle(LibrarySidebarButtonStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier("library.sidebar.\(scopeIdentifier(scope))")
        .accessibilityLabel(title)
        .accessibilityAddTraits(session.scope == scope ? .isSelected : [])
    }

    @ViewBuilder
    private func sidebarLabel(
        scope: LibraryScope,
        title: String,
        glyph: NotateAppGlyphKind
    ) -> some View {
        let isSelected = session.scope == scope
        if isRail {
            NotateSelectableAppGlyph(
                kind: glyph,
                selectedTint: isSelected ? .primary : selectedTint(for: scope),
                keepsTintWhenUnselected: keepsTintWhenUnselected(for: scope),
                isSelected: isSelected,
                size: 22
            )
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.navigationRow,
                    style: .continuous
                )
            )
            .modifier(
                LibrarySidebarSelectionModifier(
                    isSelected: isSelected,
                    tint: selectionTint(for: scope)
                )
            )
        } else {
            HStack(spacing: 13) {
                NotateSelectableAppGlyph(
                    kind: glyph,
                    selectedTint: isSelected ? .primary : selectedTint(for: scope),
                    keepsTintWhenUnselected: keepsTintWhenUnselected(for: scope),
                    isSelected: isSelected,
                    size: 22
                )
                .frame(width: 22)

                Text(title)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    .layoutPriority(1)

                Spacer()
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 14)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.navigationRow,
                    style: .continuous
                )
            )
            .modifier(
                LibrarySidebarSelectionModifier(
                    isSelected: isSelected,
                    tint: selectionTint(for: scope)
                )
            )
        }
    }

    private func selectedTint(for scope: LibraryScope) -> Color {
        switch scope {
        case .favorites:
            NotateDesign.Palette.favorite
        case .recent:
            NotateDesign.Palette.recent
        case .trash:
            NotateDesign.Palette.trash
        default:
            NotateLibraryDesign.accent
        }
    }

    private func keepsTintWhenUnselected(for scope: LibraryScope) -> Bool {
        switch scope {
        case .home, .favorites, .recent:
            true
        default:
            false
        }
    }

    private func selectionTint(for scope: LibraryScope) -> Color {
        switch scope {
        case .home, .favorites, .recent:
            selectedTint(for: scope)
        default:
            NotateLibraryDesign.accent
        }
    }

    private func selectScope(_ scope: LibraryScope) {
        withAnimation(reduceMotion ? nil : NotateDesign.Motion.navigation) {
            session.selectScope(scope)
        }
    }

    private func scopeIdentifier(_ scope: LibraryScope) -> String {
        switch scope {
        case .home: "home"
        case .favorites: "favorites"
        case .recent: "recent"
        case .trash: "trash"
        case .settings: "settings"
        case let .tag(id): "tag.\(id.uuidString)"
        case let .folder(id): "folder.\(id.uuidString)"
        }
    }
}

private struct LibrarySidebarButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && reduceMotion == false ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.feedback,
                value: configuration.isPressed
            )
    }
}

private struct LibrarySidebarSelectionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let isSelected: Bool
    var tint: Color = NotateDesign.Palette.accent

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: NotateDesign.Radius.navigationRow,
            style: .continuous
        )

        content
            .background {
                if isSelected {
                    selectionSurface(in: shape)
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.selection,
                value: isSelected
            )
    }

    @ViewBuilder
    private func selectionSurface(
        in shape: RoundedRectangle
    ) -> some View {
        shape
            .fill(NotateDesign.Palette.cardBackground)
            .overlay {
                shape.fill(
                    tint.opacity(
                        reduceTransparency
                            ? NotateDesign.Palette.opaqueSelectionFillOpacity
                            : NotateDesign.Palette.selectionFillOpacity
                    )
                )
            }
            .overlay {
                shape.strokeBorder(
                    tint.opacity(
                        NotateDesign.Hairline.selectedOpacity
                    ),
                    lineWidth: NotateDesign.Hairline.width(for: contrast)
                )
            }
    }
}
