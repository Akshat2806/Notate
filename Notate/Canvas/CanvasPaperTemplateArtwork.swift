import CoreGraphics

enum CanvasPaperTemplateArtwork {
    private static let maximumPathPrimitives = 100_000
    struct Paths {
        let pattern: CGPath
        let guides: CGPath
        let fillsPattern: Bool
    }

    static let ruleColor = CGColor(
        srgbRed: 197 / 255,
        green: 207 / 255,
        blue: 220 / 255,
        alpha: 0.72
    )

    static let guideColor = CGColor(
        srgbRed: 171 / 255,
        green: 185 / 255,
        blue: 202 / 255,
        alpha: 0.82
    )

    static func ruleColor(for tone: CanvasPaperTone) -> CGColor {
        guard tone.isDark else { return ruleColor }
        return CGColor(
            srgbRed: 190 / 255,
            green: 204 / 255,
            blue: 224 / 255,
            alpha: 0.48
        )
    }

    static func guideColor(for tone: CanvasPaperTone) -> CGColor {
        guard tone.isDark else { return guideColor }
        return CGColor(
            srgbRed: 213 / 255,
            green: 222 / 255,
            blue: 237 / 255,
            alpha: 0.66
        )
    }

    static func paths(
        for template: CanvasPaperTemplate,
        pageSize: CGSize = CanvasConstants.a4PortraitSize,
        visibleRect: CGRect? = nil,
        dotDiameter: CGFloat = 1.8
    ) -> Paths {
        let pattern = CGMutablePath()
        let guides = CGMutablePath()
        guard pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width > 0,
            pageSize.height > 0,
            dotDiameter.isFinite else {
            return Paths(
                pattern: pattern,
                guides: guides,
                fillsPattern: template.style == .dotted
            )
        }

        let pageBounds = CGRect(origin: .zero, size: pageSize)
        let renderBounds = visibleRect
            .map { $0.standardized.intersection(pageBounds) }
            ?? pageBounds
        guard renderBounds.isNull == false,
            renderBounds.isEmpty == false,
            renderBounds.minX.isFinite,
            renderBounds.minY.isFinite,
            renderBounds.maxX.isFinite,
            renderBounds.maxY.isFinite else {
            return Paths(
                pattern: pattern,
                guides: guides,
                fillsPattern: template.style == .dotted
            )
        }

        let horizontalRules: [CGFloat]
        if template.style == .cornell {
            let bodyEnd = min(
                CanvasPaperTemplateGeometry.cornellSummaryY,
                pageSize.height
            )
            horizontalRules = CanvasPaperTemplateGeometry.cornellHeaderY <= bodyEnd
                ? visibleCenteredPositions(
                    in: CanvasPaperTemplateGeometry.cornellHeaderY...bodyEnd,
                    spacing: template.density.spacing,
                    minimumEdgeGap: template.density.spacing / 2,
                    intersecting: renderBounds.minY...renderBounds.maxY
                )
                : []
        } else if template.style == .music {
            horizontalRules = []
        } else {
            horizontalRules = visibleCenteredPositions(
                in: 0...pageSize.height,
                spacing: template.density.spacing,
                intersecting: renderBounds.minY...renderBounds.maxY
            )
        }

        switch template.style {
        case .blank:
            break
        case .ruled:
            for y in horizontalRules {
                pattern.move(to: CGPoint(x: renderBounds.minX, y: y))
                pattern.addLine(to: CGPoint(x: renderBounds.maxX, y: y))
            }
        case .grid:
            for y in horizontalRules {
                pattern.move(to: CGPoint(x: renderBounds.minX, y: y))
                pattern.addLine(to: CGPoint(x: renderBounds.maxX, y: y))
            }
            for x in visibleCenteredPositions(
                in: 0...pageSize.width,
                spacing: template.density.spacing,
                intersecting: renderBounds.minX...renderBounds.maxX
            ) {
                pattern.move(to: CGPoint(x: x, y: renderBounds.minY))
                pattern.addLine(to: CGPoint(x: x, y: renderBounds.maxY))
            }
        case .dotted:
            let diameter = max(dotDiameter, 0.5)
            let radius = diameter / 2
            let xs = visibleCenteredPositions(
                in: 0...pageSize.width,
                spacing: template.density.spacing,
                intersecting: (renderBounds.minX - radius)...(renderBounds.maxX + radius)
            )
            let ys = visibleCenteredPositions(
                in: 0...pageSize.height,
                spacing: template.density.spacing,
                intersecting: (renderBounds.minY - radius)...(renderBounds.maxY + radius)
            )
            guard xs.isEmpty || ys.count <= maximumPathPrimitives / xs.count else {
                break
            }
            for y in ys {
                for x in xs {
                    pattern.addEllipse(
                        in: CGRect(
                            x: x - radius,
                            y: y - radius,
                            width: diameter,
                            height: diameter
                        )
                    )
                }
            }
        case .cornell:
            for y in horizontalRules {
                let startX = max(
                    renderBounds.minX,
                    CanvasPaperTemplateGeometry.cornellCueX
                )
                guard startX <= renderBounds.maxX else { continue }
                pattern.move(to: CGPoint(x: startX, y: y))
                pattern.addLine(to: CGPoint(x: renderBounds.maxX, y: y))
            }
            let headerY = CanvasPaperTemplateGeometry.cornellHeaderY
            if renderBounds.minY...renderBounds.maxY ~= headerY {
                guides.move(to: CGPoint(x: renderBounds.minX, y: headerY))
                guides.addLine(to: CGPoint(x: renderBounds.maxX, y: headerY))
            }
            let cueX = CanvasPaperTemplateGeometry.cornellCueX
            if renderBounds.minX...renderBounds.maxX ~= cueX {
                let startY = max(renderBounds.minY, headerY)
                let endY = min(
                    renderBounds.maxY,
                    CanvasPaperTemplateGeometry.cornellSummaryY
                )
                if startY <= endY {
                    guides.move(to: CGPoint(x: cueX, y: startY))
                    guides.addLine(to: CGPoint(x: cueX, y: endY))
                }
            }
            let summaryY = CanvasPaperTemplateGeometry.cornellSummaryY
            if renderBounds.minY...renderBounds.maxY ~= summaryY {
                guides.move(to: CGPoint(x: renderBounds.minX, y: summaryY))
                guides.addLine(to: CGPoint(x: renderBounds.maxX, y: summaryY))
            }
        case .music:
            let lineSpacing = CanvasPaperTemplateGeometry.musicStaffLineSpacing(
                for: template.density
            )
            let staffHeight = lineSpacing
                * CGFloat(CanvasPaperTemplateGeometry.musicStaffLineCount - 1)
            guard pageSize.height >= staffHeight else { break }
            let staffTops = visibleCenteredPositions(
                in: 0...(pageSize.height - staffHeight),
                spacing: CanvasPaperTemplateGeometry.musicStaffStride(
                    for: template.density
                ),
                intersecting: (renderBounds.minY - staffHeight)...renderBounds.maxY
            )
            for top in staffTops {
                for lineIndex in 0..<CanvasPaperTemplateGeometry.musicStaffLineCount {
                    let y = top + CGFloat(lineIndex) * lineSpacing
                    pattern.move(to: CGPoint(x: renderBounds.minX, y: y))
                    pattern.addLine(to: CGPoint(x: renderBounds.maxX, y: y))
                }
            }
        }

        return Paths(
            pattern: pattern,
            guides: guides,
            fillsPattern: template.style == .dotted
        )
    }

