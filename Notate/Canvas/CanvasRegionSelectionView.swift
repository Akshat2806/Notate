import UIKit

/// A transient, canvas-owned region selector for Wand.
///
/// The overlay never changes the active PaperKit tool or writes to the page.
/// Lifting Pencil or a finger completes the one-shot selection and immediately
/// hands the bounded region to Image Playground. There is deliberately no
/// app-owned confirmation step between circling and the system experience.
@MainActor
final class CanvasRegionSelectionView: UIView, UIGestureRecognizerDelegate {
    private enum Phase: Equatable {
        case inactive
        case drawing
        case processing
    }

    var onCancel: (() -> Void)?
    var onRegionConfirmed: ((CGPath) -> Void)?

    private let haloLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let cursorView = UIView()
    private let cursorGlyph = UIImageView()
    private lazy var selectionGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(selectionGestureChanged(_:))
    )

    private var phase: Phase = .inactive
    private var activePath: UIBezierPath?
    private var selectionLimit: CGRect = .zero
    private var sampleCount = 0
    private var lastSamplePoint: CGPoint?
    private var workspaceColor = CanvasConstants.workspaceBackground

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        accessibilityViewIsModal = false

        configureSelectionLayers()
        configureCursor()
        configureGesture()
        applyAppearance()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: CanvasRegionSelectionView, _: UITraitCollection) in
            view.applyAppearance()
        }
        updatePresentation()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func configureAppearance(workspaceColor: UIColor) {
        self.workspaceColor = workspaceColor
        applyAppearance()
    }

    func begin(selectionBounds: CGRect) {
        let available = selectionBounds.standardized.intersection(bounds)
        guard available.isNull == false,
            available.width >= 20,
            available.height >= 20 else {
            clear()
            return
        }

        selectionLimit = available
        phase = .drawing
        accessibilityViewIsModal = false
        activePath = nil
        sampleCount = 0
        lastSamplePoint = nil
        haloLayer.path = nil
        outlineLayer.path = nil
        outlineLayer.lineDashPattern = [6, 4]
        selectionGesture.isEnabled = true
        cursorView.isHidden = true
        isHidden = false
        stopProcessingAnimation()
        updatePresentation()
        setNeedsLayout()
    }

    func presentPersistentPath(_ path: CGPath) {
        phase = .processing
        accessibilityViewIsModal = false
        activePath = UIBezierPath(cgPath: path)
        sampleCount = 0
        lastSamplePoint = nil
        haloLayer.path = path
        outlineLayer.path = path
        outlineLayer.lineDashPattern = [6, 4]
        selectionGesture.isEnabled = false
        cursorView.isHidden = true
        isHidden = false
        stopProcessingAnimation()
        updatePresentation()
        setNeedsLayout()
    }

    func clear() {
        phase = .inactive
        accessibilityViewIsModal = false
        activePath = nil
        sampleCount = 0
        lastSamplePoint = nil
        selectionLimit = .zero
        haloLayer.path = nil
        outlineLayer.path = nil
        selectionGesture.isEnabled = false
        cursorView.isHidden = true
        stopProcessingAnimation()
        updatePresentation()
        isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        haloLayer.frame = bounds
        outlineLayer.frame = bounds
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyAppearance()
    }

    // MARK: - Private

    private func configureSelectionLayers() {
        haloLayer.lineWidth = 6
        haloLayer.lineJoin = .round
        haloLayer.lineCap = .round
        layer.addSublayer(haloLayer)

        outlineLayer.lineWidth = 2
        outlineLayer.lineJoin = .round
        outlineLayer.lineCap = .round
        layer.addSublayer(outlineLayer)
    }

    private func configureCursor() {
        cursorView.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        cursorView.layer.cornerRadius = 14
        cursorView.layer.borderWidth = 1.5
        cursorView.layer.shadowOpacity = 0.12
        cursorView.layer.shadowRadius = 4
        cursorView.layer.shadowOffset = CGSize(width: 0, height: 2)
        cursorView.isUserInteractionEnabled = false
        cursorView.isAccessibilityElement = false
        cursorView.isHidden = true
        addSubview(cursorView)

        cursorGlyph.image = UIImage(systemName: "wand.and.stars")
        cursorGlyph.contentMode = .center
        cursorGlyph.frame = cursorView.bounds
        cursorGlyph.isAccessibilityElement = false
        addSubview(cursorGlyph)
    }

    private func configureGesture() {
        selectionGesture.cancelsTouchesInView = true
        selectionGesture.minimumNumberOfTouches = 1
        selectionGesture.maximumNumberOfTouches = 1
        selectionGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        selectionGesture.delegate = self
        addGestureRecognizer(selectionGesture)
    }

    private func applyAppearance() {
        let accent = tintColor ?? .systemIndigo
        let resolvedWorkspace = workspaceColor.resolvedColor(with: traitCollection)
        let resolvedAccent = accent.resolvedColor(with: traitCollection)

        haloLayer.fillColor = resolvedAccent.withAlphaComponent(0.635).cgColor
        haloLayer.strokeColor = resolvedWorkspace.withAlphaComponent(0.96).cgColor
        outlineLayer.fillColor = resolvedAccent.withAlphaComponent(0.025).cgColor
        outlineLayer.strokeColor = resolvedAccent.withAlphaComponent(0.9).cgColor

        cursorView.backgroundColor = workspaceColor
        cursorView.layer.borderColor = resolvedAccent.withAlphaComponent(0.9).cgColor
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorGlyph.tintColor = accent
    }

    private func updatePresentation() {
        let isProcessing = phase == .processing

        if isProcessing {
            startProcessingAnimation()
        } else {
            stopProcessingAnimation()
        }
    }

    private func startProcessingAnimation() {
        if UIAccessibility.isReduceMotionEnabled {
            outlineLayer.removeAnimation(forKey: "image-wand-selection-dash")
        } else {
            guard outlineLayer.animation(forKey: "image-wand-selection-dash") == nil else { return }
            let dashAnimation = CABasicAnimation(keyPath: "lineDashPhase")
            dashAnimation.fromValue = 0
            dashAnimation.toValue = 20
            dashAnimation.duration = 0.8
            dashAnimation.repeatCount = .infinity
            outlineLayer.add(dashAnimation, forKey: "image-wand-selection-dash")
        }
    }

    private func stopProcessingAnimation() {
        outlineLayer.removeAnimation(forKey: "image-wand-selection-dash")
    }

    // MARK: - Gesture Recognition

    override func accessibilityPerformEscape() -> Bool {
        guard phase != .inactive else { return false }
        onCancel?()
        return true
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard phase == .drawing else { return false }
        return selectionLimit.contains(gestureRecognizer.location(in: self))
    }

    @objc
    private func selectionGestureChanged(_ gesture: UIPanGestureRecognizer) {
        let location = clampedPoint(gesture.location(in: self))
        switch gesture.state {
        case .began:
            let path = UIBezierPath()
            path.move(to: location)
            activePath = path
            sampleCount = 1
            lastSamplePoint = location
            updateCursor(at: location)
            updateLayers(with: path)

        case .changed:
            guard let path = activePath,
                let previousPoint = lastSamplePoint,
                hypot(location.x - previousPoint.x, location.y - previousPoint.y) >= 2 else {
                return
            }
            let midpoint = CGPoint(
                x: (previousPoint.x + location.x) / 2,
                y: (previousPoint.y + location.y) / 2
            )
            path.addQuadCurve(to: midpoint, controlPoint: previousPoint)
            lastSamplePoint = location
            sampleCount += 1
            updateCursor(at: location)
            updateLayers(with: path)

        case .ended:
            finishSelection()

        case .cancelled, .failed:
            resetDrawingPath()

        default:
            break
        }
    }

    private func finishSelection() {
        guard let path = activePath,
            sampleCount >= 4,
            path.bounds.width >= 12,
            path.bounds.height >= 12 else {
            resetDrawingPath()
            return
        }
        if let finalPoint = lastSamplePoint, path.currentPoint != finalPoint {
            path.addLine(to: finalPoint)
        }
        path.close()
        updateLayers(with: path)
        phase = .processing
        accessibilityViewIsModal = false
        selectionGesture.isEnabled = false
        cursorView.isHidden = true
        updatePresentation()
        setNeedsLayout()
        onRegionConfirmed?(path.cgPath)
    }

    private func resetDrawingPath() {
        activePath = nil
        sampleCount = 0
        lastSamplePoint = nil
        haloLayer.path = nil
        outlineLayer.path = nil
        cursorView.isHidden = true
    }

    private func updateLayers(with path: UIBezierPath) {
        haloLayer.path = path.cgPath
        outlineLayer.path = path.cgPath
    }

    private func updateCursor(at point: CGPoint) {
        cursorView.center = point
        cursorView.isHidden = false
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, selectionLimit.minX), selectionLimit.maxX),
            y: min(max(point.y, selectionLimit.minY), selectionLimit.maxY)
        )
    }
}

#if DEBUG
extension CanvasRegionSelectionView {
    var phaseForTesting: String {
        switch phase {
        case .inactive: "inactive"
        case .drawing: "drawing"
        case .processing: "processing"
        }
    }

    var workspaceColorForTesting: UIColor { workspaceColor }

    func completePathForTesting(_ path: CGPath) {
        activePath = UIBezierPath(cgPath: path)
        sampleCount = 4
        lastSamplePoint = nil
        if let activePath {
            updateLayers(with: activePath)
        }
        finishSelection()
    }
}
#endif
