# Live-front latency and landing audit — 2026-11-08

Baseline Map modules: **a31b85c**. Patched: Codex Map working tree over that commit. No shared/server/UI/config/Net changes by Codex. Default SPEED settings remain OFF.

## Method

Real World terrain, 2000x1000, initially 30.40% own land; 140 confirmed name anchors, 500 ships, 500 structures, plus 320 pre-existing structures for landing/destruction cases. Seven 100-tile railroad paths cross x=1024. Desktop 1280x720 policy, coasts enabled. This is synthetic confirmed state, not a sim replay or execution of conquerPlayer/capitulation.

Two 178k-transfer cases (fixed camera and sweep) continue 12 visible own-affecting edits every six frames. A separate overload case sends 1200 *all-own, scattered, visible* edits every six frames. Landing cases exercise atom then hydrogen, and 24 MIRV warheads in four groups of six over four ticks; confirmed ownership loss, fallout, inactive reached-target records, destruction, debris/fire, shockwaves and glow are present. Labels run their camera/LOD/status paths; server anchors are fixed, so this is not a label-anchor recalculation benchmark. A separate 2–8 zoom sweep crosses rail fade/detail thresholds. Unit motion reflects at map edges: an earlier draft incorrectly wrapped a transport between map rows and generated a false 2000-tile trail spike; that draft's records were discarded.

Logical time advances at 60Hz, simulation notifications at 10Hz. Host execution is unpaced. Timings sum top-level renderer methods/callbacks, excluding synthetic list/buffer construction; nested components are not counted twice. Native-property shims and upload-acknowledgement bookkeeping are included. Native GUI/layout, image upload, GPU, audio, HUD, server, network decode and real device pacing are excluded.

**Host timing varied substantially.** Retained evidence includes the serial four-mode pass and an additional OFF before/after/after/before control. All results are retained; neither run order nor these Lua wall times establish native FPS savings.

## Paired OFF control

The frame distributions below combine the raw per-frame samples from two before and two after runs (ABBA order). Entries are mean / p95 / max renderer Lua wall ms.

| Scenario | Before | After |
| --- | ---: | ---: |
| capture178kFixed | 4.37/14.16/255.71 | 4.55/14.58/276.80 |
| capture178kSweep | 5.11/12.98/278.19 | 5.41/14.20/243.90 |
| front1200Sweep | 7.42/24.88/37.69 | 7.32/22.52/32.29 |
| atomHydrogenSweep | 5.25/15.80/75.11 | 4.60/14.84/57.79 |
| mirv24Sweep | 4.67/15.18/47.75 | 4.12/13.36/30.87 |
| cameraOnlySweep | 3.78/11.52/22.47 | 3.32/10.42/18.95 |
| railCameraSweep | 3.80/10.64/20.86 | 3.44/9.57/16.70 |

Age entries below are **p95/max frames per run**, not averaged percentiles.

| Case/metric | Before 1; Before 2 | After 1; After 2 |
| --- | --- | --- |
| capture178kFixed/own | 189/225; 174/214 | 202/249; 196/236 |
| capture178kFixed/tip | 118/188; 109/208 | 4/7; 4/5 |
| front1200Sweep/own | 271/337; 313/375 | 278/375; 272/343 |
| front1200Sweep/tip | 81/148; 151/266 | 110/200; 94/198 |

“Own” retains the existing visible-block upload-age semantics: one maximum row age per upload frame, including old bulk ownership work and own-content samples. “Tip” independently times requested live edits until a base-image rectangle containing them is written. A tip leaving the viewport is censored; it is not counted as a foreground stall when the camera returns. Unserved tips are checked during final drain. These are base-image acknowledgements, not GPU presentation timestamps. Counts/censoring are in JSONL.

**The scheduling target is met for small live updates during a huge transfer, not for every owned tile.** Old bulk repaint ages stay high. The sustained all-own scatter case remains a latency failure; normal/fairness service is retained, but this workload exceeds the current bounded paint/expansion throughput. No universal few-frame guarantee or default flag promotion follows.

## Serial four-mode pass

