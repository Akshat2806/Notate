import SwiftUI
import UIKit

enum LibraryEmptyArtworkKind: Hashable, Sendable {
    case home
    case favorites
    case recent
    case trash
    case tag
    case folder
    case search
    case generic

    enum Fallback: Hashable, Sendable {
        case genericRaster
        case folderComposition
    }

    static func resolve(scope: LibraryScope, searchQuery: String) -> Self {
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .search
        }

        return switch scope {
        case .home: .home
        case .favorites: .favorites
        case .recent: .recent
        case .tag: .tag
        case .trash: .trash
        case .folder: .folder
        case .settings: .generic
        }
    }

    /// These stable names let the illustration set evolve independently from
    /// the empty-state layout. Missing assets fall back gracefully at runtime.
    var preferredAssetName: String? {
        switch self {
        case .home: "NotateEmptyHome"
        case .favorites: "NotateEmptyFavorites"
        case .recent: "NotateEmptyRecent"
        case .trash: "NotateEmptyTrash"
        case .tag: "NotateEmptyTag"
        case .folder: "NotateEmptyFolder"
        case .search: "NotateEmptySearch"
        case .generic: nil
        }
    }

    var fallback: Fallback {
        self == .folder ? .folderComposition : .genericRaster
    }

    var accessibilityLabel: String {
        switch self {
        case .home:
            "An open notebook ready for your first idea."
        case .favorites:
            "A star marking a saved notebook."
        case .recent:
            "A clock marking a recent note."
        case .trash:
            "An empty paper bin."
        case .tag:
            "A label ready to organize notes."
        case .folder:
            "An open folder waiting for notes."
        case .search:
            "A magnifying glass over an empty page."
        case .generic:
            "An empty workspace ready for notes."
        }
    }

    var illustrationSize: CGSize {
        CGSize(width: 276, height: 207)
    }
}

struct LibraryEmptyStateView: View {
    let scope: LibraryScope
    let searchQuery: String
    let onPrimaryAction: () -> Void

    private var artworkKind: LibraryEmptyArtworkKind {
        .resolve(scope: scope, searchQuery: searchQuery)
    }

    private var isSearching: Bool {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var scopeIsTag: Bool {
        if case .tag = scope { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 14) {
            LibraryEmptyArtwork(kind: artworkKind)
                .id(artworkKind)

            if case .folder = scope, isSearching == false {
                VStack(spacing: 7) {
                    Text("This Folder is Empty")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Tap + to add here, or move an item in.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            } else {
                Text(message)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
                    .accessibilityAddTraits(.isHeader)
            }

            if isSearching {
                Button("Clear Search", action: onPrimaryAction)
                    .buttonStyle(.bordered)
            } else if scope == .favorites || scope == .recent || scopeIsTag {
                Button("Open Home", action: onPrimaryAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .offset(y: -8)
    }

    private var message: String {
        if isSearching {
            return "Nothing matches this search."
        }
        return switch scope {
        case .home:
            "A clear page for your next idea."
        case .favorites:
            "Star a note or folder to keep it close."
        case .recent:
            "Open a note and it will appear here."
        case .tag:
            "Add this tag to a note to see it here."
        case .trash:
            "Trash is empty."
        case .settings:
            ""
        case .folder:
            "Add something with +, or move an item into this folder."
        }
    }
}

private struct LibraryEmptyArtwork: View {
    let kind: LibraryEmptyArtworkKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        artwork
            .frame(maxWidth: kind.illustrationSize.width)
            .frame(maxWidth: .infinity)
            .frame(height: kind.illustrationSize.height)
            .opacity(hasAppeared ? 0.96 : 0)
            .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.978)
            .offset(y: reduceMotion || hasAppeared ? 0 : 6)
            .accessibilityHidden(true)
            .onAppear {
                guard hasAppeared == false else { return }
                withAnimation(reduceMotion ? nil : NotateDesign.Motion.content) {
                    hasAppeared = true
                }
            }
    }

    @ViewBuilder
    private var artwork: some View {
        if let assetName = availablePreferredAssetName {
            rasterArtwork(named: assetName)
        } else {
            switch kind.fallback {
            case .genericRaster:
                rasterArtwork(named: "NotateEmptyLibrary")
            case .folderComposition:
                LibraryEmptyFolderIllustration()
            }
        }
    }

    private var availablePreferredAssetName: String? {
        guard let assetName = kind.preferredAssetName,
              UIImage(named: assetName) != nil
        else {
            return nil
        }
        return assetName
    }

    private func rasterArtwork(named assetName: String) -> some View {
        // Each asset catalog entry supplies a matching luminosity variant,
        // allowing UIImage to resolve coordinated artwork in either mode.
        rasterImage(named: assetName)
    }

    private func rasterImage(named assetName: String) -> some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(maxWidth: kind.illustrationSize.width)
    }
}

/// A small native fallback if the folder illustration asset cannot be loaded.
/// It deliberately avoids texture and heavy shadows.
private struct LibraryEmptyFolderIllustration: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LibraryFolderArtwork(
                symbolName: "folder",
                color: LibraryRGBAColor.folderBlue.swiftUIColor,
                showsBackdrop: false
            )
            .frame(width: 214, height: 146)
            .offset(y: 22)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.96))
                .frame(width: 88, height: 70)
                .rotationEffect(.degrees(-5))
                .overlay {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(.secondary.opacity(0.42)).frame(width: 52, height: 3)
                        Capsule().fill(.secondary.opacity(0.30)).frame(width: 36, height: 3)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.24), lineWidth: 1)
                }
            .offset(y: -39)

            Image(systemName: "sparkle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .offset(x: 100, y: -42)
        }
    }
}
