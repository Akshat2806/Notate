# Native notebook viewport: device results

**Follow-up:** The fixed-zoom manual scrolling report prompted another renderer
correction. See [fixed-scroll findings and new evidence](native-ink-viewport-fixed-scroll.md).
The results below describe the earlier implementation, before that correction.

The page/background defects have concrete fixes. Three final optimized Release
saved-notebook stress runs completed with zero viewport violations and bounded
editor counts. This report does not certify Goodnotes parity,
Pencil latency, or an acceptable memory budget for the largest notebooks.

## Device and workload

Physical iPad Air (5th generation, M1, 8 GB), iPadOS 27.0 (24A437), Xcode 27.
The saved **Viewport Performance · 1,000 pages** notebook uses the normal library,
verified Canvas Core checkpoint, editor, tool picker, persistence and previews.
Each A4 page has native ink, numbered editable text, a shape and image; six paper
styles and three tones vary by page, with a table every 25 pages. This notebook
is explicitly created test content. Other notebooks were not selected or edited.

The final profiling build uses Release `-O`, whole-module optimization, no
`DEBUG`, `ENABLE_CODE_COVERAGE=NO`, and `CLANG_ENABLE_CODE_COVERAGE=NO`.
`NOTATE_INK_PROFILING` includes only the local benchmark/fixture entry points.
A separate normal signed Release build compiles with those entry points excluded.
Earlier optimized diagnostics also used Release, but some had code coverage
instrumentation: treat them as diagnostics, not a controlled production A/B.

## Corrections and resource bounds

- Lazy page backgrounds immediately use their authored A4 position and size.
  They previously used the screen-sized editor frame at document zero.
- Same-zoom layout refreshes preserve the zoomed document transform and projected
  center. They previously reset the transform while the scroll view retained
  its old zoom, making paper, ink and viewport coordinates disagree.
- Native hosts synchronize actual PaperKit zoom after layout, hide the complete
  wrapper offscreen, and tolerate one display pixel of scroll-offset rounding.
  Writing freezes viewport changes; pending navigation is flushed before contact.
- The native content view owns paper patterns. Its vector paths are cached until
  authored size/style changes; the document decoration supplies tone and borders.
  Cached layout plans avoid page-array/layout reconstruction during pan/zoom.
- Safe idle native editors are reused, capped at four per editor. Selection,
  markup, content views and undo are cleared between pages. Page-local undo and
  active insertion/editing protections remain; memory warnings empty the pool.
- One full checkpoint per editor can serialize/verify at once. New generations
  wait without capturing another full notebook and coalesce to the latest state.
  Existing storage formats, resource admission and verification remain intact.
- Back remains available during a Reader transition. Other editor actions still
  wait for the handoff. No custom stroke engine or Metal renderer was introduced.

## Verification status

All **52 substantive checks passed** in the final physical-iPad run (32.28 s):
18 viewport tests, 33 existing canvas tests, and one save-concurrency test.
This includes native zoom, geometry round trips, same-zoom page transitions,
rotation/horizontal paging, mixed-content export, tool/ruler state, undo/remount,
memory-warning pool eviction, concurrent tile drawing, and artwork page bounds.
The save test pauses one checkpoint, requests newer focus generations plus a
lifecycle flush, and verifies one active attempt with only the latest subsequent
generation durably published. [Test summary](native-ink-viewport-evidence/final-release/final-regression-summary.json).

The scrolling test runs in a real UIWindow, presents frames between page moves,
and captures the page surfaces. Its snapshots show separate A4 sheets, correct
alternating templates and the authored page gap, without a center background
spilling into the next sheet. Test-only construction of 1,000 unique mixed-content
fixtures now drains temporary image allocations and yields between batches.
An earlier interrupted runner was killed, and a stale Xcode GUI debugger launch
blocked subsequent installs; those incomplete runs are not counted as passing.

Both final physical UI tests **passed** (92.87 s combined): actual finger drags
advance the page indicator, pinch gestures zoom in/out, three Back/library/reopen
cycles succeed, Reader then Back succeeds, and the canvas presents portrait and
landscape bounds. These gesture tests use the Debug profiling-enabled test app;
the resource comparisons below use the optimized Release app. The passing
rotation check used the actual canvas bounds, with the device flat and Rotation
Lock off. Earlier selector/orientation attempts are not counted as passing.
[Test summary](native-ink-viewport-evidence/final-release/final-navigation-summary.json)
and [device screenshots](native-ink-viewport-evidence/device-gesture-snapshots).

Expanded physical iPadOS 26 checks, real Pencil prediction/pressure,
draw-and-hold, selection/erasers, and end-to-end writing latency still require
manual acceptance. The tests do not certify every handwriting interaction. The Debug fixture
creation run also emitted PaperKit warnings about finding imported synthetic
strokes; rendered dense-ink coverage is not established by those fixtures.
Real Pencil-created ink must be included in the next rendering/latency check.

