import UIKit

/// A transient drawing aid layered over the canvas.
///
/// The view deliberately participates in hit testing only at its two handles
/// and, for the compass, the insert button. Drawing can therefore continue
/// through every other visible part of the instrument.
@MainActor
final class CanvasGeometryInstrumentView: UIView {
    var topChromeHeight: CGFloat = CanvasConstants.toolbarTopPadding + CanvasConstants.toolbarHeight {
        didSet { setNeedsLayout() }
    }
    private enum Metrics {
        static let canvasInset: CGFloat = 16
        static let handleHitDiameter: CGFloat = 66
        static let handleVisualRadius: CGFloat = 13
        static let protractorMaximumRadius: CGFloat = 146
        static let protractorHandleOffset: CGFloat = 29
        static let protractorMinimumRadius: CGFloat = 46
        static let compassMaximumRadius: CGFloat = 124
        static let compassEdgeClearance: CGFloat = 31
        static let insertButtonGap: CGFloat = 34
        static let insertButtonSize = CGSize(width: 146, height: 42)
    }

    var tool: CanvasGeometryTool? {
        didSet { applyTool() }
    }

    /// Called with a center and radius expressed in this view's coordinate
    /// space. The receiver decides how those points map into page coordinates.
    var onInsertCircle: ((CGPoint, CGFloat) -> Bool)?

    private let moveHandle = UIView()
    private let adjustmentHandle = UIView()
    private let insertCircleButton = UIButton(type: .system)

