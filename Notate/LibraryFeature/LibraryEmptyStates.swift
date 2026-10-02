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
    /// Offered on Home and in folders, where creating something is the
    /// obvious next step. Nil hides the buttons.
    var onNewNotebook: (() -> Void)? = nil
    var onImportDocument: (() -> Void)? = nil

    private var artworkKind: LibraryEmptyArtworkKind {
        .resolve(scope: scope, searchQuery: searchQuery)
    }

    private var isSearching: Bool {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var offersCreation: Bool {
        if case .folder = scope { return true }
        return scope == .home
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
                    Text("Add something new or move an item here.")
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
            } else if let onNewNotebook, offersCreation {
                HStack(spacing: 12) {
                    Button(action: onNewNotebook) {
                        Label("New Notebook", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("library.empty.new-notebook")
                    if let onImportDocument {
                        Button(action: onImportDocument) {
                            Label("Import PDF", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("library.empty.import")
                    }
                }
                .padding(.top, 4)
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
            "Start creating your first note here."
        case .favorites:
            "Your favorites will appear here."
        case .recent:
            "No notes were used in this time range."
        case .tag:
            "No notes with this tag yet."
        case .trash:
            "Trash is empty."
        case .settings:
            ""
        case .folder:
            "This folder is empty. Add something new or move an item here."
        }
    }
}

private struct LibraryEmptyArtwork: View {
    let kind: LibraryEmptyArtworkKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        artwork
            .frame(
                width: kind.illustrationSize.width,
                height: kind.illustrationSize.height
            )
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
        // The editorial assets carry their own restrained cream, ink, and
        // pastel palette. Rendering those authored colors unchanged keeps skin
        // tones and background fields stable in both Light and Dark Mode.
        rasterImage(named: assetName)
    }

    private func rasterImage(named assetName: String) -> some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
    }
}

/// A temporary flat composition used only until `NotateEmptyFolder` is added
/// to the asset catalog. It deliberately avoids texture and heavy shadows.
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
