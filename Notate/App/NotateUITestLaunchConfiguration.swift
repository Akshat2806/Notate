import Foundation

/// Deliberately small launch contract shared by the app and `NotateUITests`.
/// Keeping it environment-based prevents test data from leaking into a real
/// user's persistent catalog and lets each test launch a clean process.
enum NotateUITestLaunchConfiguration {
    static var isEnabled: Bool {
        #if DEBUG
        isEnabled(environment: ProcessInfo.processInfo.environment)
        #else
        false
        #endif
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        environment["NOTATE_UI_TESTING"] == "1"
    }

    static var seedFixture: Bool {
        isEnabled
            && ProcessInfo.processInfo.environment["NOTATE_UI_TEST_SEED"] == "fixture"
    }

    static var forcesDarkAppearance: Bool {
        isEnabled
            && ProcessInfo.processInfo.environment["NOTATE_UI_TEST_APPEARANCE"] == "dark"
    }

    static var suppressesInitialFocus: Bool {
        isEnabled
            && ProcessInfo.processInfo.environment["NOTATE_UI_TEST_SUPPRESS_AUTOFOCUS"] == "1"
    }

    static var isolatedLibraryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "Notate-UITests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    }
}
