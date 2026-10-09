import XCTest
import PaperKit
@testable import Notate

@MainActor
private final class PausedCanvasCheckpointStore: CanvasCoreCheckpointing {
    private var snapshot: CanvasCoreSnapshot
    private var firstCheckpoint: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var startedGenerations: [Int64] = []
    private(set) var maximumActiveAttempts = 0
    private var activeAttempts = 0

    init(snapshot: CanvasCoreSnapshot) { self.snapshot = snapshot }
    func load() async -> CanvasCoreLoadResult { .restored(snapshot) }
    func checkpoint(_ snapshot: CanvasCoreSnapshot) async throws {
        activeAttempts += 1
        maximumActiveAttempts = max(maximumActiveAttempts, activeAttempts)
        startedGenerations.append(snapshot.generation)
        defer { activeAttempts -= 1 }
        if startedGenerations.count == 1 {
            await withCheckedContinuation { continuation in
                firstCheckpoint = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        self.snapshot = snapshot
    }
    func waitForFirstCheckpoint() async {
        guard firstCheckpoint == nil else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func releaseFirstCheckpoint() {
        firstCheckpoint?.resume()
        firstCheckpoint = nil
    }
}

@MainActor
final class CanvasCheckpointConcurrencyTests: XCTestCase {
    func testPageNavigationPersistsFocusWithoutCheckpointingMarkup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = (0..<3).map { _ in CanvasPageSnapshot(markup: PaperMarkup(
            bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))) }
        let store = PausedCanvasCheckpointStore(snapshot: CanvasCoreSnapshot(
            generation: 1, pages: pages, currentPageID: pages[0].id))
        let preferences = CanvasPreferencesStore(rootURL: root)
        let model = CanvasEditorModel(checkpointStore: store,
            preferencesStore: preferences,
            autosaveTiming: CanvasAutosaveTiming(trailingDelay: .seconds(30),
                forcedDelay: .seconds(30), preferencesDelay: .milliseconds(1)))
        await model.start()
        model.callbacks.focusedPageChanged(pages[2].id)
        await model.retrySave()
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(store.startedGenerations.isEmpty)
        let restoredPreferences = await preferences.load()
        XCTAssertEqual(restoredPreferences.currentPageID, pages[2].id)
    }

    func testRulerToolbarSlotTogglesPaperKitRulerWithoutOpeningAnInstrumentPanel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = CanvasPageSnapshot(markup: PaperMarkup(
            bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)))
        let store = PausedCanvasCheckpointStore(snapshot: CanvasCoreSnapshot(
            generation: 1, pages: [page], currentPageID: page.id))
        let model = CanvasEditorModel(
            checkpointStore: store,
            preferencesStore: CanvasPreferencesStore(rootURL: root),
            autosaveTiming: CanvasAutosaveTiming(
                trailingDelay: .seconds(30),
                forcedDelay: .seconds(30),
                preferencesDelay: .seconds(30)
            )
        )
        await model.start()

        model.handle(.tapGeometryToolSlot)
        XCTAssertEqual(model.activeGeometryTool, .ruler)
        XCTAssertEqual(model.overlay, .none)

        model.handle(.tapGeometryToolSlot)
        XCTAssertNil(model.activeGeometryTool)
        XCTAssertEqual(model.overlay, .none)
    }

    func testInkCheckpointsWaitUntilContactEndsAndCoalesceGenerations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = (0..<3).map { _ in CanvasPageSnapshot(markup: PaperMarkup(
            bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))) }
        let store = PausedCanvasCheckpointStore(snapshot: CanvasCoreSnapshot(
            generation: 1, pages: pages, currentPageID: pages[0].id))
        let model = CanvasEditorModel(checkpointStore: store,
            preferencesStore: CanvasPreferencesStore(rootURL: root),
            autosaveTiming: CanvasAutosaveTiming(trailingDelay: .seconds(30),
                forcedDelay: .seconds(30), preferencesDelay: .seconds(30)))
        await model.start()
        XCTAssertEqual(model.launchState, .ready)
        model.callbacks.interactionBegan(pages[1].id)
        model.callbacks.markupChanged(pages[1].id, markup(revision: 1, from: pages[1].markup))
        XCTAssertEqual(model.saveState, .saving)
        // Ink is already published in memory, but no full notebook snapshot
        // should begin while the Pencil contact is still active.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.startedGenerations.isEmpty)
        model.callbacks.snapshotContactEnded()
        let first = Task { await model.retrySave() }
        await store.waitForFirstCheckpoint()
        // Several later strokes and concurrent explicit/lifecycle saves must
        // not start duplicate encodes or publish intermediate markup.
        model.callbacks.interactionBegan(pages[2].id)
        model.callbacks.markupChanged(pages[2].id, markup(revision: 2, from: pages[2].markup))
        model.callbacks.snapshotContactEnded()
        let second = Task { await model.retrySave() }
        model.callbacks.interactionBegan(pages[0].id)
        model.callbacks.markupChanged(pages[0].id, markup(revision: 3, from: pages[0].markup))
        model.callbacks.snapshotContactEnded()
        let lifecycle = Task { await model.flushForLifecycle() }
        for _ in 0..<20 { await Task.yield() }
        let pending = store.startedGenerations
        XCTAssertEqual(pending, [2])
        store.releaseFirstCheckpoint()
        await first.value
        await second.value
        await lifecycle.value
        let generations = store.startedGenerations
        let maximum = store.maximumActiveAttempts
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(generations, [2, 4])
        guard case let .restored(snapshot) = await store.load() else { return XCTFail("Missing verified checkpoint") }
        XCTAssertEqual(snapshot.currentPageID, pages[0].id)
        XCTAssertEqual(snapshot.generation, 4)
        XCTAssertNotEqual(snapshot.pages, pages)
    }

    private func markup(revision: Int, from source: PaperMarkup) -> PaperMarkup {
        var value = source
        value.insertNewTextbox(
            attributedText: NSAttributedString(string: "Ink revision \(revision)"),
            frame: CGRect(x: 60, y: CGFloat(100 + revision * 24), width: 300, height: 20)
        )
        return value
    }
}
