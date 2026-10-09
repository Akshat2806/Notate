import SwiftUI

enum NotateAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User-facing defaults shared by Settings and newly created documents.
/// Existing documents retain their own saved canvas preferences.
enum NotatePreferences {
    static let appearanceKey = "notate.settings.appearance"
    static let drawWithFingerKey = "notate.settings.drawWithFingerByDefault"
    static let scrollDirectionKey = "notate.settings.defaultScrollDirection"

    static var defaultCanvasPreferences: CanvasPreferences {
        CanvasPreferences(
            inputMode: drawWithFingerByDefault ? .pencilAndFinger : .pencilOnly,
            pageLayout: CanvasPageLayoutPreferences(
                scrollDirection: defaultScrollDirection,
                pageDisplayMode: .singlePage
            )
        )
    }

    static var defaultPaperTemplate: CanvasPaperTemplate {
        CanvasPaperTemplate(style: .blank, tone: .paperWhite)
    }

    static var drawWithFingerByDefault: Bool {
        UserDefaults.standard.bool(forKey: drawWithFingerKey)
    }

    static var defaultScrollDirection: CanvasScrollDirection {
        guard let stored = UserDefaults.standard.string(forKey: scrollDirectionKey) else {
            return .vertical
        }
        return CanvasScrollDirection(rawValue: stored) ?? .vertical
    }

    static var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, build.isEmpty == false else { return version }
        return "\(version) (\(build))"
    }
}

@main
struct NotateApp: App {
    var body: some Scene {
        // Keep the WindowGroup factory free of application state. SwiftUI may
        // evaluate this synchronous template on its AsyncRenderer executor;
        // capturing @State, @AppStorage, or the @MainActor coordinator here
        // adds a dynamic MainActor precondition and traps before launch.
        WindowGroup {
            NotateAppRoot()
        }
    }
}

private struct NotateAppRoot: View {
    @AppStorage(NotatePreferences.appearanceKey)
    private var appearance = NotateAppearance.system
    @State private var bootstrapState: NotateApplicationCoordinator.BootstrapState?

    var body: some View {
        root
            .preferredColorScheme(
                NotateUITestLaunchConfiguration.forcesDarkAppearance
                    ? .dark
                    : appearance.colorScheme
            )
            .task { @MainActor in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--folder-reference-preview") { return }
                #endif
                #if DEBUG || NOTATE_INK_PROFILING
                if ProcessInfo.processInfo.arguments.contains("--ink-viewport-experiment") { return }
                #endif
                // Let SwiftUI commit the lightweight opening screen before
                // synchronous SwiftData container and repository setup. That
                // work can otherwise consume the scene-creation watchdog's
                // first-frame budget on slower devices.
                await Task.yield()
                guard bootstrapState == nil else { return }
                NotateLaunchInstrumentation.beginLaunchToLibraryVisibility()
                bootstrapState = NotateApplicationCoordinator.bootstrap()
            }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--folder-reference-preview") {
            LibraryFolderDebugPreview()
        } else if ProcessInfo.processInfo.arguments.contains("--ink-viewport-experiment") {
            CanvasInkViewportExperiment()
        } else {
            applicationRoot
        }
        #else
        #if NOTATE_INK_PROFILING
        if ProcessInfo.processInfo.arguments.contains("--ink-viewport-experiment") {
            CanvasInkViewportExperiment()
        } else {
            applicationRoot
        }
        #else
        applicationRoot
        #endif
        #endif
    }

    @ViewBuilder
    private var applicationRoot: some View {
        switch bootstrapState {
        case nil:
            ProgressView("Opening Notate")
                .accessibilityIdentifier("notate-startup-progress")
        case .ready(let application):
            NotateRootView(application: application)
        case .unavailable:
            ContentUnavailableView {
                Label("Notate Couldn't Start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(
                    "Notate couldn't initialize its protected local library. "
                        + "Your saved files were not replaced. Make sure your iPad has "
                        + "free storage, then try again or reopen Notate."
                )
            } actions: {
                Button("Try Again") {
                    bootstrapState = NotateApplicationCoordinator.bootstrap()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