Each cell is before → after, mean/p95/max ms. This earlier pass has different host load from the paired control above.

| Scenario | OFF | Split | Deferred | Both |
| --- | --- | --- | --- | --- |
| capture178kFixed | 2.62/8.33/136.87 → 3.28/11.23/183.81 | 2.67/9.04/144.29 → 2.89/9.95/157.38 | 2.70/8.75/123.80 → 2.75/8.84/121.71 | 2.97/10.27/164.54 → 3.55/10.69/195.61 |
| capture178kSweep | 3.26/8.34/134.67 → 3.97/10.71/158.06 | 3.25/8.98/135.30 → 4.39/11.38/136.42 | 3.31/8.06/117.05 → 4.33/11.14/118.19 | 3.79/9.07/119.72 → 4.47/9.96/130.02 |
| front1200Sweep | 5.33/14.92/21.49 → 6.28/17.77/28.35 | 5.29/15.27/20.82 → 5.97/18.32/24.79 | 5.12/12.69/19.33 → 5.40/16.61/24.51 | 5.12/12.83/19.26 → 6.05/19.17/28.22 |
| atomHydrogenSweep | 2.67/8.81/35.92 → 3.80/11.40/45.36 | 2.74/8.65/33.37 → 2.84/9.51/27.08 | 2.71/9.12/33.78 → 2.78/8.47/31.42 | 2.59/8.12/31.25 → 3.54/10.79/36.26 |
| mirv24Sweep | 2.37/9.29/19.21 → 3.09/9.65/24.96 | 2.37/8.31/18.25 → 2.53/9.30/18.51 | 2.49/9.52/16.03 → 2.85/9.53/17.39 | 2.37/8.96/15.75 → 3.12/11.34/21.95 |
| cameraOnlySweep | 1.98/7.40/10.95 → 2.43/9.06/15.29 | 1.96/7.01/11.00 → 2.13/6.69/12.67 | 2.10/7.62/13.00 → 2.62/9.18/16.20 | 2.02/7.51/18.03 → 2.81/8.81/17.46 |
| railCameraSweep | 2.05/6.98/12.31 → 2.47/8.30/11.81 | 2.03/6.34/11.07 → 2.25/7.91/13.45 | 1.87/6.15/8.89 → 3.07/8.97/17.69 | 1.82/5.99/9.45 → 2.64/8.64/14.51 |

All age pairs are p95/max frames, before → after.

| Mode/scenario | All own row ages | Continuously visible live-tip ages | Extra drain frames |
| --- | ---: | ---: | ---: |
| off/capture178kFixed | 85/109 → 118/146 | 22/87 → 3/6 | 6 → 8 |
| off/capture178kSweep | 4/6 → 4/5 | 3/6 → 3/5 | 7 → 29 |
| off/front1200Sweep | 77/138 → 169/306 | 33/91 → 53/132 | 171 → 264 |
| off/atomHydrogenSweep | 4/7 → 4/6 | 3/7 → 4/6 | 10 → 11 |
| off/mirv24Sweep | 3/3 → 4/4 | 3/3 → 3/4 | 6 → 7 |
| off/cameraOnlySweep | 3/3 → 3/3 | 0/0 → 0/0 | 7 → 7 |
| off/railCameraSweep | 0/0 → 0/0 | 0/0 → 0/0 | 6 → 7 |
| split/capture178kFixed | 92/113 → 97/122 | 27/95 → 3/5 | 6 → 6 |
| split/capture178kSweep | 3/5 → 4/6 | 3/5 → 3/5 | 6 → 58 |
| split/front1200Sweep | 78/105 → 176/305 | 34/100 → 43/121 | 173 → 190 |
| split/atomHydrogenSweep | 4/8 → 3/6 | 3/7 → 3/5 | 9 → 9 |
| split/mirv24Sweep | 3/4 → 3/3 | 3/4 → 3/4 | 7 → 7 |
| split/cameraOnlySweep | 3/3 → 3/3 | 0/0 → 0/0 | 7 → 7 |
| split/railCameraSweep | 0/0 → 0/0 | 0/0 → 0/0 | 6 → 6 |
| deferred/capture178kFixed | 125/149 → 123/147 | 90/137 → 3/6 | 6 → 6 |
| deferred/capture178kSweep | 108/167 → 5/161 | 47/108 → 3/6 | 6 → 35 |
| deferred/front1200Sweep | 312/342 → 313/352 | 126/394 → 145/465 | 467 → 540 |
| deferred/atomHydrogenSweep | 4/12 → 4/6 | 3/12 → 3/6 | 8 → 8 |
| deferred/mirv24Sweep | 3/3 → 3/4 | 3/3 → 3/4 | 6 → 7 |
| deferred/cameraOnlySweep | 3/4 → 3/4 | 0/0 → 0/0 | 7 → 7 |
| deferred/railCameraSweep | 0/0 → 0/0 | 0/0 → 0/0 | 6 → 7 |
| both/capture178kFixed | 136/166 → 163/197 | 90/144 → 4/6 | 7 → 6 |
| both/capture178kSweep | 159/177 → 7/173 | 47/108 → 4/8 | 12 → 129 |
| both/front1200Sweep | 308/336 → 323/365 | 129/395 → 166/531 | 457 → 651 |
| both/atomHydrogenSweep | 4/12 → 4/7 | 3/12 → 3/6 | 8 → 10 |
| both/mirv24Sweep | 3/4 → 3/4 | 3/4 → 3/4 | 6 → 7 |
| both/cameraOnlySweep | 3/3 → 4/4 | 0/0 → 0/0 | 7 → 7 |
| both/railCameraSweep | 0/0 → 0/0 | 0/0 → 0/0 | 6 → 7 |

