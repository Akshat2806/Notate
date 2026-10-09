# Native notebook ink: local validation

Paged notebooks use **Notebook viewport by default in Release**. The established
full-page PaperKit renderer remains selectable only in Debug for comparison:
add `NOTATE_NATIVE_PAGED_VIEWPORT = 0` under the Debug scheme's
**Run → Arguments**. Release builds always use Notebook viewport and ignore
that override. No notebook data or preference migration is required; freeform
boards retain their existing renderer.

## Stable native rendering window

Visibility and rendering are separate. A page uses a native window whose size
is capped by the page and screen dimensions; it does not shrink as the page
crosses a viewport edge. Fit pages move as complete native surfaces. Larger
zoomed pages retain a screen-sized authored crop. Insertion and overlays share
the rendering-window transform. Alignment checks the actual native content
projection, avoiding repeated fit corrections from rounded framework readbacks.
See [fixed-scroll validation](native-ink-viewport-fixed-scroll.md).

## Compare renderers in Debug

In Xcode, edit the Notate Debug scheme, select **Run → Arguments**, and add:

```text
NOTATE_NATIVE_PAGED_VIEWPORT = 0
```

This selects the established renderer in Debug only. Omit the variable or set
it to `1` to use Notebook viewport. Release always uses Notebook viewport.
Close and reopen the editor after changing it. Renderer selection is fixed for
each editor lifetime.

## Compare the same markup

Add this launch argument to a Debug run:

```text
--ink-viewport-experiment
```

This opens an isolated experiment without opening or writing to your library.
The fixture contains thin PencilKit strokes, a shape, text, and an image. Edits
carry across when switching renderers. The system tool picker and its insertion
button are available in all three modes:

| Mode | Purpose |
| --- | --- |
| Existing | Current notebook renderer, with a bounded native basis and outer magnification. |
| Native only | Standalone screen-sized PaperKit controller at the selected native zoom. |
| Notebook viewport | New notebook renderer, with native viewport synchronization. |

Compare at 100%, 600%, 800%, and 1000%. Use the same tool, width, and color.
Draw new strokes, watch them during contact, then lift and wait. Also compare
the supplied thin strokes, which are identical across modes. Textured pencil
and crayon grain should retain their native appearance; grain is distinct from
doubled contours or a resolution drop. Embedded images retain their source
resolution.

If standalone PaperKit is already blurry while writing, capture that result:
the notebook renderer cannot improve on a framework limitation in live ink.
If standalone is sharp but the notebook viewport is not, investigate viewport
geometry or gesture synchronization before considering a custom drawing engine.

## Acceptance checks on physical iPads

Run on both iPadOS 26 and 27. Record device model, OS build, tool/width, zoom,
page size/background, and renderer for any failure.

- **Ink:** no doubled contours; active and settled ink have comparable sharpness;
  immediate writing after a pinch does not jump, lose the first point, or resize
  the page during contact. Test pen, highlighter, and textured brushes.
- **Native features:** draw and hold lines/circles/rectangles; insert and edit
  text, images, and shapes; drag/resize/rotate selections; test lasso, pixel and
  stroke erasers, ruler, undo/redo, and tool-picker changes.
- **App overlays:** insert/move/resize tables, use compass/protractor and laser
  pointer, and make a Wand region selection. All positions must stay aligned
  after pan, zoom, and rotation.
- **Navigation:** test Pencil-only and finger-writing modes, including two-finger
  pan/pinch during finger writing. Cross page edges, show two pages, use vertical
  scrolling and horizontal paging, bounce at boundaries, switch pages, and
  rotate while zoomed. Selection gestures must still reach PaperKit.
- **Durability:** undo on one page after visiting another; reopen a saved mixed
  notebook; export PDF/image and compare content and placement. No duplicate ink
  or lost shapes, text, images, or strokes.
