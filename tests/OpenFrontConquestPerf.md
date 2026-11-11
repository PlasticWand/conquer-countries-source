# Large-country renderer audit — 2026-11-08

Baseline: saved Map modules at **8844e9e**. Patched: Codex Map working tree over **738f230** (Claude's Studio probes). No sim/Net/config/UI changes by Codex. The eight measurement runs were serial; gates ran after them.

## Method and limits

Real OpenFront World terrain, 2000x1000, 651,569 land tiles. Initial local ownership is 30.40% of land. Synthetic confirmed state contains 140 player/name anchors, 500 ships and 500 structures. Desktop policy, 1280x720, static coasts enabled. Synthetic unit/ownership layouts are stress fixtures, not a replay or execution of conquerPlayer/capitulation. Shared sim, network decoding, HUD, audio and server are excluded.

Visual clocks advance at 60Hz; host runs unpaced. Ship movement and confirmed ticks arrive every six frames. Pan/zoom sweeps run with these updates in flight. Each conquest size transfers three batches at frames 1/121/241 over 360 frames. The sustained front scenario changes 1200 scattered land refs every six frames (72k edits in six logical seconds), deliberately stressing disconnected fronts. The attacking case has 11 outgoing targets. The separate feel stress repeatedly exercises impact/loss, new structure settle/dust, completion/upgrade and merged conquest/stamp/gold during pan/zoom.

Times are **renderer Lua mean / p95 / max ms per logical frame**: elapsed time in top-level renderer methods/callbacks is summed without double counting nested calls. Synthetic source-buffer/list construction is excluded; gross frame-loop timings are also in JSONL. Components overlap and must not be added. The property/lifecycle shim adds instrumentation overhead. There is no native GUI/layout, EditableImage WritePixelsBuffer, GPU, display pacing or phone measurement. Host/JIT/GC variance applies; three bursts are not a statistical confidence interval.

Uploads count individual mocked native WritePixelsBuffer calls (base, atlas and coasts); many calls may update one image. MiB below are **base raster bytes only**, excluding atlas/coast bytes. GUI objects count live Frame/ImageLabel/TextLabel views after final draining; instance count, per-property writes, component timings, queue fallbacks and fingerprints are in the JSONL fixtures. Drain means *additional frames after the scenario*, not time from each conquest to settled display.

## Per-frame Lua comparison

Every cell is mean / p95 / max ms, before → after.

| Scenario | OFF | Split | Deferred | Both |
| --- | --- | --- | --- | --- |
| idle | 0.05/0.17/0.31 → 0.05/0.21/0.41 | 0.05/0.21/0.43 → 0.04/0.12/0.33 | 0.05/0.23/0.64 → 0.05/0.21/0.56 | 0.05/0.22/0.32 → 0.05/0.16/0.54 |
| panZoom | 4.00/13.40/22.35 → 3.61/11.40/19.43 | 4.05/13.03/23.09 → 3.51/11.65/20.83 | 4.12/15.89/26.88 → 3.42/11.05/19.02 | 3.97/12.81/23.09 → 3.33/9.96/18.78 |
| frontPanZoom | 7.44/27.00/39.36 → 6.46/18.43/32.15 | 7.27/22.68/35.24 → 6.34/19.80/28.12 | 6.51/19.22/33.10 → 5.78/15.94/27.00 | 6.88/23.71/37.65 → 5.69/17.72/27.76 |
| conquest5000PanZoom | 3.88/13.12/28.18 → 3.29/10.95/22.27 | 3.94/14.52/26.21 → 3.45/11.50/22.81 | 3.45/13.05/28.33 → 3.13/9.14/23.51 | 3.55/13.60/30.16 → 3.30/10.86/25.98 |
| conquest15000PanZoom | 4.15/13.76/61.82 → 3.33/9.07/25.15 | 3.68/13.20/48.37 → 3.18/11.08/22.86 | 3.76/12.17/45.32 → 3.43/11.17/18.44 | 4.11/12.98/47.57 → 3.34/9.62/18.37 |
| conquest30000PanZoom | 5.35/15.40/169.15 → 3.82/11.88/38.13 | 4.76/12.94/143.71 → 3.58/9.70/43.62 | 4.75/12.38/133.33 → 3.74/10.72/33.21 | 5.03/13.45/145.84 → 3.98/11.48/35.82 |
| attacking30000PanZoom | 5.22/14.18/150.93 → 3.52/10.78/44.92 | 5.06/14.34/159.70 → 3.68/11.38/45.67 | 4.92/13.84/137.28 → 3.84/12.15/41.38 | 5.15/11.86/148.54 → 3.97/10.55/46.94 |
| feelPanZoom | 3.32/12.05/24.54 → 3.05/10.04/17.99 | 3.36/11.13/19.40 → 2.88/9.71/17.57 | 3.32/10.53/22.20 → 3.21/9.72/21.09 | 3.60/12.49/26.01 → 3.50/10.29/20.01 |

## Uploads, objects and catch-up

Before → after. Counts are over each 240- or 360-frame measured window. GUI figures are after; JSONL also retains baseline counts.

| Mode/scenario | Upload calls | Base MiB | Live GUI objects | Extra drain frames | Cumulative queue fallbacks |
| --- | ---: | ---: | ---: | ---: | ---: |
| off/idle | 0 → 0 | 0.000 → 0.000 | 2673 | 0 → 0 | 0 → 0 |
| off/panZoom | 10246 → 10280 | 0.084 → 0.084 | 3550 | 2 → 4 | 0 → 0 |
| off/frontPanZoom | 7014 → 7411 | 3.403 → 3.427 | 3350 | 226 → 191 | 0 → 0 |
| off/conquest5000PanZoom | 10248 → 10280 | 0.179 → 0.179 | 3524 | 2 → 1 | 0 → 0 |
| off/conquest15000PanZoom | 9313 → 9488 | 0.285 → 0.286 | 3533 | 1 → 1 | 0 → 0 |
| off/conquest30000PanZoom | 8721 → 8791 | 0.498 → 0.498 | 3521 | 1 → 2 | 0 → 0 |
| off/attacking30000PanZoom | 8686 → 9081 | 0.512 → 0.514 | 3535 | 3 → 1 | 0 → 0 |
| off/feelPanZoom | 6010 → 6024 | 0.075 → 0.075 | 3572 | 1 → 1 | 0 → 0 |
| split/idle | 0 → 0 | 0.000 → 0.000 | 2680 | 0 → 0 | 0 → 0 |
| split/panZoom | 10273 → 10288 | 0.084 → 0.084 | 3530 | 2 → 4 | 0 → 0 |
| split/frontPanZoom | 7281 → 7874 | 3.482 → 3.546 | 3353 | 199 → 198 | 0 → 0 |
| split/conquest5000PanZoom | 10107 → 10148 | 0.181 → 0.180 | 3507 | 2 → 2 | 0 → 0 |
| split/conquest15000PanZoom | 9442 → 9498 | 0.287 → 0.285 | 3540 | 2 → 1 | 0 → 0 |
| split/conquest30000PanZoom | 8930 → 8980 | 0.499 → 0.499 | 3529 | 2 → 1 | 0 → 0 |
| split/attacking30000PanZoom | 8846 → 8792 | 0.511 → 0.511 | 3561 | 2 → 2 | 0 → 0 |
| split/feelPanZoom | 6001 → 5983 | 0.075 → 0.074 | 3483 | 1 → 2 | 0 → 0 |
| deferred/idle | 0 → 0 | 0.000 → 0.000 | 2673 | 0 → 0 | 0 → 0 |
| deferred/panZoom | 10218 → 10275 | 0.084 → 0.084 | 3523 | 1 → 3 | 0 → 0 |
| deferred/frontPanZoom | 9270 → 9256 | 2.078 → 2.016 | 3362 | 537 → 524 | 13280 → 12512 |
| deferred/conquest5000PanZoom | 10262 → 10128 | 0.184 → 0.184 | 3533 | 2 → 1 | 13280 → 12512 |
| deferred/conquest15000PanZoom | 9398 → 9232 | 0.298 → 0.296 | 3551 | 2 → 2 | 13280 → 12512 |
| deferred/conquest30000PanZoom | 8690 → 8799 | 0.514 → 0.517 | 3551 | 2 → 2 | 13280 → 12512 |
| deferred/attacking30000PanZoom | 8698 → 8484 | 0.524 → 0.527 | 3550 | 2 → 2 | 13280 → 12512 |
| deferred/feelPanZoom | 6019 → 5903 | 0.075 → 0.072 | 3497 | 2 → 1 | 13280 → 12512 |
| both/idle | 0 → 0 | 0.000 → 0.000 | 2680 | 0 → 0 | 0 → 0 |
| both/panZoom | 10286 → 10283 | 0.084 → 0.084 | 3528 | 2 → 1 | 0 → 0 |
| both/frontPanZoom | 8364 → 9595 | 1.957 → 2.057 | 3337 | 583 → 542 | 14528 → 12320 |
| both/conquest5000PanZoom | 10183 → 10082 | 0.183 → 0.180 | 3531 | 1 → 1 | 14528 → 12320 |
| both/conquest15000PanZoom | 9236 → 9237 | 0.295 → 0.293 | 3540 | 3 → 1 | 14528 → 12320 |
| both/conquest30000PanZoom | 8691 → 8466 | 0.512 → 0.511 | 3528 | 1 → 3 | 14528 → 12320 |
| both/attacking30000PanZoom | 8566 → 8521 | 0.523 → 0.532 | 3529 | 1 → 3 | 14528 → 12320 |
| both/feelPanZoom | 6000 → 6012 | 0.075 → 0.075 | 3540 | 2 → 1 | 14528 → 12320 |

## Findings and changes

- **DefenseRanges.tilesChanged** dominated large transfers. OFF peak defense invalidation was 111.75 ms without outgoing targets and 103.79 ms with targets. After: effectively zero without targets; 11.86 ms in the attacking case. Skip irrelevant posts, build candidates once per touched cell, remove already-invalidated candidates, and look up changed witnesses directly. Surviving witnesses keep their circles; idle changes are reconsidered when an attack makes a post relevant.
- **EditableRenderer.applyTileStates / RasterCore.applyTileStates** now collect own-land/fallout transitions during the confirmed-state copy, removing the adapter's duplicate scan. Immediate horizontal halos that already overlap are unioned before dirtyRect. Dirty coverage and own priority are preserved; no sorting, broad clean-gap fill or deferred semantic change.
- **SceneOverlay.drawUnit / zoomAdornment / step** retain pose-only warship movement through zoom and update stable symbol text in the existing capped adornment sweep. Symbol art/record restyling is skipped only with unchanged confirmed fields, palette, highlight, LOD and completed composition, and no live progress bar. Progress/flicker/pending or changed units keep full drawing. OFF pan/zoom unit work fell 1.478 → 1.075 ms mean, 8.118 → 5.707 ms p95.
- **Feel effects are small in this fixture:** OFF feel stress averages 0.199 ms/frame for FeelOverlay and 0.019 ms/frame for EffectOverlay (including staged conquests); units/raster remain larger. This is not a native/device cost finding.
- All 32 before/after mode/scenario pairs match settled base raster fingerprints, also across modes. Measured frames updated at most one image. Existing budgets, visual rules, queues/caps, camera gain/clamps/gestures, commands and default SPEED flags remain unchanged.
- Deferred modes are **not an unconditional winner**: the sustained scatter load reaches the existing bounded queue cap and takes 524/542 extra frames to drain after the patched deferred/both window, with 12,512/12,320 cumulative immediate-fallback operations. Fallbacks also occur in the baseline; they preserve state. Later rows retain the cumulative count. OFF/split drain 191/198 frames under this deliberately high scattered load. No state is dropped and settled fingerprints agree. This does not establish comfortable sustained-load latency.
- Upload volume is broadly unchanged and sometimes higher because wall-clock budgets change slicing. There is no upload-merging change or claim of fewer native calls. No new GUI/image pool, cap or retained buffer was introduced by these fixes.

## Studio follow-up

Capture the active FPS mode (restart to apply SPEED), then compare fixed-camera 5k/15k/30k conquest and the same pan/zoom scene. Separate server tick time from client timing_units, timing_trails, timing_raster, timing_names and total frame time; bracket the TilesChanged renderer callback too, because it occurs outside Renderer.step's frame bucket. Native MicroProfiler GUI/layout, image upload and render/GPU markers are needed to explain remaining FPS drops and decide whether split ScreenGuis help. Check symbol/level/station/veterancy sizing across LOD thresholds, moving damaged warships, live construction bars, defense witnesses, conquest feedback and visible own-front catch-up. No Codex Studio/device review was performed.

## Reproduction

From the project root, run serially (replace off with split, deferred or both):

~~~powershell
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontConquestPerf off tests/fixtures/OpenFrontConquestPerf.before.off.jsonl 8844e9e
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontConquestPerf off tests/fixtures/OpenFrontConquestPerf.after.off.jsonl
~~~

Baseline modules are read using git show; no checkout or reference-repository tools run. The existing recent-performance harness now supports snapshotting DefenseRanges/StructureAtlas and exposes the real Core module for callback instrumentation.

Coverage added in OpenFrontFinish (batch relevance/witness/cell invalidation and reopening attacks), OpenFrontRecent (decorated ship pose/zoom and capped stable structure text across LOD), and OpenFrontRenderSpeed (halo-mask/priority/pixel parity and exact transition collection including duplicates).

Gates on the combined working tree over 738f230: OpenFront subset **278/0**, fresh Rojo sourcemap plus full-src strict analysis clean, Rojo build OK, whitespace clean. The expected warship listener-error warning is an intentional test case. No full-suite or native/device run by Codex; no staging or commit.
