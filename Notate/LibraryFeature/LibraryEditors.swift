import PhotosUI
import SwiftUI
import UIKit

struct LibraryTagEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onCommit: (LibraryTagDraft) -> Void

    @State private var name: String
    @State private var selectedColor: LibraryColorDraft
    @State private var customColor: Color
    @FocusState private var isNameFocused: Bool

    init(
        title: String,
        initialName: String = "",
        initialColor: LibraryColorDraft = .violet,
        onCommit: @escaping (LibraryTagDraft) -> Void
    ) {
        self.title = title
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
        _selectedColor = State(initialValue: initialColor)
        _customColor = State(initialValue: initialColor.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Color") {
                    ScrollView(.horizontal) {
                        HStack(spacing: NotateDesign.Spacing.control) {
                            ForEach(LibraryColorDraft.palette, id: \.self) { color in
                                colorButton(color)
                            }
                        }
                        ColorPicker("Custom Color", selection: $customColor, supportsOpacity: false)
                            .labelsHidden()
                            .notateMinimumHitTarget()
                            .accessibilityLabel("Custom tag color")
                            .onChange(of: customColor) { _, value in
                                selectedColor = LibraryColorDraft(value)
                            }
                    }
                    .scrollIndicators(.hidden)
                }
                Section("Name") {
                    TextField("Tag name", text: $name)
                        .focused($isNameFocused)
                        .accessibilityIdentifier("library.tag.name")
                        .submitLabel(.done)
                        .onSubmit(commit)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(NotateLibraryDesign.warmBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: commit)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .task {
                guard NotateUITestLaunchConfiguration.suppressesInitialFocus == false else {
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                isNameFocused = true
            }
        }
    }

    private func colorButton(_ color: LibraryColorDraft) -> some View {
        Button {
            selectedColor = color
            customColor = color.color
        } label: {
            ZStack {
                Circle().fill(color.color)
                if selectedColor == color {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(color.contrastingForeground)
                }
            }
            .frame(width: 30, height: 30)
            .frame(
                minWidth: NotateDesign.Control.minimumHitTarget,
                minHeight: NotateDesign.Control.minimumHitTarget
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(color.accessibilityName) tag color")
        .accessibilityValue(selectedColor == color ? "Selected" : "")
        .accessibilityAddTraits(selectedColor == color ? .isSelected : [])
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard trimmedName.isEmpty == false else { return }
        onCommit(LibraryTagDraft(name: trimmedName, color: selectedColor))
        dismiss()
    }
}



struct LibraryFolderEditor: View {
    private enum AppearanceTab: String, CaseIterable, Identifiable {
        case color = "Color"
        case icon = "Icon"

        var id: Self { self }
    }

    private struct SymbolOption: Identifiable {
        let name: String
        let label: String

        var id: String { name }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let onCommit: (LibraryFolderDraft) -> Void

    @State private var name: String
    @State private var selectedColor: LibraryColorDraft
    @State private var customColor: Color
    @State private var symbolName: String
    @State private var appearanceTab: AppearanceTab = .color
    @FocusState private var isNameFocused: Bool

    private let symbols = [
        SymbolOption(name: "folder", label: "Folder"),
        SymbolOption(name: "graduationcap", label: "Study"),
        SymbolOption(name: "briefcase", label: "Work"),
        SymbolOption(name: "paintpalette", label: "Art"),
        SymbolOption(name: "music.note", label: "Music"),
        SymbolOption(name: "airplane", label: "Travel"),
        SymbolOption(name: "chevron.left.forwardslash.chevron.right", label: "Coding"),
        SymbolOption(name: "lightbulb", label: "Ideas"),
        SymbolOption(name: "person.crop.circle", label: "Personal"),
    ]

    init(
        title: String,
        initialName: String = "",
        initialColor: LibraryColorDraft = .folderDefault,
        initialSymbolName: String = "folder",
        onCommit: @escaping (LibraryFolderDraft) -> Void
    ) {
        self.title = title
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
        _selectedColor = State(initialValue: initialColor)
        _customColor = State(initialValue: initialColor.color)
        _symbolName = State(initialValue: initialSymbolName)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 18) {
                        LibraryFolderEditorPreview(color: selectedColor.color, symbolName: symbolName)
                            .accessibilityHidden(true)

                        TextField("Folder name", text: $name)
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 18)
                            .frame(maxWidth: 470, minHeight: 46)
                            .notateLibraryCardSurface()
                            .focused($isNameFocused)
                            .accessibilityIdentifier("library.folder.title")
                            .submitLabel(.done)
                            .onSubmit(commit)

                        Picker("Folder appearance", selection: $appearanceTab) {
                            ForEach(AppearanceTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        Group {
                            switch appearanceTab {
                            case .color:
                                folderColorGrid
                            case .icon:
                                folderIconGrid
                            }
                        }
                        .frame(maxWidth: 470)
                        .transition(.opacity)
                        .animation(
                            reduceMotion ? nil : NotateDesign.Motion.content,
                            value: appearanceTab
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(
                        .horizontal,
                        dynamicTypeSize.isAccessibilitySize
                            ? NotateDesign.Spacing.content
                            : NotateDesign.Spacing.page
                    )
                    .padding(.top, 64)
                    .padding(.bottom, 28)
                }
                .scrollBounceBehavior(.basedOnSize)
                folderEditorChrome
            }
            .background(NotateLibraryDesign.warmBackground)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                guard name.isEmpty else { return }
                guard NotateUITestLaunchConfiguration.suppressesInitialFocus == false else {
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                isNameFocused = true
            }
        }
    }

    private var folderEditorChrome: some View {
        GlassEffectContainer(spacing: NotateDesign.Spacing.control) {
            HStack(spacing: NotateDesign.Spacing.control) {
                Button {
                    dismiss()
                } label: {
                    NotateCompactGlassGlyphLabel(
                        kind: .close,
                        tint: .primary,
                        glyphSize: 19
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                Spacer(minLength: NotateDesign.Spacing.control)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: NotateDesign.Spacing.control)
                Button(action: commit) {
                    NotateCompactGlassGlyphLabel(
                        kind: .confirm,
                        tint: NotateLibraryDesign.accent,
                        isSelected: true,
                        glyphSize: 20
                    )
                }
                .buttonStyle(.plain)
                .disabled(trimmedName.isEmpty)
                .accessibilityLabel(title == "New Folder" ? "Create" : "Done")
                .accessibilityIdentifier("library.folder.done")
            }
            .padding(.horizontal, NotateDesign.Spacing.content)
            .padding(.top, NotateDesign.Spacing.tight)
        }
        .padding(.horizontal, NotateDesign.Spacing.content)
        .padding(.top, NotateDesign.Spacing.tight)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var folderColorGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 10) {
            ForEach(LibraryColorDraft.folderPalette, id: \.self) { color in
                Button {
                    selectedColor = color
                    customColor = color.color
                } label: {
                    Circle()
                        .fill(color.color)
                        .padding(NotateDesign.Spacing.tight)
                        .overlay {
                            if selectedColor == color {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(color.contrastingForeground)
                            }
                        }
                        .overlay {
                            if selectedColor == color {
                                Circle()
                                    .strokeBorder(color.color.opacity(0.72), lineWidth: 2)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .frame(
                            minWidth: NotateDesign.Control.minimumHitTarget,
                            minHeight: NotateDesign.Control.minimumHitTarget
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(color.accessibilityName) folder color")
                .accessibilityValue(selectedColor == color ? "Selected" : "")
                .accessibilityAddTraits(selectedColor == color ? .isSelected : [])
            }
        }
        ColorPicker("Custom Color", selection: $customColor, supportsOpacity: false)
            .labelsHidden()
            .notateMinimumHitTarget()
            .accessibilityLabel("Custom folder color")
            .onChange(of: customColor) { _, value in
                selectedColor = LibraryColorDraft(value)
            }
    }

        .padding(.vertical, 6)
    }

    private var folderIconGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58))], spacing: 10) {
            ForEach(symbols) { symbol in
                Button {
                    symbolName = symbol.name
                } label: {
                    NotateFolderGlyph(
                        symbolName: symbol.name,
                        tint: selectedColor.color,
                        isSelected: symbolName == symbol.name,
                        size: 24
                    )
                }
                .frame(width: 50, height: 50)
                .background(
                    symbolName == symbol.name
                        ? selectedColor.color.opacity(0.13)
                        : Color(uiColor: .tertiarySystemFill),
                    in: .rect(cornerRadius: NotateDesign.Radius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: NotateDesign.Radius.control,
                        style: .continuous
                    )
                    .strokeBorder(
                        symbolName == symbol.name
                            ? selectedColor.color.opacity(0.72)
                            : NotateLibraryDesign.hairline,
                        lineWidth: symbolName == symbol.name ? 1.5 : 0.8
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(symbol.label)
            .accessibilityValue(symbolName == symbol.name ? "Selected" : "")
            .accessibilityAddTraits(symbolName == symbol.name ? .isSelected : [])
        }
        .padding(.vertical, 6)
    }

    private func commit() {
        guard trimmedName.isEmpty == false else { return }
        onCommit(
            LibraryFolderDraft(
                name: trimmedName,
                color: selectedColor,
                symbolName: symbolName
            )
        )
        dismiss()
    }
}

private struct LibraryFolderEditorPreview: View {
    let color: Color
    let symbolName: String

    var body: some View {
        LibraryFolderArtwork(
            symbolName: symbolName,
            color: color,
            showsBackdrop: false
        )
        .aspectRatio(300 / 230, contentMode: .fit)
        .frame(maxWidth: 300)
        .padding(.vertical, NotateDesign.Spacing.tight)
    }
}



struct LibraryNotebookEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let onCommit: (LibraryNotebookDraft) -> Void

    @State private var name: String
    @State private var coverChoice: LibraryCoverChoice
    @State private var customCover: LibraryCustomCoverDraft?
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var coverImportError: String?
    @FocusState private var isNameFocused: Bool

    init(
        title: String,
        initialName: String = "",
        initialCoverChoice: LibraryCoverChoice = .automatic,
        onCommit: @escaping (LibraryNotebookDraft) -> Void
    ) {
        self.title = title
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
        _coverChoice = State(initialValue: initialCoverChoice)
        _customCover = State(initialValue: nil)
    }

    var body: some View {
        let customPreview = customCover?.data
        let customSelected = isCustomCoverSelected
        let customTileWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 164 : 116

        NavigationStack {
            ScrollView {
                VStack(spacing: NotateDesign.Spacing.page) {
                    LibraryCoverArtwork(
                        choice: coverChoice,
                        title: trimmedName.isEmpty ? nil : trimmedName,
                        customImageData: customCover?.data
                    )
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .frame(width: 168)
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 7)
                    .padding(.top, NotateDesign.Spacing.compact)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
                        Text("Name")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextField("Notebook title", text: $name)
                            .focused($isNameFocused)
                            .accessibilityIdentifier("library.notebook.title")
                            .submitLabel(.done)
                            .onSubmit(commit)
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .notateLibraryCardSurface()
                    }
                    VStack(alignment: .leading, spacing: NotateDesign.Spacing.control) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                coverSectionTitle
                                Spacer()
                                coverSectionHint
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            coverSectionTitle
                            coverSectionHint
                        }
                    }
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(LibraryCoverOption.all) { option in
                            LibraryCoverSelectionTile(
                                option: option,
                                selectedChoice: coverChoice,
                                previewTitle: trimmedName.isEmpty ? nil : trimmedName
                            ) {
                                withAnimation(
                                    reduceMotion ? nil : NotateDesign.Motion.selection
                                ) {
                                    coverChoice = option.choice
                                }
                            }
                            .frame(width: dynamicTypeSize.isAccessibilitySize ? 164 : 116)
                        }
                    }
                }
                PhotosPicker(
                    selection: $selectedCoverPhoto,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    LibraryCustomCoverSelectionTile(
                        imageData: customPreview,
                        isSelected: customSelected
                    )
                    .frame(width: customTileWidth)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.cover.custom")
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: 620)
        .padding(
            .horizontal,
            dynamicTypeSize.isAccessibilitySize ? NotateDesign.Spacing.content : 22
        )
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(NotateLibraryDesign.warmBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create & Open", action: commit)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            isNameFocused = true
        }
        .onChange(of: selectedCoverPhoto) { _, selection in
            guard let selection else { return }
            Task { await importCustomCover(from: selection) }
        }
        .alert(
            "Cover Could Not Be Added",
            isPresented: Binding(
                get: { coverImportError != nil },
                set: { if $0 == false { coverImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { coverImportError = nil }
        } message: {
            Text(coverImportError ?? "Choose another image and try again.")
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var coverSectionTitle: some View {
        Text("Cover templates")
            .font(.headline)
    }

    private var coverSectionHint: some View {
        Text("Swipe to explore")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func commit() {
        guard trimmedName.isEmpty == false else { return }
        onCommit(
            LibraryNotebookDraft(
                name: trimmedName,
                coverChoice: coverChoice,
                customCover: isCustomCoverSelected ? customCover : nil
            )
        )
        dismiss()
    }

    private var isCustomCoverSelected: Bool {
        if case .customAsset = coverChoice { return true }
        return false
    }

    @MainActor
    private func importCustomCover(from selection: PhotosPickerItem) async {
        do {
            guard let transfer = try await selection.loadTransferable(
                type: CanvasImageTransfer.self
            ) else {
                throw LibraryCustomCoverImageError.unreadableImage
            }
            defer { transfer.discard() }
            let normalized = try await LibraryCustomCoverImageNormalizer.normalizedPNG(
                from: transfer.fileURL
            )
            let draft = LibraryCustomCoverDraft(data: normalized)
            withAnimation(reduceMotion ? nil : NotateDesign.Motion.selection)
            customCover = draft
            coverChoice = .customAsset(relativePath: draft.itemRelativePath)
        } catch {
            coverImportError = error.localizedDescription
        }
    }
}








struct LibraryCoverPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let itemID: UUID?
    let thumbnailStore: LibraryAutomaticThumbnailStore
    let onPick: (LibraryCoverChoice, LibraryCustomCoverDraft?) -> Void
    @State private var selectedChoice: LibraryCoverChoice
    @State private var customCover: LibraryCustomCoverDraft?
    @State private var customPreviewData: Data?
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var coverImportError: String?

    init(
        initialChoice: LibraryCoverChoice = .automatic,
        itemID: UUID? = nil,
        thumbnailStore: LibraryAutomaticThumbnailStore = .shared,
        onPick: @escaping (LibraryCoverChoice, LibraryCustomCoverDraft?) -> Void
    ) {
        self.itemID = itemID
        self.thumbnailStore = thumbnailStore
        self.onPick = onPick
        _selectedChoice = State(initialValue: initialChoice)
        _customCover = State(initialValue: nil)
        _customPreviewData = State(initialValue: nil)
    }

    var body: some View {
        let visibleCustomPreview = customCover?.data ?? customPreviewData
        let customSelected = isCustomCoverSelected

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotateDesign.Spacing.content) {
                    VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                        Text("Cover templates")
                            .font(.title3.weight(.semibold))
                        Text("Choose a tactile cover, or let the first page become the cover.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(
                        columns: coverColumns,
                        alignment: .leading,
                        spacing: NotateDesign.Spacing.section
                    ) {
                        ForEach(LibraryCoverOption.all) { option in
                            LibraryCoverSelectionTile(
                                option: option,
                                selectedChoice: selectedChoice,
                                previewTitle: nil
                            ) {
                                withAnimation(
                                    reduceMotion ? nil : NotateDesign.Motion.selection
                                ) {
                                    selectedChoice = option.choice
                                }
                            }
                        }
                        PhotosPicker(
                            selection: $selectedCoverPhoto,
                            matching: .images,
                            preferredItemEncoding: .current
                        ) {
                            LibraryCustomCoverSelectionTile(
                                imageData: visibleCustomPreview,
                                isSelected: customSelected
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.cover.custom")
                    }
                }
                .padding(
                    dynamicTypeSize.isAccessibilitySize ? NotateDesign.Spacing.content : 22
                )
            }
            .background(NotateLibraryDesign.warmBackground)
            .navigationTitle("Choose Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pick") {
                        onPick(
                            selectedChoice,
                            isCustomCoverSelected ? customCover : nil
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task(id: itemID) {
                guard isCustomCoverSelected, let itemID else { return }
                customPreviewData = await thumbnailStore.data(for: itemID)
            }
            .onChange(of: selectedCoverPhoto) { _, selection in
                guard let selection else { return }
                Task { await importCustomCover(from: selection) }
            }
            .alert(
                "Cover Could Not Be Added",
                isPresented: Binding(
                    get: { coverImportError != nil },
                    set: { if $0 == false { coverImportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { coverImportError = nil }
            } message: {
                Text(coverImportError ?? "Choose another image and try again.")
            }
        }
    }

    private var coverColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [
                GridItem(
                    .flexible(minimum: 0),
                    spacing: NotateDesign.Spacing.content,
                    alignment: .top
                ),
            ]
        }
        return [
            GridItem(
                .adaptive(minimum: 118, maximum: 154),
                spacing: NotateDesign.Spacing.content,
                alignment: .top
            ),
        ]
    }

    private var isCustomCoverSelected: Bool {
        if case .customAsset = selectedChoice { return true }
        return false
    }

    @MainActor
    private func importCustomCover(from selection: PhotosPickerItem) async {
        do {
            guard let transfer = try await selection.loadTransferable(
                type: CanvasImageTransfer.self
            ) else {
                throw LibraryCustomCoverImageError.unreadableImage
            }
            defer { transfer.discard() }
            let normalized = try await LibraryCustomCoverImageNormalizer.normalizedPNG(
                from: transfer.fileURL
            )
            let draft = LibraryCustomCoverDraft(data: normalized)
            withAnimation(reduceMotion ? nil : NotateDesign.Motion.selection)
            customCover = draft
            customPreviewData = normalized
            selectedChoice = .customAsset(relativePath: draft.itemRelativePath)
        } catch {
            coverImportError = error.localizedDescription
        }
    }
}

private struct LibraryCoverOption: Identifiable {
    let title: String
    let subtitle: String
    let choice: LibraryCoverChoice

    var id: String {
        switch choice {
        case .automatic:
            "automatic"
        case let .preset(preset):
            "preset-\(preset.rawValue)"
        case let .customAsset(relativePath):
            "custom-\(relativePath)"
        }
    }

    static let all: [LibraryCoverOption] = [
        LibraryCoverOption(
            title: "Automatic",
            subtitle: "Use the first page",
            choice: .automatic
        ),
    ] + LibraryCuratedCover.curated.map { cover in
        LibraryCoverOption(
            title: cover.title,
            subtitle: cover.subtitle,
            choice: .preset(cover.preset)
        )
    }
}

private struct LibraryCoverSelectionTile: View {
    let option: LibraryCoverOption
    let selectedChoice: LibraryCoverChoice
    let previewTitle: String?
    let onSelect: () -> Void

    private var isSelected: Bool { selectedChoice == option.choice }

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
                ZStack(alignment: .topTrailing) {
                    LibraryCoverArtwork(choice: option.choice, title: previewTitle)
                        .shadow(color: .black.opacity(0.12), radius: 7, y: 4)

                    if isSelected {
                        NotateAppGlyph(
                            kind: .confirm,
                            tint: NotateLibraryDesign.accent,
                            isSelected: true,
                            size: 18
                        )
                        .frame(width: 27, height: 27)
                        .notateBadgeSurface(in: Circle())
                        .padding(7)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: NotateDesign.Radius.option,
                        style: .continuous
                    )
                    .strokeBorder(
                        isSelected
                            ? NotateLibraryDesign.accent
                            : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 2.5 : 0.8
                    )
                }
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(option.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title), \(option.subtitle)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LibraryCustomCoverSelectionTile: View {
    let imageData: Data?
    let isSelected: Bool

    @State private var previewImage: UIImage?

    nonisolated init(imageData: Data?, isSelected: Bool) {
        self.imageData = imageData
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [
                                    NotateLibraryDesign.accent.opacity(0.08),
                                    Color(uiColor: .secondarySystemBackground)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            NotateAppGlyph(
                                kind: .add,
                                tint: NotateLibraryDesign.accent,
                                size: 30
                            )
                        }
                    }
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: NotateDesign.Radius.option,
                        style: .continuous
                    )
                )
                if isSelected {
                    NotateAppGlyph(
                        kind: .confirm,
                        tint: NotateLibraryDesign.accent,
                        isSelected: true,
                        size: 18
                    )
                    .frame(width: 27, height: 27)
                    .notateBadgeSurface(in: Circle())
                    .padding(7)
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.option,
                    style: .continuous
                )
                .strokeBorder(
                    isSelected ? NotateLibraryDesign.accent : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 2.5 : 0.8
                )
            }
            // Keep the intentionally icon-only action on the same grid track
            // as cover cards, whose two metadata lines determine row height.
            // Hidden labels reserve that adaptive Dynamic Type footprint
            // without reintroducing visual copy beneath the plus glyph.
            Text("Add cover")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .hidden()
            Text("Choose photo")
                .font(.caption2)
                .lineLimit(1)
                .hidden()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(imageData == nil ? "Add your own cover" : "Custom cover")
        .accessibilityHint("Opens Photos")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: imageData) {
            previewImage = nil
            guard let imageData else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                LibraryBoundedImageDecoder.downsampledImage(
                    from: imageData,
                    policy: .customCover
                )
            }.value
            guard Task.isCancelled == false else { return }
            previewImage = decoded
        }
    }
}

private enum LibraryCustomCoverImageError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "The selected photo could not be read."
        case .encodingFailed: "The selected photo could not be prepared as a cover."
        }
    }
}

