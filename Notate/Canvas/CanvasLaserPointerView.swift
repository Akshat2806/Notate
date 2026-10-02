import UIKit

struct CanvasLaserPointerSample: Equatable {
    let location: CGPoint
    let timestamp: TimeInterval
}

struct CanvasLaserTrailVertex: Equatable {
    let location: CGPoint
    let strength: CGFloat
}

/// Produces a dense, corner-softened centerline for the transient laser trail.
/// Rendering this centerline as one variable-width ribbon avoids the row of
/// round segment caps that otherwise reads as a chain of dots.
enum CanvasLaserTrailGeometry {
    static let preferredPointSpacing: CGFloat = 3
    static let maximumVertexCount = 384

    static func vertices(
        for samples: [CanvasLaserPointerSample],
        at timestamp: TimeInterval,
        lifetime: TimeInterval = CanvasLaserPointerTrace.trailLifetime
    ) -> [CanvasLaserTrailVertex] {
        let validSamples = sanitized(samples)
        guard validSamples.isEmpty == false, lifetime.isFinite, lifetime > 0 else { return [] }

        let smoothedSamples = smoothed(validSamples, iterations: validSamples.count > 2 ? 1 : 0)
        let totalLength = zip(smoothedSamples, smoothedSamples.dropFirst()).reduce(CGFloat.zero) {
            $0 + distance(from: $1.0.location, to: $1.1.location)
        }
        let adaptiveSpacing = max(
            preferredPointSpacing,
            totalLength / CGFloat(maximumVertexCount - 1)
        )
        var renderedSamples = resampled(smoothedSamples, spacing: adaptiveSpacing)
        if renderedSamples.count > maximumVertexCount {
            renderedSamples = evenlyReduced(renderedSamples, to: maximumVertexCount)
        }

        var vertices = renderedSamples.map { sample in
            let remaining = CGFloat(
                1 - ((timestamp - sample.timestamp) / lifetime)
            ).clamped(to: 0...1)
            return CanvasLaserTrailVertex(
                location: sample.location,
                strength: pow(remaining, 0.82)
            )
        }

        // The visible tail always closes to a point. This keeps a newly drawn
        // trail elegant and also makes the lifetime cutoff advance without a
        // blunt cap popping between display-link frames.
        if vertices.count > 1, let oldest = vertices.first {
            vertices[0] = CanvasLaserTrailVertex(
                location: oldest.location,
                strength: 0
            )
        }
        return vertices
    }

    /// A single variable-width silhouette for the whole trail. There are no
    /// per-sample circles or separately stroked segments, so neither sampling
    /// density nor round caps can show up as beads in the rendered pointer.
    static func ribbonPath(
        for vertices: [CanvasLaserTrailVertex],
        maximumRadius: CGFloat
    ) -> CGPath? {
        guard maximumRadius.isFinite, maximumRadius > 0 else { return nil }

        var usable: [CanvasLaserTrailVertex] = []
        usable.reserveCapacity(vertices.count)
        for vertex in vertices where vertex.location.x.isFinite
            && vertex.location.y.isFinite
            && vertex.strength.isFinite {
            if let previous = usable.last,
                distance(from: previous.location, to: vertex.location) < 0.001 {
                usable[usable.index(before: usable.endIndex)] = vertex
            } else {
                usable.append(vertex)
            }
        }
        guard usable.count > 1 else { return nil }

        let points = usable.map(\.location)
        let directions = zip(points, points.dropFirst()).map { pair in
            normalizedVector(from: pair.0, to: pair.1)
        }
        guard directions.allSatisfy({ $0 != nil }) else { return nil }
        let resolvedDirections = directions.compactMap { $0 }

        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(usable.count)
        rightEdge.reserveCapacity(usable.count)

        for index in usable.indices {
            let before = resolvedDirections[index == 0 ? 0 : index - 1]
            let after = resolvedDirections[index == usable.index(before: usable.endIndex)
                ? resolvedDirections.index(before: resolvedDirections.endIndex)
                : index]
            let beforeNormal = CGVector(dx: -before.dy, dy: before.dx)
            let afterNormal = CGVector(dx: -after.dy, dy: after.dx)
            let joinedNormal = normalized(
                CGVector(
                    dx: beforeNormal.dx + afterNormal.dx,
                    dy: beforeNormal.dy + afterNormal.dy
                )
            ) ?? afterNormal

            let rawStrength = usable[index].strength.clamped(to: 0...1)
            let easedStrength = rawStrength * rawStrength * (3 - 2 * rawStrength)
            let radius = maximumRadius * easedStrength
            let denominator = max(
                abs(joinedNormal.dx * afterNormal.dx + joinedNormal.dy * afterNormal.dy),
                0.5
            )
            let offsetLength = min(radius / denominator, radius * 1.75)
            let offset = CGVector(
                dx: joinedNormal.dx * offsetLength,
                dy: joinedNormal.dy * offsetLength
            )
            let point = usable[index].location
            leftEdge.append(CGPoint(x: point.x + offset.dx, y: point.y + offset.dy))
            rightEdge.append(CGPoint(x: point.x - offset.dx, y: point.y - offset.dy))
        }

        let path = CGMutablePath()
        appendSmoothedEdge(leftEdge, to: path, movesToFirstPoint: true)
        let reversedRightEdge = Array(rightEdge.reversed())
        if let head = reversedRightEdge.first { path.addLine(to: head) }
        appendSmoothedEdge(reversedRightEdge, to: path, movesToFirstPoint: false)
        path.closeSubpath()
        return path
    }

