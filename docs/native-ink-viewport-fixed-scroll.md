# Fixed-zoom notebook scrolling follow-up

This follow-up addresses the manual scrolling report after the earlier viewport
work. The earlier zoom-cycle results did not establish stability while a page
moves continuously through the screen at 50%.

## Rendering correction

The original viewport sized each PaperKit controller to the page/screen
intersection. As a sheet entered or left the screen, its native bounds changed
on every navigation frame, even when notebook zoom stayed constant. That caused
repeated native layout and rendering-window changes during an ordinary pan.

`CanvasNativeViewport` now distinguishes actual visibility from the rendering
window. The native window has a stable size, capped per axis by the screen and
page dimensions. At a fit zoom, an A4 page retains its complete native surface;
the outer scroll view moves and clips it. At higher zooms, PaperKit receives a
screen-sized authored window. The full stored markup remains unchanged.

The host updates its screen position and visibility cache during scrolling,
but skips native bounds, zoom and visible-frame assignments when the render
window is unchanged. Geometry changes disable UIKit/Core Animation actions.
Authored-to-local insertion and overlay mappings use the rendering window.

The new physical test also exposed a fractional full-page fit case on PaperKit
27: `contentVisibleFrame` reported screen-sized dimensions despite correct
native content zoom/origin. Using that getter as the sole alignment check
triggered a correction on every pan frame. Alignment now checks the actual
public `contentView` projection into the controller's bounds, with display-pixel
tolerance. The authored viewport still uses Apple's public setter.

This uses PaperKit for all native markup and editing. It adds no custom Metal
renderer, external ink magnification, document migration or second ink preview.
The current native path keeps at most one idle editor, retains page-local undo
protections, clears the idle pool on memory warning, and allows one checkpoint
at a time. Older measurements in this report used the then-current four-editor
pool and are labeled as historical results.

## Physical regression evidence

On the M1 iPad Air (5th generation), iPadOS 27.0 (24A437), **54 tests passed**
with no skips/failures in 44.606 seconds. The new motion test exercises vertical
and horizontal navigation at requested zooms 50%, 60% and 100%, forward and
back, with normal display-link updates between offsets. It checks the actual
native content anchor on every sample, unchanged native bounds, constant zoom,
viewport alignment and no repeated native geometry application at fit zoom.
Horizontal mode retains its existing minimum-fit behavior: requested 50%/60%
was clamped to approximately 81.71% in this landscape test window.

The other tests cover viewport round trips, native zoom, page edges, rotation,
contact deferral, tools/ruler, undo/remount, eviction, mixed-content export,
concurrent template drawing and checkpoint generation coalescing. Test fixtures
for the new motion test use native editable text and alternating templates.

[Unit summary](native-ink-viewport-evidence/fixed-scroll/unit-summary.json),
[50% vertical capture](native-ink-viewport-evidence/fixed-scroll/vertical-50.png),
[horizontal fit capture](native-ink-viewport-evidence/fixed-scroll/horizontal-fit-requested-50.png),
[source hashes](native-ink-viewport-evidence/fixed-scroll/source-hashes.json).

## Release checks

The gesture and memory checks use the optimized Release app with the local
`NOTATE_INK_PROFILING` entry point, the saved 1,000-page fixture and the normal
library/editor/navigation path. Code coverage is off. The UI runner is Debug;
the application under test is Release. A separate normal Release app excludes
fixture creation, profiling and automation launch arguments.

A new opt-in gesture test performs six forward and six reverse finger drags
without any pinch in each vertical/horizontal configuration at requested 50%,
60% and 100%, then checks Back. Screen recordings allow inspection during motion;
settled screenshots alone are insufficient evidence of scrolling smoothness.

A separate paced memory workload traverses 32 page spacings forward/back twice
at one constant zoom, with 2,049 updates, rendered-frame waits, actual native
alignment checks and 18 footprint samples including a final ten-second settle.
This measures main-actor viewport synchronization, not full frame/GPU or Pencil
latency. Sampled process footprint is not a retain-cycle/leak certification.

The final **three Release UI tests passed**, with zero failures/skips (419.594
seconds including runner overhead). The fixed-zoom test completed all six
configurations and 72 finger drags (326.934 seconds). The other tests verified
pinch, page advance, three library/reopen cycles, Reader then Back, and actual
portrait/landscape canvas bounds. The dedicated fixture is restored to vertical
layout for the final checks. Horizontal requested zooms below fit remain clamped
by the existing navigation policy.

[Release UI summary](native-ink-viewport-evidence/fixed-scroll/release-ui-summary.json),
[50% vertical motion excerpt](native-ink-viewport-evidence/fixed-scroll/vertical-50-motion.mp4),
[horizontal fit motion excerpt](native-ink-viewport-evidence/fixed-scroll/horizontal-fit-motion.mp4).
Canvas-only excerpts and the inspected frames show the sheet, template and native
text/image/shape moving together, with page gaps and no stationary sheet spilling
under another sheet. They do not establish frame-time or handwritten-ink parity
with Goodnotes. Library screenshots are excluded from the repository.

