import ImagePlayground
import SwiftUI
import UIKit

import SwiftUI
import UIKit

struct CanvasTableSizeGridGeometry {
    var range: ClosedRange<Int>

    init(range: ClosedRange<Int> = CanvasTableSize.pickerRange) {
        self.range = range
    }

    func selection(at point: CGPoint, in rect: CGRect) -> CanvasTableSize? {
        let cellWidth = rect.width / CGFloat(range.count)
        let cellHeight = rect.height / CGFloat(range.count)
        let col = Int(point.x / cellWidth) + range.lowerBound
        let row = Int(point.y / cellHeight) + range.lowerBound
        guard range.contains(col), range.contains(row) else { return nil }
        return CanvasTableSize(rowCount: row, columnCount: col)
    }

    func clampedOffset(for size: CanvasTableSize, in rect: CGRect) -> CGSize {
        let cellWidth = rect.width / CGFloat(range.count)
        let cellHeight = rect.height / CGFloat(range.count)
        let x = CGFloat(size.columnCount - range.lowerBound) * cellWidth + cellWidth / 2
        let y = CGFloat(size.rowCount - range.lowerBound) * cellHeight + cellHeight / 2
        return CGSize(width: x, height: y)
    }
}

public struct CanvasToolPicker: View {
    /// The picker is rendered as two pieces so the editor can seat the tool
    /// pill on the same line as its navigation buttons while the options strip
    /// opens directly beneath it.
    public enum Placement: Sendable {
        case pill
        case history
        case options
    }

    enum PillMetrics {
        static let itemWidth: CGFloat = 38
        static let itemHeight: CGFloat = 40
        static let itemSpacing: CGFloat = 2
        static let horizontalPadding: CGFloat = 6
        static let itemCount = 9
    }

    enum StripMetrics {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 4
        static let sectionSpacing: CGFloat = 8
        static let chipWidth: CGFloat = 34
        static let chipHeight: CGFloat = 38
        static let swatchDiameter: CGFloat = 22
    }

    enum TableSizePickerMetrics {
        static let cellHitDimension: CGFloat = 28
        static let cellVisualDimension: CGFloat = 18
        static let contentSpacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 12
        static var gridSide: CGFloat {
            cellHitDimension * CGFloat(CanvasTableSize.pickerRange.count)
        }
        static let coordinateSpaceName = "TableSizePicker"
    }

    /// The width the tool pill needs to show every control without scrolling.
    /// The editor uses it to decide whether the pill can share the navigation
    /// row.
    static var preferredPillWidth: CGFloat {
        let items = CGFloat(PillMetrics.itemCount) * PillMetrics.itemWidth
        let gaps = CGFloat(PillMetrics.itemCount) * PillMetrics.itemSpacing
        return items + gaps + (2 * PillMetrics.horizontalPadding)
    }

    /// Undo and redo share one small capsule.
    static var preferredHistoryWidth: CGFloat {
        (2 * PillMetrics.itemWidth) + PillMetrics.itemSpacing
            + (2 * PillMetrics.horizontalPadding)
    }

    public let toolState: CanvasToolState
    public let overlay: CanvasOverlay
    public let preferredGeometryTool: CanvasGeometryTool
    public let activeGeometryTool: CanvasGeometryTool?
    public let canUndo: Bool
    public let canRedo: Bool
    public let usesCompactLayout: Bool
    public let placement: Placement
    public let onIntent: (CanvasToolbarIntent) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    private var reduceTransparency: Bool { UIAccessibility.isReduceTransparencyEnabled }
    private var voiceOverEnabled: Bool { UIAccessibility.isVoiceOverRunning }

    @AccessibilityFocusState private var isAddButtonFocused: Bool
    @AccessibilityFocusState private var focusedTool: CanvasTool?
    @AccessibilityFocusState private var focusedShape: CanvasShape?
    @AccessibilityFocusState private var focusedTableSize: CanvasTableSize?
    @AccessibilityFocusState private var isTableStepperFocused: Bool
    @AccessibilityFocusState private var focusedGeometryTool: CanvasGeometryTool?
    @AccessibilityFocusState private var isGeometrySlotFocused: Bool

    @FocusState private var keyboardFocusedTableSize: CanvasTableSize?

    @State private var rolledOverTableSize: CanvasTableSize = .standard
    @GestureState private var pressedTableSize: CanvasTableSize? = nil
    @State private var tableSizeSlideDidRecognize = false

    @Namespace private var glassNamespace

    public init(
        toolState: CanvasToolState,
        overlay: CanvasOverlay,
        preferredGeometryTool: CanvasGeometryTool,
        activeGeometryTool: CanvasGeometryTool?,
        canUndo: Bool,
        canRedo: Bool,
        usesCompactLayout: Bool = false,
        placement: Placement = .pill,
        onIntent: @escaping (CanvasToolbarIntent) -> Void
    ) {
        self.toolState = toolState
        self.overlay = overlay
        self.preferredGeometryTool = preferredGeometryTool
        self.activeGeometryTool = activeGeometryTool
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.usesCompactLayout = usesCompactLayout
        self.placement = placement
        self.onIntent = onIntent
    }