## Final saved-notebook Release stress

Three fresh processes each ran 120 cycles, 960 updates through
0.6×/0.6×/1×/6×/8×/10×/10×/0.6× and 120 separated pages, with 15-second
settling before/after. The normal editor viewport was 1180×820 points.
All three reported **zero geometry violations**, at most **three mounted page
hosts** and **four idle native editors**. These counts describe this unedited
workload; edited-page undo retention has a separate eight-host limit.

| Run | Median sync (ms) | p95 sync (ms) | Sampled peak (MiB) | Settled footprint (MiB) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3.39 | 30.62 | 587.7 | 324.3 |
| 2 | 3.64 | 30.44 | 596.7 | 322.3 |
| 3 | 3.64 | 32.73 | 627.4 | 309.3 |

The samples oscillated rather than increasing continuously with visited pages,
and settled footprints were similar across runs. This supports bounded editor
reuse for this workload. It does **not** prove a leak-free process or an acceptable
budget for image/PDF-heavy content: sparse samples underestimate true peaks, the
model retains the complete decoded document, and synchronization spikes remain.
The default Canvas Core admission limits remain 1,000 pages, 96 MiB aggregate
markup, 128 MiB encoded checkpoints/imported sources, and 256 MiB serialized
working set. Encoded budgets do not bound decoded/GPU memory.

The same UIKit content-offset constraint warning appeared in the final large
runs. Zero geometry violations do not resolve that warning or prove frame pacing.
[Final raw reports](native-ink-viewport-evidence/final-release) retain every sample.

## Final identical-content renderer comparison

Three fresh processes per mode used the same mixed fixture, 30 cycles through
1×/6×/8×/10×/6×/1×, and the same 1180×571.5-point viewport. The large
experiment uses shared fixture markup; it is lighter than the saved unique-page
notebook and excludes the normal library/save workload. All runs reported zero
geometry violations. The table shows ranges across three runs.

| Mode | Median sync (ms) | p95 sync (ms) | Sampled peak (MiB) | Settled footprint (MiB) |
| --- | ---: | ---: | ---: | ---: |
| Native only, 1 page | 1.63–1.72 | 24.03–25.31 | 70.91–73.66 | 59.38–65.05 |
| Notebook viewport, 1 page | 7.34–8.16 | 15.99–16.30 | 76.02–82.08 | 63.80–66.20 |
| Notebook viewport, 1,000 pages | 7.70–8.27 | 30.17–30.71 | 190.81–197.31 | 120.31–151.70 |

Notebook synchronization adds main-actor work compared with standalone PaperKit.
Its one-page p95 was lower in this workload, while the large notebook incurred
page-mounting/template transitions. These figures do not measure handwriting
latency or frame pacing, and support no claim of Goodnotes or native performance
parity. Resource qualification remains incomplete for heavy imports and real
Pencil interaction.

## Earlier memory diagnostics

Earlier 120-cycle full-editor runs retained two mounted page editors, recovered
memory after settling, and had substantial temporary physical-footprint peaks.
One later projection-only run sampled approximately **922 MiB**. A controller
pool alone did not prove a footprint reduction. These peaks are retained as
failures to meet a lightweight budget, not omitted as outliers.

A presented Release probe with 30 stress cycles through 60%–1000%, before the
single-checkpoint change, reported **zero geometry violations**, a maximum of
three mounted/four idle editors, median synchronization 3.66 ms and p95 40.39 ms.
Sampled footprint was 409/331/556/474 MiB. That build had coverage instrumentation;
its timing and memory are not the final production result.

An Allocations capture of an earlier active run showed substantial temporary
IOSurface churn and PaperKit tool-list helpers surviving editor construction.
This motivated bounded editor reuse. The trace is allocation evidence, not proof
of an application retain cycle or a completed leak audit. Serialized checkpoint
budgets bound encoded data, not the complete decoded/GPU/process footprint.

Very large scroll offsets still triggered UIKit’s internal content-offset
constraint warning in earlier runs. Explicit frames alone did not remove it.
It must be tracked alongside the final large-notebook visual/gesture checks;
no private framework constraints or selectors were modified to hide the warning.

## Reproducibility and outstanding checks

[Validation procedure](native-ink-viewport-validation.md) contains flags and
acceptance checks. [Raw earlier reports](native-ink-viewport-evidence/earlier-release)
retain samples and outliers. [Rendered window captures](native-ink-viewport-evidence/window-snapshots)
come from the physical UIKit regression, not hardware latency measurement.
[Source hashes](native-ink-viewport-evidence/source-hashes.json) identify the
uncommitted implementation being evaluated.

The final comparison is three fresh-process runs each of standalone
native, one-page notebook viewport and 1,000-page notebook viewport. The three
120-cycle saved-notebook stress runs completed as reported above.
Geometry violations must stay zero and editor counts bounded. Physical footprint
samples are sparse and are lower bounds on true peaks. Main-actor synchronization
measurements exclude end-to-end Pencil/GPU latency; frame smoothness, handwriting
features and photo/PDF-heavy imports still require interaction checks. Back/Reader
and basic physical navigation passed the automated checks above.