    private static func sanitized(
        _ samples: [CanvasLaserPointerSample]
    ) -> [CanvasLaserPointerSample] {
        var result: [CanvasLaserPointerSample] = []
        result.reserveCapacity(samples.count)
        for sample in samples where sample.timestamp.isFinite
            && sample.location.x.isFinite
            && sample.location.y.isFinite {
            guard let previous = result.last else {
                result.append(sample)
                continue
            }
            guard sample.timestamp >= previous.timestamp else { continue }
            if distance(from: previous.location, to: sample.location) < 0.05 {
                result[result.index(before: result.endIndex)] = sample
            } else {
                result.append(sample)
            }
        }
        return result
    }

    private static func smoothed(
        _ samples: [CanvasLaserPointerSample],
        iterations: Int
    ) -> [CanvasLaserPointerSample] {
        guard samples.count > 2, iterations > 0 else { return samples }
        var result = samples
        for _ in 0..<iterations {
            var next: [CanvasLaserPointerSample] = [result[0]]
            next.reserveCapacity(result.count * 2)
            for index in 1..<result.count {
                let start = result[index - 1]
                let end = result[index]
                next.append(interpolated(from: start, to: end, progress: 0.25))
                next.append(interpolated(from: start, to: end, progress: 0.75))
            }
            next.append(result[result.index(before: result.endIndex)])
            result = next
        }
        return result
    }

    private static func resampled(
        _ samples: [CanvasLaserPointerSample],
        spacing: CGFloat
    ) -> [CanvasLaserPointerSample] {
        guard let first = samples.first,
            let last = samples.last,
            samples.count > 1,
            spacing.isFinite,
            spacing > 0 else { return samples }

        var result = [first]
        var distanceUntilNextOutput = spacing
        for index in 1..<samples.count {
            let start = samples[index - 1]
            let end = samples[index]
            let length = distance(from: start.location, to: end.location)
            guard length > 0.001 else { continue }

            var consumed: CGFloat = 0
            while length - consumed >= distanceUntilNextOutput {
                consumed += distanceUntilNextOutput
                result.append(
                    interpolated(
                        from: start,
                        to: end,
                        progress: consumed / length
                    )
                )
                distanceUntilNextOutput = spacing
            }
            distanceUntilNextOutput -= length - consumed
        }

        if distance(from: result[result.index(before: result.endIndex)].location, to: last.location) < 0.001 {
            result[result.index(before: result.endIndex)] = last
        } else {
            result.append(last)
        }
        return result
    }

    private static func evenlyReduced(
        _ samples: [CanvasLaserPointerSample],
        to count: Int
    ) -> [CanvasLaserPointerSample] {
        guard samples.count > count, count > 1 else { return samples }
        let lastIndex = samples.count - 1
        return (0..<count).map { outputIndex in
            let progress = CGFloat(outputIndex) / CGFloat(count - 1)
            return samples[Int((progress * CGFloat(lastIndex)).rounded())]
        }
    }