## Churn and uploads (OFF serial pass)

Counts are over each measured window. “GUI” counts all live shim GUI objects, including unparented spares; it is not native GUI layout cost. Upload calls include base/coast/atlas calls; many calls can update one image.

| Scenario | Coast creates/deletes before → after | GUI before → after | Upload calls before → after |
| --- | ---: | ---: | ---: |
| capture178kFixed | 0/0 → 0/0 | 2675 → 2675 | 20322 → 19562 |
| capture178kSweep | 971/921 → 541/0 | 3197 → 3684 | 19665 → 19180 |
| front1200Sweep | 741/429 → 0/0 | 3576 → 3684 | 20972 → 14457 |
| atomHydrogenSweep | 898/1018 → 0/0 | 4262 → 4519 | 16457 → 16346 |
| mirv24Sweep | 912/883 → 0/0 | 4268 → 4525 | 15816 → 15554 |
| cameraOnlySweep | 737/655 → 0/0 | 4417 → 4525 | 11070 → 10969 |
| railCameraSweep | 87/481 → 0/0 | 4723 → 5225 | 13525 → 13438 |

## Changes and diagnosis

- **RasterCore:** old own-visible priority put a fresh front behind old nation-sized repaint rows. Small own-affecting deltas (<4096 refs) now tag bounded per-row priority masks. A narrow front slice consumes at most min(1 ms, one quarter of the existing raster budget), within the original deadline; remaining work uses normal rectangles. The selected page still obeys the one-image rule. Normal turns explicitly promote the oldest visible block, with rotating ties; background turns remain. Dirty ages/revisions and original confirmed-state copies are preserved.
- **DeferredDirty:** the same small-own lane can pass old run records; big owned buffers rotate after each bounded span instead of pinning the head. Front work shares the original record cap, copied buffers, reservations, visit/deadline bounds and cleanup. Original ages remain.
- **RasterCore.dirtyRect / politicalPixel:** avoid redundant dirty/own-row reads/writes; fallout uses the exact source noise/colour formula through numeric RGBA compositing, removing five temporary tables per fallout pixel. Exact RGBA8 source comparisons cover terrain variants.
- **FalloutMasks.tilesChanged:** ordered large lists use binary searches of each mask's row intervals rather than walking an entire surrounding blast. An actual intersecting change schedules an implicit whole-mask refresh via the existing 1024-pixel/1-ms step budget; arbitrary lists retain an exact scan. Unaffected glows are not hidden just because bounding boxes overlap. Refreshed masks retain exact clipping and final pixels; completion timing under load can differ.
- **CoastOverlay:** the old 32-spare policy repeatedly deleted and recreated views during zoom. Spares now remain unparented and hidden up to the existing *total* view cap (384 touch / 1024 desktop), then reuse on return. Creation/deletion quotas remain. All spares are owned and destroyed on renderer teardown. This trades bounded retained GUI memory against churn; it is not a native layout/GPU saving claim.
- Existing explosion/debris/shockwave/glow visuals and creation caps remain. In the OFF serial run, fallout invalidation's atom/hydrogen callback maximum drops from 5.41 ms to 1.08 ms. Other landing components and server/GPU cost remain separate.
- Rail fade stays 3–5. The dense rail sweep retains 32-per-frame create/delete caps. Camera, picking, gestures, visual scales, ranges, progress, hit testing and gameplay numbers are unchanged.

