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

/// Session-independent configuration for the canvas tool picker.
/// This is factored out to make it easier to preview in isolation.
public struct CanvasToolPicker: View {
    enum TrayGlyph {
        case add(CanvasTrayGlyphKind)
        case geometry(CanvasGeometryTool)
    }

    enum PickerBarMetrics {
        static let itemSpacing: CGFloat = 2
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 8
    }

    enum ToolOptionsMetrics {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 12
        static let itemSpacing: CGFloat = 8
    }

    enum InsertTrayMetrics {
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 8
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

    public let toolState: CanvasToolState
    public let overlay: CanvasOverlay
    public let preferredGeometryTool: CanvasGeometryTool
    public let activeGeometryTool: CanvasGeometryTool?
    public let canUndo: Bool
    public let canRedo: Bool
    public let usesCompactLayout: Bool
    public let onIntent: (CanvasToolbarIntent) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        onIntent: @escaping (CanvasToolbarIntent) -> Void
    ) {
        self.toolState = toolState
        self.overlay = overlay
        self.preferredGeometryTool = preferredGeometryTool
        self.activeGeometryTool = activeGeometryTool
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.usesCompactLayout = usesCompactLayout
        self.onIntent = onIntent
    }

    public var body: some View {
        GlassEffectContainer(spacing: PickerBarMetrics.itemSpacing) {
            VStack(alignment: .leading, spacing: PickerBarMetrics.itemSpacing) {
                adaptivePickerBar
                    .frame(maxWidth: .infinity)
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(
                            cornerRadius: NotateDesign.Radius.chrome,
                            style: .continuous
                        )
                    )
                adaptiveAccessorySurface
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: overlay) { _, newValue in
            if case .insert = newValue {
                isAddButtonFocused = true
            }
        }
        .onChange(of: overlay) { oldValue, newValue in
            if case .toolOptions = oldValue, case .toolOptions = newValue {
                return
            }
            if case .insert = oldValue, case .insert = newValue {
                return
            }
        }
    }