    private static func interpolated(
        from start: CanvasLaserPointerSample,
        to end: CanvasLaserPointerSample,
        progress: CGFloat
    ) -> CanvasLaserPointerSample {
        CanvasLaserPointerSample(
            location: CGPoint(
                x: start.location.x + (end.location.x - start.location.x) * progress,
                y: start.location.y + (end.location.y - start.location.y) * progress
            ),
            timestamp: start.timestamp
                + (end.timestamp - start.timestamp) * TimeInterval(progress)
        )
    }

    private static func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private static func normalizedVector(from start: CGPoint, to end: CGPoint) -> CGVector? {
        normalized(CGVector(dx: end.x - start.x, dy: end.y - start.y))
    }

    private static func normalized(_ vector: CGVector) -> CGVector? {
        let length = hypot(vector.dx, vector.dy)
        guard length.isFinite, length > 0.001 else { return nil }
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    private static func appendSmoothedEdge(
        _ points: [CGPoint],
        to path: CGMutablePath,
        movesToFirstPoint: Bool
    ) {
        guard let first = points.first else { return }
        if movesToFirstPoint { path.move(to: first) }
        guard points.count > 1 else { return }
        guard points.count > 2 else {
            path.addLine(to: points[1])
            return
        }

        for index in 1..<(points.count - 1) {
            let point = points[index]
            let following = points[index + 1]
            path.addQuadCurve(
                to: CGPoint(
                    x: (point.x + following.x) / 2,
                    y: (point.y + following.y) / 2
                ),
                control: point
            )
        }
        if let last = points.last { path.addQuadCurve(to: last, control: last) }
    }
}

/// Transient laser state in viewport coordinates. Nothing here is part of the
/// PaperKit document, so laser gestures cannot enter save, undo, or export.
struct CanvasLaserPointerTrace {
    static let trailLifetime: TimeInterval = 0.9
    static let dotFadeDuration: TimeInterval = 0.22

    private(set) var style: CanvasLaserPointerStyle = .dot
    private(set) var samples: [CanvasLaserPointerSample] = []
    private(set) var isContactActive = false
    private(set) var releaseTimestamp: TimeInterval?

    mutating func setStyle(_ style: CanvasLaserPointerStyle) {
        guard self.style != style else { return }
        self.style = style
        clear()
    }

    mutating func begin(at location: CGPoint, timestamp: TimeInterval) {
        samples = [CanvasLaserPointerSample(location: location, timestamp: timestamp)]
        isContactActive = true
        releaseTimestamp = nil
    }

    mutating func append(_ additions: [CanvasLaserPointerSample]) {
        guard isContactActive else { return }

        for sample in additions where sample.timestamp.isFinite {
            guard sample.location.x.isFinite, sample.location.y.isFinite else { continue }
            if style == .dot {
                samples = [sample]
                continue
            }

            if let previous = samples.last,
                hypot(
                    sample.location.x - previous.location.x,
                    sample.location.y - previous.location.y
                ) < 0.5,
                sample.timestamp - previous.timestamp < 1.0 / 120.0 {
                continue
            }
            samples.append(sample)
        }
    }

    mutating func end(at location: CGPoint, timestamp: TimeInterval) {
        guard isContactActive else { return }
        append([CanvasLaserPointerSample(location: location, timestamp: timestamp)])
        isContactActive = false
        releaseTimestamp = timestamp
    }

    mutating func clear() {
        samples.removeAll(keepingCapacity: true)
        isContactActive = false
        releaseTimestamp = nil
    }

    mutating func prune(at timestamp: TimeInterval) {
        guard style == .trail else {
            if dotOpacity(at: timestamp) <= 0 { clear() }
            return
        }

        let cutoff = timestamp - Self.trailLifetime
        guard let firstVisible = samples.firstIndex(where: { $0.timestamp >= cutoff }) else {
            if isContactActive == false { clear() }
            return
        }

        // Retain one expired sample so the oldest visible segment does not pop.
        let retainedStart = max(firstVisible - 1, 0)
        if retainedStart > 0 { samples.removeFirst(retainedStart) }
    }

