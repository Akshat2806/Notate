import SwiftUI
import UIKit

struct CanvasExportSheet: View {
    let document: CanvasExportDocument
    let suggestedFilename: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isRangeFieldFocused: Bool
    @State private var selectedPageIDs: Set<UUID>
    @State private var rangeText = ""
    @State private var rangeError: String?
    @State private var format: CanvasExportFormat = .pdf
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var shareArtifact: CanvasExportArtifact?
    @State private var exportError: String?

    init(document: CanvasExportDocument, suggestedFilename: String? = nil) {
        self.document = document
        self.suggestedFilename = suggestedFilename
        _selectedPageIDs = State(initialValue: Set(document.pages.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                pageSelectionSection
                    .disabled(isExporting)

                formatSection
                    .disabled(isExporting)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        exportTask?.cancel()
                        dismiss()
                    }
                    .accessibilityHint("Closes without exporting")
                    .accessibilityIdentifier("export.close")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: beginExport) {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Export")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(hasExportSelection == false || isExporting)
                    .accessibilityLabel(isExporting ? "Creating export" : "Export")
                    .accessibilityIdentifier("export.confirm")
                }
            }
        }
        .interactiveDismissDisabled(isExporting)
        .sheet(item: $shareArtifact) { artifact in
            CanvasShareSheet(urls: artifact.urls)
                .onDisappear {
                    artifact.removeTemporaryFiles()
                }
        }
        .alert(
            "Export Could Not Be Created",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if $0 == false { exportError = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { exportError = nil }
            },
            message: {
                Text(exportError ?? "Please try again.")
            }
        )
        .onDisappear {
            exportTask?.cancel()
            shareArtifact?.removeTemporaryFiles()
        }
    }

    @ViewBuilder
    private var pageSelectionSection: some View {
        Section {
            adaptiveSelectionSummary

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: NotateDesign.Spacing.control) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                        pageButton(page, number: index + 1)
                    }
                }
                .padding(.vertical, NotateDesign.Spacing.tight)
            }
            .scrollIndicators(.hidden)
            .listRowInsets(
                EdgeInsets(
                    top: NotateDesign.Spacing.compact,
                    leading: NotateDesign.Spacing.content,
                    bottom: NotateDesign.Spacing.compact,
                    trailing: NotateDesign.Spacing.content
                )
            )

            pageSelectionControls
        } header: {
            Text("Pages")
        } footer: {
            if let rangeError {
                Text(rangeError)
                    .foregroundStyle(NotateDesign.Palette.error)
                    .accessibilityLabel("Page range error: \(rangeError)")
            } else {
                Text("Tap page previews, or enter pages such as 2–5, 8.")
            }
        }
    }

    private var pageSelectionSummary: some View {
        Text("\(selectedPageIDs.count) of \(document.pages.count) selected")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("export.selection-summary")
    }

    @ViewBuilder
    private var adaptiveSelectionSummary: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                Text("Selected")
                pageSelectionSummary
            }
            .padding(.vertical, NotateDesign.Spacing.tight)
        } else {
            HStack {
                Text("Selected")
                Spacer()
                pageSelectionSummary
            }
        }
    }

    @ViewBuilder
    private var pageSelectionControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
                Text("Range")
                rangeEntryControls
            }
            .padding(.vertical, NotateDesign.Spacing.tight)
        } else {
            HStack(spacing: NotateDesign.Spacing.control) {
                Text("Range")
                rangeEntryControls
            }
        }

        Toggle("Select All Pages", isOn: allPagesSelection)
            .tint(NotateDesign.Palette.accent)
            .disabled(document.pages.isEmpty)
            .accessibilityLabel("Select all pages")
            .accessibilityValue(
                allPagesAreSelected
                    ? "All \(document.pages.count) pages selected"
                    : "\(selectedPageIDs.count) of \(document.pages.count) pages selected"
            )
            .accessibilityHint(
                allPagesAreSelected
                    ? "Turn off to deselect every page"
                    : "Turn on to select every page"
            )
            .accessibilityIdentifier("export.select-all")
    }

    private var rangeEntryControls: some View {
        HStack(spacing: NotateDesign.Spacing.control) {
            TextField("2–5, 8", text: $rangeText)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Page range")
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isRangeFieldFocused)
                .onSubmit {
                    _ = applyPageRange()
                }
            .onChange(of: rangeText) { _, _ in
                rangeError = nil
            }

            Button("Apply") {
                _ = applyPageRange()
            }
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: NotateDesign.Control.minimumHitTarget, minHeight: 44)
            .disabled(rangeDraftIsEmpty)
        }
    }

    @ViewBuilder
    private var formatSection: some View {
        Section("File Format") {
            Picker("Export as", selection: $format) {
                ForEach(CanvasExportFormat.allCases) { choice in
                    Label(choice.title, systemImage: choice.systemImage)
                        .tag(choice)
                        .accessibilityIdentifier("export.format.\(choice.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Export as")
        }
    }

    private func pageButton(_ page: CanvasPageSnapshot, number: Int) -> some View {
        let isSelected = selectedPageIDs.contains(page.id)
        let previewSize = pagePreviewSize(for: page)
        let pageShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button {
            if isSelected {
                selectedPageIDs.remove(page.id)
            } else {
                selectedPageIDs.insert(page.id)
            }
            rangeText = CanvasPageRangeParser.formattedSelection(
                pageIDs: selectedPageIDs,
                in: document.pages
            )
            rangeError = nil
        } label: {
            VStack(spacing: NotateDesign.Spacing.tight) {
                ZStack(alignment: .bottomTrailing) {
                    CanvasPageThumbnail(page: page)
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipShape(pageShape)
                        .overlay {
                            pageShape.strokeBorder(
                                isSelected
                                    ? NotateDesign.Palette.accent
                                    : Color.primary.opacity(0.14),
                                lineWidth: isSelected ? 2 : 1
                            )
                        }

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(NotateDesign.Palette.accent, in: Circle())
                            .padding(4)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 76, height: 98)

                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(number)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("export.page.\(number)")
    }

    private func pagePreviewSize(for page: CanvasPageSnapshot) -> CGSize {
        let pageSize = page.displaySize
        let bounds = CGSize(width: 72, height: 94)
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              pageSize.width > 0,
              pageSize.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        return CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    }

    private var allPagesAreSelected: Bool {
        selectedPageIDs.count == document.pages.count && document.pages.isEmpty == false
    }

    private var hasExportSelection: Bool {
        selectedPageIDs.isEmpty == false
            || rangeDraftIsEmpty == false
    }

    private var rangeDraftIsEmpty: Bool {
        rangeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var allPagesSelection: Binding<Bool> {
        Binding(
            get: { allPagesAreSelected },
            set: { shouldSelectAll in
                setAllPagesSelected(shouldSelectAll)
            }
        )
    }

    private func setAllPagesSelected(_ shouldSelectAll: Bool) {
        selectedPageIDs = shouldSelectAll ? Set(document.pages.map(\.id)) : []
        rangeText = ""
        rangeError = nil
    }

    @discardableResult
    private func applyPageRange() -> Set<UUID>? {
        do {
            let indices = try CanvasPageRangeParser.parse(
                rangeText,
                pageCount: document.pages.count
            )
            let pageIDs = Set(indices.map { document.pages[$0].id })
            selectedPageIDs = pageIDs
            rangeText = CanvasPageRangeParser.formattedSelection(
                pageIDs: pageIDs,
                in: document.pages
            )
            rangeError = nil
            isRangeFieldFocused = false
            return pageIDs
        } catch {
            rangeError = error.localizedDescription
            isRangeFieldFocused = true
            UIAccessibility.post(notification: .announcement, argument: rangeError)
            return nil
        }
    }

    private func beginExport() {
        guard isExporting == false else { return }

        var pageIDs = selectedPageIDs
        if rangeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            guard let rangePageIDs = applyPageRange() else { return }
            pageIDs = rangePageIDs
        }

        let selectedPages = document.selectedPages(pageIDs: pageIDs)
        guard selectedPages.isEmpty == false else { return }

        isExporting = true
        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
                let artifact = try await CanvasDocumentExporter().export(
                    pages: selectedPages,
                    format: format,
                    suggestedFilename: suggestedFilename
                )
                guard Task.isCancelled == false else {
                    artifact.removeTemporaryFiles()
                    return
                }
                shareArtifact = artifact
            } catch is CancellationError {
                return
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

struct CanvasPageThumbnail: View {
    let page: CanvasPageSnapshot

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color(uiColor: page.paperTemplate.tone.uiColor)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if didFail {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Rendering page preview")
            }
        }
        .clipped()
        // Page identity stays stable across rotation and editing. Key the
        // renderer by the complete snapshot so an in-place page update cannot
        // leave a stale portrait/landscape preview in All Pages or Export.
        .task(id: page) {
            image = nil
            didFail = false
            do {
                let rendered = try await CanvasDocumentExporter.shared.thumbnail(for: page)
                guard Task.isCancelled == false else { return }
                image = UIImage(cgImage: rendered)
            } catch is CancellationError {
                return
            } catch {
                didFail = true
            }
        }
        .onDisappear {
            // Lazy grids should not retain decoded page images after a cell
            // leaves the viewport in a long notebook.
            image = nil
            didFail = false
        }
    }
}

struct CanvasShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