    private lazy var movePanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleMovePan(_:))
    )
    private lazy var adjustmentPanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleAdjustmentPan(_:))
    )

    private var protractorCenter = CGPoint.zero
    private var protractorRadius = Metrics.protractorMaximumRadius
    private var protractorAngle: CGFloat = 0
    private var hasPositionedProtractor = false

    private var compassCenter = CGPoint.zero
    private var compassRadius: CGFloat = 92
    private var compassAngle: CGFloat = -.pi / 4
    private var hasPositionedCompass = false

    private var dragStartLocation = CGPoint.zero
    private var dragStartCenter = CGPoint.zero

    override init(frame: CGRect) {
        tool = nil
        super.init(frame: frame)

        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        isHidden = true

        configureHandle(moveHandle)
        configureHandle(adjustmentHandle)
        moveHandle.addGestureRecognizer(movePanGesture)
        adjustmentHandle.addGestureRecognizer(adjustmentPanGesture)
        addSubview(moveHandle)
        addSubview(adjustmentHandle)

        var buttonConfiguration = UIButton.Configuration.tinted()
        buttonConfiguration.title = "Insert circle"
        buttonConfiguration.image = UIImage(systemName: "circle.badge.plus")
        buttonConfiguration.imagePadding = 7
        buttonConfiguration.cornerStyle = .capsule
        insertCircleButton.configuration = buttonConfiguration
        insertCircleButton.accessibilityLabel = "Insert circle"
        insertCircleButton.accessibilityHint = "Adds the circle shown by the compass to the note."
        insertCircleButton.addTarget(
            self,
            action: #selector(insertCircle),
            for: .primaryActionTriggered
        )
        addSubview(insertCircleButton)

        applyTool()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func setTool(_ tool: CanvasGeometryTool?) {
        self.tool = tool
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        insertCircleButton.configuration?.baseForegroundColor = tintColor
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let safeRect = instrumentSafeRect
        guard safeRect.isEmpty == false else { return }

        prepareProtractorIfNeeded(in: safeRect)
        prepareCompassIfNeeded(in: safeRect)

        protractorRadius = min(protractorRadius, maximumProtractorRadius(in: safeRect, angle: protractorAngle))
        compassRadius = min(compassRadius, maximumCompassRadius(in: safeRect))
        constrainProtractorCenter(to: safeRect)
        constrainCompassCenter(to: safeRect)
        positionInteractiveElements()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isHidden == false, alpha > 0.01, isUserInteractionEnabled else { return false }

        if moveHandle.isHidden == false, moveHandle.frame.contains(point) { return true }
        if adjustmentHandle.isHidden == false, adjustmentHandle.frame.contains(point) { return true }
        if insertCircleButton.isHidden == false,
           insertCircleButton.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return true
        }
        return false
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), isHidden == false else { return }

        switch tool {
        case .protractor:
            drawProtractor(in: context)
        case .compass:
            drawCompass(in: context)
        case .ruler, nil:
            break
        }
    }

    private func configureHandle(_ handle: UIView) {
        handle.backgroundColor = .clear
        handle.isOpaque = false
        handle.isExclusiveTouch = true
        handle.isAccessibilityElement = true
        handle.accessibilityElementsHidden = false
    }

    private func applyTool() {
        switch tool {
        case .protractor:
            isHidden = false
            isUserInteractionEnabled = true
            moveHandle.isHidden = false
            adjustmentHandle.isHidden = false
            insertCircleButton.isHidden = false
            accessibilityLabel = "Protractor"
            moveHandle.accessibilityLabel = "Move protractor"
            moveHandle.accessibilityHint = "Use the custom actions to move the protractor."
            moveHandle.accessibilityCustomActions = movementAccessibilityActions
            adjustmentHandle.accessibilityLabel = "Rotate protractor"
            adjustmentHandle.accessibilityHint = "Use the custom actions to rotate or resize the protractor."
            adjustmentHandle.accessibilityCustomActions = rotationAccessibilityActions
        case .compass:
            isHidden = false
            isUserInteractionEnabled = true
            moveHandle.isHidden = false
            adjustmentHandle.isHidden = false
            insertCircleButton.isHidden = false
            accessibilityLabel = "Compass"
            moveHandle.accessibilityLabel = "Move compass"
            moveHandle.accessibilityHint = "Use the custom actions to move the compass."
            moveHandle.accessibilityCustomActions = movementAccessibilityActions
            adjustmentHandle.accessibilityLabel = "Adjust compass"
            adjustmentHandle.accessibilityHint = "Use the custom actions to resize or rotate the compass."
            adjustmentHandle.accessibilityCustomActions = compassAdjustmentAccessibilityActions
        case .ruler, nil:
            // Paperkit owns the native ruler. This overlay must not obscure it
            // or take part in input while that tool is selected.
            isHidden = true
            isUserInteractionEnabled = false
            moveHandle.isHidden = true
            adjustmentHandle.isHidden = true
            insertCircleButton.isHidden = true
            accessibilityLabel = nil
            moveHandle.accessibilityCustomActions = nil
            adjustmentHandle.accessibilityCustomActions = nil
        }

        setNeedsLayout()
        setNeedsDisplay()
    }

    private var instrumentSafeRect: CGRect {
        let safeBounds = bounds.inset(by: safeAreaInsets)
        let topChromeExclusion = topChromeHeight
            + CanvasConstants.firstPageToolbarGap
        var preferred = safeBounds.insetBy(dx: Metrics.canvasInset, dy: Metrics.canvasInset)
        preferred.origin.y += topChromeExclusion
        preferred.size.height -= topChromeExclusion
        if preferred.width > 0, preferred.height > 0 { return preferred }
        return bounds.insetBy(dx: 4, dy: 4)
    }

    private func prepareProtractorIfNeeded(in safeRect: CGRect) {
        guard hasPositionedProtractor == false else { return }
        protractorRadius = maximumProtractorRadius(in: safeRect, angle: protractorAngle)
        protractorCenter = CGPoint(
            x: safeRect.midX,
            y: safeRect.midY + protractorRadius * 0.28
        )
        hasPositionedProtractor = true
    }

    private func prepareCompassIfNeeded(in safeRect: CGRect) {
        guard hasPositionedCompass == false else { return }
        compassRadius = min(96, maximumCompassRadius(in: safeRect))
        compassCenter = CGPoint(x: safeRect.midX, y: safeRect.midY - 22)
        hasPositionedCompass = true
    }

    private func maximumProtractorRadius(in safeRect: CGRect, angle: CGFloat) -> CGFloat {
        let limitingDimension = min(safeRect.width, safeRect.height)
        var lower = min(24, limitingDimension / 4)
        var upper = min(Metrics.protractorMaximumRadius, max(lower, limitingDimension / 2 - 12))

        func fits(_ radius: CGFloat) -> Bool {
            let localBounds = CGRect(
                x: -radius - 5,
                y: -radius - 5,
                width: radius * 2 + 10,
                height: radius * 2 + 10
            )
            let envelope = rotatedBoundingRect(localBounds, angle: angle)
            return envelope.width <= safeRect.width && envelope.height <= safeRect.height
        }

        guard fits(lower) else { return max(12, lower) }
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if fits(candidate) {
                lower = candidate
            } else {
                upper = candidate
            }
        }

        return lower
    }

    private func maximumCompassRadius(in safeRect: CGRect) -> CGFloat {
        let horizontal = (safeRect.width - Metrics.compassEdgeClearance * 2) / 2
        let verticalReserved = Metrics.compassEdgeClearance
            + Metrics.insertButtonGap
            + Metrics.insertButtonSize.height
        let vertical = (safeRect.height - verticalReserved) / 2
        return min(Metrics.compassMaximumRadius, max(32, min(horizontal, vertical)))
    }

    private func positionInteractiveElements() {
        let hitSize = CGSize(
            width: Metrics.handleHitDiameter,
            height: Metrics.handleHitDiameter
        )

        switch tool {
        case .protractor:
            moveHandle.bounds = CGRect(origin: .zero, size: hitSize)
            moveHandle.center = protractorCenter

            let adjustmentLocalPoint = CGPoint(
                x: 0,
                y: -protractorRadius - Metrics.protractorHandleOffset
            )
            adjustmentHandle.bounds = CGRect(origin: .zero, size: hitSize)
            adjustmentHandle.center = transformed(
                adjustmentLocalPoint,
                around: protractorCenter,
                angle: protractorAngle
            )

            moveHandle.accessibilityValue = accessibilityPosition(protractorCenter)
            adjustmentHandle.accessibilityValue = "\(accessibilityDegrees(protractorAngle)) degrees"

        case .compass:
            moveHandle.bounds = CGRect(origin: .zero, size: hitSize)
            moveHandle.center = compassCenter

            adjustmentHandle.bounds = CGRect(origin: .zero, size: hitSize)
            adjustmentHandle.center = transformed(
                CGPoint(x: compassRadius, y: 0),
                around: compassCenter,
                angle: compassAngle
            )
            moveHandle.accessibilityValue = accessibilityPosition(compassCenter)
            adjustmentHandle.accessibilityValue =
                "Radius \(accessibilityNumber(compassRadius)) screen points."

            let safeRect = instrumentSafeRect
            var buttonFrame = CGRect(
                x: compassCenter.x - Metrics.insertButtonSize.width / 2,
                y: compassCenter.y + compassRadius + Metrics.insertButtonGap,
                width: Metrics.insertButtonSize.width,
                height: Metrics.insertButtonSize.height
            )
            buttonFrame.origin.x = constrainedOrigin(
                buttonFrame.origin.x,
                minimum: safeRect.minX,
                maximum: safeRect.maxX - buttonFrame.width,
                fallback: safeRect.midX - buttonFrame.width / 2
            )
            buttonFrame.origin.y = constrainedOrigin(
                buttonFrame.origin.y,
                minimum: safeRect.minY,
                maximum: safeRect.maxY - buttonFrame.height,
                fallback: safeRect.midY - buttonFrame.height / 2
            )
            insertCircleButton.frame = buttonFrame.integral

        case .ruler, nil:
            break
        }
    }

    @objc private func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            dragStartLocation = location
            switch tool {
            case .protractor:
                dragStartCenter = protractorCenter
            case .compass:
                dragStartCenter = compassCenter
            case .ruler, nil:
                return
            }

        case .changed:
            let proposedCenter = CGPoint(
                x: dragStartCenter.x + location.x - dragStartLocation.x,
                y: dragStartCenter.y + location.y - dragStartLocation.y
            )

            switch tool {
            case .protractor:
                protractorCenter = proposedCenter
                constrainProtractorCenter(to: instrumentSafeRect)
            case .compass:
                compassCenter = proposedCenter
                constrainCompassCenter(to: instrumentSafeRect)
            case .ruler, nil:
                return
            }

        default:
            break
        }

        updateAfterInteraction()
    }

    @objc private func handleAdjustmentPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let location = recognizer.location(in: self)

        switch tool {
        case .protractor:
            let delta = CGPoint(
                x: location.x - protractorCenter.x,
                y: location.y - protractorCenter.y
            )

            guard squaredLength(of: delta) > 144 else { return }
            protractorAngle = normalizedAngle(atan2(delta.y, delta.x) + .pi / 2)
            protractorRadius = maximumProtractorRadius(
                in: instrumentSafeRect,
                angle: protractorAngle
            )

            constrainProtractorCenter(to: instrumentSafeRect)

        case .compass:
            let delta = CGPoint(
                x: location.x - compassCenter.x,
                y: location.y - compassCenter.y
            )

            let proposedRadius = sqrt(squaredLength(of: delta))
            guard proposedRadius > 12 else { return }

            compassAngle = normalizedAngle(atan2(delta.y, delta.x))
            let maximumRadius = maximumCompassRadius(in: instrumentSafeRect)
            let minimumRadius = min(36, maximumRadius)
            compassRadius = clamped(proposedRadius, to: minimumRadius...maximumRadius)
            constrainCompassCenter(to: instrumentSafeRect)

        case .ruler, nil:
            return
        }

        updateAfterInteraction()
    }

    private func updateAfterInteraction() {
        positionInteractiveElements()
        setNeedsDisplay()
    }

    @objc private func insertCircle() {
        if onInsertCircle?(compassCenter, compassRadius) == true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Place the circle fully inside a page before inserting it."
            )
        }
    }

    private var movementAccessibilityActions: [UIAccessibilityCustomAction] {
        [
            UIAccessibilityCustomAction(
                name: "Move up",
                target: self,
                selector: #selector(accessibilityMoveUp(_:))
            ),
            UIAccessibilityCustomAction(
                name: "Move down",
                target: self,
                selector: #selector(accessibilityMoveDown(_:))
            ),
            UIAccessibilityCustomAction(
                name: "Move left",
                target: self,
                selector: #selector(accessibilityMoveLeft(_:))
            ),
            UIAccessibilityCustomAction(
                name: "Move right",
                target: self,
                selector: #selector(accessibilityMoveRight(_:))
            )
        ]
    }

    private var rotationAccessibilityActions: [UIAccessibilityCustomAction] {
        [
            UIAccessibilityCustomAction(
                name: "Rotate counterclockwise",
                target: self,
                selector: #selector(rotateCounterclockwise(_:))
            ),
            UIAccessibilityCustomAction(
                name: "Rotate clockwise",
                target: self,
                selector: #selector(rotateClockwise(_:))
            )
        ]
    }

    private var compassAdjustmentAccessibilityActions: [UIAccessibilityCustomAction] {
        [
            UIAccessibilityCustomAction(
                name: "Increase radius",
                target: self,
                selector: #selector(accessibilityIncreaseRadius(_:))
            ),
            UIAccessibilityCustomAction(
                name: "Decrease radius",
                target: self,
                selector: #selector(accessibilityDecreaseRadius(_:))
            )
        ] + rotationAccessibilityActions
    }

    @objc private func accessibilityMoveUp(_ action: UIAccessibilityCustomAction) -> Bool {
        moveInstrumentBy(dx: 0, dy: -24)
    }

    @objc private func accessibilityMoveDown(_ action: UIAccessibilityCustomAction) -> Bool {
        moveInstrumentBy(dx: 0, dy: 24)
    }

    @objc private func accessibilityMoveLeft(_ action: UIAccessibilityCustomAction) -> Bool {
        moveInstrumentBy(dx: -24, dy: 0)
    }

    @objc private func accessibilityMoveRight(_ action: UIAccessibilityCustomAction) -> Bool {
        moveInstrumentBy(dx: 24, dy: 0)
    }

    @objc private func rotateCounterclockwise(_ action: UIAccessibilityCustomAction) -> Bool {
        rotateInstrument(by: -.pi / 12)
    }

    @objc private func rotateClockwise(_ action: UIAccessibilityCustomAction) -> Bool {
        rotateInstrument(by: .pi / 12)
    }

    @objc private func accessibilityIncreaseRadius(_ action: UIAccessibilityCustomAction) -> Bool {
        resizeCompass(by: 12)
    }

    @objc private func accessibilityDecreaseRadius(_ action: UIAccessibilityCustomAction) -> Bool {
        resizeCompass(by: -12)
    }

    @discardableResult
    private func moveInstrumentBy(dx: CGFloat, dy: CGFloat) -> Bool {
        switch tool {
        case .protractor:
            protractorCenter.x += dx
            protractorCenter.y += dy
            constrainProtractorCenter(to: instrumentSafeRect)
        case .compass:
            compassCenter.x += dx
            compassCenter.y += dy
            constrainCompassCenter(to: instrumentSafeRect)
        case .ruler, nil:
            return false
        }

        updateAfterInteraction()
        return true
    }

    @discardableResult
    private func rotateInstrument(by delta: CGFloat) -> Bool {
        switch tool {
        case .protractor:
            protractorAngle = normalizedAngle(protractorAngle + delta)
            protractorRadius = maximumProtractorRadius(
                in: instrumentSafeRect,
                angle: protractorAngle
            )
            constrainProtractorCenter(to: instrumentSafeRect)
        case .compass:
            compassAngle = normalizedAngle(compassAngle + delta)
            constrainCompassCenter(to: instrumentSafeRect)
        case .ruler, nil:
            return false
        }

        updateAfterInteraction()
        return true
    }

    @discardableResult
    private func resizeCompass(by delta: CGFloat) -> Bool {
        guard tool == .compass else { return false }
        let maximumRadius = maximumCompassRadius(in: instrumentSafeRect)
        let minimumRadius = min(36, maximumRadius)
        let proposedRadius = clamped(compassRadius + delta, to: minimumRadius...maximumRadius)
        compassRadius = proposedRadius
        constrainCompassCenter(to: instrumentSafeRect)
        updateAfterInteraction()
        return true
    }

    private func constrainProtractorCenter(to safeRect: CGRect) {
        guard safeRect.isEmpty == false else { return }

        let localBounds = CGRect(
            x: -protractorRadius - 5,
            y: -protractorRadius - 5,
            width: protractorRadius * 2 + 10,
            height: protractorRadius * 2 + Metrics.protractorHandleOffset + Metrics.handleHitDiameter
        )
        let relativeBounds = rotatedBoundingRect(localBounds, angle: protractorAngle)

        protractorCenter.x = constrainedOrigin(
            protractorCenter.x,
            minimum: safeRect.minX - relativeBounds.minX,
            maximum: safeRect.maxX - relativeBounds.maxX,
            fallback: safeRect.midX
        )
        protractorCenter.y = constrainedOrigin(
            protractorCenter.y,
            minimum: safeRect.minY - relativeBounds.minY,
            maximum: safeRect.maxY - relativeBounds.maxY,
            fallback: safeRect.midY
        )
    }

    private func constrainCompassCenter(to safeRect: CGRect) {
        guard safeRect.isEmpty == false else { return }

        compassRadius = min(compassRadius, maximumCompassRadius(in: safeRect))
        let horizontalClearance = compassRadius + Metrics.compassEdgeClearance
        let topClearance = compassRadius + Metrics.compassEdgeClearance
        let bottomClearance = compassRadius
            + Metrics.insertButtonGap
            + Metrics.insertButtonSize.height

        compassCenter.x = constrainedOrigin(
            compassCenter.x,
            minimum: safeRect.minX + horizontalClearance,
            maximum: safeRect.maxX - horizontalClearance,
            fallback: safeRect.midX
        )
        compassCenter.y = constrainedOrigin(
            compassCenter.y,
            minimum: safeRect.minY + topClearance,
            maximum: safeRect.maxY - bottomClearance,
            fallback: safeRect.midY
        )
    }

    private func maximumCompassRadius(at center: CGPoint, in safeRect: CGRect) -> CGFloat {
        let available = min(
            center.x - safeRect.minX - Metrics.compassEdgeClearance,
            safeRect.maxX - center.x - Metrics.compassEdgeClearance,
            center.y - safeRect.minY - Metrics.compassEdgeClearance,
            safeRect.maxY - center.y - Metrics.insertButtonGap - Metrics.insertButtonSize.height
        )
        return min(Metrics.compassMaximumRadius, max(30, available))
    }

    private func drawProtractor(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: protractorCenter.x, y: protractorCenter.y)
        context.rotate(by: protractorAngle)

        let radius = protractorRadius
        let bodyPath = protractorBodyPath(radius: radius)
        let accent = tintColor.resolvedColor(with: traitCollection)
        let foreground = UIColor.label.resolvedColor(with: traitCollection)
        let background = UIColor.systemBackground.resolvedColor(with: traitCollection)

        context.setShadow(
            offset: CGSize(width: 0, height: 5),
            blur: 14,
            color: UIColor.black.withAlphaComponent(0.18).cgColor
        )

        context.addPath(bodyPath)
        context.setFillColor(background.withAlphaComponent(0.76).cgColor)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                accent.withAlphaComponent(0.16).cgColor,
                background.withAlphaComponent(0.04).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.saveGState()
            context.addPath(bodyPath)
            context.clip()
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: -radius),
                end: .zero,
                options: []
            )
            context.restoreGState()
        }

        context.addPath(bodyPath)
        context.setStrokeColor(accent.withAlphaComponent(0.82).cgColor)
        context.setLineWidth(1.6)
        context.strokePath()

        drawProtractorTicks(radius: radius, color: foreground, in: context)
        drawProtractorLabels(radius: radius, color: foreground)

        let rotationHandleY = -protractorRadius - Metrics.protractorHandleOffset
        context.setStrokeColor(accent.withAlphaComponent(0.62).cgColor)
        context.setLineWidth(1.4)
        context.setLineDash(phase: 0, lengths: [3, 4])
        context.move(to: CGPoint(x: 0, y: -protractorRadius + 2))
        context.addLine(to: CGPoint(x: 0, y: rotationHandleY))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        drawMoveHandle(at: .zero, accent: accent, in: context)
        drawRotationHandle(at: CGPoint(x: 0, y: rotationHandleY), accent: accent, in: context)
        context.restoreGState()
    }

    private func protractorBodyPath(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: radius, y: 0))
        for index in 1...90 {
            let angle = CGFloat(index) * .pi / 90
            path.addLine(to: CGPoint(
                x: cos(angle) * radius,
                y: -sin(angle) * radius
            ))
        }
        path.closeSubpath()
        return path
    }

    private func drawProtractorTicks(
        radius: CGFloat,
        color: UIColor,
        in context: CGContext
    ) {
        for degree in stride(from: 0, through: 180, by: 2) {
            let angle = CGFloat(degree) * .pi / 180
            let isMajor = degree.isMultiple(of: 10)
            let isMidpoint = degree.isMultiple(of: 5)
            let tickLength: CGFloat = isMajor ? 17 : (isMidpoint ? 11 : 6)
            let innerRadius = radius - tickLength

            context.move(to: CGPoint(
                x: cos(angle) * innerRadius,
                y: -sin(angle) * innerRadius
            ))
            context.addLine(to: CGPoint(
                x: cos(angle) * (radius - 1),
                y: -sin(angle) * (radius - 1)
            ))
            context.setStrokeColor(
                color.withAlphaComponent(isMajor ? 0.72 : 0.4).cgColor
            )
            context.setLineWidth(isMajor ? 1.25 : 0.7)
            context.strokePath()
        }

        context.setStrokeColor(color.withAlphaComponent(0.34).cgColor)
        context.setLineWidth(1)
        context.addPath(semicirclePath(radius: radius * 0.56))
        context.strokePath()

        context.move(to: CGPoint(x: -radius, y: 0))
        context.addLine(to: CGPoint(x: radius, y: 0))
        context.setStrokeColor(color.withAlphaComponent(0.58).cgColor)
        context.setLineWidth(1.2)
        context.strokePath()
    }

    private func drawProtractorLabels(radius: CGFloat, color: UIColor) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.72)
        ]

        for degree in stride(from: 30, through: 150, by: 30) {
            let angle = CGFloat(degree) * .pi / 180
            let labelRadius = radius - 29
            let label = "\(degree)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: CGPoint(
                    x: cos(angle) * labelRadius - size.width / 2,
                    y: -sin(angle) * labelRadius - size.height / 2
                ),
                withAttributes: attributes
            )
        }
    }

    private func semicirclePath(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: 0))
        for index in 1...72 {
            let angle = CGFloat(index) * .pi / 72
            path.addLine(to: CGPoint(
                x: cos(angle) * radius,
                y: -sin(angle) * radius
            ))
        }
        return path
    }

    private func drawCompass(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: compassCenter.x, y: compassCenter.y)
        context.rotate(by: compassAngle)

        let radius = compassRadius
        let accent = tintColor.resolvedColor(with: traitCollection)
        let foreground = UIColor.label.resolvedColor(with: traitCollection)
        let background = UIColor.systemBackground.resolvedColor(with: traitCollection)

        let circleRect = CGRect(
            x: -radius,
            y: -radius,
            width: radius * 2,
            height: radius * 2
        )

        context.setShadow(
            offset: CGSize(width: 0, height: 4),
            blur: 12,
            color: UIColor.black.withAlphaComponent(0.14).cgColor
        )
        context.setFillColor(accent.withAlphaComponent(0.07).cgColor)
        context.fillEllipse(in: circleRect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(accent.withAlphaComponent(0.76).cgColor)
        context.setLineWidth(1.7)
        context.strokeEllipse(in: circleRect.insetBy(dx: 0.8, dy: 0.8))

        drawCompassTicks(radius: radius, color: foreground, in: context)
        drawCompassArms(
            radius: radius,
            accent: accent,
            background: background,
            in: context
        )
        drawCompassRadiusLabel(radius: radius, color: foreground)
        drawMoveHandle(at: .zero, accent: accent, in: context)
        drawRadiusHandle(at: CGPoint(x: radius, y: 0), accent: accent, in: context)
        context.restoreGState()
    }

    private func drawCompassTicks(
        radius: CGFloat,
        color: UIColor,
        in context: CGContext
    ) {
        for index in 0..<36 {
            let angle = CGFloat(index) * .pi / 18
            let isMajor = index.isMultiple(of: 3)
            let tickLength: CGFloat = isMajor ? 9 : 5

            context.move(to: CGPoint(
                x: cos(angle) * (radius - tickLength),
                y: sin(angle) * (radius - tickLength)
            ))
            context.addLine(to: CGPoint(
                x: cos(angle) * (radius - 1),
                y: sin(angle) * (radius - 1)
            ))
            context.setStrokeColor(
                color.withAlphaComponent(isMajor ? 0.6 : 0.3).cgColor
            )
            context.setLineWidth(isMajor ? 1.1 : 0.7)
            context.strokePath()
        }
    }

    private func drawCompassArms(
        radius: CGFloat,
        accent: UIColor,
        background: UIColor,
        in context: CGContext
    ) {
        let hingeHeight = min(72, max(38, radius * 0.68))
        let hinge = CGPoint(x: radius / 2, y: -hingeHeight)
        let pivot = CGPoint.zero
        let pencil = CGPoint(x: radius, y: 0)

        context.setLineCap(.round)
        for (width, color) in [
            (CGFloat(7), background.withAlphaComponent(0.92)),
            (CGFloat(3.2), accent.withAlphaComponent(0.82))
        ] {
            context.setLineWidth(width)
            context.setStrokeColor(color.cgColor)
            context.move(to: hinge)
            context.addLine(to: pivot)
            context.move(to: hinge)
            context.addLine(to: pencil)
            context.strokePath()
        }

        context.setStrokeColor(accent.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 15, y: -3))
        context.addLine(to: CGPoint(x: radius - 15, y: -3))
        context.strokePath()

        context.setFillColor(background.withAlphaComponent(0.96).cgColor)
        context.fillEllipse(in: CGRect(
            x: hinge.x - 10,
            y: hinge.y - 10,
            width: 20,
            height: 20
        ))
        context.setStrokeColor(accent.withAlphaComponent(0.80).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(
            x: hinge.x - 10,
            y: hinge.y - 10,
            width: 20,
            height: 20
        ))
        context.setFillColor(accent.withAlphaComponent(0.72).cgColor)
        context.fillEllipse(in: CGRect(
            x: hinge.x - 3,
            y: hinge.y - 3,
            width: 6,
            height: 6
        ))
        context.setLineWidth(3)
        context.setStrokeColor(accent.withAlphaComponent(0.82).cgColor)
        context.move(to: CGPoint(x: hinge.x, y: hinge.y - 10))
        context.addLine(to: CGPoint(x: hinge.x, y: hinge.y - 23))
        context.strokePath()
    }

    private func drawCompassRadiusLabel(radius: CGFloat, color: UIColor) {
        let label = "Drag to resize" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.72)
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: radius / 2 - size.width / 2, y: 7),
            withAttributes: attributes
        )
    }

    private func drawMoveHandle(
        at point: CGPoint,
        accent: UIColor,
        in context: CGContext
    ) {
        drawLandmarkBase(
            at: point,
            accent: accent,
            in: context
        )
        context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: point.x - 5, y: point.y))
        context.addLine(to: CGPoint(x: point.x + 5, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - 5))
        context.addLine(to: CGPoint(x: point.x, y: point.y + 5))
        context.strokePath()
    }

    private func drawRotationHandle(
        at point: CGPoint,
        accent: UIColor,
        in context: CGContext
    ) {
        drawLandmarkBase(
            at: point,
            accent: accent,
            in: context
        )
        context.setStrokeColor(accent.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(1.5)
        context.addArc(
            center: point,
            radius: 5.2,
            startAngle: -.pi * 0.85,
            endAngle: .pi * 0.65,
            clockwise: false
        )
        context.strokePath()
        context.fillPath()

        let arrowTip = CGPoint(x: point.x - 4.7, y: point.y + 3.1)
        context.setFillColor(accent.withAlphaComponent(0.92).cgColor)
        context.move(to: arrowTip)
        context.addLine(to: CGPoint(x: arrowTip.x + 0.5, y: arrowTip.y - 5))
        context.addLine(to: CGPoint(x: arrowTip.x + 4.2, y: arrowTip.y - 1.7))
        context.closePath()
        context.fillPath()
    }

    private func drawRadiusHandle(
        at point: CGPoint,
        accent: UIColor,
        in context: CGContext
    ) {
        drawLandmarkBase(at: point, accent: accent, in: context)
        context.setStrokeColor(accent.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: point.x - 5.5, y: point.y))
        context.addLine(to: CGPoint(x: point.x + 5.5, y: point.y))
        context.move(to: CGPoint(x: point.x - 5.5, y: point.y - 2.1))
        context.addLine(to: CGPoint(x: point.x - 2.7, y: point.y + 2.1))
        context.move(to: CGPoint(x: point.x + 5.5, y: point.y - 2.1))
        context.addLine(to: CGPoint(x: point.x + 2.7, y: point.y + 2.1))
        context.strokePath()
    }

    private func drawLandmarkBase(
        at point: CGPoint,
        accent: UIColor,
        in context: CGContext
    ) {
        let radius = Metrics.handleVisualRadius
        let handleRect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        context.setShadow(
            offset: CGSize(width: 0, height: 2),
            blur: 5,
            color: UIColor.black.withAlphaComponent(0.22).cgColor
        )
        context.setFillColor(
            UIColor.systemBackground.resolvedColor(with: traitCollection)
                .withAlphaComponent(0.96).cgColor
        )
        context.fillEllipse(in: handleRect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(accent.withAlphaComponent(0.94).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: handleRect.insetBy(dx: 1, dy: 1))
    }

    private func transformed(
        _ point: CGPoint,
        around center: CGPoint,
        angle: CGFloat
    ) -> CGPoint {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGPoint(
            x: center.x + point.x * cosine - point.y * sine,
            y: center.y + point.x * sine + point.y * cosine
        )
    }

    private func rotatedBoundingRect(_ rect: CGRect, angle: CGFloat) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        let cosine = cos(angle)
        let sine = sin(angle)
        let rotated = corners.map { point in
            CGPoint(
                x: point.x * cosine - point.y * sine,
                y: point.x * sine + point.y * cosine
            )
        }
        let minimumX = rotated.map(\.x).min() ?? 0
        let maximumX = rotated.map(\.x).max() ?? 0
        let minimumY = rotated.map(\.y).min() ?? 0
        let maximumY = rotated.map(\.y).max() ?? 0
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private func constrainedOrigin(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard minimum <= maximum else { return fallback }
        return clamped(value, to: minimum...maximum)
    }

    private func clamped(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func squaredLength(of point: CGPoint) -> CGFloat {
        point.x * point.x + point.y * point.y
    }

    private func accessibilityPosition(_ point: CGPoint) -> String {
        "\(accessibilityNumber(point.x)), \(accessibilityNumber(point.y))"
    }

    private func accessibilityNumber(_ value: CGFloat) -> String {
        guard value.isFinite else { return "0" }
        return Double(value).formatted(.number.precision(.fractionLength(0)))
    }

    private func accessibilityDegrees(_ angle: CGFloat) -> Int {
        guard angle.isFinite else { return 0 }
        let degrees = Int((normalizedAngle(angle) * 180 / .pi).rounded())
        return degrees >= 0 ? degrees : degrees + 360
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var result = angle.truncatingRemainder(dividingBy: .pi * 2)
        if result > .pi { result -= .pi * 2 }
        if result < -.pi { result += .pi * 2 }
        return result
    }
}