    func dotOpacity(at timestamp: TimeInterval) -> CGFloat {
        guard samples.isEmpty == false else { return 0 }
        guard isContactActive == false else { return 1 }
        guard let releaseTimestamp else { return 0 }
        return CGFloat(
            1 - ((timestamp - releaseTimestamp) / Self.dotFadeDuration)
        ).clamped(to: 0...1)
    }

    func trailOpacity(for sample: CanvasLaserPointerSample, at timestamp: TimeInterval) -> CGFloat {
        let remaining = 1 - ((timestamp - sample.timestamp) / Self.trailLifetime)
        return CGFloat(remaining).clamped(to: 0...1)
    }

    func hasVisibleContent(at timestamp: TimeInterval) -> Bool {
        guard samples.isEmpty == false else { return false }
        if isContactActive { return true }
        switch style {
        case .dot:
            return dotOpacity(at: timestamp) > 0
        case .trail:
            return samples.contains { trailOpacity(for: $0, at: timestamp) > 0 }
        }
    }
}

@MainActor
final class CanvasLaserPointerView: UIView {
    private static let laserRed = UIColor(
        red: 1,
        green: 45 / 255,
        blue: 38 / 255,
        alpha: 1
    )

    private var trace = CanvasLaserPointerTrace()
    private var displayLink: CADisplayLink?
    private lazy var displayLinkTarget = CanvasLaserDisplayLinkTarget(owner: self)