The normal signed Release app was installed and launched with an empty argument
list and no benchmark environment. Its installed-bundle process remained alive
after launch. The dedicated notebook remains in the library as **Viewport
Performance · 1,000 pages**. The older test-installation process was stopped.
[Launch record](native-ink-viewport-evidence/final-release/normal-release-launch.json).

## Additional Release rerun after device storage was freed

On 2026-10-09, the saved 1,000-page Release fixture completed another fresh
120-cycle stress run on the same iPad Air 5 / iPadOS 27.0 after the user freed
device storage. The workload used 960 updates through
0.6×/0.6×/1×/6×/8×/10×/10×/0.6×, with a 1180×820-point viewport. It reported
zero viewport violations, at most three mounted page hosts and one idle native
editor.

| Median sync (ms) | p95 sync (ms) | Highest sampled footprint (MiB) | Final footprint (MiB) |
| ---: | ---: | ---: | ---: |
| 1.18 | 42.42 | 566.5 at startup | 204.9 |

The footprint samples were 566.5, 316.4, 311.9, 317.6, 277.0, 292.2, 303.8,
292.3, 324.1, 304.1, 286.3, 322.0 and 204.9 MiB at cycles 0 through 120 in
steps of 10. This run did not show increasing memory with repeated visits, but
its p95 synchronization time regressed beyond the previous three-run range and
the 4 ms target. UIKit again warned that a constraint constant exceeded its
internal limit. This is a failed smoothness gate and needs investigation; the
memory samples alone do not qualify the renderer.

The app printed the report in the device console, but the follow-up report-file
copy and relaunch could not be completed: CoreDevice timed out while initializing
after the console-attached process was stopped. The table above records the
console output; it is not a preserved raw device JSON. Physical Pencil latency,
GPU/frame pacing, and the four-page Quick Note remain unverified by this rerun.

## Submitted subminimum zoom-out recording

The user's 2026-10-09 recording shows page **3 of 5**, with dense handwriting.
Across the supplied frames, paper and ink appear to shrink together; the visible
failure is a lateral/origin shift as zoom settles, rather than a clear ink-only
scale change. This is consistent with viewport focus switching to a neighboring
page during the final zoom frames, though the recording alone cannot establish
the exact UIKit/PaperKit callback sequence.

The native paged path now retains the page that owned the pinch until the next
pan or direct PaperKit interaction. It also disables `UIScrollView`'s outer
zoom bounce for this path: sibling PaperKit page viewports do not currently own
the pinch presentation, so mirroring an outer overshoot can make their paper
projection diverge during spring-back. At the 50% floor the path clamps instead
of showing that bounce. The legacy full-page renderer keeps its established
bounce. This is a stability mitigation, not proof that native PaperKit bounce
has been reproduced.

The complete 28-test native viewport suite passed on the connected iPad Air /
iPadOS 27. It covers subminimum paper/ink projection, stable focus through
zoom-settlement and subsequent scroll callbacks, and the native clamp versus
legacy bounce. The anchor test was rerun after adding the post-settlement
callback checks and passed again. A UI automation attempt against the copied
Quick Note did not produce a reliable subminimum gesture: its saved zoom was
793%, the zoom control was hidden, and XCTest's touch scrub did not reset it.
The recording itself identifies page 3 of 5; no claim is made that the separate
four-page description matched this copy. The user's original note was not edited.

Actual Pencil interaction and a real sub-50% gesture after this change remain
manual device checks. The revised native renderer remains Debug-default and
Release-opt-in; the normal Release fallback is unchanged until the iPadOS 26
and 27 interaction gates pass.

## Selected-ink transform jitter recording

The 2026-10-09 selection recording shows page **1 of 4** and PaperKit's blue
selection/transform bounds. In the native viewport path, finger drags inside an
existing selection were not classified as active editing contacts in Pencil-only
mode. PaperKit could therefore report a changing content viewport while the
notebook's display-frame coordinator reapplied its geometry during the same
selection transform.

The contact monitor now recognizes a direct touch that starts inside the
selected content or its 28-point handle margin. It freezes native viewport
reconciliation for that contact, then publishes the changed markup and applies
pending geometry once the touch ends. A touch beginning elsewhere still follows
ordinary notebook scrolling. Pencil contacts retain their existing path.

The full **30-test** native viewport suite passed on the connected iPad Air /
iPadOS 27 after this change. New checks cover selection hit routing and ensure a
simulated PaperKit transform causes no native geometry application until
lift-off, while preserving the moved markup and restoring projection afterward.
The suite does not replay the supplied selection gesture or measure frame
pacing; a manual drag of the same selected handwriting remains the final visual
check. The original note was not modified by the test run.