    private var adaptivePickerBar: some View {
        Group {
            if usesCompactLayout || dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 6),
                    spacing: 2
                ) {
                    pickerControls
                }
                .accessibilityIdentifier("canvas.tool.strip")
            } else {
                HStack(spacing: PickerBarMetrics.itemSpacing) {
                    pickerControls
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("canvas.tool.strip")
            }
        }
        .padding(.horizontal, PickerBarMetrics.horizontalPadding)
        .padding(.vertical, PickerBarMetrics.verticalPadding)
    }

    @ViewBuilder private var pickerControls: some View {
            utilityButton(title: "Undo", systemImage: "arrow.uturn.backward", isEnabled: canUndo) {
                onIntent(.undo)
            }
            utilityButton(title: "Redo", systemImage: "arrow.uturn.forward", isEnabled: canRedo) {
                onIntent(.redo)
            }
            toolButton(.lasso)
            toolButton(.pen)
            toolButton(.pencil)
            toolButton(.fountainPen)
            toolButton(.highlighter)
            toolButton(.eraser)
            toolButton(.laserPointer)
            addButton
    }

    private var addButton: some View {
        Button {
            onIntent(.toggleInsert)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: NotateDesign.Control.standard, height: NotateDesign.Control.standard)
                .background {
                    if case .insert = overlay {
                        selectedToolBackground
                    }
                }
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityFocused($isAddButtonFocused)
        .accessibilityLabel("Add")
        .accessibilityValue(isAddExpanded ? "expanded" : "collapsed")
        .help("Add content")
    }

    private var adaptiveAccessorySurface: some View {
        accessorySurface
    }

    @ViewBuilder private var accessorySurface: some View {
        switch overlay {
        case .toolOptions(let tool) where tool.supportsOptions:
            toolOptions(for: tool)
                .padding(.horizontal, ToolOptionsMetrics.horizontalPadding)
                .padding(.vertical, ToolOptionsMetrics.verticalPadding)
                .notateGlassSurface(
                    shape: RoundedRectangle(
                        cornerRadius: NotateDesign.Radius.chrome,
                        style: .continuous
                    ),
                    reduceTransparency: reduceTransparency
                )
                .glassEffectID("canvas-tool-options", in: glassNamespace)
                .transition(accessoryTransition)
        case .insert, .geometryTools:
            VStack(alignment: .leading, spacing: PickerBarMetrics.itemSpacing) {
                insertTraySurface
                geometryToolPickerSurface
            }
        case .shapes:
            shapeCatalog
        case .tableSizePicker:
            tableSizePicker
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

    private var isAddExpanded: Bool {
        switch overlay {
        case .insert, .shapes, .tableSizePicker, .geometryTools:
            return true
        default:
            return false
        }
    }

    private func utilityButton(title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: NotateDesign.Control.standard, height: NotateDesign.Control.standard)
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
        let label = displayedTool.title
        let hasFamilyVariants = displayedTool.toolbarFamilyVariants.count > 1
        let familyOptionsExpanded = isFamilyOptionsExpanded(for: toolbarTool)

        return Button { activate(displayedTool) } label: {
            ToolGlyph(
                tool: displayedTool,
                inkColor: Color(rgba: configuration?.color ?? .black),
                isSelected: selected
            )
                .frame(width: NotateDesign.Control.standard, height: NotateDesign.Control.standard)
                .background {
                    if selected {
                        selectedToolBackground
                    }
                }
                .overlay(alignment: .bottom) {
                    toolIndicator(for: displayedTool, configuration: configuration)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasFamilyVariants {
                        Image(systemName: familyOptionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.secondary)
                            .padding(2)
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
        .accessibilityHint(hasFamilyVariants ? "Double tap and hold for options" : "")
        .help(label)
    }

    @ViewBuilder
    private func toolIndicator(
        for tool: CanvasTool,
        configuration: CanvasToolConfiguration?
    ) -> some View {
        if tool == .eraser {
            Capsule()
                .fill(Color.primary)
                .frame(width: toolState.eraserMode == .pixel ? 3 : 8, height: 3)
                .padding(.bottom, 2)
        } else if let color = configuration?.color,
                  tool != .lasso,
                  tool != .laserPointer {
            Capsule()
                .fill(Color(rgba: color))
                .frame(
                    width: toolbarInkIndicatorWidth(configuration?.width ?? 2, for: tool),
                    height: 3
                )
                .padding(.bottom, 2)
        }
    }

    private var selectedToolBackground: some View {
        ZStack {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotateDesign.Radius.control, style: .continuous)
                    .fill(NotateDesign.Palette.background)
            }
            RoundedRectangle(cornerRadius: NotateDesign.Radius.control, style: .continuous)
                .fill(
                    NotateDesign.Palette.accent.opacity(
                        reduceTransparency
                            ? NotateDesign.Palette.opaqueSelectionFillOpacity
                            : NotateDesign.Palette.selectionFillOpacity
                    )
                )
            RoundedRectangle(cornerRadius: NotateDesign.Radius.control, style: .continuous)
                .strokeBorder(
                    NotateDesign.Palette.accent.opacity(
                        colorSchemeContrast == .increased
                            ? 1
                            : NotateDesign.Hairline.selectedOpacity
                    ),
                    lineWidth: NotateDesign.Hairline.width(for: colorSchemeContrast)
                )
        }
    }

    private func toolOptions(for tool: CanvasTool) -> some View {
        Group {
            if tool.toolbarFamilyVariants.count > 1 {
                familyToolOptionControls(for: tool)
            } else {
                toolVariantOptions(for: tool)
            }
        }
    }

    private func familyToolOptionControls(for tool: CanvasTool) -> some View {
        VStack(alignment: .leading, spacing: ToolOptionsMetrics.itemSpacing) {
            familyWidthOptions(for: tool)
            familyColorOptions(for: tool)
        }
    }

    private func toolVariantOptions(for tool: CanvasTool) -> some View {
        VStack(alignment: .leading, spacing: ToolOptionsMetrics.itemSpacing) {
            Text("Style")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48, maximum: 64))], spacing: 4) {
                ForEach(tool.toolbarFamilyVariants, id: \.self) { variant in
                    toolVariantButton(variant)
                }
            }
            .accessibilityIdentifier("canvas.tool.variants")
            toolOptionControls(for: tool)
        }
    }

    @ViewBuilder private func toolOptionControls(for tool: CanvasTool) -> some View {
        if tool == .laserPointer {
            laserPointerStyles
        } else if tool == .eraser {
            eraserModes
            widthOptions(for: tool)
        } else {
            widthOptions(for: tool)
            colorOptions(for: tool)
        }
    }

    private func toolVariantButton(_ tool: CanvasTool) -> some View {
        Button {
            Task { @MainActor in
                await onIntent(.tapTool(tool))
            }
        } label: {
            VStack(spacing: 2) {
                ToolGlyph(
                    tool: tool,
                    inkColor: Color(rgba: toolState.configuration(for: tool)?.color ?? .black),
                    isSelected: tool == toolState.activeTool
                )
                    .frame(height: 36)
                Text(tool.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 108 : 88)
            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 72 : 58)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 4 : 0)
            .background {
                if tool == toolState.activeTool {
                    selectedToolBackground
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityFocused($focusedTool, equals: tool)
        .accessibilityLabel(tool.title)
        .accessibilityIdentifier("canvas.tool.\(tool.rawValue)")
        .accessibilityValue(tool == toolState.activeTool ? "Selected" : "Not selected")
        .accessibilityAddTraits(tool == toolState.activeTool ? .isSelected : [])
        .help(tool.title)
    }

    private var laserPointerStyles: some View {
        VStack(alignment: .leading, spacing: ToolOptionsMetrics.itemSpacing) {
            Text("Style")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
            laserPointerStyleButtons
        }
    }

    private var laserPointerStyleButtons: some View {
        HStack(spacing: ToolOptionsMetrics.itemSpacing) {
            ForEach(CanvasLaserPointerStyle.allCases, id: \.self) { style in
                laserPointerStyleButton(style)
            }
        }
    }

    private func laserPointerStyleButton(_ style: CanvasLaserPointerStyle) -> some View {
        Button {
            onIntent(.setLaserPointerStyle(style))
        } label: {
            HStack(spacing: 6) {
                LaserPointerStyleGlyph(style: style)
                    .frame(width: 24, height: 20)
                Text(style.title)
                    .font(.caption.weight(.medium))
            }
            .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 104 : 76, minHeight: dynamicTypeSize.isAccessibilitySize ? 60 : 44)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: NotateDesign.Radius.option, style: .continuous)
                    .fill(NotateDesign.Palette.laser.opacity(
                        toolState.laserPointerStyle == style ? 0.12 : 0
                    ))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(style.title)
        .accessibilityValue(toolState.laserPointerStyle == style ? "Selected" : "Not selected")
        .accessibilityAddTraits(toolState.laserPointerStyle == style ? .isSelected : [])
        .help(style.title)
    }

    private func widthOptions(for tool: CanvasTool) -> some View {
        widthOptionButtons(for: tool)
            .frame(maxWidth: 299, alignment: .leading)
    }

    private func familyWidthOptions(for tool: CanvasTool) -> some View {
        widthOptionButtons(for: tool)
            .frame(maxWidth: 299, alignment: .leading)
    }

    private func widthOptionButtons(for tool: CanvasTool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: NotateDesign.Control.standard))], spacing: 4) {
            ForEach(CanvasToolState.widthPresets(for: tool), id: \.self) { width in
                widthButton(width, for: tool)
            }
        }
    }

    private func widthButton(_ width: Double, for tool: CanvasTool) -> some View {
        Button {
            updateWidth(width, for: tool)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: NotateDesign.Radius.option, style: .continuous)
                    .fill(toolState.configuration(for: tool)?.width == width ? NotateDesign.Palette.accent.opacity(NotateDesign.Palette.selectionFillOpacity) : Color.clear)
                if tool == .eraser {
                    let diameter = eraserPreviewDiameter(width)
                    Circle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: diameter, height: diameter)
                } else {
                    let inkHeight = inkPreviewHeight(width, for: tool)
                    Capsule()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 20, height: inkHeight)
                }
            }
            .frame(width: NotateDesign.Control.standard, height: NotateDesign.Control.standard)
            .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("\(formattedWidth(width)) points")
        .accessibilityAddTraits(toolState.configuration(for: tool)?.width == width ? .isSelected : [])
    }

    private func colorOptions(for tool: CanvasTool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ToolOptionsMetrics.itemSpacing) {
                colorSwatches(colorPalette(for: tool), current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
                customColorPicker(current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
            }
            VStack(alignment: .leading, spacing: ToolOptionsMetrics.itemSpacing) {
                colorSwatches(colorPalette(for: tool), current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
                customColorPicker(current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
            }
        }
    }

    private func colorPalette(for tool: CanvasTool) -> [RGBAColor] {
        tool == .highlighter ? RGBAColor.highlighterPalette : RGBAColor.inkPalette
    }

    private func familyColorOptions(for tool: CanvasTool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ToolOptionsMetrics.itemSpacing) {
                colorSwatches(colorPalette(for: tool), current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
                    .frame(minWidth: NotateDesign.Control.standard, idealWidth: 248, maxWidth: 248)
                customColorPicker(current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
            }
            VStack(alignment: .leading, spacing: ToolOptionsMetrics.itemSpacing) {
                colorSwatches(colorPalette(for: tool), current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
                customColorPicker(current: toolState.configuration(for: tool)?.color ?? .black, for: tool)
            }
        }
    }

    private func colorSwatches(_ palette: [RGBAColor], current: RGBAColor, for tool: CanvasTool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 44))], spacing: 2) {
            ForEach(palette.indices, id: \.self) { index in
                colorButton(palette[index], name: colorName(at: index, for: tool), current: current, for: tool)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
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
        .frame(width: NotateDesign.Control.standard, height: NotateDesign.Control.standard)
        .accessibilityLabel("Custom color")
    }

    private func colorButton(_ swatch: RGBAColor, name: String, current: RGBAColor, for tool: CanvasTool) -> some View {
        Button {
            updateColor(swatch, for: tool)
        } label: {
            Circle()
                .fill(Color(rgba: swatch))
                .frame(width: 25, height: 25)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
                .overlay {
                    if colorsMatch(swatch, current) {
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .frame(width: NotateDesign.Control.standard, height: NotateDesign.Control.standard)
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(name)
        .accessibilityAddTraits(colorsMatch(swatch, current) ? .isSelected : [])
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
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 280 : 196)
    }

    private var insertTraySurface: some View {
        insertTray
            .padding(.horizontal, InsertTrayMetrics.horizontalPadding)
            .padding(.vertical, InsertTrayMetrics.verticalPadding)
            .notateGlassSurface(
                shape: RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.chrome,
                    style: .continuous
                ),
                reduceTransparency: reduceTransparency
            )
            .glassEffectID("canvas-insert-tray", in: glassNamespace)
            .transition(accessoryTransition)
    }

    private var insertTray: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 144))], spacing: 4) {
            insertTrayButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add")
    }

    @ViewBuilder private var insertTrayButtons: some View {
            CanvasInsertTrayButton(title: "Text", glyph: .text) {
                onIntent(.insertText)
                isAddButtonFocused = true
            }
            .accessibilityLabel("Insert text")
            .accessibilityHint("Inserts a text box")
            .accessibilityIdentifier("canvas.insert.text")
            .help("Insert text")

            CanvasInsertTrayButton(title: "Shape", glyph: .shape) {
                onIntent(.showShapes)
                Task { @MainActor in
                    await Task.yield()
                    focusedShape = CanvasShape.allCases.first
                }
            }
            .accessibilityLabel("Insert shape")
            .accessibilityHint("Opens a shape picker")
            .accessibilityIdentifier("canvas.insert.shape")
            .help("Insert shape")

            CanvasInsertTrayButton(title: "Table", glyph: .table) {
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
            .accessibilityLabel("Choose table size")
            .accessibilityHint("Opens a rows and columns picker")
            .accessibilityIdentifier("canvas.insert.table")
            .help("Insert table")

            geometryToolSlot

            CanvasInsertTrayButton(title: "Wand", glyph: .wand) {
                onIntent(.requestImageWand)
                isAddButtonFocused = true
            }
            .accessibilityLabel("Create image with Wand")
            .accessibilityHint("Circle a sketch or region and create an image with Image Playground")
            .accessibilityIdentifier("canvas.insert.image-wand")
            .help("Wand")

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
                trayLabel(title: "Image", glyph: .add(.image))
            }
            .tint(Color.primary)
            .accessibilityLabel("Insert image")
            .help("Insert image")
    }

    private var geometryToolSlot: some View {
        let isActive = activeGeometryTool == preferredGeometryTool

        return Button {
            let opensChooser = activeGeometryTool != nil
            onIntent(.tapGeometryToolSlot)
            if opensChooser {
                Task { @MainActor in
                    await Task.yield()
                    focusedGeometryTool = activeGeometryTool
                }
            }
        } label: {
            trayLabel(
                title: preferredGeometryTool.title,
                glyph: .geometry(preferredGeometryTool),
                isSelected: isActive
            )
        }
        .background {
            if isActive {
                selectedTrayBackground
            }
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityFocused($isGeometrySlotFocused)
        .accessibilityLabel(preferredGeometryTool.title)
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityHint(
            isActive
                ? "Opens the ruler, protractor, and compass chooser"
                : "Turns on the \(preferredGeometryTool.title.lowercased())"
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("canvas.geometry.slot")
        .help(
            isActive
                ? "Choose a geometry tool"
                : "Show \(preferredGeometryTool.title.lowercased())"
        )
    }

    private var geometryToolPickerSurface: some View {
        geometryToolPicker
            .padding(.horizontal, NotateDesign.Spacing.compact)
            .padding(.vertical, NotateDesign.Spacing.compact)
            .notateGlassSurface(
                shape: RoundedRectangle(
                    cornerRadius: NotateDesign.Radius.chrome,
                    style: .continuous
                ),
                reduceTransparency: reduceTransparency
            )
            .glassEffectID("canvas-geometry-picker", in: glassNamespace)
            .transition(accessoryTransition)
    }

    private var geometryToolPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 176))], spacing: 4) {
            ForEach(CanvasGeometryTool.allCases, id: \.self) { tool in
                geometryToolOption(tool)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: NotateDesign.Spacing.tight) {
                CanvasGeometryToolGlyph(tool: tool, isSelected: isActive)
                    .frame(width: 30, height: 24)
                Text(tool.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.leading)
            }
            .frame(
                minWidth: dynamicTypeSize.isAccessibilitySize ? 128 : 104,
                minHeight: dynamicTypeSize.isAccessibilitySize ? 60 : 44
            )
            .padding(.horizontal, 4)
            .background {
                if isActive {
                    RoundedRectangle(
                        cornerRadius: NotateDesign.Radius.option,
                        style: .continuous
                    )
                    .fill(
                        NotateDesign.Palette.accent.opacity(
                            NotateDesign.Palette.selectionFillOpacity
                        )
                    )
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
        .help(isActive ? "Hide \(tool.title.lowercased())" : "Show \(tool.title.lowercased())")
    }

    private var shapeCatalog: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: NotateDesign.Control.standard))], spacing: 2) {
            ForEach(CanvasShape.allCases, id: \.self) { shape in
                    Button {
                        onIntent(.insertShape(shape))
                        isAddButtonFocused = true
                    } label: {
                        Image(systemName: systemImage(for: shape))
                            .font(.system(size: 18, weight: .regular))
                            .frame(
                                width: NotateDesign.Control.standard,
                                height: NotateDesign.Control.standard
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
                    .accessibilityFocused($focusedShape, equals: shape)
                    .accessibilityLabel(shape.title)
                    .help(shape.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var selectedTrayBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: NotateDesign.Radius.control,
            style: .continuous
        )

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
        }
        .overlay {
            shape.strokeBorder(
                NotateDesign.Palette.accent.opacity(
                    colorSchemeContrast == .increased
                        ? 1
                        : NotateDesign.Hairline.selectedOpacity
                ),
                lineWidth: NotateDesign.Hairline.width(for: colorSchemeContrast)
            )
        }
    }

    private func trayLabel(
        title: String,
        glyph: TrayGlyph,
        isSelected: Bool = false
    ) -> some View {
        VStack(spacing: 2) {
            Group {
                switch glyph {
                case let .add(kind):
                    CanvasTrayGlyph(kind: kind, isSelected: isSelected)
                case let .geometry(tool):
                    CanvasGeometryToolGlyph(tool: tool, isSelected: isSelected)
                }
            }
            .frame(height: 22)
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
        }
        .frame(
            width: dynamicTypeSize.isAccessibilitySize ? nil : 64,
            height: dynamicTypeSize.isAccessibilitySize ? nil : 48
        )
        .frame(
            minWidth: dynamicTypeSize.isAccessibilitySize ? 84 : 64,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 48
        )
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
        .foregroundStyle(Color.primary)
        .contentShape(Rectangle())
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

/// A concrete view boundary keeps the Add tray out of `CanvasToolPicker`'s
/// already-deep opaque return type. It avoids the former generic helper path
/// that crashed while the tray expanded on an iPadOS 27 device.
private struct CanvasInsertTrayButton: View {
    let title: String
    let glyph: CanvasTrayGlyphKind
    let action: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                CanvasTrayGlyph(kind: glyph)
                    .frame(height: 22)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .frame(
                width: dynamicTypeSize.isAccessibilitySize ? nil : 64,
                height: dynamicTypeSize.isAccessibilitySize ? nil : 48
            )
            .frame(
                minWidth: dynamicTypeSize.isAccessibilitySize ? 84 : 64,
                minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 48
            )
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
            .foregroundStyle(Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(CanvasCrispToolButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("Insert \(title.lowercased())")
        .accessibilityValue("")
        .help("Insert \(title.lowercased())")
    }
}

private struct LaserPointerStyleGlyph: View {
    let style: CanvasLaserPointerStyle

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
                    with: .color(NotateDesign.Palette.laser)
                )
                context.stroke(
                    Path(ellipseIn: frame.insetBy(dx: -2, dy: -2)),
                    with: .color(NotateDesign.Palette.laser.opacity(0.24)),
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
                    with: .color(NotateDesign.Palette.laser),
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
                    with: .color(NotateDesign.Palette.laser)
                )
            }
        }
        .frame(width: 24, height: 20)
        .accessibilityHidden(true)
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