    public var body: some View {
        switch placement {
        case .pill:
            toolPill
                .onChange(of: overlay) { _, newValue in
                    if case .insert = newValue {
                        isAddButtonFocused = true
                    }
                }
        case .history:
            historyPill
        case .options:
            GlassEffectContainer(spacing: NotateDesign.Spacing.compact) {
                accessorySurface
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Tool pill

    private var toolPill: some View {
        CanvasToolPillContainer(scrolls: usesCompactLayout || dynamicTypeSize.isAccessibilitySize) {
            pickerControls
        }
        .accessibilityIdentifier("canvas.tool.strip")
    }

    @ViewBuilder private var pickerControls: some View {
        toolButton(.lasso)
        toolButton(.pen)
        toolButton(.pencil)
        toolButton(.fountainPen)
        toolButton(.highlighter)
        toolButton(.eraser)
        toolButton(.laserPointer)
        rulerButton
        addButton
    }

    private var historyPill: some View {
        HStack(spacing: PillMetrics.itemSpacing) {
            utilityButton(title: "Undo", systemImage: "arrow.uturn.backward", isEnabled: canUndo) {
                onIntent(.undo)
            }
            utilityButton(title: "Redo", systemImage: "arrow.uturn.forward", isEnabled: canRedo) {
                onIntent(.redo)
            }
        }
        .padding(.horizontal, PillMetrics.horizontalPadding)
        .frame(height: NotateDesign.Control.compactGlassDiameter)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History")
        .accessibilityIdentifier("canvas.history")
    }

    private var addButton: some View {
        Button {
            onIntent(.toggleInsert)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: PillMetrics.itemWidth, height: PillMetrics.itemHeight)
                .background {
                    if isAddExpanded {
                        selectedToolBackground
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityFocused($isAddButtonFocused)
        .accessibilityLabel("Add")
        .accessibilityIdentifier("canvas.tool.add")
        .accessibilityValue(isAddExpanded ? "expanded" : "collapsed")
        .help("Add content")
    }

    private var rulerButton: some View {
        let isActive = activeGeometryTool != nil
        let isExpanded = overlay == .geometryTools

        return Button {
            onIntent(.tapGeometryToolSlot)
        } label: {
            CanvasGeometryToolGlyph(
                tool: activeGeometryTool ?? preferredGeometryTool,
                isSelected: isActive
            )
            .frame(width: PillMetrics.itemWidth, height: PillMetrics.itemHeight)
            .background {
                if isActive || isExpanded {
                    selectedToolBackground
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            onIntent(.showGeometryChooser)
        })
        .accessibilityFocused($isGeometrySlotFocused)
        .accessibilityLabel("Ruler")
        .accessibilityValue(
            isActive
                ? "\((activeGeometryTool ?? preferredGeometryTool).title) on"
                : "Off"
        )
        .accessibilityHint(
            isActive
                ? "Switches to the next instrument, then turns instruments off. Touch and hold to choose."
                : "Turns on the \(preferredGeometryTool.title.lowercased())"
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("canvas.geometry.slot")
        .help("Ruler, protractor and compass")
    }

    private var isAddExpanded: Bool {
        switch overlay {
        case .insert, .shapes, .tableSizePicker:
            return true
        default:
            return false
        }
    }

    private func utilityButton(title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: PillMetrics.itemWidth, height: PillMetrics.itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .keyboardShortcut(title == "Undo" ? KeyboardShortcut("z", modifiers: .command) : KeyboardShortcut("z", modifiers: [.command, .shift]))
        .help(title)
    }

    private func toolButton(_ toolbarTool: CanvasTool) -> some View {
        let displayedTool = displayedToolbarTool(for: toolbarTool)
        let selected = toolState.activeTool.toolbarFamilyRoot == toolbarTool
        let configuration = toolState.configuration(for: displayedTool)
        let label = displayedTool.toolbarFamilyTitle
        let familyOptionsExpanded = isFamilyOptionsExpanded(for: toolbarTool)

        return Button { activate(displayedTool) } label: {
            ToolGlyph(
                tool: displayedTool,
                inkColor: Color(rgba: configuration?.color ?? .black),
                isSelected: selected
            )
                .frame(width: PillMetrics.itemWidth, height: PillMetrics.itemHeight)
                .background {
                    if selected {
                        selectedToolBackground
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            showOptions(for: displayedTool)
        })
        .gesture(SecondaryClickGesture {
            showOptions(for: displayedTool)
        })
        .accessibilityLabel(label)
        .accessibilityIdentifier("canvas.tool.\(displayedTool.rawValue)")
        .accessibilityValue(accessibilityValue(for: displayedTool, toolbarTool: toolbarTool, selected: selected, optionsExpanded: familyOptionsExpanded))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(
            displayedTool.supportsOptions
                ? "Double tap to \(familyOptionsExpanded ? "hide" : "show") options"
                : ""
        )
        .help(label)
    }

    private var selectedToolBackground: some View {
        let shape = RoundedRectangle(cornerRadius: NotateDesign.Radius.control, style: .continuous)

        return ZStack {
            if reduceTransparency {
                shape.fill(NotateDesign.Palette.background)
            }
            shape.fill(
                NotateDesign.Palette.accent.opacity(
                    reduceTransparency
                        ? NotateDesign.Palette.opaqueSelectionFillOpacity
                        : NotateDesign.Palette.selectionFillOpacity
                )
            )
            shape.strokeBorder(
                NotateDesign.Palette.accent.opacity(
                    colorSchemeContrast == .increased
                        ? 1
                        : NotateDesign.Hairline.selectedOpacity
                ),
                lineWidth: NotateDesign.Hairline.width(for: colorSchemeContrast)
            )
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 1)
    }

    // MARK: Options strip

    @ViewBuilder private var accessorySurface: some View {
        switch overlay {
        case .toolOptions(let tool) where tool.supportsOptions:
            stripSurface { toolStrip(for: tool) }
                .glassEffectID("canvas-tool-options", in: glassNamespace)
                .transition(accessoryTransition)
        case .geometryTools:
            stripSurface { geometryStrip }
                .glassEffectID("canvas-geometry-picker", in: glassNamespace)
                .transition(accessoryTransition)
        case .insert:
            stripSurface { insertStrip }
                .glassEffectID("canvas-insert-tray", in: glassNamespace)
                .transition(accessoryTransition)
        case .shapes:
            stripSurface { shapeCatalog }
                .transition(accessoryTransition)
        case .tableSizePicker:
            stripSurface { tableSizePicker }
                .transition(accessoryTransition)
        default:
            EmptyView()
        }
    }

    private var accessoryTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.1)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    private func stripSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        CanvasOptionsStripContainer(content: content())
            .notateGlassSurface(
                shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                reduceTransparency: reduceTransparency
            )
    }

    /// Level two and three of the picker: style (when the family has styles),
    /// thickness, then colors, on one compact line.
    @ViewBuilder private func toolStrip(for tool: CanvasTool) -> some View {
        if tool == .eraser {
            HStack(spacing: StripMetrics.sectionSpacing) {
                eraserModes
                if toolState.eraserMode == .pixel {
                    stripDivider
                    thicknessChips(for: tool)
                }
            }
            .accessibilityIdentifier("canvas.tool.options")
        } else if tool == .laserPointer {
            HStack(spacing: StripMetrics.sectionSpacing) {
                laserPointerStyleButtons
                stripDivider
                colorChips(for: tool)
            }
            .accessibilityIdentifier("canvas.tool.options")
        } else if tool.toolbarFamilyVariants.count > 1 {
            HStack(spacing: StripMetrics.sectionSpacing) {
                styleChips(for: tool)
                stripDivider
                thicknessChips(for: tool)
                stripDivider
                colorChips(for: tool)
            }
            .accessibilityIdentifier("canvas.tool.options")
        } else {
            HStack(spacing: StripMetrics.sectionSpacing) {
                thicknessChips(for: tool)
                stripDivider
                colorChips(for: tool)
            }
            .accessibilityIdentifier("canvas.tool.options")
        }
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 20)
            .accessibilityHidden(true)
    }

    private func styleChips(for tool: CanvasTool) -> some View {
        HStack(spacing: 0) {
            ForEach(tool.toolbarFamilyVariants, id: \.self) { variant in
                styleChip(variant)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Style")
        .accessibilityIdentifier("canvas.tool.variants")
    }

    private func styleChip(_ tool: CanvasTool) -> some View {
        let isActive = tool == toolState.activeTool

        return Button {
            onIntent(.tapTool(tool))
        } label: {
            ToolGlyph(
                tool: tool,
                inkColor: Color(rgba: toolState.configuration(for: tool)?.color ?? .black),
                isSelected: isActive
            )
            .frame(width: StripMetrics.chipWidth + 4, height: StripMetrics.chipHeight + 2)
            .background {
                if isActive {
                    selectedToolBackground
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityFocused($focusedTool, equals: tool)
        .accessibilityLabel(tool.title)
        .accessibilityIdentifier("canvas.tool.\(tool.rawValue)")
        .accessibilityValue(isActive ? "Selected" : "Not selected")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(tool.title)
    }

    private func thicknessChips(for tool: CanvasTool) -> some View {
        HStack(spacing: 0) {
            ForEach(CanvasToolState.widthPresets(for: tool), id: \.self) { width in
                thicknessChip(width, for: tool)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thickness")
    }

    private func thicknessChip(_ width: Double, for tool: CanvasTool) -> some View {
        let isSelected = toolState.configuration(for: tool)?.width == width

        return Button {
            updateWidth(width, for: tool)
        } label: {
            ZStack {
                if isSelected {
                    selectedToolBackground
                }
                if tool == .eraser {
                    let diameter = eraserPreviewDiameter(width)
                    Circle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: diameter, height: diameter)
                } else {
                    Capsule()
                        .fill(Color.primary.opacity(0.82))
                        .frame(width: 18, height: inkPreviewHeight(width, for: tool))
                }
            }
            .frame(width: StripMetrics.chipWidth, height: StripMetrics.chipHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("\(formattedWidth(width)) points")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func quickPalette(for tool: CanvasTool) -> [RGBAColor] {
        tool == .highlighter
            ? Array(RGBAColor.highlighterPalette.prefix(5))
            : RGBAColor.quickInkPalette
    }

    private func colorChips(for tool: CanvasTool) -> some View {
        let current = toolState.configuration(for: tool)?.color ?? .black

        return HStack(spacing: 0) {
            ForEach(quickPalette(for: tool), id: \.self) { swatch in
                colorChip(swatch, current: current, for: tool)
            }
            customColorPicker(current: current, for: tool)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color")
    }

    private func colorChip(_ swatch: RGBAColor, current: RGBAColor, for tool: CanvasTool) -> some View {
        let isSelected = colorsMatch(swatch, current)

        return Button {
            updateColor(swatch, for: tool)
        } label: {
            Circle()
                .fill(Color(rgba: swatch))
                .frame(width: StripMetrics.swatchDiameter, height: StripMetrics.swatchDiameter)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 2)
                            .padding(-3.5)
                    }
                }
                .frame(width: StripMetrics.chipWidth, height: StripMetrics.chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(colorName(for: swatch, tool: tool))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func customColorPicker(current: RGBAColor, for tool: CanvasTool) -> some View {
        ColorPicker(
            "",
            selection: Binding(
                get: { Color(rgba: current) },
                set: { updateCustomColor($0, for: tool) }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .frame(width: StripMetrics.chipWidth, height: StripMetrics.chipHeight)
        .accessibilityLabel("Custom color")
    }

    private var eraserModes: some View {
        Picker("Eraser mode", selection: Binding(
            get: { toolState.eraserMode },
            set: { onIntent(.setEraserMode($0)) }
        )) {
            Text("Pixel").tag(CanvasEraserMode.pixel)
            Text("Stroke").tag(CanvasEraserMode.stroke)
        }
        .pickerStyle(.segmented)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 240 : 150)
    }

    private var laserPointerStyleButtons: some View {
        HStack(spacing: 0) {
            ForEach(CanvasLaserPointerStyle.allCases, id: \.self) { style in
                laserPointerStyleButton(style)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Laser style")
    }

    private func laserPointerStyleButton(_ style: CanvasLaserPointerStyle) -> some View {
        let isSelected = toolState.laserPointerStyle == style
        let tint = Color(rgba: toolState.configuration(for: .laserPointer)?.color ?? .laserRed)

        return Button {
            onIntent(.setLaserPointerStyle(style))
        } label: {
            LaserPointerStyleGlyph(style: style, tint: tint)
                .frame(width: StripMetrics.chipWidth + 8, height: StripMetrics.chipHeight)
                .background {
                    if isSelected {
                        selectedToolBackground
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(style.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(style.title)
    }

    // MARK: Ruler strip

    private var geometryStrip: some View {
        HStack(spacing: 0) {
            ForEach(CanvasGeometryTool.allCases, id: \.self) { tool in
                geometryToolOption(tool)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Geometry tools")
        .accessibilityIdentifier("canvas.geometry.picker")
    }

    private func geometryToolOption(_ tool: CanvasGeometryTool) -> some View {
        let isActive = activeGeometryTool == tool

        return Button {
            onIntent(.toggleGeometryTool(tool))
            isGeometrySlotFocused = true
            UIAccessibility.post(
                notification: .announcement,
                argument: isActive ? "\(tool.title) off" : "\(tool.title) on"
            )
        } label: {
            CanvasGeometryToolGlyph(tool: tool, isSelected: isActive)
                .frame(width: StripMetrics.chipWidth + 14, height: StripMetrics.chipHeight)
                .background {
                    if isActive {
                        selectedToolBackground
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityFocused($focusedGeometryTool, equals: tool)
        .accessibilityLabel(tool.title)
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityHint(
            isActive
                ? "Turns off the \(tool.title.lowercased())"
                : "Selects and turns on the \(tool.title.lowercased())"
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("canvas.geometry.option.\(tool.rawValue)")
        .help(tool.title)
    }

    // MARK: Add strip

    private var insertStrip: some View {
        HStack(spacing: 0) {
            insertChip(.text, title: "Text", hint: "Inserts a text box", identifier: "canvas.insert.text") {
                onIntent(.insertText)
                isAddButtonFocused = true
            }
            insertChip(.shape, title: "Shape", hint: "Opens a shape picker", identifier: "canvas.insert.shape") {
                onIntent(.showShapes)
                Task { @MainActor in
                    await Task.yield()
                    focusedShape = CanvasShape.allCases.first
                }
            }
            insertChip(.table, title: "Table", hint: "Opens a rows and columns picker", identifier: "canvas.insert.table") {
                onIntent(.showTableSizePicker)
                Task { @MainActor in
                    await Task.yield()
                    if usesAccessibleTableSizePicker {
                        isTableStepperFocused = true
                    } else {
                        focusedTableSize = .standard
                    }
                }
            }
            imageMenu
            if supportsImagePlayground {
                insertChip(
                    .wand,
                    title: "Wand",
                    hint: "Circle a sketch or region and create an image with Image Playground",
                    identifier: "canvas.insert.image-wand"
                ) {
                    onIntent(.requestImageWand)
                    isAddButtonFocused = true
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add")
    }

    private func insertChip(
        _ glyph: CanvasTrayGlyphKind,
        title: String,
        hint: String,
        identifier: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        CanvasInsertChipButton(glyph: glyph, title: title, action: action)
            .accessibilityHint(hint)
            .accessibilityIdentifier(identifier)
    }

    private var imageMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") {
                onIntent(.requestPhoto)
                isAddButtonFocused = true
            }
            Button("Files", systemImage: "folder") {
                onIntent(.requestFile)
                isAddButtonFocused = true
            }
        } label: {
            CanvasTrayGlyph(kind: .image)
                .frame(width: StripMetrics.chipWidth + 8, height: StripMetrics.chipHeight)
                .contentShape(Rectangle())
        }
        .tint(Color.primary)
        .accessibilityLabel("Insert image")
        .accessibilityIdentifier("canvas.insert.image")
        .help("Insert image")
    }

    private var shapeCatalog: some View {
        HStack(spacing: 0) {
            ForEach(CanvasShape.allCases, id: \.self) { shape in
                Button {
                    onIntent(.insertShape(shape))
                    isAddButtonFocused = true
                } label: {
                    Image(systemName: systemImage(for: shape))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(
                            width: StripMetrics.chipWidth + 4,
                            height: StripMetrics.chipHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
                .accessibilityFocused($focusedShape, equals: shape)
                .accessibilityLabel(shape.title)
                .help(shape.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shapes")
    }

    @ViewBuilder
    private var tableSizePicker: some View {
        if usesAccessibleTableSizePicker {
            tableSizeStepperForm
        } else {
            ViewThatFits(in: .horizontal) {
                tableSizeGrid
                tableSizeStepperForm
            }
        }
    }

    private var usesAccessibleTableSizePicker: Bool {
        dynamicTypeSize.isAccessibilitySize
            || voiceOverEnabled
            || UIAccessibility.isSwitchControlRunning
    }

    private var tableSizeGrid: some View {
        VStack(alignment: .leading, spacing: TableSizePickerMetrics.contentSpacing) {
            tableSizePickerHeading

            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(CanvasTableSize.pickerRange, id: \.self) { row in
                    GridRow {
                        ForEach(CanvasTableSize.pickerRange, id: \.self) { column in
                            tableSizeCell(
                                CanvasTableSize(rowCount: row, columnCount: column)
                            )
                        }
                    }
                }
            }
            .frame(
                width: TableSizePickerMetrics.gridSide,
                height: TableSizePickerMetrics.gridSide
            )
            .contentShape(Rectangle())
            .coordinateSpace(name: TableSizePickerMetrics.coordinateSpaceName)
            .highPriorityGesture(tableSizeSlideGesture)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table size")
        .accessibilityValue(
            "\(displayedTableSize.columnCount) columns, \(displayedTableSize.rowCount) rows"
        )
        .accessibilityHint(
            "Tap a cell to insert, or slide across the grid and lift to choose a size."
        )
        .accessibilityIdentifier("canvas.table-size-picker")
    }

    private var tableSizeStepperForm: some View {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
            tableSizePickerHeading

            Stepper(
                "Rows: \(rolledOverTableSize.rowCount)",
                value: tableRowsBinding,
                in: CanvasTableSize.pickerRange
            )
            .accessibilityFocused($isTableStepperFocused)
            Stepper(
                "Columns: \(rolledOverTableSize.columnCount)",
                value: tableColumnsBinding,
                in: CanvasTableSize.pickerRange
            )
            Button {
                insertTable(rolledOverTableSize)
            } label: {
                Label(
                    "Insert \(rolledOverTableSize.columnCount) × \(rolledOverTableSize.rowCount) Table",
                    systemImage: "tablecells"
                )
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: NotateDesign.Control.minimumHitTarget)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(
                "Insert table with \(rolledOverTableSize.columnCount) columns and \(rolledOverTableSize.rowCount) rows"
            )
            .accessibilityIdentifier("canvas.table-size.insert")
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
        .accessibilityIdentifier("canvas.table-size-picker")
    }

    private var tableSizePickerHeading: some View {
        HStack(spacing: NotateDesign.Spacing.tight) {
            Image(systemName: "tablecells")
                .foregroundStyle(NotateDesign.Palette.accent)
            Text(
                "\(displayedTableSize.columnCount) × \(displayedTableSize.rowCount) Table"
            )
            .font(.subheadline.weight(.semibold))
            .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(displayedTableSize.columnCount) columns, \(displayedTableSize.rowCount) rows"
        )
    }

    private func tableSizeCell(_ size: CanvasTableSize) -> some View {
        let isHighlighted = size.rowCount <= displayedTableSize.rowCount
            && size.columnCount <= displayedTableSize.columnCount

        return Button {
            handleTableSizeCellTap(size)
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    isHighlighted
                        ? NotateDesign.Palette.accent.opacity(0.22)
                        : Color.primary.opacity(0.055)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            isHighlighted
                                ? NotateDesign.Palette.accent.opacity(0.82)
                                : Color.primary.opacity(0.24),
                            lineWidth: isHighlighted ? 1.25 : 0.75
                        )
                }
                .frame(
                    width: TableSizePickerMetrics.cellVisualDimension,
                    height: TableSizePickerMetrics.cellVisualDimension
                )
                .frame(
                    width: TableSizePickerMetrics.cellHitDimension,
                    height: TableSizePickerMetrics.cellHitDimension
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityFocused($focusedTableSize, equals: size)
        .focused($keyboardFocusedTableSize, equals: size)
        .accessibilityLabel(
            "Insert table with \(size.columnCount) columns and \(size.rowCount) rows"
        )
        .accessibilityValue("\(size.columnCount) columns, \(size.rowCount) rows")
        .accessibilityIdentifier(
            "canvas.table-size.r\(size.rowCount).c\(size.columnCount)"
        )
        .onHover { isInside in
            if isInside {
                rolledOverTableSize = size
            }
        }
        .help("\(size.columnCount) columns × \(size.rowCount) rows")
    }

    private var displayedTableSize: CanvasTableSize {
        pressedTableSize ?? rolledOverTableSize
    }

    private var tableSizeSlideGesture: some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(TableSizePickerMetrics.coordinateSpaceName)
        )
        .updating($pressedTableSize) { value, pressedSize, _ in
            pressedSize = tableSizeSelection(at: value.location)
        }
        .onChanged { _ in
            tableSizeSlideDidRecognize = true
        }
        .onEnded { value in
            if let size = tableSizeSelection(at: value.location) {
                insertTable(size)
            }
            resetTableSizeSlideRecognitionAfterEventDelivery()
        }
    }

    private func handleTableSizeCellTap(_ size: CanvasTableSize) {
        guard tableSizeSlideDidRecognize == false else {
            tableSizeSlideDidRecognize = false
            return
        }
        insertTable(size)
    }

    private func resetTableSizeSlideRecognitionAfterEventDelivery() {
        Task { @MainActor in
            await Task.yield()
            tableSizeSlideDidRecognize = false
        }
    }

    private func tableSizeSelection(at location: CGPoint) -> CanvasTableSize? {
        CanvasTableSizeGridGeometry().selection(
            at: location,
            in: CGRect(
                origin: .zero,
                size: CGSize(
                    width: TableSizePickerMetrics.gridSide,
                    height: TableSizePickerMetrics.gridSide
                )
            )
        )
    }

    private var tableRowsBinding: Binding<Int> {
        Binding(
            get: { rolledOverTableSize.rowCount },
            set: { value in
                rolledOverTableSize = CanvasTableSize(
                    rowCount: value,
                    columnCount: rolledOverTableSize.columnCount
                )
            }
        )
    }

    private var tableColumnsBinding: Binding<Int> {
        Binding(
            get: { rolledOverTableSize.columnCount },
            set: { value in
                rolledOverTableSize = CanvasTableSize(
                    rowCount: rolledOverTableSize.rowCount,
                    columnCount: value
                )
            }
        )
    }

    private func insertTable(_ size: CanvasTableSize) {
        rolledOverTableSize = size
        onIntent(.insertTable(size))
        isAddButtonFocused = true
    }

    private func activate(_ tool: CanvasTool) {
        onIntent(.tapTool(tool))
    }

    private func showOptions(for tool: CanvasTool) {
        guard tool.supportsOptions else {
            onIntent(.dismissOverlay)
            return
        }
        onIntent(.showOptions(tool))
    }

    private func updateWidth(_ width: Double, for tool: CanvasTool) {
        onIntent(.setWidth(tool, width))
    }

    private func updateColor(_ color: RGBAColor, for tool: CanvasTool) {
        onIntent(.setColor(tool, normalized(color, for: tool)))
    }

    private func updateCustomColor(_ color: Color, for tool: CanvasTool) {
        var rgba = RGBAColor(uiColor: UIColor(color))
        if tool == .highlighter {
            rgba.alpha = 0.45
        } else {
            rgba.alpha = 1
        }
        updateColor(rgba, for: tool)
    }

    private func normalized(_ color: RGBAColor, for tool: CanvasTool) -> RGBAColor {
        var result = color
        result.alpha = tool == .highlighter ? 0.45 : 1
        return result
    }

    private func accessibilityValue(
        for tool: CanvasTool,
        toolbarTool: CanvasTool,
        selected: Bool,
        optionsExpanded: Bool? = nil
    ) -> String {
        func includingOptionsState(_ value: String) -> String {
            guard let optionsExpanded else { return value }
            return "\(value), Options \(optionsExpanded ? "expanded" : "collapsed")"
        }

        let variantPrefix = tool.title != toolbarTool.toolbarFamilyTitle
            ? "\(tool.title), "
            : ""
        guard selected else {
            return includingOptionsState("\(variantPrefix)Not selected")
        }
        if tool == .laserPointer {
            return includingOptionsState(
                "\(variantPrefix)Selected, \(toolState.laserPointerStyle.title)"
            )
        }
        guard let configuration = toolState.configuration(for: tool) else {
            return includingOptionsState("\(variantPrefix)Selected")
        }
        if tool == .eraser {
            if toolState.eraserMode == .stroke {
                return includingOptionsState("\(variantPrefix)Selected, Stroke")
            }
            return includingOptionsState(
                "\(variantPrefix)Selected, Pixel, \(formattedWidth(configuration.width)) points"
            )
        }
        return includingOptionsState(
            "\(variantPrefix)Selected, \(formattedWidth(configuration.width)) points"
        )
    }

    private func isFamilyOptionsExpanded(for toolbarTool: CanvasTool) -> Bool {
        guard case let .toolOptions(tool) = overlay else { return false }
        return tool.toolbarFamilyRoot == toolbarTool.toolbarFamilyRoot
    }

    private func displayedToolbarTool(for toolbarTool: CanvasTool) -> CanvasTool {
        if toolState.activeTool.toolbarFamilyRoot == toolbarTool {
            return toolState.activeTool
        }
        return switch toolbarTool {
        case .pen:
            toolState.preferredPenTool
        case .fountainPen:
            toolState.preferredBrushTool
        default:
            toolbarTool
        }
    }

    private func formattedWidth(_ width: Double) -> String {
        width.formatted(
            .number.precision(
                .fractionLength(width.rounded() == width ? 0 : 1)
            )
        )
    }

    private func eraserPreviewDiameter(_ width: Double) -> CGFloat {
        let presets = CanvasToolState.widthPresets(for: .eraser)
        guard let index = presets.firstIndex(of: width), presets.count > 1 else { return 15 }
        return 8 + CGFloat(index) * (14 / CGFloat(presets.count - 1))
    }

    private func toolbarEraserDiameter(_ width: Double) -> CGFloat {
        max(5, min(10, 5 + (CGFloat(width) - 16) * (5 / 32)))
    }

    private func toolbarInkIndicatorWidth(_ width: Double, for tool: CanvasTool) -> CGFloat {
        let presets = CanvasToolState.widthPresets(for: tool)
        guard presets.count > 1 else { return 8 }
        let nearestIndex = presets.indices.min { lhs, rhs in
            abs(presets[lhs] - width) < abs(presets[rhs] - width)
        } ?? presets.startIndex
        return 8 + CGFloat(nearestIndex) * (16 / CGFloat(presets.count - 1))
    }

    private func inkPreviewHeight(_ width: Double, for tool: CanvasTool) -> CGFloat {
        let presets = CanvasToolState.widthPresets(for: tool)
        guard let index = presets.firstIndex(of: width), presets.count > 1 else { return 4.5 }
        return 1.5 + CGFloat(index) * (6.5 / CGFloat(presets.count - 1))
    }

    private func colorsMatch(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Bool {
        abs(lhs.red - rhs.red) < 0.01 &&
            abs(lhs.green - rhs.green) < 0.01 &&
            abs(lhs.blue - rhs.blue) < 0.01
    }

    private func colorName(for swatch: RGBAColor, tool: CanvasTool) -> String {
        let palette = tool == .highlighter ? RGBAColor.highlighterPalette : RGBAColor.inkPalette
        guard let index = palette.firstIndex(where: { colorsMatch($0, swatch) }) else {
            return "Color"
        }
        return colorName(at: index, for: tool)
    }

    private func colorName(at index: Int, for tool: CanvasTool) -> String {
        let inkNames = [
            "Black", "White", "Slate", "Blue", "Cyan", "Teal",
            "Green", "Yellow", "Orange", "Red", "Rose", "Violet",
        ]
        let highlighterNames = [
            "Yellow", "Lime", "Mint", "Cyan", "Blue", "Violet",
            "Pink", "Peach", "Orange", "Red", "Gray", "Brown",
        ]
        let names = tool == .highlighter ? highlighterNames : inkNames
        return names.indices.contains(index) ? names[index] : "Color \(index + 1)"
    }

    private func systemImage(for shape: CanvasShape) -> String {
        switch shape {
        case .rectangle: "rectangle"
        case .roundedRectangle: "rectangle.roundedtop"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .star: "star"
        case .speechBubble: "bubble"
        case .polygon: "hexagon"
        }
    }
}

private struct LaserPointerStyleGlyph: View {
    let style: CanvasLaserPointerStyle
    var tint: Color = NotateDesign.Palette.laser

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            switch style {
            case .dot:
                let diameter: CGFloat = 7
                let frame = CGRect(
                    x: (size.width - diameter) / 2,
                    y: (size.height - diameter) / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: frame),
                    with: .color(tint)
                )
                context.stroke(
                    Path(ellipseIn: frame.insetBy(dx: -2, dy: -2)),
                    with: .color(tint.opacity(0.24)),
                    lineWidth: 2
                )

            case .trail:
                var trail = Path()
                trail.move(to: CGPoint(x: 2, y: size.height * 0.72))
                trail.addCurve(
                    to: CGPoint(x: size.width - 4, y: size.height * 0.30),
                    control1: CGPoint(x: size.width * 0.30, y: size.height * 0.14),
                    control2: CGPoint(x: size.width * 0.58, y: size.height * 0.90)
                )
                context.stroke(
                    trail,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: size.width - 6.5,
                            y: size.height * 0.30 - 2.5,
                            width: 5,
                            height: 5
                        )
                    ),
                    with: .color(tint)
                )
            }
        }
        .frame(width: 24, height: 20)
        .accessibilityHidden(true)
    }
}

/// Concrete containers keep the pill and strip out of `CanvasToolPicker`'s
/// opaque return type; deep generic helper chains crashed the compiler on
/// device builds before.
private struct CanvasToolPillContainer<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: false) {
                    row
                }
                .frame(maxWidth: CanvasToolPicker.preferredPillWidth)
            } else {
                row
            }
        }
        .frame(height: NotateDesign.Control.compactGlassDiameter)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var row: some View {
        HStack(spacing: CanvasToolPicker.PillMetrics.itemSpacing) {
            content
        }
        .padding(.horizontal, CanvasToolPicker.PillMetrics.horizontalPadding)
        .frame(height: NotateDesign.Control.compactGlassDiameter)
    }
}

private struct CanvasOptionsStripContainer<Content: View>: View {
    let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            padded(content)
            ScrollView(.horizontal, showsIndicators: false) {
                padded(content)
            }
        }
    }

    private func padded(_ view: Content) -> some View {
        view
            .padding(.horizontal, CanvasToolPicker.StripMetrics.horizontalPadding)
            .padding(.vertical, CanvasToolPicker.StripMetrics.verticalPadding)
    }
}

private struct CanvasInsertChipButton: View {
    let glyph: CanvasTrayGlyphKind
    let title: String
    let action: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            CanvasTrayGlyph(kind: glyph)
                .frame(
                    width: CanvasToolPicker.StripMetrics.chipWidth + 8,
                    height: CanvasToolPicker.StripMetrics.chipHeight
                )
                .foregroundStyle(Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("Insert \(title.lowercased())")
        .help("Insert \(title.lowercased())")
    }
}

/// Canvas tools must remain optically sharp while the document beneath them
/// zooms. Feedback changes opacity only; transform-based press animations can
/// force a temporary offscreen resample of thin vector keylines.
private struct CanvasCrispToolButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.feedback,
                value: configuration.isPressed
            )
    }
}

private struct SecondaryClickGesture: UIGestureRecognizerRepresentable {
    let action: @MainActor () -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.buttonMaskRequired = .secondary
        recognizer.cancelsTouchesInView = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UITapGestureRecognizer,
        context: Context
    ) {
        guard recognizer.state == .ended else { return }
        action()
    }
}

private extension Color {
    init(rgba: RGBAColor) {
        self.init(
            red: rgba.red,
            green: rgba.green,
            blue: rgba.blue,
            opacity: rgba.alpha
        )
    }
}