- **Resources:** in Instruments, compare the experiment's native-only and
  notebook-viewport modes using the same content. Perform at least 30 repeated
  100%↔1000% zoom/pan cycles, then repeat with a large notebook and an imported
  page. Inspect Allocations/VM and Time Profiler. Memory must plateau after
  caches warm; viewport updates and writing latency must remain comparable to
  the standalone native baseline. Also test recovery after a memory warning.

## Repeatable local resource comparison

For each mode, terminate and relaunch the app so framework caches from another
renderer do not bias the next run. Use both launch arguments:

```text
--ink-viewport-experiment
--ink-viewport-benchmark
```

Set `NOTATE_INK_PROFILE_MODE` to `native`, `notebook`, or `large` (a 1,000-page
notebook). Use the same device, orientation, configuration, and viewport size.
The default benchmark uses the same mixed fixture, 30 zoom/pan cycles through 1×, 6×,
8×, and 10×, and yields between updates so the framework can present frames.
The large run also visits 30 separated pages. The experiment's button can run
an additional profile manually. Controls are disabled while a run is active,
and leaving the experiment cancels it.

Each run writes `Documents/ink-viewport-profile.json` inside the app sandbox and
prints `INK_VIEWPORT_PROFILE` in the Xcode console. The report includes OS,
viewport, page count, median/p95 main-actor update time, physical footprint, and
mounted-host counts at cycles 0, 10, 20, and 30. Warm-cache memory (10→20→30)
should plateau; repeat at least three runs before drawing performance conclusions.
These timings measure viewport synchronization, **not** end-to-end Pencil,
GPU, or touch-to-display latency. Use Instruments on your iPad for those checks.
Simulator footprints are not a device memory budget.

## Optimized Release and a saved notebook

For local profiling only, build **Release** with `ENABLE_CODE_COVERAGE=NO` and
`CLANG_ENABLE_CODE_COVERAGE=NO` and the extra Swift compilation
condition `NOTATE_INK_PROFILING`. This preserves `-O`/whole-module optimization
and does not define `DEBUG`. Normal Release builds exclude the experiment,
fixture creation, and benchmark runners.

The experiment arguments and environment variables above work in this build.
Set `NOTATE_INK_PROFILE_CYCLES=120` and `NOTATE_INK_PROFILE_SETTLE_SECONDS=15`
for an extended fresh-process run. Set `NOTATE_INK_PROFILE_STRESS=1` to use
0.6×, 0.6×, 1×, 6×, 8×, 10×, 10×, 0.6×, including same-scale transitions.
Reports also record the exact workload, maximum mounted/idle editor counts,
and viewport geometry violations. Do not interact with the editor while its
automated benchmark is active; omit the benchmark argument for manual use.
For the real editor check, use:

```text
--ink-viewport-notebook
--ink-viewport-benchmark
```

This explicitly creates a dedicated **Viewport Performance · 1,000 pages**
notebook in the normal library, using its catalog, verified Canvas Core
checkpoint, previews, editor model, tool picker, and save/load paths. The notebook
has numbered native text, ink, an editable shape/image, six paper styles, three
paper tones, and tables every 25 pages. Subsequent runs reopen only its recorded
ID; they do not open another user's notebook. The benchmark restores its starting
viewport after completion. Omit the benchmark argument to inspect and write in
that notebook manually. Fixture creation is a separate warm-up: compare at least
three fresh-process reloads after it has been created. This is synthetic mixed
content, not a worst-case scanned PDF or photo-heavy notebook.

## Automated checks

`CanvasNativeViewportTests` covers geometry validity and round trips, actual
PaperKit viewport/zoom synchronization, pending-frame flush before contact,
deferred zoom during writing, overlay alignment, lifecycle cancellation, and
legacy/freeform isolation, lazy-host bounds at 2/32/1,000 pages, mixed-content
PDF export, remount tool/input/ruler state, page-local undo, rotation/paging,
contact cancellation, indexed-layout equivalence, and concurrent paper-tile
snapshot updates/drawing. Enable Thread Sanitizer for the tile stress test. Run the tests on both supported simulator versions:

```sh
xcodebuild -project Notate.xcodeproj -scheme Notate \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0' \
  -only-testing:NotateTests/CanvasNativeViewportTests test
```

Use an installed iPadOS 26 destination for the compatibility run. Simulator
tests cannot establish physical Pencil latency, prediction, pressure, or
draw-and-hold quality. Complete the physical checklist before distributing this build; simulator
checks do not establish handwriting quality or interaction latency on hardware.

## Verification recorded for this implementation

- The latest iOS 26.2 simulator regression run passed all 25
  `CanvasNativeViewportTests` and both `CanvasCheckpointConcurrencyTests`,
  including transient 50% zoom, stable page scrolling, same-zoom page changes,
  ruler margins, and save/navigation behavior. This is historical evidence from
  before the latest build-aware renderer gate, not a fresh pass for this exact
  branch state.
- Final Debug app and complete test target compile for arm64/x86_64 simulators.
- Final unsigned Debug and Release builds compile for physical iPads.
- The initial seven viewport tests passed on iPadOS 26.2 after fixing page-host
  teardown. All 18 expanded viewport tests passed on the physical iPad Air
  (5th generation) running iPadOS 27.0. The complete expanded iPadOS 26 runtime
  run remains pending because of the simulator failure described below.
- Independent native-viewport geometry checks passed 980 cases. An extracted,
  unchanged UIKit-independent layout implementation passed 2,134 differential
  layout, bounded-candidate, and mixed-contact/cancellation assertions.
- The final immutable paper snapshot store and drawing code passed 800 tile draws
  across four concurrent tasks during 200 snapshot replacements under macOS
  Thread Sanitizer, without findings. That source-only check uses macOS Core
  Animation and does not establish iPad/PaperKit drawing latency.
- Further simulator runtime tests and presented memory comparisons were blocked
  by CoreSimulator boot failures: `launchd failed to respond` and `could not bind
  to session`. A fresh isolated simulator reproduced the failure and was removed.
- See [the physical-device results](native-ink-viewport-device-results.md) for
  Release memory/timing measurements and rendered page-transition evidence.
- The opt-in physical UI gesture/Back test timed out enabling device automation
  before executing. Set `NOTATE_RUN_DEVICE_VIEWPORT_UI_TESTS=1` in the UI test
  runner environment and use the local `NOTATE_INK_PROFILING` build to run
  `NativeViewportNavigationUITests` against the dedicated saved notebook.
- On 2026-10-09, the current Debug app, unit-test bundle, and UI-test runner
  compiled and signed for the connected iPad. The test preflight then reported
  that the iPad was locked, so no assertions ran. The iOS 27 simulator build
  also compiled the app and test bundles, but its test session stalled before
  cases started and was canceled; no viewport assertions passed in that run.
- Physical Pencil quality, end-to-end latency, UI gesture/Back validation and
  complete iPadOS 26 coverage remain acceptance checks. This document does not
  claim Goodnotes parity or completed no-regression certification.

## Architecture notes

The outer scroll view retains page layout, navigation, and persisted zoom.
Visible PaperKit editors are unscaled siblings of the zoomed document view.
Each editor keeps its full, unchanged markup, receives the actual logical zoom,
and displays only the corresponding authored page rectangle. Navigation changes
are coalesced with a one-shot display link; the latest geometry is flushed at
contact onset and held during writing. Page controllers and native undo managers
are retained rather than recreated on zoom. Native notebooks always mount hosts
lazily. Visibility lookup uses binary-search bounds over the primary axis,
including unequal-sized legacy spreads. Geometry is cached until layout or
page order changes. Per-frame host and table work visits mounted pages only.
Visible/prefetched pages and protected editing state retain their controllers;
inactive hosts without history are retired even during finger navigation.
Existing bounded page-local undo retention and memory-pressure safeguards apply.