## Constant-zoom Release measurements

Three fresh-process runs completed, **6,147 updates total**, with zero native
alignment violations. Each traversed 32 page spacings twice forward/back.

| Direction / actual zoom | Mounted / idle maximum | Synchronization median / p95 | Highest sampled footprint | Final footprint |
| --- | --- | --- | --- | --- |
| Vertical / 50% | 3 / 2 | 0.37 / 9.02 ms | 513.5 MiB | 333.4 MiB |
| Vertical / 60% | 3 / 1 | 0.39 / 9.26 ms | 626.8 MiB | 273.3 MiB |
| Horizontal / 81.71% minimum fit | 2 / 1 | 0.33 / 8.47 ms | 609.1 MiB | 364.7 MiB |

Footprint samples oscillate and decrease between traversals; none grows
monotonically. The final measurements follow ten seconds of settling. Peaks
are the largest **sampled** values, not a measurement of every allocation.
The temporary footprint remains substantial for this 1,000-page mixed-content
fixture; this is evidence of bounded editor allocation, not a claim of a low
universal memory budget. Times measure viewport synchronization, not complete
frame presentation, GPU work, drawing latency or a comparison with Goodnotes.

[50% raw report](native-ink-viewport-evidence/fixed-scroll/vertical-0.5.json),
[60% raw report](native-ink-viewport-evidence/fixed-scroll/vertical-0.6.json),
[horizontal raw report](native-ink-viewport-evidence/fixed-scroll/horizontal-0.5.json).

The first expanded gesture run completed five configurations but failed its
horizontal 100% page-advance assertion. The recording shows the sheet moving
then snapping back: a slow half-screen drag did not cross half the existing
zoomed page stride. The test now uses an 80%-screen horizontal drag to explicitly
cross that paging threshold. Product paging behavior was not changed to satisfy
the assertion. This failed run is not counted as a passing UI suite.

## Instrumented memory inspection

A separate 45.841-second physical-device Leaks/Allocations trace covered 50%
vertical motion in the same Release fixture. Instruments showed two successful
leak checks and an empty Leaked Object table: **zero detected leaks in those
checks**. This is limited evidence, not certification that every lifetime or
editing flow has no retain cycle. The allocation view showed nine persistent
IOSurfaces totaling 16.39 MiB; 24 transient surfaces were released during the
capture. Instrumented heap/VM statistics are not the uninstrumented footprint
measurements above.

[Inspection record](native-ink-viewport-evidence/fixed-scroll/leak-inspection.json),
[trace metadata](native-ink-viewport-evidence/fixed-scroll/leaks-toc.xml).
The raw 2.26-GB trace remains at
`/tmp/notate-fixed-scroll-profiles/fixed-scroll-leaks.trace` rather than in the
repository. An initial Animation Hitches capture was interrupted by the UI
runner relaunch; that incomplete trace supplies no performance evidence. Subsequent
name/PID attachment failed despite the CoreDevice process listing. A final
20-second compositor capture completed with the error **"Transferred trace file
is malformed"**. Its output is excluded from performance claims; reliable hitch
counts/frame times remain unmeasured. [Capture error](native-ink-viewport-evidence/fixed-scroll/hitches-capture-error.log).

## Remaining acceptance

Physical iPadOS 26 testing of this correction, manual Pencil live/settled ink,
draw-and-hold, both erasers, selection/text editing and perceived motion still
need device verification. The synthetic mixed fixture previously emitted
PaperKit imported-stroke recognition warnings; it cannot establish dense
handwritten-ink quality. The earlier high-zoom/large-offset UIKit constraint
warning is tracked in the previous report and is not resolved by these fit-scroll
checks. No Goodnotes parity or universal absence of leaks is claimed.

## Final installed state and storage limitation

The tested optimized Release app, containing this fix, remains installed. All
benchmark processes were stopped, and it was relaunched with **no arguments and
no NOTATE environment variables**. Its profiling entry points are compiled but
inactive. The normal Release package was built successfully with those entry
points excluded; a binary string check also found none of the fixture/benchmark
launch strings.

Replacing it with that package failed twice because the iPad had only about
9–10 MB available and needed another 31–32 MB for installation staging. The
experiment's UI-test runner and its disposable data were removed, but no
notebook, other app or user file was removed. More free iPad storage is required
for the final normal-package replacement. Storage exhaustion is also a material
limit on further captures and notebook saves; frame-hitch capture errors are not
interpreted as application performance measurements.

[Final device state](native-ink-viewport-evidence/fixed-scroll/final-device-state.json),
[normal launch](native-ink-viewport-evidence/fixed-scroll/installed-release-normal-launch.json),
[installer storage error](native-ink-viewport-evidence/fixed-scroll/normal-release-install-blocked.json).
