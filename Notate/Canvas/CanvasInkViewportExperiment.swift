#if DEBUG || NOTATE_INK_PROFILING
import PaperKit
import PencilKit
import SwiftUI
import UIKit

/// Isolated from the library and persistence. All three renderers use the same
/// full-page markup; switching carries edits across without touching documents.
struct CanvasInkViewportExperiment: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CanvasInkViewportExperimentController {
        CanvasInkViewportExperimentController()
    }
    func updateUIViewController(_ controller: CanvasInkViewportExperimentController, context: Context) {}
    static func dismantleUIViewController(_ controller: CanvasInkViewportExperimentController, coordinator: ()) {
        controller.stopExperiment()
    }
}

@MainActor
enum CanvasInkViewportFixture {
    #if NOTATE_INK_PROFILING
    static func notebookPages() async throws -> [CanvasPageSnapshot] {
        let base = markup()
        let styles: [CanvasPaperStyle] = [.blank, .ruled, .grid, .dotted, .cornell, .music]
        let tones: [CanvasPaperTone] = [.white, .cream, .lightBlue]
        var pages: [CanvasPageSnapshot] = []
        pages.reserveCapacity(1_000)
        for index in 0..<1_000 {
            try Task.checkCancellation()
            var pageMarkup = base
            pageMarkup.insertNewTextbox(attributedText: NSAttributedString(
                string: "Viewport Performance — page \(index + 1) of 1,000\nMixed ink, editable text, shape and image",
                attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black]),
                frame: CGRect(x: 60, y: 70, width: 475, height: 55))
            var strokes: [PKStroke] = []
            for row in 0..<12 {
                var points: [PKStrokePoint] = []
                for point in 0..<100 {
                    let x = 65.0 + Double(point) * 4.4
                    let wave = sin(Double(point + index) * 0.2) * 2
                    let y = 160.0 + Double(row) * 11 + wave
                    points.append(PKStrokePoint(location: CGPoint(x: x, y: y),
                        timeOffset: Double(point) / 120, size: CGSize(width: 0.7, height: 0.7),
                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                }
                strokes.append(PKStroke(ink: PKInk(.pen, color: .darkGray),
                    path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))))
            }
            pageMarkup.append(contentsOf: PKDrawing(strokes: strokes))
            let tables = index.isMultiple(of: 25)
                ? [CanvasTable(origin: CGPoint(x: 65, y: 480), rowCount: 4, columnCount: 4)] : []
            pages.append(CanvasPageSnapshot(markup: pageMarkup, tables: tables,
                paperTemplate: CanvasPaperTemplate(style: styles[index % styles.count],
                                                   tone: tones[index % tones.count])))
            if index.isMultiple(of: 20) { await Task.yield() }
        }
        return pages
    }
    #endif

    static func markup() -> PaperMarkup {
        var markup = PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        var strokes: [PKStroke] = []
        for row in 0..<5 {
            var points: [PKStrokePoint] = []
            for index in 0..<100 {
                let x = 220.0 + Double(index) * 0.8
                let wave = sin(Double(index) * 0.16) * 3.0
                let y = 340.0 + Double(row) * 8.0 + wave
                points.append(PKStrokePoint(
                    location: CGPoint(x: x, y: y),
                    timeOffset: Double(index) / 120,
                    size: CGSize(width: 0.35, height: 0.35), opacity: 1,
                    force: 1, azimuth: 0, altitude: .pi / 2
                ))
            }
            strokes.append(PKStroke(ink: PKInk(.pen, color: .black),
                            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))))
        }
        markup.append(contentsOf: PKDrawing(strokes: strokes))
        markup.insertNewShape(
            configuration: ShapeConfiguration(type: .ellipse, fillColor: nil,
                                              strokeColor: UIColor.systemBlue.cgColor, lineWidth: 0.35),
            frame: CGRect(x: 290, y: 350, width: 28, height: 28)
        )
        markup.insertNewTextbox(
            attributedText: NSAttributedString(string: "Thin ink · native text", attributes: [
                .font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.black
            ]), frame: CGRect(x: 220, y: 390, width: 120, height: 18)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(3)
            context.cgContext.strokeEllipse(in: CGRect(x: 16, y: 16, width: 96, height: 96))
        }
        if let cgImage = image.cgImage {
            markup.insertNewImage(cgImage, frame: CGRect(x: 330, y: 350, width: 24, height: 24))
        }
        return markup
    }
}

