import SwiftUI

/// Compatibility name for feature code written before the library tokens were
/// nested under the canonical app design system. Every value forwards to
/// `NotateDesign`; this type intentionally owns no visual constants.
typealias NotateLibraryDesign = NotateDesign.Library

extension View {
    func notateLibraryCardSurface(
        isSelected: Bool = false,
        tint: Color = NotateDesign.Palette.accent,
        showsBackground: Bool = true
    ) -> some View {
        notateCardSurface(
            isSelected: isSelected,
            tint: tint,
            showsBackground: showsBackground
        )
    }

    func notateMinimumHitTarget() -> some View {
        frame(
            minWidth: NotateDesign.Control.minimumHitTarget,
            minHeight: NotateDesign.Control.minimumHitTarget
        )
        .contentShape(Rectangle())
    }

    /// Connects a folder's library artwork to its selected glyph beside the
    /// destination heading. Exactly one endpoint is the geometry source;
    /// Reduce Motion removes the spatial morph entirely.
    func notateFolderGeometryTransition(
        itemID: UUID?,
        in namespace: Namespace.ID,
        isSource: Bool
    ) -> some View {
        modifier(
            NotateFolderGeometryTransitionModifier(
                itemID: itemID,
                namespace: namespace,
                isSource: isSource
            )
        )
    }

    /// Marks a notebook, canvas, or document preview as the stable source for
    /// the system navigation zoom. The namespace is optional so isolated
    /// library previews and tests keep working without manufacturing a
    /// transition context. Reduce Motion leaves the source unmodified and lets
    /// NavigationStack use the system's accessibility-aware transition.
    func notateEditorGeometryTransition(
        itemID: UUID?,
        in namespace: Namespace.ID?,
        isSource: Bool
    ) -> some View {
        modifier(
            NotateEditorGeometryTransitionModifier(
                itemID: itemID,
                namespace: namespace,
                isSource: isSource
            )
        )
    }

    /// Applies the native iOS navigation zoom to the outermost editor view.
    /// NavigationStack owns the forward transition and the button-driven
    /// reverse transition. Under Reduce Motion the explicit zoom is omitted so
    /// the system chooses its reduced transition.
    func notateEditorNavigationTransition(
        itemID: UUID,
        in namespace: Namespace.ID
    ) -> some View {
        modifier(
            NotateEditorNavigationTransitionModifier(
                itemID: itemID,
                namespace: namespace
            )
        )
    }
}

/// App-owned glyph treatment for selectable navigation controls. Unselected
/// glyphs inherit the semantic foreground; selection colors only the artwork,
/// leaving adjacent labels unchanged.
struct NotateSelectableAppGlyph: View {
    let kind: NotateAppGlyphKind
    var selectedTint: Color = NotateDesign.Palette.accent
    var keepsTintWhenUnselected = false
    let isSelected: Bool
    var size: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let glow = NotateDesign.Elevation.selectionGlow

        NotateAppGlyph(
            kind: kind,
            tint: isSelected || keepsTintWhenUnselected ? selectedTint : Color.primary,
            isSelected: isSelected,
            usesTintedOutline: keepsTintWhenUnselected,
            size: size
        )
        .scaleEffect(isSelected && reduceMotion == false ? 1.10 : 1)
        .offset(y: isSelected && reduceMotion == false ? -1 : 0)
        .shadow(
            color: isSelected && reduceTransparency == false
                ? selectedTint.opacity(glow.opacity)
                : .clear,
            radius: glow.radius,
            y: glow.y
        )
        .animation(
            reduceMotion ? nil : NotateDesign.Motion.selection,
            value: isSelected
        )
    }
}

private struct NotateFolderGeometryTransitionModifier: ViewModifier {
    let itemID: UUID?
    let namespace: Namespace.ID
    let isSource: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if let itemID, reduceMotion == false {
            content.matchedGeometryEffect(
                id: itemID,
                in: namespace,
                properties: .frame,
                anchor: .center,
                isSource: isSource
            )
        } else {
            content
        }
    }
}

private struct NotateEditorGeometryTransitionModifier: ViewModifier {
    let itemID: UUID?
    let namespace: Namespace.ID?
    let isSource: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if let itemID, let namespace, reduceMotion == false, isSource {
            content.matchedTransitionSource(id: itemID, in: namespace)
        } else {
            content
        }
    }
}

private struct NotateEditorNavigationTransitionModifier: ViewModifier {
    let itemID: UUID
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content.navigationTransition(.automatic)
        } else {
            content.navigationTransition(
                .zoom(sourceID: itemID, in: namespace)
            )
        }
    }
}

/// Library-flavoured content for the app-wide 40-point circular glass button.
/// The custom glyph keeps these controls visually related to the canvas tools.
struct NotateCompactGlassGlyphLabel: View {
    let kind: NotateAppGlyphKind
    var tint: Color = NotateDesign.Palette.accent
    var isSelected = false
    var glyphSize: CGFloat = 18

    var body: some View {
        NotateCompactGlassButtonLabel {
            NotateAppGlyph(
                kind: kind,
                tint: tint,
                isSelected: isSelected,
                size: glyphSize
            )
        }
    }
}
