import PhotosUI
import SwiftUI
import UIKit

struct CanvasMoreButton: View {
    @Bindable var model: CanvasEditorModel
    let item: LibraryItemRecord
    let onRename: @MainActor (String) throws -> Void

    @State private var destination: CanvasMoreDestination?
    @State private var isPanelPresented = false
    @State private var isGoToPagePresented = false
    @State private var pageNumberText = ""
    @State private var isRenamePresented = false
    @State private var renameDraft = ""
    @State private var presentedError: CanvasMorePresentedError?
    @State private var pendingPresentation: CanvasMorePendingPresentation?

    var body: some View {
        Button {
            model.handle(.dismissOverlay)
            isPanelPresented.toggle()
        } label: {
            NotateCompactGlassIconLabel(
                systemImage: "ellipsis",
                iconSize: NotateDesign.compactMoreIconSize
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityHint(
            model.isReaderMode
                ? "Shows page navigation, export, and reader settings"
                : model.supportsPageStack
                ? "Shows page, paper, export, and note settings"
                : "Shows paper, export, and canvas settings"
        )
        .popover(
            isPresented: $isPanelPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            CanvasMorePanel(
                model: model,
                item: item,
                onDismiss: { isPanelPresented = false },
                onRename: presentRenamePrompt,
                onGoToPage: presentGoToPagePrompt,
                onPaperSetup: { present(.paperSetup) },
                onExport: presentExport,
                onSettings: { present(.settings) }
            )
            .onDisappear(perform: presentPendingPresentation)
            .presentationSizing(.fitted)
            .presentationCompactAdaptation(.popover)
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .paperSetup:
                CanvasPaperSetupSheet(model: model)
                    .presentationSizing(.form)
            case .settings:
                CanvasNoteSettingsSheet(
                    model: model,
                    item: item,
                    onRename: onRename
                )
                .presentationSizing(.form)
            case let .export(document):
                CanvasExportSheet(
                    document: document,
                    suggestedFilename: item.name
                )
                .presentationSizing(.form)
            }
        }
        .alert("Go to Page", isPresented: $isGoToPagePresented) {
            TextField("Page number", text: $pageNumberText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Go") {
                guard let pageNumber = Int(pageNumberText) else { return }
                _ = model.goToPage(number: pageNumber)
            }
            .disabled(isPageNumberValid == false)
        } message: {
            Text("Enter a page from 1 to \(model.pageCount).")
        }
        .alert("Rename Note", isPresented: $isRenamePresented) {
            TextField("Note name", text: $renameDraft)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: renameNote)
                .disabled(trimmedRenameDraft.isEmpty || trimmedRenameDraft == item.name)
        } message: {
            Text("Choose a clear name for this note.")
        }
        .alert(
            presentedError?.title ?? "Action Unavailable",
            isPresented: Binding(
                get: { presentedError != nil },
                set: { if $0 == false { presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { presentedError = nil }
        } message: {
            Text(presentedError?.message ?? "Please try again.")
        }
    }

    private var trimmedRenameDraft: String {
        renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPageNumberValid: Bool {
        guard let pageNumber = Int(pageNumberText) else { return false }
        return 1...model.pageCount ~= pageNumber
    }

    private func present(_ newDestination: CanvasMoreDestination) {
        model.handle(.dismissOverlay)
        dismissPanel(then: .destination(newDestination))
    }

    private func presentRenamePrompt() {
        renameDraft = item.name
        dismissPanel(then: .rename)
    }

    private func presentGoToPagePrompt() {
        pageNumberText = String(model.currentPageNumber)
        dismissPanel(then: .goToPage)
    }

    private func presentExport() {
        model.handle(.dismissOverlay)
        Task { @MainActor in
            if let document = await model.prepareExportDocumentWhenReady() {
                dismissPanel(then: .destination(.export(document)))
            } else {
                dismissPanel(
                    then: .error(
                        CanvasMorePresentedError(
                            title: "Export Unavailable",
                            message: CanvasExportError.canvasUnavailable.localizedDescription
                        )
                    )
                )
            }
        }
    }

    private func dismissPanel(then presentation: CanvasMorePendingPresentation) {
        pendingPresentation = presentation
        isPanelPresented = false
    }

    private func presentPendingPresentation() {
        guard let pendingPresentation else { return }
        self.pendingPresentation = nil

        switch pendingPresentation {
        case let .destination(newDestination):
            destination = newDestination
        case .goToPage:
            isGoToPagePresented = true
        case .rename:
            isRenamePresented = true
        case let .error(error):
            presentedError = error
        }
    }

    private func renameNote() {
        do {
            try onRename(trimmedRenameDraft)
        } catch {
            presentedError = CanvasMorePresentedError(
                title: "Rename Failed",
                message: error.localizedDescription
            )
        }
    }
}

private enum CanvasMorePendingPresentation {
    case destination(CanvasMoreDestination)
    case goToPage
    case rename
    case error(CanvasMorePresentedError)
}

private enum CanvasMoreDestination: Identifiable {
    enum ID: Hashable {
        case paperSetup
        case settings
        case export(UUID)
    }

    case paperSetup
    case settings
    case export(CanvasExportDocument)

    var id: ID {
        switch self {
        case .paperSetup: .paperSetup
        case .settings: .settings
        case let .export(document): .export(document.id)
        }
    }
}

private struct CanvasMorePresentedError {
    let title: String
    let message: String
}

private struct CanvasNoteSettingsSheet: View {
    @Bindable var model: CanvasEditorModel
    let item: LibraryItemRecord
    let onRename: @MainActor (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft: String
    @State private var renameError: String?

    init(
        model: CanvasEditorModel,
        item: LibraryItemRecord,
        onRename: @escaping @MainActor (String) throws -> Void
    ) {
        self.model = model
        self.item = item
        self.onRename = onRename
        _nameDraft = State(initialValue: item.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Document Details") {
                    if model.isReaderMode {
                        LabeledContent("Name", value: item.name)
                    } else {
                        TextField("Name", text: $nameDraft)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(saveName)
                            .accessibilityIdentifier("canvas.settings.name")
                    }

                    LabeledContent("Created") {
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Last Modified") {
                        Text(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if model.supportsPageStack {
                        LabeledContent("Pages", value: "\(model.pageCount)")
                    }
                }

                if model.isReaderMode == false {
                    Section {
                        Toggle(
                            "Draw with Finger",
                            isOn: Binding(
                                get: { model.inputMode == .pencilAndFinger },
                                set: model.setDrawWithFinger
                            )
                        )
                    } header: {
                        Text("Input")
                    } footer: {
                        Text(
                            model.inputMode == .pencilAndFinger
                                ? "One finger draws. Use two fingers to move or zoom the page."
                                : "Apple Pencil draws. One or two fingers can move or zoom the page."
                        )
                    }
                }

                if model.supportsPageStack, model.isReaderMode == false {
                    Section {
                        Picker("Scroll Direction", selection: scrollDirectionBinding) {
                            ForEach(CanvasScrollDirection.allCases, id: \.self) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color(uiColor: .secondaryLabel))
                    } header: {
                        Text("Page View")
                    } footer: {
                        Text(
                            "Vertical scrolls continuously. Horizontal starts with one full page and snaps left or right."
                        )
                    }
                }

                if model.supportsPageStack {
                    Section {
                        Picker("Direction", selection: readerScrollDirectionBinding) {
                            ForEach(CanvasScrollDirection.allCases, id: \.self) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("canvas.reader.direction")

                        Picker("Landscape Layout", selection: readerPageDisplayBinding) {
                            Text("One Page").tag(CanvasPageDisplayMode.singlePage)
                            Text("Two Pages").tag(CanvasPageDisplayMode.twoPage)
                        }
                        .pickerStyle(.menu)
                        .disabled(model.readerPreferences.scrollDirection != .horizontal)
                        .accessibilityIdentifier("canvas.reader.page-display")

                        Picker("Page Turn", selection: readerTransitionBinding) {
                            ForEach(CanvasReaderPageTransition.allCases, id: \.self) { transition in
                                Text(transition.title).tag(transition)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(model.readerPreferences.scrollDirection != .horizontal)
                        .accessibilityIdentifier("canvas.reader.transition")
                    } header: {
                        Text("Reader Mode")
                    } footer: {
                        Text(
                            "Each page or spread fits the reading area and turns one screen at a time. Pinch or double-tap to zoom. Portrait and narrow windows show one page; landscape can show one or two. Page Curl is horizontal only and follows Reduce Motion."
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(
                model.isReaderMode
                    ? "Reader Settings"
                    : (model.supportsPageStack ? "Note Settings" : "Canvas Settings")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: saveAndDismiss)
                }
            }
        }
        .alert(
            "Name Could Not Be Saved",
            isPresented: Binding(
                get: { renameError != nil },
                set: { if $0 == false { renameError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "Please try another name.")
        }
    }

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var scrollDirectionBinding: Binding<CanvasScrollDirection> {
        Binding(
            get: { model.pageLayout.scrollDirection },
            set: { direction in
                var layout = model.pageLayout
                layout.scrollDirection = direction
                model.setPageLayout(layout)
            }
        )
    }

    private var readerScrollDirectionBinding: Binding<CanvasScrollDirection> {
        Binding(
            get: { model.readerPreferences.scrollDirection },
            set: { direction in
                var preferences = model.readerPreferences
                preferences.scrollDirection = direction
                model.setReaderPreferences(preferences)
            }
        )
    }

    private var readerPageDisplayBinding: Binding<CanvasPageDisplayMode> {
        Binding(
            get: { model.readerPreferences.landscapeDisplayMode },
            set: { displayMode in
                var preferences = model.readerPreferences
                preferences.landscapeDisplayMode = displayMode
                model.setReaderPreferences(preferences)
            }
        )
    }

    private var readerTransitionBinding: Binding<CanvasReaderPageTransition> {
        Binding(
            get: { model.readerPreferences.pageTransition },
            set: { transition in
                var preferences = model.readerPreferences
                preferences.pageTransition = transition
                model.setReaderPreferences(preferences)
            }
        )
    }

    private func saveName() {
        guard model.isReaderMode == false else { return }
        guard trimmedName.isEmpty == false, trimmedName != item.name else { return }
        do {
            try onRename(trimmedName)
        } catch {
            renameError = error.localizedDescription
        }
    }

    private func saveAndDismiss() {
        if model.isReaderMode {
            dismiss()
            return
        }
        guard trimmedName.isEmpty == false else {
            renameError = "A note name cannot be empty."
            return
        }
        if trimmedName != item.name {
            do {
                try onRename(trimmedName)
            } catch {
                renameError = error.localizedDescription
                return
            }
        }
        dismiss()
    }
}

struct CanvasMorePanel: View {
    @Bindable var model: CanvasEditorModel
    let item: LibraryItemRecord
    let onDismiss: () -> Void
    let onRename: () -> Void
    let onGoToPage: () -> Void
    let onPaperSetup: () -> Void
    let onExport: () -> Void
    let onSettings: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                documentHeader

                Divider()

                if model.supportsPageStack, model.isReaderMode == false {
                    Menu {
                        Button("At Beginning", systemImage: "arrow.up.to.line") {
                            model.addPage(at: .start)
                            onDismiss()
                        }
                        Button("After Current Page", systemImage: "plus.rectangle.on.rectangle") {
                            model.addPage(at: .afterCurrent)
                            onDismiss()
                        }
                        Button("At End", systemImage: "arrow.down.to.line") {
                            model.addPage(at: .end)
                            onDismiss()
                        }
                    } label: {
                        CanvasMoreActionLabel(
                            title: "Add Page",
                            systemImage: "doc.badge.plus"
                        )
                    }
                    .menuOrder(.fixed)
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityHint("Choose where the new page is inserted")
                    .accessibilityIdentifier("canvas.more.add-page")

                    Divider()
                }

                if model.supportsPageStack, model.pageCount > 1 {
                    actionButton(
                        title: "Go to Page…",
                        trailingText: "\(model.currentPageNumber) of \(model.pageCount)",
                        systemImage: "number.square",
                        accessibilityHint: "Enter a page number",
                        accessibilityIdentifier: "canvas.more.go-to-page",
                        action: onGoToPage
                    )

                    Divider()
                }

                if model.isReaderMode == false {
                    actionButton(
                        title: "Paper Setup",
                        systemImage: "doc.text.image",
                        accessibilityHint: "Choose the page template and paper color",
                        accessibilityIdentifier: "canvas.more.paper-setup",
                        action: onPaperSetup
                    )
                }

                actionButton(
                    title: "Export",
                    systemImage: "square.and.arrow.up",
                    accessibilityHint: "Export pages as a PDF or images",
                    accessibilityIdentifier: "canvas.more.export",
                    action: onExport
                )

                Divider()

                actionButton(
                    title: model.isReaderMode
                        ? "Reader Settings"
                        : (model.supportsPageStack ? "Note Settings" : "Canvas Settings"),
                    systemImage: "gearshape",
                    accessibilityHint: "View details and change input or layout settings",
                    accessibilityIdentifier: "canvas.more.settings",
                    action: onSettings
                )
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 348 : 304)
        .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 600 : 470)
        .accessibilityElement(children: .contain)
    }

    private var documentHeader: some View {
        HStack(spacing: NotateDesign.Spacing.control) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("canvas.more.note-name")

                Text(documentSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospacedDigit()
            }

            Spacer(minLength: NotateDesign.Spacing.compact)

            if model.isReaderMode == false {
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(
                            width: NotateDesign.Control.minimumHitTarget,
                            height: NotateDesign.Control.minimumHitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Rename Note")
                .accessibilityIdentifier("canvas.more.rename")
            }
        }
        .padding(.leading, NotateDesign.Spacing.content)
        .padding(.trailing, NotateDesign.Spacing.compact)
        .padding(.vertical, NotateDesign.Spacing.compact)
    }

    private var documentSummary: String {
        let kindOrPages = model.supportsPageStack
            ? "\(model.pageCount) \(model.pageCount == 1 ? "page" : "pages")"
            : item.kind.title
        return "\(kindOrPages) · Edited \(modifiedDescription)"
    }

    private var modifiedDescription: String {
        item.modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func actionButton(
        title: String,
        trailingText: String? = nil,
        systemImage: String,
        accessibilityHint: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            CanvasMoreActionLabel(
                title: title,
                systemImage: systemImage,
                trailingText: trailingText
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct CanvasMoreActionLabel: View {
    let title: String
    let systemImage: String
    var trailingText: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
            spacing: NotateDesign.Spacing.control
        ) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 5 : 0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)

                if dynamicTypeSize.isAccessibilitySize, let trailingText {
                    trailingValue(trailingText)
                }
            }

            Spacer(minLength: NotateDesign.Spacing.compact)

            if dynamicTypeSize.isAccessibilitySize == false, let trailingText {
                trailingValue(trailingText)
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 7 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, NotateDesign.Spacing.content)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? NotateDesign.Spacing.compact : 0)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func trailingValue(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CanvasPaperSetupSheet: View {
    @Bindable var model: CanvasEditorModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: CanvasPaperTemplate
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImportingPage = false
    @State private var importError: String?

    init(model: CanvasEditorModel) {
        self.model = model
        _draft = State(initialValue: model.currentPaperTemplate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotateDesign.Spacing.page) {
                    if model.currentPageHasImportedBackground {
                        importedBackgroundNotice
                    }

                    templateSection

                    if model.currentPageHasImportedBackground == false {
                        appearanceSection
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 16 : 20)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("paper-setup.scroll")
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Paper Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isImportingPage)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        model.currentPageHasImportedBackground ? "Done" : "Apply"
                    ) {
                        if model.currentPageHasImportedBackground == false {
                            model.setCurrentPaperTemplate(draft)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(
                        isImportingPage
                        || (
                            model.currentPageHasImportedBackground == false
                            && draft == model.currentPaperTemplate
                        )
                    )
                    .accessibilityIdentifier("paper-setup.apply")
                }
            }
        }
        .interactiveDismissDisabled(isImportingPage)
        .onChange(of: selectedPhoto) { _, selection in
            guard let selection else { return }
            importPhotoPage(from: selection)
        }
        .alert(
            "Page Could Not Be Imported",
            isPresented: Binding(
                get: { importError != nil },
                set: { if $0 == false { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Choose another image and try again.")
        }
    }

    private var importedBackgroundNotice: some View {
        Label(
            "Imported pages keep their original background.",
            systemImage: "photo.on.rectangle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityIdentifier("paper-setup.imported-background-hint")
    }

    private var templateSection: some View {
        let pageSize = model.currentPageDisplaySize
        let importingPage = isImportingPage

        return VStack(alignment: .leading, spacing: 14) {
            sectionHeading(model.currentPageHasImportedBackground ? "Page" : "Paper")

            LazyVGrid(columns: templateColumns, alignment: .leading, spacing: 16) {
                if model.currentPageHasImportedBackground == false {
                    ForEach(CanvasPaperStyle.allCases, id: \.self) { style in
                        CanvasPaperPresetTile(
                            style: style,
                            tone: draft.tone,
                            density: draft.density,
                            pageSize: pageSize,
                            isSelected: style == draft.style
                        ) {
                            withAnimation(reduceMotion ? nil : NotateDesign.Motion.selection) {
                                draft.style = style
                            }
                        }
                    }
                }

                if model.supportsPageStack {
                    PhotosPicker(
                        selection: $selectedPhoto,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        CanvasPaperImportTile(
                            pageSize: pageSize,
                            isLoading: importingPage
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(importingPage)
                    .accessibilityLabel("Import page")
                    .accessibilityHint("Opens Photos and adds the chosen image as a new page")
                    .accessibilityIdentifier("paper-setup.import-page")
                }
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Appearance")

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    adaptiveValueRow(title: "Color", value: draft.tone.title)

                    toneRow(title: "Light", tones: CanvasPaperTone.lightTones)
                    toneRow(title: "Dark", tones: CanvasPaperTone.darkTones)

                    if draft.tone.isDark {
                        Text("Existing ink colors won't change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                            .accessibilityIdentifier("paper-setup.dark-paper-hint")
                    }
                }
                .padding(16)

                if draft.style != .blank {
                    Divider()
                        .padding(.leading, 16)

                    Menu {
                        ForEach(CanvasPaperDensity.allCases, id: \.self) { density in
                            Button {
                                withAnimation(reduceMotion ? nil : NotateDesign.Motion.selection) {
                                    draft.density = density
                                }
                            } label: {
                                HStack {
                                    Text(density.title)
                                    if density == draft.density {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: NotateDesign.Spacing.control) {
                            adaptiveValueRow(title: "Spacing", value: draft.density.title)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 10 : 0)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("paper-setup.density")
                }
            }
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private func adaptiveValueRow(title: String, value: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: NotateDesign.Spacing.compact)

                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorSwatch(_ tone: CanvasPaperTone) -> some View {
        CanvasPaperToneSwatch(
            tone: tone,
            isSelected: draft.tone == tone
        ) {
            withAnimation(reduceMotion ? nil : NotateDesign.Motion.selection) {
                draft.tone = tone
            }
        }
    }

    private func toneRow(
        title: String,
        tones: [CanvasPaperTone]
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 34, alignment: .leading)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tones, id: \.self) { tone in
                        colorSwatch(tone)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
    }

    private var templateColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.adaptive(minimum: 138, maximum: 184), spacing: 14, alignment: .top)]
        }
        return [
            GridItem(
                .adaptive(minimum: 100, maximum: 124),
                spacing: 14,
                alignment: .top
            ),
        ]
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private func importPhotoPage(from item: PhotosPickerItem) {
        guard isImportingPage == false else { return }
        isImportingPage = true
        Task { @MainActor in
            defer {
                selectedPhoto = nil
                isImportingPage = false
            }
            do {
                guard let transfer = try await item.loadTransferable(
                    type: CanvasImageTransfer.self
                ) else {
                    throw CanvasPaperSetupImportError.unreadableImage
                }
                defer { transfer.discard() }
                let data = try await CanvasImageIngestor.shared.validatedOriginalData(
                    fileURL: transfer.fileURL
                )
                guard try model.addImagePageFromOverview(
                    data: data,
                    suggestedName: "Imported Page"
                ) != nil else {
                    throw CanvasPaperSetupImportError.importUnavailable
                }
                dismiss()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

private struct CanvasPaperPresetTile: View {
    let style: CanvasPaperStyle
    let tone: CanvasPaperTone
    let density: CanvasPaperDensity
    let pageSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CanvasPaperPreview(
                        template: CanvasPaperTemplate(
                            style: style,
                            density: density,
                            tone: tone
                        ),
                        pageSize: pageSize
                    )
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(NotateDesign.Palette.accent, lineWidth: 2.5)
                        }
                    }

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(NotateDesign.Palette.accent, in: Circle())
                            .padding(5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(style.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paper-setup.template.\(templateIdentifier)")
    }

    private var templateIdentifier: String {
        switch style {
        case .grid: "squared"
        case .music: "music-staff"
        default: style.rawValue
        }
    }
}

private struct CanvasPaperImportTile: View {
    let pageSize: CGSize
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 24, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(NotateDesign.Palette.accent)
                }
            }
            .aspectRatio(
                resolvedPageSize.width / resolvedPageSize.height,
                contentMode: .fit
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        NotateDesign.Palette.accent.opacity(0.72),
                        style: StrokeStyle(lineWidth: 1.25, dash: [5, 4])
                    )
            }
            .shadow(color: .black.opacity(0.10), radius: 3, y: 2)

            Text("Import Page")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var resolvedPageSize: CGSize {
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              pageSize.width > 0,
              pageSize.height > 0 else {
            return CanvasConstants.a4PortraitSize
        }
        return pageSize
    }
}

private struct CanvasPaperToneSwatch: View {
    let tone: CanvasPaperTone
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(uiColor: tone.uiColor))
                    .frame(width: 38, height: 38)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? NotateDesign.Palette.accent
                                    : Color.primary.opacity(0.16),
                                lineWidth: isSelected ? 2.5 : 1
                            )
                    }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tone.isDark ? .white : NotateDesign.Palette.accent)
                }
            }
            .frame(
                width: NotateDesign.Control.minimumHitTarget,
                height: NotateDesign.Control.minimumHitTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tone.title) paper")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paper-setup.tone.\(tone.rawValue)")
    }
}

private struct CanvasPaperPreview: View {
    let template: CanvasPaperTemplate
    let pageSize: CGSize

    init(
        template: CanvasPaperTemplate,
        pageSize: CGSize = CanvasConstants.a4PortraitSize
    ) {
        self.template = template
        self.pageSize = pageSize
    }

    var body: some View {
        ZStack {
            Color(uiColor: template.tone.uiColor)

            Canvas { context, size in
                let sourceSize = resolvedPageSize
                var transform = CGAffineTransform(
                    scaleX: size.width / sourceSize.width,
                    y: size.height / sourceSize.height
                )
                let artwork = CanvasPaperTemplateArtwork.paths(
                    for: template,
                    pageSize: sourceSize
                )
                let pattern = artwork.pattern.copy(using: &transform) ?? artwork.pattern
                let guides = artwork.guides.copy(using: &transform) ?? artwork.guides
                let ruleColor = Color(
                    uiColor: UIColor(
                        cgColor: CanvasPaperTemplateArtwork.ruleColor(for: template.tone)
                    )
                )
                let guideColor = Color(
                    uiColor: UIColor(
                        cgColor: CanvasPaperTemplateArtwork.guideColor(for: template.tone)
                    )
                )

                if artwork.fillsPattern {
                    context.fill(Path(pattern), with: .color(ruleColor))
                } else {
                    context.stroke(
                        Path(pattern),
                        with: .color(ruleColor),
                        lineWidth: max(size.width / sourceSize.width * 0.7, 0.5)
                    )
                }
                context.stroke(
                    Path(guides),
                    with: .color(guideColor),
                    lineWidth: max(size.width / sourceSize.width, 0.7)
                )
            }

        }
        .aspectRatio(
            resolvedPageSize.width / resolvedPageSize.height,
            contentMode: .fit
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 3, y: 2)
        .accessibilityLabel("\(template.accessibilityValue) preview")
    }

    private var resolvedPageSize: CGSize {
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              pageSize.width > 0,
              pageSize.height > 0 else {
            return CanvasConstants.a4PortraitSize
        }
        return pageSize
    }
}

private enum CanvasPaperSetupImportError: LocalizedError {
    case unreadableImage
    case importUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "The selected photo could not be read."
        case .importUnavailable:
            "The page could not be added right now."
        }
    }
}
