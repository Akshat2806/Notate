# Dense ink device results — 2026-10-10

## Changes exercised

The viewport mount now computes the page's initial native crop before PaperKit loads its view, so a newly mounted page does not start with a full-page crop and immediately switch to the visible crop. PaperKit stage signposts now separate markup assignment, selection reset, crop, zoom range, view load, and attachment. A profiling-only environment switch, `NOTATE_INK_DISABLE_CONTROLLER_REUSE=1`, supports comparing newly created controllers with the reused-controller path; it does not change the normal Release default.

## Quick Note Copy

On Akshat's iPad Air (5th generation), iPadOS 27.0 (24A437), the physical-device UI regression found a 17-page Quick Note Copy. Its densest page was page 9, with 1,885 strokes and page ID `294A14C8-EB13-477B-98BA-37D81F92AFD6`. Pages 10–16 each had 1,852–1,853 strokes. The test visited that page, captured 1000%, 600%, 100%, and 50% zoom, then captured the 50% page immediately and at 100 ms, 250 ms, 1 s, 5 s, and 10 s. The page remained fully populated in those captures; the test also scrolled forward and backward across the adjacent dense pages. This is screenshot-based UI evidence, not a continuous gesture video or an Apple Pencil latency measurement.

The UI test result is `/private/tmp/NotateDenseViewportSeedProfileUITestDerived/Logs/Test/Test-Notate-2026.10.10_10-48-28-+0530.xcresult`. Its exported screenshots and geometry attachments are in `/private/tmp/NotateDenseDenseUITestAttachments/`.

## Release scroll profile

The fixed-zoom Release profiling workload used a separate 40-page Quick Note-derived notebook with 1,000 strokes on each page and two forward/back traversals. It recorded 2,049 app viewport-update callbacks over about 43 seconds. These callback measurements are not compositor frame timing.

| Controller setup | Callback p95 | Callbacks >33 ms | Peak physical footprint | Result |
|---|---:|---:|---:|---|
| Reuse loaded PaperKit controller | 29.9 ms | 77 / 2,049 (3.8%) | 964.6 MiB | Fails the 4 ms / 1% targets |
| Create a fresh controller (profiling A/B) | 26.4 ms | 57 / 2,049 (2.8%) | 912.5 MiB | Better callback tail and peak in this run; still fails both targets |

The detailed trace attributed about 29 ms median to replacing markup on a loaded controller and about 13.6 ms median to setting its content crop. In the fresh-controller run those assignments took under 0.04 ms, but loading the PaperKit view took about 34.5 ms median and 40.2 ms at p95. The cost moved rather than disappeared. The fresh-controller path remains a profiling experiment until a longer memory and frame-time soak establishes whether it is safe to adopt.

Trace and report files are in `/private/tmp/NotateDenseStage.trace`, `/private/tmp/NotateDenseStageProfile.json`, `/private/tmp/NotateDenseNoReuse.trace`, `/private/tmp/NotateDenseNoReuseProfile.json`, and their matching `*Signposts.xml` files.

## Automated checks

The final iPad run passed 46 tests: 42 `CanvasNativeViewportTests` and 4 `CanvasCheckpointConcurrencyTests`, with zero failures or skips. The UI regression `testQuickNoteDenseCopiedPageZoomOutKeepsFullSurfaceRendered` also passed separately. The test bundle is `/private/tmp/NotateDenseFinalTests/Logs/Test/Test-Notate-2026.10.10_11-08-16-+0530.xcresult`.

## Release gates still open

- The 40-page profile misses the callback thresholds. It did not measure physical compositor frame pacing or Apple Pencil input-to-presentation latency.
- No 30-minute scroll/pinch/write/save soak has run, and the 5,000- and 10,000-stroke active-page cases remain untested.
- The v7 repository is still not integrated into the regular editor, Reader, indexing, preview, and export paths. Those paths retain full v6 page snapshots; the 96 MiB aggregate markup and 60-photo-page limits remain intentionally in place.
- The 500-page cases currently exercise the repository tests, not the live editor. iPadOS 26 validation is unavailable in this device run.

Do not treat the current measurements as a pass for release or merge. Continue with lazy repository integration and separately instrument compositor timing before deciding whether to change controller reuse in Release.

## Fast-scroll and zoom follow-up

The viewport now retains PaperKit's authored render crop while the visible page rectangle stays inside a screen-space scroll buffer. It rebases the crop only at the buffer edge. The page window also mounts one PaperKit host ahead in the current scroll direction, so its initial crop and template are configured before that page enters view. Speculative mounting is disabled under memory pressure. A new crop signpost records the cost when a rebase does occur, and the Quick Note Copy UI regression captures immediate screenshots during repeated fast scroll reversals and 50%↔1000% zoom changes.

The standalone viewport geometry harness passed buffer coverage, crop retention, edge rebasing, and coordinate round-trip checks. All changed Swift sources passed the parser. This follow-up has **not** been run on the iPad: Xcode's current `xcdevice list` sees only the Mac, `devicectl` times out, and `build-for-testing` is blocked by malformed SwiftData/Observation/SwiftUI macro-server responses in the installed Xcode 27 toolchain. Therefore the new fast-scroll UI regression, continuous-motion recordings, and post-change frame/memory profile remain outstanding.
