import Foundation
import PaperKit
import SwiftUI

struct PaperCanvasRepresentable: UIViewControllerRepresentable {
    let initialPages: [CanvasPageSnapshot]
    let initialPageID: UUID
    let initialViewport: CanvasViewportState
    let initialInputMode: CanvasInputMode
    let initialPageLayout: CanvasPageLayoutPreferences
    let documentMode: CanvasDocumentMode
    let topChromeHeight: CGFloat
    let callbacks: PaperCanvasCallbacks
    let onAttach: @MainActor (any PaperCanvasCommanding) -> Void
    let onDetach: @MainActor (any PaperCanvasCommanding) -> Void

    init(
        initialPages: [CanvasPageSnapshot],
        initialPageID: UUID,
        initialViewport: CanvasViewportState,
        initialInputMode: CanvasInputMode,
        initialPageLayout: CanvasPageLayoutPreferences = .default,
        documentMode: CanvasDocumentMode = .paged,
        topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight,
        callbacks: PaperCanvasCallbacks,
        onAttach: @escaping @MainActor (any PaperCanvasCommanding) -> Void,
        onDetach: @escaping @MainActor (any PaperCanvasCommanding) -> Void
    ) {
        self.initialPages = initialPages
        self.initialPageID = initialPageID
        self.initialViewport = initialViewport
        self.initialInputMode = initialInputMode
        self.initialPageLayout = initialPageLayout
        self.documentMode = documentMode
        self.topChromeHeight = topChromeHeight
        self.callbacks = callbacks
        self.onAttach = onAttach
        self.onDetach = onDetach
    }

    /// Transitional initializer for the single-page model. It still enters
    /// the same continuous-stack controller and can receive later insertions.
    init(
        initialPageID: UUID,
        initialMarkup: PaperMarkup,
        initialViewport: CanvasViewportState,
        initialInputMode: CanvasInputMode,
        initialPageLayout: CanvasPageLayoutPreferences = .default,
        documentMode: CanvasDocumentMode = .paged,
        topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight,
        callbacks: PaperCanvasCallbacks,
        onAttach: @escaping @MainActor (any PaperCanvasCommanding) -> Void,
        onDetach: @escaping @MainActor (any PaperCanvasCommanding) -> Void
    ) {
        self.init(
            initialPages: [
                CanvasPageSnapshot(
                    id: initialPageID,
                    markup: initialMarkup,
                    viewport: initialViewport
                )
            ],
            initialPageID: initialPageID,
            initialViewport: initialViewport,
            initialInputMode: initialInputMode,
            initialPageLayout: initialPageLayout,
            documentMode: documentMode,
            topChromeHeight: topChromeHeight,
            callbacks: callbacks,
            onAttach: onAttach,
            onDetach: onDetach
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PaperCanvasViewController {
        let controller = PaperCanvasViewController(
            pages: initialPages,
            currentPageID: initialPageID,
            viewport: initialViewport,
            inputMode: initialInputMode,
            pageLayout: initialPageLayout,
            documentMode: documentMode,
            callbacks: callbacks
        )
        context.coordinator.controller = controller
        onAttach(controller)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: PaperCanvasViewController,
        context: Context
    ) {
        // SwiftUI presentation changes intentionally perform no canvas mutation.
        // Only refresh the one-way event closures retained by UIKit.
        context.coordinator.parent = self
        uiViewController.updateCallbacks(callbacks)
        uiViewController.updateTopChromeHeight(topChromeHeight)
    }

    static func dismantleUIViewController(
        _ uiViewController: PaperCanvasViewController,
        coordinator: Coordinator
    ) {
        coordinator.parent.onDetach(uiViewController)
        uiViewController.prepareForDismantle()
        coordinator.controller = nil
    }

    @MainActor
    final class Coordinator {
        var parent: PaperCanvasRepresentable
        weak var controller: PaperCanvasViewController?

        init(parent: PaperCanvasRepresentable) {
            self.parent = parent
        }
    }
}