The new fixed World buffers total **518,112 bytes (~0.494 MiB)** for priority masks, row ages and flags. Queue/table/GC overhead is not included in buffer accounting. No new EditableImage or image upload allowance is added. Whole-transfer callbacks still produce large Lua wall-time outliers outside Renderer.step; this round does not eliminate every conquest hitch. CPU means/p95 are mixed across scenarios/modes and should not be called a general FPS win.

All 28 scenario/mode pairs and all 28 control records agree on settled base raster fingerprints. Every measured frame updates at most one image. Source-pixel, revision, snapshot, starvation, cap, deferred-reservation and spare-cleanup coverage is in OpenFrontLatency.spec.luau.

## Native diagnostics and remaining checks

Existing recentOwnUploadP95Frames/MaxFrames remain unchanged. New recentOwnFrontUploadP95Frames, recentOwnFrontUploadMaxFrames and recentOwnFrontUploadSamples describe the small-own priority work separately; row/merged-record ages are conservative, not attack timestamps. Coasts expose coastAttachedPatches and coastRetainedPatches alongside coastSpareViews.

In Studio, bracket Renderer.applyTileStates separately: it occurs outside timing_frame, so a 12.5-ms renderer frame maximum can miss a much larger delta callback. Record incoming tick/delta gaps, ownTileUpdateGapMs, both own-age families, server tick time, and native GUI/layout, image-write and GPU markers around nuke/MIRV landings. Repeat the same pan/zoom and inspect spare-view memory, labels, rail crossings, fallout refresh, and visibly continuous owned fronts. Phone/native timing and appearance are unverified by Codex. Dense sustained scatter, huge atomic callback cost and dynamic server-anchor changes remain limits or follow-ups; no further shared/Net/config agreement is implied.

## Reproduction

Run serially from the project root; substitute split/deferred/both as needed:

~~~powershell
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontFrontLatencyPerf off tests/fixtures/OpenFrontFrontLatencyPerf.before.off.jsonl a31b85c
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontFrontLatencyPerf off tests/fixtures/OpenFrontFrontLatencyPerf.after.off.jsonl
~~~

The control uses the same commands in before1/after1/after2/before2 order with control filenames. Frame samples are retained for combining distributions (do not average p95 values). Baseline modules are read with git show; no checkout or upstream tools are executed. The tracked OpenFrontLatePerf benchmark is preserved byte-for-byte after normalization; the new benchmark has a separate name.

## Validation

Baseline HEAD remained a31b85c. Claude independently reports **OpenFront 284/0** on these renderer changes; Codex also obtained 284/0 earlier. A repeated Codex subset run hit one readiness assertion in OpenFrontMatchPerf (283/1); the final focused rerun of that suite passes **24/0**. That assertion expects readiness within 100 unpaced iterations, rather than reporting an image-slot violation. The six new latency tests passed, including pixel parity, bounded queues, service fairness and cleanup.

Final fresh `rojo sourcemap`, full-src strict analysis and `rojo build` all pass. `git diff --check` passes. Concurrent shared/server changes belong to Claude and were not edited by Codex. No additional timing runs were made during Claude's current server benchmarks. No Studio/device check, staging or commit by Codex.
