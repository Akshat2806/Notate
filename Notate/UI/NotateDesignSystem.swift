import SwiftUI
import UIKit

/// Notate's canonical visual language.
///
/// Feature design systems may add semantic layout names, but color, spacing,
/// geometry, control sizing, elevation, and motion all originate here. This
/// keeps the paper canvas and the library feeling like one application rather
/// than two independently styled surfaces.
enum NotateDesign {
    enum Palette {
        /// Always follows the app asset/system accent instead of freezing a
        /// second brand blue in code.
        static let accent = Color.accentColor
        /// A warm semantic accent reserved for favorited content.
        static let favorite = Color(red: 0.96, green: 0.70, blue: 0.12)
        /// A calm teal identity for time-based and recently opened content.
        static let recent = Color(red: 0.22, green: 0.67, blue: 0.62)
        /// A destructive accent reserved for Trash navigation and actions.
        static let trash = Color.red
        /// Communicates validation and recovery failures.
        static let error = Color.red
        /// Communicates recoverable missing or incomplete content.
        static let warning = Color.orange
        /// Keeps the laser pointer's conventional red identity centralized.
        static let laser = Color.red
        static let background = Color(uiColor: .systemBackground)
        static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

        static let sidebarBackground = Color(uiColor: .secondarySystemBackground)

        static let selectionFillOpacity = 0.13
        static let opaqueSelectionFillOpacity = 0.20
        static let translucentCardOpacity = 0.82
        static let tintedControlFillOpacity = 0.16
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let control: CGFloat = 12
        static let content: CGFloat = 16
        static let section: CGFloat = 20
        static let page: CGFloat = 24
        static let spacious: CGFloat = 32
    }

    /// Semantic radii shared by canvas and library surfaces.
    enum Radius {
        static let option: CGFloat = 10
        static let control: CGFloat = 14
        static let chrome: CGFloat = 18
        static let navigationRow: CGFloat = 19
        static let card: CGFloat = 22
        static let panel: CGFloat = 26
    }

    enum Control {
        /// The visible size of a standalone icon-only Liquid Glass button.
        static let compactGlassDiameter: CGFloat = 40
        /// The compact glass circle remains 40 points while this transparent
        /// outer frame preserves Apple's minimum comfortable hit target.
        static let minimumHitTarget: CGFloat = 44
        static let standard: CGFloat = 44
        static let floatingAction: CGFloat = 56
        static let compactGlassIcon: CGFloat = 14
        static let moreIcon: CGFloat = 16
    }

    enum Hairline {
        static let subtleOpacity = 0.075
        static let standardOpacity = 0.10
        static let increasedContrastOpacity = 0.24
        static let selectedOpacity = 0.78
        static let standardWidth: CGFloat = 1
        static let increasedContrastWidth: CGFloat = 2

        static func opacity(
            for contrast: ColorSchemeContrast,
            subtle: Bool = false
        ) -> Double {
            if contrast == .increased { return increasedContrastOpacity }
            return subtle ? subtleOpacity : standardOpacity
        }

        static func width(for contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? increasedContrastWidth : standardWidth
        }
    }

    enum Elevation {
        struct Shadow: Sendable {
            let opacity: Double
            let radius: CGFloat
            let y: CGFloat
        }

        static let compact = Shadow(opacity: 0.08, radius: 7, y: 3)
        static let floating = Shadow(opacity: 0.08, radius: 10, y: 4)
        static let primaryAction = Shadow(opacity: 0.24, radius: 14, y: 7)
        static let card = Shadow(opacity: 0.045, radius: 14, y: 6)
        static let opaqueCard = Shadow(opacity: 0.08, radius: 14, y: 6)
        static let panel = Shadow(opacity: 0.14, radius: 24, y: 12)
        static let selectionGlow = Shadow(opacity: 0.18, radius: 4, y: 2)
    }

    /// Motion is named for intent so callers do not invent durations while
    /// laying out a feature. Movement-based effects must still be disabled by
    /// their owning view when Reduce Motion is enabled.
    enum Motion {
        static let feedback = Animation.easeOut(duration: 0.10)
        static let selection = Animation.snappy(duration: 0.20, extraBounce: 0.06)
        static let content = Animation.smooth(duration: 0.24)
        static let presentation = Animation.snappy(duration: 0.30, extraBounce: 0.04)
        static let navigation = Animation.snappy(duration: 0.28, extraBounce: 0.04)
        static let removal = Animation.easeOut(duration: 0.14)
        static let spatial = Animation.smooth(duration: 0.36)
    }