@MainActor
private enum LibraryCustomCoverImageNormalizer {
    private static let outputSize = CGSize(width: 1_240, height: 1_754)
    private static let imageIngestor = CanvasImageIngestor(
        policy: CanvasImageIngestionPolicy.canvasDefault,
        maximumEncodedByteCount: CanvasImageIngestionPolicy.canvasDefault
            .maximumEncodedByteCount,
        maximumSourcePixelCount: CanvasImageIngestionPolicy.canvasDefault
            .maximumSourcePixelCount,
        maximumDecodedPixelCount: 2_400 * 2_400,
        maximumDecodedDimension: 2_400
    )

    static func normalizedPNG(from fileURL: URL) async throws -> Data {
        // ImageIO metadata inspection and orientation-normalized decode run on
        // the ingestion actor; only the small cover composition returns here.
        let imported = try await imageIngestor.ingest(fileURL: fileURL)
        let image = imported.image

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let normalized = renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))

            let sourceSize = CGSize(width: image.width, height: image.height)
            let scale = max(
                outputSize.width / sourceSize.width,
                outputSize.height / sourceSize.height
            )
            let drawSize = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            let drawRect = CGRect(
                x: (outputSize.width - drawSize.width) / 2,
                y: (outputSize.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            UIImage(cgImage: image).draw(in: drawRect)
        }
        guard let result = normalized.pngData() else {
            throw LibraryCustomCoverImageError.encodingFailed
        }
        return result
    }
}