PaperKit and UIKit mutations stay on the main actor. Value-only viewport geometry
is Sendable and independent of actor isolation. Existing store/export actors keep
serialization and export work away from UIKit; no background task mutates live
PaperKit controllers. The display-link target holds its owner weakly, and
presentation work stops at dismantle. Paper tile inputs are immutable checked
Sendable snapshots, their geometry/artwork helpers are explicitly nonisolated,
and snapshot replacement/read uses `Synchronization.Mutex`; tile drawing releases
the lock before constructing paths. Finger/Pencil contact transitions and
recognizer resets release navigation locks exactly once. Host cleanup executes
explicitly on the main actor; a nonisolated host deallocator avoids an iOS 26
Swift runtime crash reproduced with the Xcode 27 compiler.

PaperKit 26 does not expose scroll configuration. The renderer establishes
navigation priority with public UIKit failure relationships on embedded
`UIScrollView` pan/pinch recognizers. It does not modify private classes,
drawing recognizers, selection recognizers, KVC properties, or rendering layers.
This discovery of embedded scroll views is a compatibility boundary: physical
pan/pinch and selection tests on both OS versions are required before rollout.

The paged path has no settled-ink preview or rasterization handoff. The same
native canvas draws during contact and after lift-off. Any rollout must keep
that invariant; overlaying an exported image on live ink can introduce doubled
edges and changes to highlighter blending.

## Scrolling and allocation corrections

Native lazy mounts give paper decorations their authored document frames, not
screen-sized editor frames at document zero. Same-zoom layout refreshes preserve
the document transform, bounds and projected center. Hidden hosts hide their
entire wrapper; newly visible hosts resolve native layout within the same actor
turn. Actual PaperKit zoom is synchronized after layout (the public iOS 27
scroll configuration, and public UIKit containment/zoom on iOS 26). Visible
rectangles tolerate at most one display pixel of scroll-offset rounding.

Only PaperKit's app-owned content view draws native notebook templates. Vector
paths are cached until the template or authored size changes; the document
background supplies paper tone and borders. Content-inset calculations use the
cached layout plan instead of rebuilding page geometry during every pan/zoom.
Back remains available during Reader handoff; editing actions remain disabled.

Safe idle native editors are recycled with a maximum of one per editor. Markup,
selection, content view and undo are cleared before reuse. Existing history,
insertion, active-selection and snapshot safety gates still protect page hosts.
Memory warnings clear the idle pool. At most one full checkpoint per editor can
serialize/verify at once; newer generations wait and coalesce to the latest
snapshot, preserving existing storage verification and document formats.

## Current implementation boundary — 2026-10-09

The latest recorded iOS 26.2 simulator run passed all 25 viewport tests and
both checkpoint-concurrency tests, and an unsigned iPadOS Release build
compiled before the latest renderer gate. The current Debug app and both test
bundles compiled and signed for the connected iPad, but it was locked at test
preflight. The current iOS 27 simulator session stalled before assertions and
was canceled. Notebook viewport is the Release default; Debug also defaults to
viewport and can select the established renderer with
`NOTATE_NATIVE_PAGED_VIEWPORT=0`.

The native renderer still mirrors zoom from the notebook scroll view; native
PaperKit does not yet own the active page's pinch. The model and checkpoint API
also still retain/decode full page snapshots. A metadata-only page repository,
encoded-payload reuse for unchanged pages, and the planned 16 MiB/32 MiB cache
bounds remain unimplemented. Physical iPadOS 26 interaction, Apple Pencil
latency, the 30-minute soak, and reliable compositor/frame-pacing measurements
remain release qualification work. The Release default does not imply these
checks passed. Use the Debug comparison above to diagnose renderer-specific
regressions; changing the Release renderer requires a source change and rebuild.

An Xcode 27 arm64 Release build succeeded before the latest Debug-only renderer
gate. Earlier device test attempts stalled while Xcode materialized test
workers; none produced assertions for those source revisions. The current
post-gate test attempts and their exact outcomes are recorded above. Earlier
passing results are historical evidence for the implementation state recorded
with those runs, not proof that the current branch passes every gate.