    /// Library-only dimensions remain nested in the canonical system. Its
    /// semantic values are aliases to the app-wide tokens above.
    enum Library {
        typealias Spacing = NotateDesign.Spacing
        typealias Radius = NotateDesign.Radius
        typealias Motion = NotateDesign.Motion

        enum Layout {
            static let sidebarWidth: CGFloat = 280
            static let accessibilitySidebarWidth: CGFloat = 336
            static let sidebarRailWidth: CGFloat = 64
            static let cardMinimumWidth: CGFloat = 184
            static let cardMaximumWidth: CGFloat = 248
            static let accessibilityCardMaximumWidth: CGFloat = 320
            static let contentMaximumWidth: CGFloat = 1_520
        }

        /// A shared shelf lane, independent of the physical format inside it.
        /// New sheet formats supply their own ratio and fit into this envelope.
        enum Shelf {
            static let artworkAspectRatio: CGFloat = 1
            static let notebookAspectRatio: CGFloat = 2 / 3
            static let aSeriesAspectRatio: CGFloat = 1 / CGFloat(2).squareRoot()
            static let folderAspectRatio: CGFloat = 584 / 436
            static let artworkInset: CGFloat = 6
            static let artworkToTitleSpacing: CGFloat = 12
            static let labelSpacing: CGFloat = artworkToTitleSpacing - artworkInset
            static let metadataSpacing: CGFloat = 4
            static let columnSpacing: CGFloat = 28
            static let rowSpacing: CGFloat = 32
            static let folderWidthFraction: CGFloat = 160 / 184
            static let smallEnvelope: CGFloat = 144
            static let comfortableEnvelope: CGFloat = 168
            static let largeEnvelope: CGFloat = 200
            static let smallZoom: Double = 0.72
            static let comfortableZoom: Double = 0.84
            static let largeZoom: Double = 1.48

            static func envelopeWidth(for zoom: Double) -> CGFloat {
                let boundedZoom = zoom.isFinite
                    ? min(max(zoom, smallZoom), largeZoom) : comfortableZoom
                if boundedZoom <= comfortableZoom {
                    return smallEnvelope + (comfortableEnvelope - smallEnvelope)
                        * CGFloat((boundedZoom - smallZoom) / (comfortableZoom - smallZoom))
                }
                return comfortableEnvelope + (largeEnvelope - comfortableEnvelope)
                    * CGFloat((boundedZoom - comfortableZoom) / (largeZoom - comfortableZoom))
            }

            static func tileSizeSelection(for zoom: Double) -> Int {
                if zoom < (smallZoom + comfortableZoom) / 2 { return 0 }
                if zoom > (comfortableZoom + largeZoom) / 2 { return 2 }
                return 1
            }

            static func zoom(for selection: Int) -> Double {
                switch selection {
                case 0: smallZoom
                case 2: largeZoom
                default: comfortableZoom
                }
            }
            static let folderFrontTop: CGFloat = 0.16
            static let folderCornerFraction: CGFloat = 0.065
        }

        static let minimumHitTarget = NotateDesign.Control.minimumHitTarget
        static let floatingActionSize = NotateDesign.Control.floatingAction
        static let sidebarWidth = Layout.sidebarWidth
        static let accessibilitySidebarWidth = Layout.accessibilitySidebarWidth
        static let sidebarRailWidth = Layout.sidebarRailWidth
        static let cardMinimumWidth = Layout.cardMinimumWidth
        static let cardMaximumWidth = Layout.cardMaximumWidth
        static let accessibilityCardMaximumWidth = Layout.accessibilityCardMaximumWidth
        static let contentMaximumWidth = Layout.contentMaximumWidth
        static let accent = NotateDesign.Palette.accent
        static let warmBackground = NotateDesign.Palette.background
        static let sidebarBackground = NotateDesign.Palette.sidebarBackground
        static let hairline = Color.primary.opacity(NotateDesign.Hairline.subtleOpacity)
    }

    // Compatibility spellings retained while feature code adopts the grouped
    // token namespaces.
    static let accent = Palette.accent
    static let compactGlassDiameter = Control.compactGlassDiameter
    static let minimumHitTarget = Control.minimumHitTarget
    static let controlSize = Control.standard
    static let compactMoreIconSize = Control.moreIcon
    static let hairlineOpacity = Hairline.standardOpacity
}