struct LibraryTagAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let repository: LibraryRepository
    let item: LibraryItemRecord
    let onAssign: (UUID, UUID) -> Void
    let onRemove: (UUID, UUID) -> Void
    let onCreateTag: (LibraryTagDraft) -> Void

    @State private var assignedTagIDs: Set<UUID> = []
    @State private var isCreatingTag = false
    @AccessibilityFocusState private var isNewTagButtonAccessibilityFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if repository.tags.isEmpty {
                        ContentUnavailableView(
                            "No Tags Yet",
                            systemImage: "tag",
                            description: Text("Create a tag, then use it to filter related work.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(repository.tags) { tag in
                            Toggle(isOn: assignmentBinding(for: tag)) {
                                HStack(spacing: NotateDesign.Spacing.control) {
                                    Image(systemName: "tag.fill")
                                        .foregroundStyle(tag.color.swiftUIColor)
                                        .frame(width: 22)
                                    Text(tag.name)
                                }
                                .frame(minHeight: NotateDesign.Control.minimumHitTarget)
                            }
                            .tint(tag.color.swiftUIColor)
                            .accessibilityHint("Adds or removes this tag from \(item.name)")
                        }
                    }
                } header: {
                    Text("Assigned to \(item.name)")
                }
                Section {
                    Button("New Tag", systemImage: "plus") {
                        isCreatingTag = true
                    }
                    .frame(minHeight: NotateDesign.Control.minimumHitTarget)
                    .accessibilityFocused($isNewTagButtonAccessibilityFocused)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NotateLibraryDesign.warmBackground)
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                assignedTagIDs = Set(repository.tags(for: item.id).map(\.id))
            }
            .sheet(isPresented: $isCreatingTag) {
                LibraryTagEditor(title: "New Tag", onCommit: onCreateTag)
                    .presentationSizing(.form)
            }
            .onChange(of: isCreatingTag) { _, isPresented in
                guard isPresented == false else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    isNewTagButtonAccessibilityFocused = true
                }
            }
        }
    }

    private func assignmentBinding(for tag: TagRecord) -> Binding<Bool> {
        Binding(
            get: { assignedTagIDs.contains(tag.id) },
            set: { isAssigned in
                if isAssigned {
                    assignedTagIDs.insert(tag.id)
                    onAssign(tag.id, item.id)
                } else {
                    assignedTagIDs.remove(tag.id)
                    onRemove(tag.id, item.id)
                }
            }
        )
    }
}