    var style: CanvasLaserPointerStyle { trace.style }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
            trace.clear()
        }
    }

    func activate(style: CanvasLaserPointerStyle) {
        trace.setStyle(style)
        isHidden = false
        setNeedsDisplay()
    }

    func deactivate() {
        stopDisplayLink()
        trace.clear()
        isHidden = true
        setNeedsDisplay()
    }

    func begin(at location: CGPoint, timestamp: TimeInterval) {
        trace.begin(at: location, timestamp: timestamp)
        isHidden = false
        if trace.style == .trail { startDisplayLink() }
        setNeedsDisplay()
    }

    func move(_ samples: [CanvasLaserPointerSample]) {
        trace.append(samples)
        setNeedsDisplay()
    }

    func end(at location: CGPoint, timestamp: TimeInterval) {
        trace.end(at: location, timestamp: timestamp)
        if UIAccessibility.isReduceMotionEnabled {
            // Direct tracking remains exact while contact is active, but the
            // post-release dot fade / trail recession is removed entirely.
            stopDisplayLink()
            trace.clear()
        } else {
            startDisplayLink()
        }
        setNeedsDisplay()
    }

    func cancel() {
        stopDisplayLink()
        trace.clear()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        trace.prune(at: timestamp)

        switch trace.style {
        case .dot:
            guard let point = trace.samples.last?.location else { return }
            drawDot(at: point, opacity: trace.dotOpacity(at: timestamp), in: context)
        case .trail:
            drawTrail(at: timestamp, in: context)
        }
    }

    private func drawTrail(at timestamp: TimeInterval, in context: CGContext) {
        let samples = trace.samples
        guard let endpoint = samples.last else { return }
        let vertices = CanvasLaserTrailGeometry.vertices(for: samples, at: timestamp)
        if vertices.count > 1, let endpointStrength = vertices.last?.strength, endpointStrength > 0 {
            drawRibbon(
                vertices,
                maximumRadius: 7,
                color: Self.laserRed.withAlphaComponent(endpointStrength * 0.14),
                in: context
            )
            drawRibbon(
                vertices,
                maximumRadius: 3,
                color: Self.laserRed.withAlphaComponent(endpointStrength * 0.86),
                in: context
            )
            drawRibbon(
                vertices,
                maximumRadius: 0.85,
                color: UIColor.white.withAlphaComponent(endpointStrength * 0.5),
                in: context
            )
        }
        let endpointOpacity = trace.isContactActive
            ? CGFloat(1)
            : trace.trailOpacity(for: endpoint, at: timestamp)
        drawDot(at: endpoint.location, opacity: endpointOpacity, in: context, compact: true)
    }

    private func drawRibbon(
        _ vertices: [CanvasLaserTrailVertex],
        maximumRadius: CGFloat,
        color: UIColor,
        in context: CGContext
    ) {
        guard let path = CanvasLaserTrailGeometry.ribbonPath(
            for: vertices,
            maximumRadius: maximumRadius
        ) else { return }

        context.saveGState()
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private func drawDot(
        at point: CGPoint,
        opacity: CGFloat,
        in context: CGContext,
        compact: Bool = false
    ) {
        guard opacity > 0 else { return }
        let glowRadius: CGFloat = compact ? 10 : 14
        let coreRadius: CGFloat = compact ? 4.5 : 6

        context.setFillColor(Self.laserRed.withAlphaComponent(opacity * 0.18).cgColor)
        context.fillEllipse(in: CGRect(
            x: point.x - glowRadius,
            y: point.y - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        ))

        context.setShadow(
            offset: .zero,
            blur: compact ? 5 : 7,
            color: Self.laserRed.withAlphaComponent(opacity * 0.72).cgColor
        )
        context.setFillColor(Self.laserRed.withAlphaComponent(opacity).cgColor)
        context.fillEllipse(in: CGRect(
            x: point.x - coreRadius,
            y: point.y - coreRadius,
            width: coreRadius * 2,
            height: coreRadius * 2
        ))
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let highlightRadius = coreRadius * 0.28
        context.setFillColor(UIColor.white.withAlphaComponent(opacity * 0.72).cgColor)
        context.fillEllipse(in: CGRect(
            x: point.x - coreRadius * 0.35 - highlightRadius,
            y: point.y - coreRadius * 0.35 - highlightRadius,
            width: highlightRadius * 2,
            height: highlightRadius * 2
        ))
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: displayLinkTarget, selector: #selector(CanvasLaserDisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func displayLinkDidTick() {
        let timestamp = ProcessInfo.processInfo.systemUptime
        trace.prune(at: timestamp)
        setNeedsDisplay()
        if trace.hasVisibleContent(at: timestamp) == false { stopDisplayLink() }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

#if DEBUG
    var isDisplayLinkActiveForTesting: Bool { displayLink != nil }
#endif
}

@MainActor
private final class CanvasLaserDisplayLinkTarget: NSObject {
    weak var owner: CanvasLaserPointerView?

    init(owner: CanvasLaserPointerView) {
        self.owner = owner
    }

    @objc func tick() {
        owner?.displayLinkDidTick()
    }
}

@MainActor
final class CanvasLaserPointerGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegan: ((CanvasLaserPointerSample) -> Void)?
    var onMoved: (([CanvasLaserPointerSample]) -> Void)?
    var onEnded: ((CanvasLaserPointerSample) -> Void)?
    var onCancelled: (() -> Void)?

    private var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch {
            // Keep an active Pencil presentation stable when iPadOS also
            // delivers an incidental palm or finger. A second finger still
            // cancels finger pointing so the outer two-finger pan can begin.
            if trackedTouch.type == .pencil { return }
            cancelTracking()
            return
        }
        guard touches.count == 1, let touch = touches.first, let view else {
            state = .failed
            return
        }

        trackedTouch = touch
        state = .began
        onBegan?(sample(from: touch, in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
            touches.contains(where: { $0 === trackedTouch }),
            let view else { return }
        state = .changed
        let touches = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
        onMoved?(touches.map { sample(from: $0, in: view) })
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
            touches.contains(where: { $0 === trackedTouch }),
            let view else { return }
        onEnded?(sample(from: trackedTouch, in: view))
        self.trackedTouch = nil
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch,
            touches.contains(where: { $0 === trackedTouch }) else { return }
        cancelTracking()
    }

    override func reset() {
        trackedTouch = nil
        super.reset()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        touch.type == .pencil || touch.type == .direct
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    private func cancelTracking() {
        trackedTouch = nil
        onCancelled?()
        state = .cancelled
    }

    private func sample(from touch: UITouch, in view: UIView) -> CanvasLaserPointerSample {
        CanvasLaserPointerSample(
            location: touch.location(in: view),
            timestamp: touch.timestamp
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