    /// Returns only the authored lattice positions that can intersect the
    /// presentation window. This keeps an expanded freeform board proportional
    /// to the viewport rather than to the square of its full logical size.
    private static func visibleCenteredPositions(
        in authoredRange: ClosedRange<CGFloat>,
        spacing: CGFloat,
        minimumEdgeGap: CGFloat = 0,
        intersecting visibleRange: ClosedRange<CGFloat>
    ) -> [CGFloat] {
        guard spacing.isFinite,
            spacing > 0,
            minimumEdgeGap.isFinite,
            minimumEdgeGap >= 0,
            authoredRange.lowerBound.isFinite,
            authoredRange.upperBound.isFinite,
            authoredRange.lowerBound <= authoredRange.upperBound,
            visibleRange.lowerBound.isFinite,
            visibleRange.upperBound.isFinite,
            visibleRange.lowerBound <= visibleRange.upperBound else { return [] }
        let availableLength = authoredRange.upperBound - authoredRange.lowerBound
            - (minimumEdgeGap * 2)
        guard availableLength.isFinite,
            availableLength >= 0,
            availableLength / spacing < CGFloat(Int.max) else { return [] }

        let lastIndex = Int(floor(availableLength / spacing))
        let occupiedLength = CGFloat(lastIndex) * spacing
        let first = authoredRange.lowerBound
            + minimumEdgeGap
            + ((availableLength - occupiedLength) / 2)
        let rawLowerIndex = ceil((visibleRange.lowerBound - first) / spacing)
        let rawUpperIndex = floor((visibleRange.upperBound - first) / spacing)
        guard rawLowerIndex.isFinite,
            rawUpperIndex.isFinite,
            rawLowerIndex >= CGFloat(Int.min),
            rawLowerIndex < CGFloat(Int.max),
            rawUpperIndex >= CGFloat(Int.min),
            rawUpperIndex < CGFloat(Int.max) else { return [] }
        let lowerIndex = max(0, Int(rawLowerIndex))
        let upperIndex = min(lastIndex, Int(rawUpperIndex))
        guard lowerIndex <= upperIndex else { return [] }
        guard upperIndex - lowerIndex < maximumPathPrimitives else { return [] }
        return (lowerIndex...upperIndex).map { first + CGFloat($0) * spacing }
    }