struct LibraryMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: LibraryRepository
    let movingItemIDs: Set<UUID>
    let onMove: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    move(to: nil)
                } label: {
                    HStack(spacing: 10) {
                        NotateAppGlyph(
                            kind: .home,
                            tint: NotateLibraryDesign.accent,
                            size: 21
                        )
                        Text("Home")
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: NotateDesign.Control.minimumHitTarget,
                        alignment: .leading
                    )
                }
                Section("Folders") {
                    ForEach(candidateFolders) { folder in
                        Button {
                            move(to: folder.id)
                        } label: {
                            HStack(spacing: NotateDesign.Spacing.control) {
                                NotateFolderGlyph(
                                    symbolName: folder.folderSettings?.symbolName ?? "folder",
                                    tint: (folder.folderSettings?.color ?? .folderBlue).swiftUIColor,
                                    size: 22
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name)
                                    Text(folderPath(folder))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: NotateDesign.Control.minimumHitTarget)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NotateLibraryDesign.warmBackground)
            .navigationTitle("Move \(movingItemIDs.count == 1 ? "Item" : "Items")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private var candidateFolders: [LibraryItemRecord] {
        let forbidden = Set(movingItemIDs.flatMap { id in
            repository.subtree(of: id, includingRoot: true).map(\.id)
        })
        return repository.items
            .filter { $0.kind == .folder && $0.isTrashed == false && forbidden.contains($0.id) == false }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func folderPath(_ folder: LibraryItemRecord) -> String {
        var names = [folder.name]
        var parentID = folder.parentID
        var visited: Set<UUID> = [folder.id]
        while let id = parentID,
            visited.insert(id).inserted,
            let parent = repository.item(id: id) {
            names.append(parent.name)
            parentID = parent.parentID
        }
        return (["Home"] + names.reversed()).joined(separator: " / ")
    }

    private func move(to parentID: UUID?) {
        onMove(parentID)
        dismiss()
    }
}




struct LibrarySettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(NotatePreferences.appearanceKey)
    private var appearance = NotateAppearance.system
    @AppStorage(NotatePreferences.drawWithFingerKey)
    private var drawWithFingerByDefault = false
    @AppStorage(NotatePreferences.scrollDirectionKey)
    private var defaultScrollDirection = CanvasScrollDirection.vertical
    @State private var showsResetConfirmation = false

    var body: some View {
        ZStack {
            NotateLibraryDesign.warmBackground
                .ignoresSafeArea()
            VStack(spacing: 0) {
                settingsHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: NotateDesign.Spacing.page) {
                        LibrarySettingsControlSection(
                            title: "Appearance",
                            footer: "System follows your iPad's current Light or Dark appearance."
                        ) {
                            appearancePicker
                        }
                        LibrarySettingsControlSection(
                            title: "Writing",
                            footer: drawWithFingerByDefault
                                ? "New notes accept Apple Pencil or one-finger drawing. Use two fingers to move and zoom."
                                : "New notes reserve drawing for Apple Pencil. Fingers move and zoom the page."
                        ) {
                            Toggle("Draw with Finger", isOn: $drawWithFingerByDefault)
                                .frame(minHeight: 54)
                                .accessibilityIdentifier("settings.drawWithFinger")
                        }
                        LibrarySettingsControlSection(
                            title: "Page View",
                            footer: "Vertical scrolls continuously. Horizontal starts with one full page and snaps left or right, one page at a time. This applies to new notebooks and can be changed later in Note Settings."
                        ) {
                            defaultScrollingPicker
                        }
                        LibrarySettingsSection(
                            title: "Storage & Privacy",
                            rows: [
                                .init(title: "Storage", value: "On this iPad"),
                                .init(title: "Folder depth", value: "\(LibraryRepository.maximumFolderDepth) levels"),
                            ],
                            footer: "Your notes stay in Notate's private app container. Notate does not use advertising or analytics SDKs."
                        )
                        LibrarySettingsSection(
                            title: "About",
                            rows: [
                                .init(title: "App", value: "Notate"),
                                .init(
                                    title: "Version",
                                    value: NotatePreferences.versionDescription
                                ),
                                .init(
                                    title: "Privacy",
                                    value: "View policy",
                                    destination: .privacy
                                ),
                            ]
                        )
                        Button("Restore Default Settings", role: .destructive) {
                            showsResetConfirmation = true
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            NotateDesign.Palette.cardBackground,
                            in: RoundedRectangle(
                                cornerRadius: NotateDesign.Radius.control,
                                style: .continuous
                            )
                        )
                        .accessibilityIdentifier("settings.restoreDefaults")
                        .frame(
                            maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 760,
                            alignment: .leading
                        )
                        .padding(.horizontal, settingsHorizontalInset)
                        .padding(.top, NotateDesign.Spacing.compact)
                        .padding(.bottom, NotateDesign.Spacing.spacious)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("settings.scrollView")
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            // The library owns its own compact header. Keeping the root navigation
            // bar hidden avoids placing a second title underneath the custom
            // sidebar and gives Settings the same content lane as Home.
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                "Restore Default Settings?",
                isPresented: $showsResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive, action: restoreDefaults)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This changes app preferences only. Your notes and folders are not affected.")
            }
        }
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 46)
                .accessibilityHidden(true)
            Text("Settings")
                .font(.largeTitle.weight(.bold))
                .fontDesign(.serif)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("library.settings.title")
        }
        .padding(.horizontal, settingsHorizontalInset)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(NotateLibraryDesign.warmBackground)
    }

    private var settingsHorizontalInset: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 18 : 28
    }

    @ViewBuilder
    private var appearancePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                Text("Theme")
                    .accessibilityHidden(true)
                appearanceMenu
            }
            .padding(.vertical, NotateDesign.Spacing.control)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        } else {
            HStack(spacing: NotateDesign.Spacing.control) {
                Text("Theme")
                    .accessibilityHidden(true)
                Spacer(minLength: NotateDesign.Spacing.content)
                appearanceMenu
            }
            .frame(maxWidth: .infinity, minHeight: 54)
        }
    }

    @ViewBuilder
    private var defaultScrollingPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                Text("Scroll Direction")
                    .accessibilityHidden(true)
                scrollingMenu
            }
            .padding(.vertical, NotateDesign.Spacing.control)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        } else {
            HStack(spacing: NotateDesign.Spacing.control) {
                Text("Scroll Direction")
                    .accessibilityHidden(true)
                Spacer(minLength: NotateDesign.Spacing.content)
                scrollingMenu
            }
            .frame(maxWidth: .infinity, minHeight: 54)
        }
    }

    private var appearanceMenu: some View {
        Menu {
            ForEach(NotateAppearance.allCases) { option in
                Button {
                    appearance = option
                } label: {
                    if appearance == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            settingsMenuLabel(appearance.title)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .tint(Color(uiColor: .secondaryLabel))
        .accessibilityLabel("Theme")
        .accessibilityValue(appearance.title)
        .accessibilityIdentifier("settings.appearance")
    }

    private var scrollingMenu: some View {
        Menu {
            ForEach(CanvasScrollDirection.allCases, id: \.self) { direction in
                Button {
                    defaultScrollDirection = direction
                } label: {
                    if defaultScrollDirection == direction {
                        Label(direction.title, systemImage: "checkmark")
                    } else {
                        Text(direction.title)
                    }
                }
            }
        } label: {
            settingsMenuLabel(defaultScrollDirection.title)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .tint(Color(uiColor: .secondaryLabel))
        .accessibilityLabel("Scroll Direction")
        .accessibilityValue(defaultScrollDirection.title)
        .accessibilityIdentifier("settings.defaultScrolling")
    }

    private func settingsMenuLabel(_ value: String) -> some View {
        HStack(spacing: NotateDesign.Spacing.compact) {
            Text(value)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, NotateDesign.Spacing.compact)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func restoreDefaults() {
        appearance = .system
        drawWithFingerByDefault = false
        defaultScrollDirection = .vertical
    }
}




private struct LibrarySettingsControlSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, NotateDesign.Spacing.content)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, NotateDesign.Spacing.content)
            .background {
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.control,
                    style: .continuous
                )
                .fill(NotateDesign.Palette.cardBackground)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.control,
                    style: .continuous
                )
                .strokeBorder(
                    Color.primary.opacity(
                        NotateDesign.Hairline.opacity(for: contrast, subtle: true)
                    ),
                    lineWidth: NotateDesign.Hairline.width(for: contrast)
                )
            }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NotateDesign.Spacing.content)
            }
        }
    }
}