/// The single visible treatment for standalone icon-only Liquid Glass buttons.
/// The glass circle is 40 points; the surrounding 44-point frame is transparent
/// and exists solely for touch and accessibility ergonomics.
struct NotateCompactGlassButtonLabel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        glassContent
            .modifier(
                NotateGlassSurfaceModifier(
                    shape: Circle(),
                    tint: nil,
                    isInteractive: true,
                    elevation: .compact
                )
            )
            .frame(
                width: NotateDesign.Control.minimumHitTarget,
                height: NotateDesign.Control.minimumHitTarget
            )
            .contentShape(Circle())
    }

    private var glassContent: some View {
        content.frame(
            width: NotateDesign.Control.compactGlassDiameter,
            height: NotateDesign.Control.compactGlassDiameter
        )
    }
}

struct NotateCompactGlassIconLabel: View {
    let systemImage: String
    let iconSize: CGFloat

    init(
        systemImage: String,
        iconSize: CGFloat = NotateDesign.Control.compactGlassIcon
    ) {
        self.systemImage = systemImage
        self.iconSize = iconSize
    }

    var body: some View {
        NotateCompactGlassButtonLabel {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

struct NotatePressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && reduceMotion == false ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : NotateDesign.Motion.feedback,
                value: configuration.isPressed
            )
    }
}

extension View {
    /// Compatibility overload for existing canvas callers. Accessibility
    /// state is intentionally read inside the modifier so the environment is
    /// always authoritative.
    func notateGlassSurface<S: Shape>(
        shape: S,
        reduceTransparency _: Bool,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            NotateGlassSurfaceModifier(
                shape: shape,
                tint: nil,
                isInteractive: isInteractive,
                elevation: .floating
            )
        )
    }

    func notateGlassSurface<S: Shape>(
        shape: S,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            NotateGlassSurfaceModifier(
                shape: shape,
                tint: nil,
                isInteractive: isInteractive,
                elevation: .floating
            )
        )
    }

    /// Liquid Glass is reserved for interactive chrome. Cards and reading
    /// surfaces use the opaque card/panel treatments below.
    func notateInteractiveGlass<S: Shape>(
        tint: Color? = nil,
        in shape: S
    ) -> some View {
        modifier(
            NotateGlassSurfaceModifier(
                shape: shape,
                tint: tint,
                isInteractive: true,
                elevation: .floating
            )
        )
    }

    func notateCardSurface(
        isSelected: Bool = false,
        tint: Color = NotateDesign.Palette.accent,
        showsBackground: Bool = true
    ) -> some View {
        modifier(
            NotateCardSurfaceModifier(
                isSelected: isSelected,
                tint: tint,
                showsBackground: showsBackground
            )
        )
    }

    func notatePanelSurface() -> some View {
        modifier(NotatePanelSurfaceModifier())
    }

    /// A low-emphasis content surface for code, grouped controls, and other
    /// authored material that needs structure without floating-card chrome.
    func notateQuietSurface(
        fillOpacity: Double = 0.022,
        radius: CGFloat = NotateDesign.Radius.option
    ) -> some View {
        modifier(
            NotateQuietSurfaceModifier(
                fillOpacity: fillOpacity,
                radius: radius
            )
        )
    }

    /// A compact, noninteractive material surface for status badges layered
    /// above artwork. Unlike Liquid Glass, it belongs to the content layer.
    func notateBadgeSurface<S: Shape>(in shape: S) -> some View {
        modifier(NotateBadgeSurfaceModifier(shape: shape))
    }

    /// The app-wide treatment for the single primary floating action.
    func notatePrimaryActionSurface<S: Shape>(in shape: S) -> some View {
        modifier(NotatePrimaryActionSurfaceModifier(shape: shape))
    }
}

private enum NotateGlassElevation {
    case compact
    case floating

    var token: NotateDesign.Elevation.Shadow {
        switch self {
        case .compact: NotateDesign.Elevation.compact
        case .floating: NotateDesign.Elevation.floating
        }
    }
}

private struct NotateGlassSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S
    let tint: Color?
    let isInteractive: Bool
    let elevation: NotateGlassElevation

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    shape.fill(NotateDesign.Palette.background)
                    if let tint {
                        shape.fill(tint.opacity(reducedTransparencyTintOpacity))
                    }
                }
                .overlay(accessibleOutline)
                .shadow(
                    color: .black.opacity(elevation.token.opacity),
                    radius: elevation.token.radius,
                    y: elevation.token.y
                )
        } else if #available(iOS 26.0, *) {
            if let tint {
                content
                    .glassEffect(.regular.tint(tint).interactive(isInteractive), in: shape)
                    .overlay(accessibleOutline)
            } else {
                content
                    .glassEffect(.regular.interactive(isInteractive), in: shape)
                    .overlay(accessibleOutline)
            }
        } else {
            content
                .background {
                    shape.fill(.regularMaterial)
                    if let tint {
                        shape.fill(tint.opacity(reducedTransparencyTintOpacity))
                    }
                }
                .overlay(accessibleOutline)
        }
    }

    private var reducedTransparencyTintOpacity: Double {
        contrast == .increased
            ? NotateDesign.Palette.opaqueSelectionFillOpacity
            : NotateDesign.Palette.tintedControlFillOpacity
    }

    private var accessibleOutline: some View {
        shape.stroke(
            Color.primary.opacity(
                NotateDesign.Hairline.opacity(for: contrast, subtle: true)
            ),
            lineWidth: NotateDesign.Hairline.width(for: contrast)
        )
    }
}

