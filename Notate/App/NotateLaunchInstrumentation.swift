import Foundation
import os

/// Signposts for separating catalog, recovery, maintenance, and first-screen
/// latency in Instruments. All calls occur on the app's main actor so launch
/// intervals retain a simple, ordered lifecycle.
@MainActor
enum NotateLaunchInstrumentation {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Notate",
        category: "Launch"
    )
    private static var libraryVisibilityInterval: OSSignpostID?

    static func beginLaunchToLibraryVisibility() {
        guard libraryVisibilityInterval == nil else { return }
        libraryVisibilityInterval = begin("Launch To Library Visible")
    }

    static func endLaunchToLibraryVisibility() {
        guard let identifier = libraryVisibilityInterval else { return }
        end("Launch To Library Visible", identifier)
        libraryVisibilityInterval = nil
    }

    static func begin(_ name: StaticString) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: identifier)
        return identifier
    }

    static func end(_ name: StaticString, _ identifier: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: identifier)
    }

    static func measure<Value>(
        _ name: StaticString,
        _ operation: () throws -> Value
    ) rethrows -> Value {
        let identifier = begin(name)
        defer { end(name, identifier) }
        return try operation()
    }

    static func measureAsync<Value>(
        _ name: StaticString,
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        let identifier = begin(name)
        defer { end(name, identifier) }
        return try await operation()
    }
}