@MainActor
final class CanvasInkViewportExperimentController: UIViewController {
    private let renderer = UISegmentedControl(items: ["Existing", "Native only", "Notebook viewport"])
    private let zoom = UISegmentedControl(items: ["100%", "600%", "800%", "1000%"])
    private let container = UIView()
    private let picker = PKToolPicker()
    private let profileButton = UIButton(type: .system)
    private let profileStatus = UILabel()
    private var profileTask: Task<Void, Never>?
    private var didStartAutomaticProfile = false
    private var profileCenter: CGPoint?
    private var profileZoom: CGFloat?
    private var experimentPages: [CanvasPageSnapshot] = []
    private var profilePageCount: Int {
        ProcessInfo.processInfo.environment["NOTATE_INK_PROFILE_MODE"] == "large" ? 1_000 : 1
    }
    private var editor: PaperCanvasViewController?
    private var standalone: PaperMarkupViewController?
    private var markup = CanvasInkViewportFixture.markup()
    private let pageID = UUID()
    private let nativeUndoManager = UndoManager()
    private let insertion = MarkupEditViewController(supportedFeatureSet: PaperFeatureSetFactory.canvas,
                                                    additionalActions: [])
    private var logicalZoom: CGFloat { profileZoom ?? [1, 6, 8, 10][zoom.selectedSegmentIndex] }
    override var undoManager: UndoManager? { nativeUndoManager }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Ink clarity experiment · same markup in every renderer"
        title.font = .preferredFont(forTextStyle: .headline)
        let hint = UILabel()
        hint.text = "Write, lift, erase, select, and hold a drawn shape. Compare at the same zoom."
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .caption1)
        renderer.selectedSegmentIndex = ProcessInfo.processInfo.environment["NOTATE_INK_PROFILE_MODE"] == "native" ? 1 : 2
        zoom.selectedSegmentIndex = 1
        renderer.accessibilityIdentifier = "ink-experiment-renderer"
        zoom.accessibilityIdentifier = "ink-experiment-zoom"
        renderer.addTarget(self, action: #selector(rebuildEditor), for: .valueChanged)
        zoom.addTarget(self, action: #selector(changeZoom), for: .valueChanged)
        profileButton.setTitle("Run 30-cycle profile", for: .normal)
        profileButton.addTarget(self, action: #selector(startProfile), for: .touchUpInside)
        profileStatus.font = .preferredFont(forTextStyle: .caption2)
        profileStatus.numberOfLines = 0
        let controls = UIStackView(arrangedSubviews: [title, renderer, zoom, hint, profileButton, profileStatus])
        controls.axis = .vertical
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        picker.accessoryItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.insertion.delegate = self.standalone ?? self.editor?.paperMarkupControllerForProfiling
            self.insertion.modalPresentationStyle = .popover
            self.insertion.popoverPresentationController?.sourceView = self.view
            self.insertion.popoverPresentationController?.sourceRect = CGRect(x: 16, y: 100, width: 1, height: 1)
            self.present(self.insertion, animated: true)
        })
        rebuildEditor()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let standalone {
            standalone.view.frame = container.bounds
            updateStandaloneViewport()
        }
    }

    @objc private func rebuildEditor() {
        guard editor?.hasActiveSnapshotContact != true,
              editor?.hasPendingProgrammaticInsertions != true else { return }
        if let live = standalone?.markup ?? editor?.snapshotActivePage()?.markup { markup = live }
        retireEditor()
        let child: UIViewController
        let paper: PaperMarkupViewController
        if renderer.selectedSegmentIndex == 1 {
            paper = PaperMarkupViewController(markup: markup, supportedFeatureSet: PaperFeatureSetFactory.canvas)
            paper.contentView = UIView()
            paper.contentView?.backgroundColor = .white
            paper.overrideUserInterfaceStyle = .light
            paper.directTouchMode = .drawing
            standalone = paper
            child = paper
        } else {
            let page = CanvasPageSnapshot(id: pageID, markup: markup)
            experimentPages = [page] + (1..<profilePageCount).map { _ in CanvasPageSnapshot(markup: markup) }
            let notebook = PaperCanvasViewController(
                pages: experimentPages, currentPageID: pageID, viewport: viewport(), inputMode: .pencilAndFinger,
                pagedRenderingMode: renderer.selectedSegmentIndex == 0 ? .fullPage : .nativeViewport,
                callbacks: PaperCanvasCallbacks(markupChanged: { _, _ in }, interactionBegan: {},
                    undoAvailabilityChanged: { _, _ in }, viewportChanged: { _, _ in })
            )
            editor = notebook
            child = notebook
            // Mount at a nonzero size before resolving the first viewport.
            addChild(child)
            child.view.frame = container.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 600, height: 800) : container.bounds
            container.addSubview(child.view)
            child.view.layoutIfNeeded()
            child.didMove(toParent: self)
            notebook.applyToolState(CanvasToolState())
            paper = notebook.paperMarkupControllerForProfiling
        }
        if standalone != nil {
            addChild(child)
            child.view.frame = container.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 600, height: 800) : container.bounds
            container.addSubview(child.view)
            child.didMove(toParent: self)
            updateStandaloneViewport()
        }
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picker.addObserver(paper)
        paper.toolPickerSelectedToolItemDidChange(picker)
        pencilKitResponderState.activeToolPicker = picker
        pencilKitResponderState.toolPickerVisibility = .visible
        becomeFirstResponder()
    }

    @objc private func changeZoom() {
        if let editor { editor.setZoomScale(logicalZoom) }
        else { updateStandaloneViewport() }
    }

    private func viewport() -> CanvasViewportState {
        .stackViewport(zoomScale: logicalZoom, normalizedCenterX: profileCenter?.x ?? 0.48,
                       normalizedCenterY: profileCenter?.y ?? 0.45)
    }

    private func updateStandaloneViewport() {
        guard let standalone, !standalone.view.bounds.isEmpty else { return }
        let size = standalone.view.bounds.size
        standalone.zoomRange = logicalZoom...logicalZoom
        standalone.contentVisibleFrame = CGRect(
            x: 595 * (profileCenter?.x ?? 0.48) - size.width / logicalZoom / 2,
            y: 842 * (profileCenter?.y ?? 0.45) - size.height / logicalZoom / 2,
            width: size.width / logicalZoom, height: size.height / logicalZoom
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didStartAutomaticProfile,
           ProcessInfo.processInfo.arguments.contains("--ink-viewport-benchmark") {
            didStartAutomaticProfile = true
            startProfile()
        }
    }

    @objc private func startProfile() {
        guard profileTask == nil else { return }
        renderer.isEnabled = false
        zoom.isEnabled = false
        profileButton.isEnabled = false
        profileStatus.text = "Profiling 30 presented zoom/pan cycles…"
        profileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.profileTask = nil
                self.profileZoom = nil
                self.profileCenter = nil
                self.renderer.isEnabled = true
                self.zoom.isEnabled = true
                self.profileButton.isEnabled = true
            }
            do {
                let name = ["existing", "native", "notebook"][self.renderer.selectedSegmentIndex]
                let report = try await CanvasInkViewportProfile.run(renderer: name,
                    pageCount: self.experimentPages.isEmpty ? 1 : self.experimentPages.count,
                    viewportSize: self.container.bounds.size,
                    idleEditorCount: { [weak self] in self?.editor?.idleNativeControllerCountForProfiling ?? 0 },
                    viewportViolationCount: { [weak self] in self?.editor?.nativeViewportViolationCountForProfiling ?? 0 }
                ) { [weak self] scale, center, cycle in
                        guard let self else { return 0 }
                        self.profileZoom = scale
                        self.profileCenter = center
                        if let editor = self.editor {
                            let index = (cycle * 37) % self.experimentPages.count
                            let id = self.experimentPages[index].id
                            return editor.applyInkProfileStep(zoom: scale, center: center, pageID: id)
                        }
                        self.updateStandaloneViewport()
                        return 1
                    }
                try Task.checkCancellation()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ink-viewport-profile.json")
                try data.write(to: url, options: .atomic)
                print("INK_VIEWPORT_PROFILE " + String(decoding: data, as: UTF8.self))
                self.profileStatus.text = String(format: "%@ · median %.2f ms · p95 %.2f ms · report saved in Documents",
                    name, report.updateMedianMilliseconds, report.updateP95Milliseconds)
            } catch is CancellationError {
                self.profileStatus.text = "Profile cancelled."
            } catch {
                self.profileStatus.text = "Profile failed: \(error.localizedDescription)"
            }
        }
    }

    func stopExperiment() {
        profileTask?.cancel()
        retireEditor()
    }

    func retireEditor() {
        if let paper = standalone ?? editor?.paperMarkupControllerForProfiling { picker.removeObserver(paper) }
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        editor?.completeDismantle()
        standalone?.contentView = nil
        standalone?.markup = nil
        editor = nil
        standalone = nil
        nativeUndoManager.removeAllActions()
    }
}
#endif
