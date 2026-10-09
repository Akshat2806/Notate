#if DEBUG || NOTATE_INK_PROFILING
import Darwin
import Foundation
import UIKit

/// A rendered, paced workload rather than a loop of unpresented UIKit layouts.
/// The same fixture and zoom/pan sequence run in separate processes per mode.
/// Update time measures main-actor synchronization, not Pencil/Metal latency.
@MainActor
enum CanvasInkViewportProfile {
    struct ScrollReport: Codable {
        let buildConfiguration: String
        let workload: String
        let direction: String
        let logicalZoom: Double
        let pageCount: Int
        let updates: Int
        let maximumMountedPageHosts: Int
        let maximumIdleNativeEditors: Int
        let viewportViolationCount: Int
        let updateMedianMilliseconds: Double
        let updateP95Milliseconds: Double
        let samples: [Sample]
    }

    /// Constant zoom; two forward/back traversals, with presented frames and
    /// repeated visits to the same pages. This exercises recycling without
    /// disguising ordinary scroll work as a sequence of zoom/page jumps.
    static func runFixedScroll(direction: String, zoom: CGFloat, pageCount: Int,
                               idleEditorCount: () -> Int,
                               viewportViolationCount: () -> Int,
                               update: (CGFloat) -> Int) async throws -> ScrollReport {
        let steps = 2_048
        var durations: [Double] = []
        var samples: [Sample] = []
        var maximumMounted = 0
        var maximumIdle = 0
        var violations = 0
        try await Task.sleep(for: .seconds(5))
        for step in 0...steps {
            try Task.checkCancellation()
            let phase = CGFloat(step % 1_024) / 512
            let progress = phase <= 1 ? phase : 2 - phase
            let started = CACurrentMediaTime()
            let mounted = update(progress)
            durations.append((CACurrentMediaTime() - started) * 1_000)
            maximumMounted = max(maximumMounted, mounted)
            maximumIdle = max(maximumIdle, idleEditorCount())
            // Check after the next presented frame, including framework layout.
            try await Task.sleep(for: .milliseconds(16))
            violations += viewportViolationCount()
            if step.isMultiple(of: 128) {
                samples.append(Sample(completedCycles: step, physicalFootprintBytes: footprint(),
                                      mountedPageHosts: mounted, idleNativeEditors: idleEditorCount()))
            }
        }
        try await Task.sleep(for: .seconds(10))
        samples.append(Sample(completedCycles: steps, physicalFootprintBytes: footprint(),
                              mountedPageHosts: maximumMounted, idleNativeEditors: idleEditorCount()))
        let ordered = durations.sorted()
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release (profiling enabled)"
        #endif
        return ScrollReport(buildConfiguration: configuration, workload: "fixed-zoom-two-round-trips",
            direction: direction, logicalZoom: Double(zoom), pageCount: pageCount, updates: steps + 1,
            maximumMountedPageHosts: maximumMounted, maximumIdleNativeEditors: maximumIdle,
            viewportViolationCount: violations, updateMedianMilliseconds: ordered[ordered.count / 2],
            updateP95Milliseconds: ordered[Int(Double(ordered.count) * 0.95)], samples: samples)
    }

    struct Sample: Codable {
        let completedCycles: Int
        let physicalFootprintBytes: UInt64?
        let mountedPageHosts: Int
        let idleNativeEditors: Int
    }
    struct Report: Codable {
        let buildConfiguration: String
        let renderer: String
        let operatingSystem: String
        let viewportWidth: Double
        let viewportHeight: Double
        let pageCount: Int
        let cycles: Int
        let zoomSteps: [Double]
        let maximumMountedPageHosts: Int
        let maximumIdleNativeEditors: Int
        let viewportViolationCount: Int
        let updateMedianMilliseconds: Double
        let updateP95Milliseconds: Double
        let samples: [Sample]
    }

    static func run(renderer: String, pageCount: Int, viewportSize: CGSize,
                    idleEditorCount: () -> Int = { 0 },
                    viewportViolationCount: () -> Int = { 0 },
                    update: (CGFloat, CGPoint, Int) -> Int) async throws -> Report {
        var durations: [Double] = []
        var samples: [Sample] = []
        let environment = ProcessInfo.processInfo.environment
        let cycleCount = min(120, max(30, Int(environment["NOTATE_INK_PROFILE_CYCLES"] ?? "") ?? 30))
        let settleSeconds = min(15, max(1, Int(environment["NOTATE_INK_PROFILE_SETTLE_SECONDS"] ?? "") ?? 1))
        let zoomSteps: [CGFloat] = environment["NOTATE_INK_PROFILE_STRESS"] == "1"
            ? [0.6, 0.6, 1, 6, 8, 10, 10, 0.6] : [1, 6, 8, 10, 6, 1]
        var maximumMounted = 0
        var maximumIdle = 0
        var violations = 0
        // Let framework setup and first tiles settle before the initial sample.
        try await Task.sleep(for: .seconds(settleSeconds))
        for cycle in 0..<cycleCount {
            for (step, zoom) in zoomSteps.enumerated() {
                try Task.checkCancellation()
                let center = CGPoint(x: 0.48 + 0.02 * sin(Double(cycle)),
                                     y: 0.45 + 0.02 * cos(Double(cycle)))
                let started = CACurrentMediaTime()
                let mounted = update(zoom, center, cycle)
                durations.append((CACurrentMediaTime() - started) * 1_000)
                maximumMounted = max(maximumMounted, mounted)
                maximumIdle = max(maximumIdle, idleEditorCount())
                violations += viewportViolationCount()
                // Give Core Animation/PaperKit multiple presentation frames.
                try await Task.sleep(for: .milliseconds(50))
                if cycle == 0 && samples.isEmpty {
                    samples.append(Sample(completedCycles: 0, physicalFootprintBytes: footprint(),
                                          mountedPageHosts: mounted, idleNativeEditors: idleEditorCount()))
                }
                if step == zoomSteps.count - 1 && (cycle + 1).isMultiple(of: 10) {
                    samples.append(Sample(completedCycles: cycle + 1, physicalFootprintBytes: footprint(),
                                          mountedPageHosts: mounted, idleNativeEditors: idleEditorCount()))
                }
            }
        }
        try await Task.sleep(for: .seconds(settleSeconds))
        if let last = samples.last {
            samples[samples.count - 1] = Sample(completedCycles: cycleCount, physicalFootprintBytes: footprint(),
                                              mountedPageHosts: last.mountedPageHosts,
                                              idleNativeEditors: idleEditorCount())
        }
        let ordered = durations.sorted()
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release (profiling enabled)"
        #endif
        return Report(buildConfiguration: configuration, renderer: renderer, operatingSystem: UIDevice.current.systemVersion,
                      viewportWidth: Double(viewportSize.width), viewportHeight: Double(viewportSize.height),
                      pageCount: pageCount, cycles: cycleCount,
                      zoomSteps: zoomSteps.map(Double.init), maximumMountedPageHosts: maximumMounted,
                      maximumIdleNativeEditors: maximumIdle, viewportViolationCount: violations,
                      updateMedianMilliseconds: ordered[ordered.count / 2],
                      updateP95Milliseconds: ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))],
                      samples: samples)
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
#endif