private enum LibrarySettingsDestination {
    case privacy
}




private struct LibrarySettingsRow: Identifiable {
    let title: String
    let value: String
    var destination: LibrarySettingsDestination? = nil

    var id: String { title }
}




private struct LibrarySettingsSection: View {
    let title: String
    let rows: [LibrarySettingsRow]
    var footer: String?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, NotateDesign.Spacing.content)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if let destination = row.destination {
                        NavigationLink {
                            destinationView(for: destination)
                        } label: {
                            settingsRowContent(row, showsDisclosureIndicator: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the privacy policy")
                    } else {
                        settingsRowContent(row, showsDisclosureIndicator: false)
                    }

                    if index < rows.count - 1 {
                        Divider()
                            .padding(.leading, NotateDesign.Spacing.content)
                    }
                }
            }
            .background {
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.control,
                    style: .continuous
                )
                .fill(NotateDesign.Palette.cardBackground)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.control,
                    style: .continuous
                )
                .strokeBorder(
                    Color.primary.opacity(
                        NotateDesign.Hairline.opacity(for: contrast, subtle: true)
                    ),
                    lineWidth: NotateDesign.Hairline.width(for: contrast)
                )
            }

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NotateDesign.Spacing.content)
            }
        }
    }

    private func settingsRowContent(
        _ row: LibrarySettingsRow,
        showsDisclosureIndicator: Bool
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                    Text(row.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    HStack(alignment: .firstTextBaseline, spacing: NotateDesign.Spacing.compact) {
                        Text(row.value)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)

                        disclosureIndicator(isVisible: showsDisclosureIndicator)
                    }
                }
                .padding(.vertical, NotateDesign.Spacing.control)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: NotateDesign.Spacing.content) {
                    Text(row.title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Spacer(minLength: NotateDesign.Spacing.content)

                    Text(row.value)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)

                    disclosureIndicator(isVisible: showsDisclosureIndicator)
                }
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, NotateDesign.Spacing.content)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func disclosureIndicator(isVisible: Bool) -> some View {
        if isVisible {
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func destinationView(for destination: LibrarySettingsDestination) -> some View {
        switch destination {
        case .privacy:
            LibraryPrivacyPolicyView()
        }
    }
}




private struct LibraryPrivacyPolicyView: View {
    private let policy: AttributedString

    init(bundle: Bundle = .main) {
        policy = Self.loadPolicy(from: bundle)
    }

    var body: some View {
        ZStack {
            NotateLibraryDesign.warmBackground
                .ignoresSafeArea()

            ScrollView {
                Text(policy)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(NotateDesign.Spacing.page)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private static func loadPolicy(from bundle: Bundle) -> AttributedString {
        guard let url = bundle.url(forResource: "Privacy", withExtension: "md"),
            let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return AttributedString("The privacy policy is unavailable.")
        }

        let body = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.hasPrefix("#") || $0.isEmpty })
            .joined(separator: "\n")
        return (try? AttributedString(markdown: body)) ?? AttributedString(body)
    }
}




extension LibraryColorDraft {
    init(_ value: Color) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        UIColor(value).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
    }

    init(_ value: LibraryRGBAColor) {
        self.init(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    var libraryRGBAColor: LibraryRGBAColor {
        LibraryRGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var accessibilityName: String {
        if self == .blue { return "Blue" }
        if self == .coral { return "Coral" }
        if self == .amber { return "Amber" }
        if self == .mint { return "Mint" }
        if self == .violet { return "Violet" }
        if self == .rose { return "Rose" }

        let folderNames = [
            "Sky", "Peach", "Butter", "Mint",
            "Lavender", "Rose", "Aqua", "Periwinkle",
        ]
        if let index = Self.folderPalette.firstIndex(of: self) {
            return folderNames[index]
        }
        return "Custom"
    }

    var contrastingForeground: Color {
        // Perceived luminance keeps the selection mark legible on bright
        // amber, mint, and user-picked colors without imposing a second ring.
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.62 ? .black : .white
    }
}

extension LibraryRGBAColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var folderGlyphForeground: Color {
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return (luminance > 0.58 ? Color.black : Color.white).opacity(0.82)
    }
}