private struct NotateCardSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let isSelected: Bool
    let tint: Color
    let showsBackground: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: NotateDesign.Radius.card,
            style: .continuous
        )
        let shadow = reduceTransparency
            ? NotateDesign.Elevation.opaqueCard
            : NotateDesign.Elevation.card

        content
            .background {
                if isSelected {
                    if reduceTransparency {
                        shape.fill(NotateDesign.Palette.cardBackground)
                        shape.fill(
                            tint.opacity(NotateDesign.Palette.opaqueSelectionFillOpacity)
                        )
                    } else {
                        shape.fill(
                            tint.opacity(NotateDesign.Palette.selectionFillOpacity)
                        )
                    }
                } else if showsBackground {
                    shape.fill(
                        NotateDesign.Palette.cardBackground.opacity(
                            reduceTransparency
                                ? 1
                                : NotateDesign.Palette.translucentCardOpacity
                        )
                    )
                }
            }
            .overlay {
                if isSelected || showsBackground {
                    shape.strokeBorder(
                        isSelected
                            ? tint.opacity(NotateDesign.Hairline.selectedOpacity)
                            : Color.primary.opacity(
                                NotateDesign.Hairline.opacity(for: contrast, subtle: true)
                            ),
                        lineWidth: isSelected
                            ? max(2, NotateDesign.Hairline.width(for: contrast))
                            : NotateDesign.Hairline.width(for: contrast)
                    )
                }
            }
            .shadow(
                color: isSelected || showsBackground
                    ? .black.opacity(shadow.opacity)
                    : .clear,
                radius: shadow.radius,
                y: shadow.y
            )
    }
}

private struct NotatePanelSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: NotateDesign.Radius.panel,
            style: .continuous
        )
        let shadow = NotateDesign.Elevation.panel

        content
            .background {
                if reduceTransparency {
                    shape.fill(NotateDesign.Palette.background)
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay {
                shape.stroke(
                    Color.primary.opacity(
                        NotateDesign.Hairline.opacity(for: contrast)
                    ),
                    lineWidth: NotateDesign.Hairline.width(for: contrast)
                )
            }
            .shadow(
                color: .black.opacity(shadow.opacity),
                radius: shadow.radius,
                y: shadow.y
            )
    }
}

private struct NotateQuietSurfaceModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    let fillOpacity: Double
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background(.primary.opacity(fillOpacity), in: shape)
            .overlay {
                shape.strokeBorder(
                    .primary.opacity(
                        NotateDesign.Hairline.opacity(for: contrast, subtle: true)
                    ),
                    lineWidth: NotateDesign.Hairline.width(for: contrast)
                )
            }
    }
}

private struct NotateBadgeSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S

    func body(content: Content) -> some View {
        let shadow = NotateDesign.Elevation.compact

        content
            .background {
                if reduceTransparency {
                    shape.fill(NotateDesign.Palette.cardBackground)
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay {
                shape.stroke(
                    Color.primary.opacity(
                        NotateDesign.Hairline.opacity(for: contrast, subtle: true)
                    ),
                    lineWidth: NotateDesign.Hairline.width(for: contrast)
                )
            }
            .shadow(
                color: .black.opacity(shadow.opacity),
                radius: shadow.radius,
                y: shadow.y
            )
    }
}

private struct NotatePrimaryActionSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S

    func body(content: Content) -> some View {
        let elevation = NotateDesign.Elevation.primaryAction

        content
            .background {
                if reduceTransparency {
                    shape.fill(NotateDesign.Palette.accent)
                } else {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                NotateDesign.Palette.accent.opacity(0.88),
                                NotateDesign.Palette.accent,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                shape.stroke(
                    Color.white.opacity(contrast == .increased ? 0.46 : 0.22),
                    lineWidth: NotateDesign.Hairline.width(for: contrast)
                )
            }
            .shadow(
                color: NotateDesign.Palette.accent.opacity(elevation.opacity),
                radius: elevation.radius,
                y: elevation.y
            )
    }
}