    static func draw(
        template: CanvasPaperTemplate,
        in context: CGContext,
        pageBounds: CGRect
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        guard pageBounds.isNull == false,
            pageBounds.isInfinite == false,
            pageBounds.isEmpty == false,
            pageBounds.minX.isFinite,
            pageBounds.minY.isFinite,
            pageBounds.maxX.isFinite,
            pageBounds.maxY.isFinite else { return }
        context.setFillColor(template.tone.cgColor)
        context.fill(pageBounds)

        let visibleRect = context.boundingBoxOfClipPath.intersection(pageBounds)
        let artwork = paths(
            for: template,
            pageSize: pageBounds.size,
            visibleRect: visibleRect
        )
        let patternColor = ruleColor(for: template.tone)
        let semanticGuideColor = guideColor(for: template.tone)
        if artwork.fillsPattern {
            context.addPath(artwork.pattern)
            context.setFillColor(patternColor)
            context.fillPath()
        } else {
            context.addPath(artwork.pattern)
            context.setStrokeColor(patternColor)
            context.setLineWidth(0.7)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }

        context.addPath(artwork.guides)
        context.setStrokeColor(semanticGuideColor)
        context.setLineWidth(1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
}

/// Vector artwork shared by the live canvas and every flattened export.
///
/// Tables remain independent of PaperKit markup so their row and column count
/// can change without destructively rebuilding the user's handwriting. The
/// outline is stroked after the dividers. Clipping the dividers to that outline
/// keeps square defaults exact while preserving older rounded table documents.
enum CanvasTableArtwork {
    struct Paths {
        let outline: CGPath
        let separators: CGPath
    }

    static let strokeColor = CGColor(
        srgbRed: 35 / 255,
        green: 39 / 255,
        blue: 47 / 255,
        alpha: 0.92
    )
    static let darkPaperStrokeColor = CGColor(
        srgbRed: 232 / 255,
        green: 236 / 255,
        blue: 244 / 255,
        alpha: 0.92
    )

    static let lineWidth: CGFloat = 1.4

    static func strokeColor(for paperTone: CanvasPaperTone?) -> CGColor {
        paperTone?.isDark == true ? darkPaperStrokeColor : strokeColor
    }

    static func paths(for table: CanvasTable) -> Paths {
        let empty = CGMutablePath()
        let frame = table.frame.standardized
        guard frame.isNull == false,
            frame.isEmpty == false,
            frame.isInfinite == false,
            table.rowCount >= 1,
            table.columnCount >= 1 else {
            return Paths(outline: empty, separators: CGMutablePath())
        }

        let maximumRadius = min(frame.width, frame.height) / 2
        let cornerRadius = min(max(table.cornerRadius, 0), maximumRadius)
        let outline = CGPath(
            roundedRect: frame,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let separators = CGMutablePath()

        if table.rowCount > 1 {
            for row in 1..<table.rowCount {
                let y = frame.minY
                    + (frame.height * CGFloat(row) / CGFloat(table.rowCount))
                separators.move(to: CGPoint(x: frame.minX, y: y))
                separators.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }

        if table.columnCount > 1 {
            for column in 1..<table.columnCount {
                let x = frame.minX
                    + (frame.width * CGFloat(column) / CGFloat(table.columnCount))
                separators.move(to: CGPoint(x: x, y: frame.minY))
                separators.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
        }

        return Paths(outline: outline, separators: separators)
    }

    static func draw(
        tables: [CanvasTable],
        in context: CGContext,
        pageBounds: CGRect,
        paperTone: CanvasPaperTone? = nil
    ) {
        guard tables.isEmpty == false else { return }

        context.saveGState()
        context.clip(to: pageBounds)
        context.setStrokeColor(strokeColor(for: paperTone))
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)
        context.setLineJoin(.round)

        for table in tables {
            let paths = paths(for: table)
            guard paths.outline.isEmpty == false else { continue }

            context.saveGState()
            context.addPath(paths.outline)
            context.clip()
            context.addPath(paths.separators)
            context.strokePath()
            context.restoreGState()

            context.addPath(paths.outline)
            context.strokePath()
        }

        context.restoreGState()
    }
}
