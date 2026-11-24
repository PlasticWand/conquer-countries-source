# Renderer ports — v0.35.2

## Operation Iron Road match cosmetics, 2026-11-23

Bruno approved the match cosmetics earned by the Campaign Pass. Contract
agreement with Claude's `52a93c7`: optional human roster strings `title`,
`nameStyle`, `conquestFx`, `blastFx`; nil/unknown/non-human uses the default.
Takeover's RosterChanged path refreshes these with the rest of the roster.
Confirmed match state and gameplay outcomes remain unchanged.

`MatchCosmetics` owns the presentation ID allowlists and shared immutable RGB
values. `n_gold` changes only the name fill to gold and its outline to dark.
Troops retain their original fill/outline, and status icons/flags/heads/anchors
and source LOD retain their normal rules. Unequip and role changes restore the
original style. Titles are the fixed uppercase names RECRUIT, VETERAN, WARLORD,
SOLDIER, never arbitrary player text.

`TitleOverlay` shares **eight** pooled TextLabels/UIStrokes across the whole
map, creating at most one slot per layout pass from the existing GUI creation
allowance. It adds no image. Titles appear only when the source-visible name
em is at least **30 screen pixels**, with a **10..14px** title em. A title goes
between the name and troops; only the troop line's presentation offset changes
while the title is shown. The source name anchor never moves for a title.
Titles yield to gameplay name/troop/status bounds, existing label occluders,
other accepted titles and viewport edges. The existing own-label HUD relocation
still runs first. If the title cannot fit, the normal name/troops remain. At
most eight eligible candidates (own first, then roster order), 128 visible ink
rectangles and 1,024 title-vs-name checks per layout; dense overviews suppress
titles instead of an unbounded search. Source-culling, small fonts, unequip,
snapshot and teardown hide/recycle them. Bounds include actual title ink, not
the wide transparent TextLabel container. Stable layouts avoid title reparent,
visibility and geometry writes. Title work runs in the existing annotation
layout, with no extra RenderStepped or ownership-map scan.

`x_conquest_gold` tints the existing staged conquest mark, stencil stamp and
private gold popup, retaining their counts, timing, gold value and position.
The existing private ConquestEvent remains conqueror-only. For everyone else,
the renderer accepts this additional **live public cosmetic event** (Claude's
replication follow-up; this implementation does not edit shared/server code):

```luau
{
    type = "ConquestCosmeticEvent",
    conquerorId = "human-id", -- stable roster string id, not smallID
    conqueredId = "defeated-id",
    x = 100, y = 150, -- confirmed defeated label anchor BEFORE removal
    tick = 1200,     -- event's original match tick, stable for deduplication
    tickAge = 0,     -- elapsed ticks, matching the existing 10Hz FX convention
    conquestFx = "x_conquest_gold",
}
```

Emit only for an equipped gold conquest style, to all match viewers including
spectators; **no gold amount**, no private payload, no snapshot replay. The
existing generic ClientState.DiplomacyEvents path carries the new event. The
adapter validates known human conqueror, coordinates, style, tick and age.
The conqueror suppresses this public copy and uses the existing private effect.
Observers see one gold animated flag mark, with **no gold popup or stencil**.
Four simultaneous public marks, 900ms lifetime including event age, bounded
64-entry recent-event dedup cache; expired/overflow cosmetic marks are omitted.
No ownership inference, eliminated-player name lookup or offscreen resurrection
is used for a public event. Snapshot, rebound, results and renderer teardown
clear transient conquest presentation. A new private moment does not erase
other players' public marks.

`x_blast_ironroad` freezes the confirmed unit owner's equipped style at receipt
of the final inactive/reached-target record. Atom, Hydrogen, MIRV Warhead, Mega
and Scattershot use orange-red multipliers on the existing burst/debris sprites
and expanding shockwave. Counts, geometry, radius, start time, duration and
fade remain unchanged. Intercepts, other unit deaths, trajectory/danger/relation
colours, telegraph boundaries, authoritative fallout raster, glow masks and
long-lived aftermath retain their defaults. No per-style atlas, pixels or
EditableImage is allocated or written. Pooled sprites/rings/popups explicitly
restore white/default style on reuse. Snapshot seeding still invents no deaths.

### Studio screenshot preview

After restarting Play for synced code and entering a ready match, the renderer
creates **LocalPlayer.OpenFrontCosmetics** only when RunService:IsStudio(). It
is a local BindableFunction, not a remote or an inventory grant. Omit `player`
for your own nation; pass a known roster **smallID** to preview a bot/nation.
The override changes only cosmetic drawing; bot heads/types and confirmed
ClientState, units, gold and map tiles remain untouched.

```luau
local p = game:GetService("Players").LocalPlayer
p.OpenFrontCosmetics:Invoke("set", {
    -- player = 2, -- optional known smallID, including a bot for screenshots
    title = "t_warlord", nameStyle = "n_gold",
    conquestFx = "x_conquest_gold", blastFx = "x_blast_ironroad",
})
p.OpenFrontCosmetics:Invoke("conquest") -- synthetic 125K sequence at our label
p.OpenFrontCosmetics:Invoke("blast", {unit = "Hydrogen Bomb"}) -- our spawn tile
-- Optional {player=<smallID>,tile=<valid tile>,unit="MIRV Warhead"}, etc.
p.OpenFrontCosmetics:Invoke("clear") -- restore confirmed label/owner styles
```

Preview blasts skip fallout/mask preparation entirely, so they add no image or
gameplay fallout. Transient preview FX expire normally; clear restores equipped
styles. Snapshot and rebound clear overrides; renderer destroy removes the
endpoint/callback and pooled titles. These previews are screenshot aids, not
evidence of public replication, ownership, a purchase or a native phone gate.

### Changed functions and verification

- `EditableRenderer`: `attachState`, `destroy`; adds public event consumption,
  optional style on own conquests and the Studio-only endpoint/lifecycle.
- `SceneOverlay`: `new`, `nameScreenRect`, `layoutLabels`, private `drawNames`,
  `setRoster`, `unitUpdates`, `metrics`, `destroy`; new `publicConquests`,
  `setCosmeticPreview`. No changes to input, map camera or picking functions.
- `NameLine`: new pure `titleLayout` only.
- `FxState`: `deadUnit`, `unitUpdates`, `clearConquests`, `stagedConquests`,
  `clear`; new `publicConquests`, `clearPublicConquests`.
- `EffectOverlay`: `new`, `clearConquests`, private `drawConquestStamp`, `step`,
  and new lazy native-colour initialization/tint resolver. Require-time stays
  pure for raster-only hosts. Existing atlas/mask upload paths unchanged.
- New `MatchCosmetics` and `TitleOverlay` own their allowlists/pooling/cleanup.
  Effects harness loads the native title adapter and models Studio/Players.
  No Main/OpenFrontClient/shared/server/Net/config/art changes by Codex.

`OpenFrontMatchCosmetics` covers known IDs/role/unequip/Takeover, source LOD,
crowding/HUD/resize and ink bounds; eight-slot stress and stable native-property
reuse; exact default-vs-tinted nuke emissions/intercepts/unchanged aftermath;
pool colour restoration; private timing/gold, public age/dedup/caps/validation,
no gold leaks, no snapshot replay; live/Studio separation, bot override without
state mutation, no preview images, rebound and cleanup. Final gates over
`52a93c712f50f3721054dae8011d1e95ad8a1112` plus the shared working tree: full
**679 passed / 0 failed** (expected isolated warship-listener warning), focused
MatchCosmetics **11/0**, Raster **10/0**, FalloutReveal **10/0**; fresh-sourcemap
full-src strict, Rojo build and whitespace clean. First full was 675/4 because
raster-only hosts caught native Color3 creation at require time; initialization
now runs lazily in EffectOverlay.new. The passing full suite used unchanged
hashes for all nine renderer/test source files. No assertion was weakened.

`tmp/cosmetics_property_metrics.luau` / `.json`: warmed 844×390 property shim,
default vs gold name + visible title, 120 idle and 120 pan frames. Both allocate
**zero new instances/images/uploads**, idle has zero changed GUI properties,
pan has the same 1,151 Position and 24 Size changes in both configurations,
with no title reparent/visibility churn. The equipped title adds two bounded
name-intersection checks per layout in that scene. This is no CPU/native
font/layout/GPU timing or phone-performance claim (the full suite was running
concurrently, so no CPU benchmark is reported). Native look, crowded real
fonts, actual public event delivery and weak-phone p95 remain acceptance work.

## Sabotage reach while armed, 2026-11-17

Bruno chose to retain Sabotage's 60-tile rule and show its reason and reach.
Claude owns the new `sabotageAim.reason` and HUD text. This map change adds
an amber fill outside our territory with a stronger outer edge while Sabotage
is chosen. It remains visible without a mouse pointer or pinned target and
hides immediately on deselection or controller teardown. The existing red/
yellow target box and authoritative target/build permission are unchanged.
The region indicates distance only: allied, dark or absent buildings and
cooldown/immunity still use the server's reason and target checks.

`SabotageReach` indexes confirmed four-neighbour owned border tiles as row
runs. Off-map neighbours are ignored, matching `Game.updateBorderStatus`.
Circle dilation uses squared Euclidean distance, including the reach boundary;
it does not flood through land or use Manhattan/path distance. Mask samples
are exact at their sampled tile centres, including islands and holes. The
display is deliberately approximate between samples: the longest mask side
is at most 512 pixels, with normal image filtering and a roughly 1.5-mask-pixel
outer band. Server target validation remains authoritative at the visual edge.

The index and mask queue when a local player binds; background work starts
after first paint, before the weapon is selected. Cold initialization scans the map once across
bounded jobs. Thereafter `SceneOverlay.tilesChanged` reuses RasterCore's
existing own-ownership transition list; unrelated ownership, defence and
fallout updates do not invalidate it. Only affected border row spans rescan,
and mask rows within reach are queued. Navigation, pointer movement, ordinary
replies and deselect/reselect reuse the cache. The execution's `REACH` seeds
prewarming; a confirmed `sabotageAim.reach` overrides it and survives pointer
churn. Snapshot, owner or reach changes invalidate the old image immediately.

Jobs have a cooperative 0.6ms / 8,192-operation step allowance, yielding every
128 work units. This is an additional presentation cost, not a hard frame
ceiling. Revisions reject rows invalidated during a yield; consumed queue
storage compacts. Completed mask blocks progress round-robin during later
edits, so initial presentation does not require a quiet map. A single optional
EditableImage is allocated on first aim. Its writes use the renderer's shared
image slot (one every fourth frame while the base raster is busy), at most
64 rows / 128KiB per write. Initial presentation waits until every image block
has been initialized. Later updates retain the last displayed confirmed mask
while bounded work catches up. No native image writes run in the preview's
RenderStepped callback.

Maximum additional image pixels are 1MiB; the persistent RGBA mask is at most
1MiB and retained upload scratch at most 128KiB. Border-run tables scale with
the actual boundary, and jobs temporarily retain one row's geometry. No copy
of the ownership map is kept. Allocation refusal disables this optional mask
and records `sabotageReachFailed`; the target box and HUD reasons still work.
Metrics prefixed `sabotageReach` report CPU work/time, queue rows, border
entries, native-write time/bytes/count, and explicit buffer/image bytes.
In Studio these are returned by `LocalPlayer.OpenFrontDebugClient:Invoke("render")`.

Changed existing functions: BuildPreviewController `setChosen`, `step`,
`destroy` (plus the Reply reason type); EditableRenderer `step`, `metrics`
and new `setSabotageReach`; SceneOverlay `new`, `setLocalPlayer`, `setCamera`,
`tilesChanged`, `prepareFrame`, `destroy`; ShipArt `build`. The new pure cache and native adapter own their
cleanup. No Main, OpenFrontClient, shared/server, Net, combat, HUD or audio
files were changed by Codex. The effects test harness only adds the new
adapter to its native-property module loader.

`OpenFrontSabotageReach` has 12 passing tests covering an independent brute-
force distance oracle, radius boundaries, holes/islands/edges, downsampling,
row-span invalidation, queued changes, inactive edits, snapshots/takeover,
continuous traffic, cache reuse, camera origin/scale, cursor churn, teardown
and the shared image slot. Existing Support is 8/0 and Preview is 16/0.
Loading is 5/0, FirstPaint 9/0 and WideZoom 1/0. The fixed-tree full rerun is
**652/0**, with the expected warship-listener isolation warning. Fresh full-src
strict analysis, Rojo build and whitespace checks pass; the base and scope are
recorded in STATUS. This host's final full run took about 36 minutes.

The first full run was 649/2. The historical WideZoom scene has no optional
reach adapter, so the renderer now tolerates its absence without changing the
archived measured code. The late-snapshot loading fixture also exposed ship
art running out of its wall-clock preparation budget before the unchanged
100-call readiness assertion. Optional reach work now waits for first paint.
Loading-only ship preparation additionally guarantees 4,096 pixels of progress
per call within the existing 32,768-pixel cap; its 8ms deadline is cooperative
and can be exceeded to meet that floor. `ShipArt.build`'s new fourth argument
is optional, so ordinary live-play deadlines/work limits are unchanged. A
spent-deadline test verifies finite progress and that the floor cannot override
the pixel cap. No existing gate assertion or archived baseline was weakened.

`tests/OpenFrontSabotageReachBenchmark.luau` and its JSON fixture record four
trials after a warmup at each of 1024x512 and 2048x1024, over `78a5262` plus
this working tree. Synthetic large territories, a 289-tile local edit, real
RGBA copy sink, unpaced Lune calls: median cold background CPU **200/526ms**
across **316.5/842 calls**; median local update CPU **29.25/14.55ms** across
**45.5/23 calls**, rescanning 19 partial border rows. Largest recorded slice
p95 **0.727ms**, maximum **0.913ms**, against the cooperative 0.6ms target.
Warm arming **<=0.0019ms**, idle **<=0.00122ms/call**; initial image needs four
upload slots. Dispatch **0.145-1.024ms**; copy sink max **0.0473ms**. Each
fixture mask is 512KiB. These exclude Roblox native upload, GUI/GPU, other
systems and phones. Call counts are not FPS or wall-clock seconds. Arming
before prewarming completes can still wait for background geometry; native
warmup/reveal latency needs validation, especially after a large takeover.

`tmp/codex_sabotage_reach_preview.png` was inspected at world/closer view. It
is labelled **headless, not Studio**; the scripts/RGBA data are retained.
The additional `tmp/codex_sabotage_reach_fallout.luau` property-shim check
passed 160 changing ownership/fallout frames with reach armed and never
updated more than one image per frame. It is not native-upload evidence.
Official Studio inventory found the correct place in Edit. Execution remains
blocked by the previously recorded approval-never rejection; no workaround,
restart, native screenshot, publish or device measurement was attempted.
Claude/Bruno should check first aim, world/phone zoom, busy-front freshness,
cooldown/out-of-reach reasons and native memory/frame cost in the actual game.

## Coherent fallout reveal, 2026-11-17

Bruno reported a Hydrogen impact filling in as rectangular patches in normal
gameplay. This was the live raster scheduler: completed rows/32-tile blocks
were immediately uploaded, exposing its work order during a large fallout
and ownership-clear delta. It was not the cosmetic fallout-glow mask.

`RenderPolicy.coherentFallout` defaults true. At least 64 newly confirmed
fallout tiles register a block-aligned, halo-inclusive region on each affected
image page. Ordinary row/revision/priority work composes into the **existing**
RGBA page under the existing live paint budget, while uploads inside those
regions are held. All pieces of the impact must finish preparation before the
first reveal. Each completed region is then copied into one scratch buffer and
published with one native write. Cross-page pieces use consecutive image slots;
Roblox's one-displayed-EditableImage-per-frame rule is retained. New edits can
release that short presentation priority so other active pages keep progressing.
Ready cohorts also get a periodic slot when unrelated fronts stay busy.

This is presentation only. Confirmed tile state changes immediately; rendering
does not delay or change replication, ownership, blast formulas or outcomes.
The blast FX and other map/scene work continue normally. Unrelated regions are
not held behind the blast. Local updates, reversed tile order, overlapping
bursts, deferred invalidation and reentrant sinks retain the latest pixels;
the resulting pages must equal a fresh repaint. Snapshot and destruction clear
the staging state. The loading-cover adapter opts out and keeps its existing
hidden first-paint pipeline.

Bounds are collected once per existing horizontal run, avoiding a second
per-tile scan. The fixed staging limits are **8 regions**, **65,536 pixels per
commit** and **256 KiB retained scratch**. There are no new native images or
per-impact pixel buffers. Readiness checks use bounded block flags, not pixel
scans. Native writes remain non-preemptible and the final copy/write is an
additional bounded cost after the usual paint work, not a hard millisecond
guarantee. A large distant/multiple-blast batch whose bounding region exceeds
the cap, or a full region pool, uses ordinary bounded raster progress instead;
`falloutRevealFallbacks` records this overload case. It can still expose work
order there rather than permitting an unbounded upload/allocation.

Core metrics additionally expose `falloutRevealPending`, `Commits`, `HeldWrites`,
`Fallbacks`, `MaxPixels`, `Pixels`, `MaxDelayFrames`, `CommitMs` and `ScratchBytes`
(all with the `falloutReveal` prefix). `Core.hasPending` includes completed
regions waiting for their native image slot. Upload counters count actual sink
writes, and the scratch buffer is included in explicit CPU-buffer accounting.
Set the policy false before a new renderer for the old reveal, for comparison.

`tests/OpenFrontFalloutReveal.spec.luau` covers Hydrogen/Atom coherence, overlap,
later edits, independent fronts, cross-page/offscreen preparation and successive
image slots, mid-presentation traffic, loading, snapshots/reentrancy, capacity
fallback and cleanup. Existing raster, loading, first-paint and scheduling
checks remain required. `tests/OpenFrontFalloutRevealBenchmark.luau` runs 12
alternating paired synthetic Hydrogen trials after warmups, with a real RGBA
copy sink, 2.5ms target, 81,920-pixel shading limit and a 200-tile-wide viewport.
The recorded result is `tests/fixtures/OpenFrontFalloutRevealBenchmark.json`.
The baseline disables staging in the same working tree; it is not a separate
checkout of the base commit.

Over `1fd32e8` plus this work: baseline/coherent paint-step p95 **2.599/2.607ms**,
max **2.755/2.962ms**; coherent final commit max **0.168ms**. Mean impact sink
writes **63.83 -> 1**; uploaded pixels **34,736 -> 65,536** (the coherent write
includes unchanged pixels inside its bounding rectangle). Median `Core.applyTileStates`
**21.56/23.93ms**, completion **19/19 worker calls**. These are shared-host Lune
CPU timings, including buffer-copy sink work, **not** Roblox native upload,
GUI/GPU, replication, real-time FPS or weak-phone performance. Run-to-run host/GC
variation was observed; this is no claim of a CPU speedup. Full gate results
are in STATUS. `tmp/fallout_evidence/codex_scheduler_comparison.png` is a labelled
synthetic raster comparison, not a Studio frame.

Official Studio inventory found the correct place in Edit, but `execute_luau`
was rejected because approval policy is `never`. No native launch, screenshot
or timing was obtained. Claude/Bruno should replay the Hydrogen/Atom shots in
the actual game, including a page boundary and ordinary gameplay camera.

## Portrait shorts camera, 2026-11-17

Studio-only `LocalPlayer.OpenFrontFilmCamera` still uses the same renderer,
uniform pixels-per-tile scale and real confirmed state. It does not change
orientation, hide HUDs, stage gameplay or control audio. Ordinary gameplay
and the original `{t,x,y,zoom,easing?}` keyframes retain their behaviour.

`play` now also accepts:

- A keyframe `{t, box={x,y,w,h}, fit=.9, easing?}`. `x/y` are the **centre**,
  `w/h` are tile extents, exactly matching `ConquestFilming`'s returned `box`.
  This replaces `x/y/zoom` on that keyframe. Fit uses the smaller of available
  width / box width and available height / box height, with optional breathing
  room `fit` in (0,1]. It recomputes on viewport resize, including during the
  final hold. Boxes and explicit zooms can be mixed in one timeline.
- An optional shot `frame={x,y,w,h}` in **viewport fractions**, all inside
  [0,1]. The box/anchor is centred in this rectangle, and box fitting uses its
  dimensions. Omit it for the full viewport. This is composition, not a crop
  or clipping mask; terrain continues to fill the actual viewport.
- Optional shot `labelPixels=60`: visible names use a 60px em and troop counts
  a 42px em at 1920px viewport height (30/21 at 960px, intended to export at
  2x). Flags, heads and status icons follow the name; troops get extra line
  spacing. Default/source LOD and label exclusions still apply: zoom in on
  the important nations rather than trying to show every tiny name. The
  override resets on `stop`, shot replacement, error and teardown; no global
  render policy or normal player text is changed.

After restarting Play for Rojo edits, enter a match and wait for map readiness.
Set the Studio emulator/window to 9:16. In the **Client** data model:

```luau
local player = game:GetService("Players").LocalPlayer
player.PlayerGui.ScreenOrientation = Enum.ScreenOrientation.Portrait
-- Paste the Server ConquestFilming reply's box into this Client-side table.
-- These numbers are an example; use the actual staged map coordinates.
local box = {x=1000, y=500, w=180, h=260}
player.OpenFrontFilmCamera:Invoke("play", {
    duration=6,
    labelPixels=60,
    frame={x=60/1080, y=310/1920, w=820/1080, h=940/1920},
    keyframes={{t=0, box=box, fit=.9}},
})
-- Hold the last pose until explicitly released:
-- player.OpenFrontFilmCamera:Invoke("stop")
```

For an anchor close-up instead, supply
`box={x=reply.anchor.x,y=reply.anchor.y,w=160,h=240}`. Adjust extents to include
the action and inspect long labels at capture size. The example safe frame
maps to x60–880/y310–1250 in 1080x1920 output; its centre is (470,780).
To reserve more room for the y370 caption, increase `frame.y` and reduce `frame.h`.

Keep `OpenFrontMap` enabled. For clean story/meme footage Claude can disable
`ConquestUi` at shoot time, then restore it for tips. Mute **Music** in Settings
while retaining SFX; the filming endpoint deliberately does not touch audio.
OBS must record only the actual portrait game view, with matching 9:16 output
and no capture of Studio chrome. Changing ScreenOrientation alone does not
create a portrait desktop viewport.

Tests in `OpenFrontFilmCamera` cover aspect/resize and safe-frame coordinates,
height/width box fits, interpolation, page aspect, label scaling/LOD and
restoration (including unchanged name em with changing troop geometry).
These are headless property checks, not native font/layout/GPU evidence.
Official Studio inventory was available, but the first Edit `execute_luau`
sync check was rejected because approval policy is `never`; no Play,
orientation change or portrait screenshot was obtained. Gate results and
tested base commit are in STATUS.

## Capped warship health bars, 2026-11-13

Bruno approved the smaller close-zoom bar. `RenderPolicy.capWarshipHealthBars`
defaults true: width/height/rim cap at 48/5/1 screen pixels, retaining smaller
source dimensions at wide zoom. False restores OpenFront's 11x3-tile bar and
one-tile rim. Set the policy before a new renderer/match, like the other flags.
Health thresholds, colours, centring/vertical placement and structure bars
are unchanged. Full-health and zero-health warships still hide the bar.

Runtime functions: new local `SceneOverlay.cappedWarshipBarSize`, and local
`SceneOverlay.drawUnit`. Its pose-only path refreshes only a visible capped
bar's rectangles when movement and zoom coincide, retaining the hull/style
fast path. Recent's original constant-geometry check runs with the cap off;
SmoothLook also requires that fast path with the cap on.
No new views/images/uploads. `OpenFrontSmoothLook` checks both policies across
wide/close zoom, simultaneous movement, structure dimensions, colours,
placement and hiding. Gate results are in STATUS; native appearance remains
for Claude/Bruno's recording session.

## First paint during an active match, 2026-11-13

Claude reported a second Studio play session stuck near 90% while the server
continued expanding and staging ports/warships. Native Studio inventory and
console reads succeeded here, but the Client Luau readiness sampler was
rejected before execution (`approval policy is never`). The exact predicates
in that live session were not inspected; no native restart/rollout proof.

The local harness reproduces a matching deadlock with continuous confirmed
tile changes: first-use CoastRaster.prepare waits for core.pending == 0, but
it runs before RasterCore.step. New deltas can make that condition false on
every frame, even though the raster drains later in the frame. Across two
raster pages, updates can also keep a previously uploaded page dirty while
the other page finishes. Waiting for the whole live match to be idle is not
a finite first-paint contract.

Full paint now holds each fully painted/uploaded base page while the remaining
pages finish. `RasterCore.step` accepts an optional held-page set for this
adapter only; pending rows/revisions remain queued. Once all base pages are
uploaded, `firstPaintBaseReady` permits initial coasts to sample those complete,
unchanging RGBA pages. The adapter waits for decoded state before painting
that base. Normal scene preparation, unit/name creation budgets,
coast readiness and the no-upload settling frame still gate reveal. The map
stays hidden until that full base and scene are ready. Once coast/scene
preparation finishes, one final refresh includes paint work queued up to that
checkpoint, reopening already-uploaded pages as needed. Each refreshed page
is held again while the resulting coast recolouring finishes. This preserves
the existing live-invalidation freshness check without letting subsequent
updates restart loading indefinitely. Those later deltas resume on the next
frame after reveal under the ordinary budgets; no delta is dropped.
The initially revealed territory can lag updates received after the final
refresh checkpoint, then catches up normally.
Incremental rendering and the single displayed-image-per-frame limit remain.
`metrics().firstPaintBaseReady` identifies that loading phase.

Exact runtime functions changed: `EditableRenderer.new`, `step`, `metrics`;
`RasterCore.step`; `CoastOverlay.prepare`;
`CoastRaster.prepare`. No
OpenFrontClient/Main, shared/server/config, health-bar or filming edit.

`OpenFrontLoading` covers one and two raster pages, cold and repeat entry,
ports/damaged moving warships and continuous confirmed ownership updates.
Both cases fail to finish against the pre-fix HEAD source; after the fix both
pass. Two more cases cover late state attachment and updates every two/three
render frames (interleaved with quiet frames). The tests check
hidden-until-ready, held base bytes within each phase, bounded final refreshes,
one displayed image per frame, a quiet settling frame, one ready notification,
queued-delta catch-up, coast colour equality with a fresh composition and
image cleanup through rematches. The unchanged OpenFrontFirstPaint 9/0 cases
also pass, including the exact live-update pixels before reveal. An earlier
full run was 604/1 on that existing freshness assertion; the corrected full
rerun and final gate results are in STATUS. These are shim observations,
not native FPS or loading-time measurements.

## Singleton railroad orientation, 2026-11-13

Creator Hub reported `UnitVisuals:115: attempt to perform arithmetic (mod) on
nil and number` on place version 699. At `cc16624`, that line is railType's
`other % width`, not a unit position/owner calculation. A one-tile railroad
has neither previous nor next tile, so `prev or next` was nil. Such paths can
arrive in a snapshot or after RailNetwork splits a railroad near an endpoint.

The pinned OpenFront v0.35.2 `RailroadPass.computePathOrientations` and
`RailroadCache.computeRailTiles` explicitly draw a singleton as vertical.
`Visual.railType` now returns vertical (our encoding 1) when both neighbours
are nil. Other endpoint/turn rules and authoritative rail data are unchanged.
No generic missing-unit fallback, tile-zero substitution or packet handling
was added to the renderer.

Two regressions reproduced the exact line-115 exception before the fix:
OpenFrontScene checks singleton orientation (including tile zero), and
OpenFrontAdapters drives ClientState/renderer snapshot attachment, construction,
a split leaving one tile, rendering and later destruction. Both pass after
the fix. No native Studio or live-client rollout check by Codex.

Verification over `cc16624` plus this fix: full suite **602/0**, including
both new regressions **2/0** (subset); fresh-sourcemap full-src strict analysis,
Rojo build and scoped whitespace checks pass. The warship listener warning is
the expected error-isolation fixture.

## Studio filming camera, 2026-11-12

Bruno chose full gameplay HUD and nation labels for the Build / Conquer /
Dominate page video. FilmCameraController leaves both visible; captions and
the end card belong to the later edit. No simulation or camera-bound change.

After a Studio match creates its renderer, the local Player has a
`OpenFrontFilmCamera` BindableFunction (absent in live games). In the Client
data model, wait for the loading cover to disappear, then:

```lua
local camera = game:GetService("Players").LocalPlayer:WaitForChild("OpenFrontFilmCamera")
camera:Invoke("play", {duration = 4, keyframes = {
	{t = 0, x = 1000, y = 500, zoom = 3},
	{t = 4, x = 1050, y = 500, zoom = 2.8, easing = "smoothstep"},
}})
return camera:Invoke("status")
```

Coordinates are float centres in the **loaded map's tile space** (Compact
has different dimensions). Zoom is actual screen pixels per loaded tile;
use a 1920x1080 viewport for the agreed filming scales. No implicit resolution
scaling is applied. Easing belongs to the destination keyframe, defaults to
linear, and affects both centre interpolation and logarithmic zoom. The first
keyframe must be at t=0; times strictly increase within a finite positive
duration. A single static keyframe is allowed. Inputs are validated and copied.

`play` applies the first pose and returns true without waiting. Renderer.step
updates the shot from elapsed monotonic time **before** raster/scene work.
The final pose holds, with status `{playing=true,t=duration}`, until
`camera:Invoke("stop")`; stop returns true, releases control at that pose and
clears t. Replay replaces the current shot and starts its clock again. The
scripted camera blocks map gestures and goTo/focus/fit requests, cancels held
input and existing fly-to, and clears chosen/pending previews (including stale
reply generations) through the thin OpenFrontClient callback. HUD controls,
music, labels, confirmed effects and normal rendering budgets remain active.

Malformed commands stop the current shot and raise an error. Runtime camera
errors stop filming with a warning; they do not tear down the match. Renderer
destruction removes the endpoint and its connection; a new renderer creates
a new endpoint, so reacquire it after a staging reset/new Snapshot. This camera
does not schedule server staging or OBS: arm recording first, invoke play,
and use separate calls to inspect status/stop. Test coverage is pure math plus
the renderer/input property shim; native Studio/OBS pacing remains to verify.

Verification over `41d4c6c` plus this camera and Claude's concurrent server
staging work: full suite **600/0**, including FilmCamera **10/0** (subset),
fresh-sourcemap full-src strict analysis clean, Rojo build and scoped whitespace
checks pass. No native Studio or OBS capture/pacing check by Codex.

## UI overlap review M1-M6, 2026-11-11

Working tree over `86ca2c9`, from Claude's bounded map-side brief and Bruno's
desktop recording (`docs/design/UI_OVERLAP_REVIEW.md`). No screen UI or
orchestration edits by Codex. Extracted video frames at 1:17, 5:42, 5:55 and
11:02 were inspected; they are evidence of the old build, not the fixes.

- **M1:** `renderer:setLabelOccluders(rects)` accepts up to 64 `{x,y,w,h}`
  rectangles in absolute screen pixels, the same space as `worldToScreen`.
  Pass only visible occupied areas (rail, CoreGui exclusion, ATTACKS, notes,
  wheel/title, confirm/banner, etc.), after converting from the HUD's own
  parent/UIScale once. Replace the list after rebuild/resize/visibility changes;
  an empty list clears it. The renderer copies values and keeps no GUI refs.
  Nation ink intersecting an exclusion hides. Own ink tries nearby positions
  within 96 screen pixels, then hides when covered. Sim anchors, source LOD,
  troop cadence and camera picking are unchanged. Existing name roots carry
  the visibility/offset; no extra per-name GUI is allocated. Until Claude
  wires the rectangles, M1 has no HUD effect.
- **M2/M3:** both the Attacking/Expanding text and Boat/Missile toasts are
  `OfActions` screen UI. `renderer:playerNameScreenRect(id)` supplies complete
  displayed ink bounds, including prefix, troops, outlines and status icons,
  or nil when hidden. The existing position API follows an own-label offset
  and returns nil for excluded ink. Toast placement should avoid these bounds
  and HUD/wheel bounds. Do not feed a name-anchored toast back as an exclusion
  for its own label: doing so creates a hide/reveal feedback loop. Claude owns
  toast placement and integration; there is no separate persistent map front
  label to move here.
  Optional `playerNameScreenRect(id, true)` returns anchor bounds before LabelPlacement moves or hides the label, for stable occluding-panel placement.
- **M4: reverted by Claude at Bruno's request (2026-11-11):** "I liked how I
  could zoom out or drag past the map's edge into the grey background".
  `CameraBounds`, its two Overlap cases and the Feel/Mobile fixture edits are
  removed; `pan`, `zoom` and resize are back to the source behaviour.
- **M5:** the price tries eleven nearby positions clear of displayed name ink,
  supplied HUD exclusions and viewport edges, and hides if none fit. Cached
  layout updates on preview/name/camera/exclusion changes; camera callbacks
  update it before observers. No extra image upload or outcome prediction.
- **M6:** map range layers intentionally remain below screen UI. The SAM
  radius and circle geometry are untouched; notes shrinking is Claude's U4.

Changed runtime functions: new
`LabelPlacement.intersects/clear/cost/own`; `EditableRenderer.new`,
`playerNameScreenPosition`, new `setLabelOccluders` and
`playerNameScreenRect`; `SceneOverlay` private `measureText`,
`placeBuildCost`, `setNameVisible`, `namePose`, `drawBuildPreview`, `drawNameLine`,
`drawNames`, public `nameScreenRect`, `layoutLabels`, `setCamera`, `step`.
No Main/client orchestration,
shared/server, screen UI, upload, staging or commit by Codex.

`OpenFrontOverlap` covers both GUI modes, copied/exchanged HUD rectangles,
short own-label offsets and hidden fallback, complete bounds/anchor agreement,
price avoidance on first draw/camera change, crowded fallback, viewport-cover
zoom/pan/resize and retained explicit full-map fit. The Mobile pinch fixture
starts at zoom 8 (above its new cover floor) and retains the exact two-times
gain/subpixel assertions. Feel establishes the cover floor before its pure
translation check. Preview checks a stale response is replaced by a denied,
unvalidated draft after an in-bounds camera move and a failed query. Native
appearance, phone feel and integrated HUD rect collection require Claude's
Studio/device check.

Final working-tree gates: OpenFront renderer subset **330/0**, including
Overlap **5/0**, Mobile **10/0**, Preview **16/0**, Feel **11/0**, Recent
**8/0**, RoundB **23/0** and WideZoom **1/0** (subsets, not additive).
Fresh-sourcemap full-src strict analysis, Rojo build and whitespace check pass.
The existing first-paint deadline/reveal/upload checks and wide-zoom GUI/frame
ceilings remain unchanged. No full integration suite or native/device run by
Codex. Claude's concurrent UI and unrelated files remain untouched.

## First-paint budget test deadlines, 2026-11-10

Working tree over `a2d9426`, from Claude's bounded brief on the two audit-era
failures. No renderer function changed. Both failures were at the tests'
`isReady()` assertion after 100 calls, rather than their image/view budget
assertions. Both specs passed unchanged here (MatchPerf 24/0, RoundB 23/0),
so the original host timing was not reproduced with the normal 30 ms slice.

The 100-call expectation predates progressive row commits (`f64fb61`) and the
static-coast preparation/readiness gate (`a480ec4`). Full paint is time-sliced,
not guaranteed within 100 calls. A deliberately exhausted positive raster
slice reproduces the failing condition in both fixtures: at frame 100 scene
creation is ready, but map rows remain and the loading cover correctly stays
up. A diagnostic run finished at frames 134/133 (MatchPerf/RoundB). These are
test-shim observations, not device loading times or a native performance claim.

Only the named test callbacks in `OpenFrontMatchPerf.spec.luau` and
`OpenFrontRoundB.spec.luau` change. Each exercises the ordinary 30 ms and an
exhausted `1e-9` ms slice, with a finite bound of all block rows plus 32
preparation/reveal turns (160 for these 64×64 fixtures). The exhausted case
must still be pending at the old frame-100 cutoff. MatchPerf keeps checking
at most one distinct uploaded image per frame, including after reveal, and
requires a composed cache page and image teardown. RoundB keeps the shared
25-new-name/flag/head limit and requires every flag/head on the first revealed
frame. Both additionally check the map root stays hidden until readiness.
No production budget, readiness gate or invariant is relaxed.

Gates on this working tree: MatchPerf **24/0**, RoundB **23/0**, full
OpenFront renderer subset **326/0** (includes both specs), fresh-sourcemap
full-src strict analysis, Rojo build and whitespace check pass. No native or
device check, shared/server/UI edit, staging or commit by Codex. Claude's
concurrent pathfinding work and `weppy-project-sync/` are untouched.

## Sabotage and Field Works presentation, 2026-11-09

Working tree over `02310c5`, against the agreed final two `ARSENAL_V2`
contracts. No shared/server/UI/orchestration changes by Codex.

Sabotage aim outlines the server's actual `sabotageAim.targetTile`, including
tile zero, rather than snapping a structure ghost to the cursor. A missing
target, denied build or insufficient funds is red. A public active `Sabotage`
record renders a small stationary warm spark with a short sputter. Its final
`reachedTarget` does **not** imply success: fizzles have the same final flag.
Only a copied, continuous active building record changing `dark` false → true
emits a brief cool inward switch-off accent. Snapshot seeds emit none.

Dark buildings use a genuinely grey composed/fallback style. A slow GUI-only
opacity pulse updates existing images without restyling/uploading every frame;
absolute base alpha prevents cumulative fading. Clearing the confirmed flag
restores the owner palette. At most 32 indexed dark records are visited/frame.

Field Works uses the structure **presentation** pass, without entering sim
structure rules or the structure explosion/settle classifiers. An original
sandbag/trench glyph and rectangular plate occupy (480,0) and (448,0), 32px
each. Atlas remains 512×192; existing pixels outside the new spare cells are
guarded. Ghost stays at the tapped location even with controller snapping on;
the radius comes from `fieldWorksAim.radius` or shared
`FieldWorksExecution.RADIUS`. Invalid/unaffordable circles turn red. Inspect
uses the shared radius and existing owner/enemy/allied colours.

Construction shows a grey symbol, a filling build bar and two tiny moving
earth flecks. The flecks reuse the existing Arsenal shot pool. On completion
the same bar counts down from confirmed `expiresAt`, using shared `BUILD` and
`LIFETIME`; it also recovers snapshot construction progress without inventing
a new start tick. No local expiry removes the confirmed unit. An inactive
final or removal produces one gentle .65s glyph fade; no explosion. Snapshot,
duplicate and offscreen suppression apply.

Fuses/digging share the existing 32 shot slots / 128 candidate visits, with
four new groups/frame and plane priority retained. Switch-off/fade share the
12 merged accents / two new groups/frame. One extra image per accent displays
the fading earthworks glyph (at most 12). No new effect pool, per-tile particle,
delayed callback, camera shake or image-upload allowance. Existing snapshot,
match-end and destroy paths own cleanup; the aim outline is explicitly destroyed.

Exact functions/files for this round:

- `BuildPreviewController`: `Reply`, structure classification, private `draft`
  and `draw` forward the new aim contracts, radius and no-snap behavior.
- `UnitVisuals`: presentation lookup and new pure `fieldProgress` helper.
- `RenderDefaults.structure.shapes`: Field Works size.
- `SpriteAtlas.arsenalDistance/rgba/iconRect/shapeRect`, `StructureAtlas`
  private `distance`: original Field Works plate/glyph and cached composition.
- `ArtilleryState`: projectile classification, private `record`/`mark`, and
  `updates` copy dark state, suppress fuse success inference, deduplicate
  switch-off/removal accents and retain the existing caps.
- `ArtilleryOverlay`: private `usesSlot`, `shellVisible`, `markNew`, plus
  `setUnits` and `step` render pooled fuses, digging, switch-off and fade.
- `SceneOverlay`: watched fields/`changedUnit`, private `drawUnit`,
  `structureRange`, new `drawSabotagePreview`/`stepSupport`, `drawBuildPreview`,
  `sameGhost`, `setUnits`, `step` and `destroy` handle grey styles, absolute
  pulse alpha, lifecycle bar, aim/range invalidation and cleanup.

`tests/OpenFrontSupport.spec.luau` has eight cases for spare masks, shared
durations, actual-target/tile-zero/nil aim in both GUI modes, no-snap/red-range
placement, copied dark/fizzle/snapshot history, removal deduplication,
desaturation/restore/pulse uploads, digging/countdown/fade/teardown, and crowded
mixed fuse/digging/accent caps. The Artillery atlas golden excludes only the
added spare cells. This is pure-state/native-property proxy evidence, not
native GUI layout, GPU cost, phone feel or Studio appearance evidence.

Final gates on this working tree: focused **8/0**, renderer subset **326/0**
(includes the eight focused cases), fresh-sourcemap full-src strict analysis,
Rojo build and whitespace check pass. No new Codex full-suite or native run.

Art: `art/dossier/{arsenal_sabotage,slot_sabotage,arsenal_fieldworks,slot_fieldworks}.png`.
Photos 1024×704 opaque; slots 256×256 with genuine alpha. Built-in imagegen,
people/face-free full-scene/detail/card/icon inspection, exact prompts and
selected/rejected sources in `art/dossier/PROMPTS.md`. Claude owns Bruno's
approval, uploads and UI assets. No Codex upload, Studio action, staging or commit.

## Coastal Battery presentation, 2026-11-09

Working tree over `02310c5`, against the agreed `ARSENAL_V2` Coastal Battery
contract. Original casemate/barrel glyph and chamfered plate use spare atlas
cells (416,0) and (384,0), each 32px; the atlas remains 512×192. Cached
structures and fallback ghosts use the same shape. Construction, damaged
health bars, confirmed settle/completion and destruction use existing paths.

Draft and confirmed ranges read `Config.COASTAL_RANGE`. The confirmed Coastal
ghost and ring always follow the server's returned shore tile, including the
default controller options used by OpenFrontClient. The renderer chooses no
shore tile itself. Tapped batteries use existing inspected-range yellow/red/
allied-blue colours. Other structures retain their current snap settings.

Ordinary `Shell` stays in its existing mobile/trail/impact renderer. A copied
history of finished battery tiles identifies its first confirmed source and
adds a short muzzle accent inside the existing 12-accent pool. Explicit
`sourceTile` supports first-tick movement and instant confirmed impacts; a
first record at the battery also works. No nearest-gun/Warship inference.
Snapshots seed without accents; duplicate records, ownership, construction,
removal and offscreen sources are covered. No new image, upload allowance or
effect pool. **Shared wiring resolved (Claude, 2026-11-09):** ShellExecution
now sets `self.shell._sourceTile = self.spawn` at creation, before its first
three moves. Codex confirmed it in current source; existing Replication sends
the field. No new record field or further wiring request is needed.

Exact runtime changes:
- `UnitVisuals`: structure lookup and construction-duration table.
- `RenderDefaults.structure.shapes`: Coastal Battery presentation size.
- `SpriteAtlas.arsenalDistance/rgba/iconRect/shapeRect`: original plate/glyph.
- `StructureAtlas` private `distance`: matching cached plate.
- `BuildPreviewController` private `draft` and `draw`: config range and
  confirmed shore snapping by default.
- `SceneOverlay` private `structureRange`: inspected range.
- `ArtilleryState` private `record`, `new`, `seed`, `updates`: copied Shell
  history, confirmed battery index, muzzle accent and cleanup.
- `FeelState`/`FxState`: structure classification for existing lifecycle FX.

`tests/OpenFrontCoastal.spec.luau`: five cases for atlas/type/duration, default
shore ghost/range in both GUI modes (a deliberately changed range proves the
config read), inspected colours and health, source/dedup/snapshot/instant-hit
history, capture/construction/removal/visibility and generic Shell rendering.
The Artillery golden atlas guard excludes only the two newly occupied cells.
Focused **5/0**, fresh-sourcemap full-src strict analysis and Rojo build pass.
Full suite **748/12**: all failures were missing `isDark` in shared Coastal
Battery (2), nation traces (5), Runner preview (1) and structure traces (4),
while Claude's Sabotage API was being added. Current `Unit.isDark` exists;
fresh-process **OfCoastalBattery 4/0** and **OfRunner buildPreview 1/0** pass.
Claude subsequently confirmed those were his half-finished Sabotage edits;
he reports completed OfSabotage 5/0, OfFieldWorks 4/0, OfCoastalBattery 4/0,
OfNations parity 14/0 and strict analysis clean. No Codex clean full-suite claim. Fresh
renderer subset **318/0** (includes focused cases). No native/device evidence.

Original card/slot art: `art/dossier/arsenal_coastal.png` (1024×704, opaque) and
`slot_coastal.png` (256×256 RGBA); prompts, selected originals, export and
crew/face-free QA in `art/dossier/PROMPTS.md`. Claude owns Bruno's art approval,
uploads, UI and products. No shared/server/Ui/Main edit, Studio action, upload,
staging or commit by Codex. Concurrent files and weppy-project-sync preserved.

## Paratroopers aim marker fix, 2026-11-09

Bruno's Studio screenshot `capture/bruno-2026-11-09-para-blob.png` showed a
large yellow canopy fragment over the top-left map before launch. The private
`SceneOverlay.drawStrikePreview` called `spritePart` after sizing/positioning
its standalone landing image. That helper intentionally resets child bands to
position zero, size 100% of their parent, and visible. It stretched the canopy
to the viewport, placed its centre at the top-left, and defeated offscreen
culling. Atlas styling now runs before the marker's pixel geometry and final
visibility. This is the only runtime function changed in this follow-up.

The new `OpenFrontParatroopers.spec.luau` regression failed before the fix
(`Size.X.Scale` was 1). It checks bounded pixel size, target position with
nonzero viewport origin, atlas rectangle and offscreen hiding in both GUI
modes, draft/validated aim, zoom .2/4/20 and desktop/phone viewport sizes.
Focused tests **8/0**, renderer subset **313/0** (focused cases included);
fresh-sourcemap full-src strict analysis, Rojo build and whitespace pass.
No new full suite or Studio playtest by Codex in this follow-up.

## Paratroopers presentation, 2026-11-09

Working tree over `928ad4a`, against Claude's agreed `ARSENAL_V2` contract.
Original transport plane in its owner's colour with a dark outline, 16–32 px
across zoom levels. Interpolation starts at the last displayed confirmed pose
and stops at the newest confirmed tile; it never extrapolates. This covers the
whole delta rather than only `lastTile` (the sim moves four times per tick).
Snapshot seeding starts at the current tile and suppresses historical effects.

The advisory aim reuses the clipped launcher line and existing SAM discs, with
an 18–28 px canopy/crate landing symbol. Missing origin, failed buildability or
insufficient gold turns the validated marker red. Tile zero remains valid.
No nuke trajectory, predicted interception or invented blast/range disc.
Confirmed `reachedTarget` finals bloom three small canopies for .85 s; an
inactive plane with a matching targeting SAM and confirmed `destroyer` smallID
gets a short flash and .65 s falling smoke. Owner cleanup without a destroyer
never becomes a shoot-down. **Integration dependency resolved, 2026-11-09:**
Claude added `destroyer` smallID on Paratroopers records and in their signature;
Codex confirmed both in the current source during the aim-marker follow-up.

Paratroopers share Artillery/strike limits: 32 flight slots, 12 accent groups,
128 candidate visits, four new flight groups and two new accent groups/frame.
Visible troop planes preempt ordinary shot views inside the same cap rather
than waiting for a shell barrage to end. Nearby accents merge. No extra raster
image, upload allowance, particles or
delayed callbacks. Two original 32×32 masks occupy spare base-atlas cells
(320,0) and (352,0); the atlas remains 512×192 and its existing scheduler owns
the upload. At saturated pool sizes the added outline/canopy views cost at
most 68 extra GUI instances, plus one retained aim image; native memory/layout/
GPU cost is unmeasured. Snapshot, match-end and renderer teardown clear history
and return/hide or destroy owned views.

Exact runtime changes:
- `ArtilleryState`: projectile classification, private `record`/`mark`,
  `new`, `seed`, new `flightPosition`, `updates` (confirmed SAM association,
  interpolation, finals, deduplication and removal cleanup).
- `ArtilleryOverlay`: `new`, `setUnits`, private `shellNew`, `shellPose`,
  `shellVisible`, `markNew`, and `step` (priority, owner tint/outline, canopy
  bloom and falling smoke).
- `BuildPreviewController`: `Reply`'s optional `paraAim`, structure
  classification and `draw`'s forwarding of `paraOriginTile`.
- `SceneOverlay`: private `drawSams`, `drawStrikePreview`, `sameGhost`, and
  `destroy` (reused line, SAM ranges and owned landing marker).
- `SpriteAtlas.rgba`: original antialiased transport/canopy masks;
  `UnitVisuals` mobile lookup: Paratroopers classification.

`tests/OpenFrontParatroopers.spec.luau` covers masks/classification, valid and
invalid preview/origin0/SAM visibility in both GUI modes, copied history,
instant finals/duplicates/snapshots, packet ordering, cleanup versus shoot-down,
continuous interpolation without extrapolation, zoom size limits, public owner
tint, shared caps, one-image scheduling and teardown. The Artillery golden hash
excludes only the two newly occupied cells in addition to prior Arsenal cells.
Art: `art/dossier/{arsenal,slot}_paratroopers.png`, exact imagegen prompts and
selection/export/QA in `art/dossier/PROMPTS.md`. No realistic people/faces.
Claude reports Bruno approved the art and it is uploaded/wired: recon photo
71651099922269, slot 105699809418459. Codex did not independently verify native
asset delivery. Product unlockParatroopers is 3730069193 (Claude's report).

Native flight/landing/interception appearance, phone cost/touch feel, crowded
saturation and live multiplayer agreement remain unverified. No Studio action,
upload, shared/server/UI/Main edit, staging or commit by Codex this round.

Gates: focused renderer **7/0**, fresh-sourcemap full-src strict analysis,
Rojo build and whitespace pass. Full suite **748/2**: only failures were
`OfParatroopers`' flight/landing ownership and 30-second pocket-hold cases.
A fresh process on the current files passes **OfParatroopers 6/0**. The long
full-suite process overlapped Claude's shared/sim edits; stale loaded sim code
is a plausible cause, not a proven diagnosis. No clean full-suite claim.

## Renderer speed A/B implementation, 2026-11-03

Over `f18c754`, two independent **RenderPolicy flags default OFF**:
`splitMapGuis` and `deferredOwnership`. Exact functions, design/limits, raw
records, reproduction and Bruno's A/B sequence are in
[`ROWORLD_RENDER_SPEED.md`](../../../../docs/openfront-port/ROWORLD_RENDER_SPEED.md).

- GUI split: static, moving and label content are separated, interleaved into
  seven ordered ScreenGuis to retain ground < structures < missiles, effects
  after names, and world text above both. All stay below HUD order 10. Separate
  structure progress proxies follow the original cell/pose/scale. Full bleed,
  ready cover, viewport origin, resize-before-observers, modal input and owned
  snapshot/menu cleanup are covered by property tests. Native overlaps/clipping
  and extra ScreenGui overhead remain unreviewed, hence OFF.
- Deferred dirty expansion copies confirmed state immediately. Sparse edits
  narrow centre/cardinal/hovered-diagonal work, including our foreign-border
  cache requirements. Runs and >=4096-ref bulk changes retain conservative
  halos and drain in <=256-tile spans. Own priority and ordinary FIFO service,
  snapshots, repeated edits, caller reuse, flags/relations/trails/coasts and
  one-image scheduling remain. Targets: 2048 tile visits, min(1.25ms, half the
  raster budget); spans/native calls are non-preemptible. Sparse/run record cap
  32768; bulk reservation cap 512KiB; overflow uses immediate work. Metrics expose
  pending records/own records/ages, buffer bytes and fallback counts. Dirty-block
  count alone cannot describe unexpanded backlog. OFF because callback peaks
  improve at the expense of total CPU and drain latency in these host tests.

Serial World Core callback peaks: front1200 **1.022→.857ms**, scatter1200
**8.879→2.384ms**, capture26000 **22.530→12.325ms**. Settled fingerprints match.
Scattered shaded pixels **171363→93444**, calls **18933→19160**, max drain
**22→24** frames; capture calls **412→619**, drain **21→24**. No total-CPU win.
RecentPerf fixed-camera 600 ships changed-GUI subtree scope **70151→52798**
objects across 240 frames, but script mean **1.820→2.049ms**. This scope proxy
does not measure Roblox invalidation/layout/GPU or establish phone FPS.

Candidate 3 upload merging is deferred; candidate 4 is skipped as requested.
Focused RenderSpeed 6/0; fresh sourcemap/full-src strict, Rojo build clean.
Complete OpenFront renderer subset **258/0**, including all changed specs.
No full suite, Studio/phone check, upload,
staging or commit by Codex. Claude's code/commit ownership is preserved.

## RoWorld inline labels and speed review, 2026-11-03

Over `8b6dd57`: flag / round positive-ID human head / name on one centred
line, troops below. `NameLine` and SceneOverlay's `drawNameLine/drawNames`
port RoWorld `2be8efb` NameLayer presentation, credited in code. Bots/nations,
nil and nonpositive Studio IDs never get heads. Per-renderer `rbxthumb` URL
cache, no yielding API; view creation shares the name/status budget. Flags keep
UI-owned small FlagArt pages, Fit and internal alpha margins. Text fills stay
human 0 / nation .3 / bot .4; owner strokes now follow text size (.085 em,
minimum 1.4 screen pixels per line). Flag/head proportions .78/1.05 em.

Confirmed OpenFront placement/easing/culling, all-player 8% em cap, troop
cadence, status anchors, label toggle and toast anchor API remain. The whole
row is centred on that anchor rather than appending images left of centred
text. No camera or raster-speed change. Exact source differences, function
list, limits and ranked speed candidates are in
[`ROWORLD_CLIENT_REVIEW.md`](../../../../docs/openfront-port/ROWORLD_CLIENT_REVIEW.md).
Priority: separate static/moving/label ScreenGuis, selective deferred dirty
work, bounded upload merging, then crowded moving-unit write cadence. These
are code-based candidates, not measured phone speedups.

Gates: RoundB 23/0; OpenFront 250/0 (including changed NameCap/Adapters), fresh
sourcemap/full-src strict, Rojo build and whitespace clean. No Studio/native
thumbnail or phone appearance/performance check; no upload/staging/commit.
Changed runtime functions: SceneOverlay.new/destroy, private drawNames and
drawNameLine (replaces drawFlag); new NameLine.userId/layout/outline.

## Warship sinking and recent-client audit, 2026-10-30

Working tree over **`2a585db`**, including static coasts `a480ec4`. Bruno reported
the old sinking hull and some lag on 2026-10-29. Claude's Studio paused/running
comparison suggests much of that session's hitching comes from the server in
the same process. This round measures client work only; it does not identify
the cause of a particular native 5.4ms units sample or prove a phone FPS fix.

**Correct sinking row:** pinned `FxSpritePass.ts` names **3 UnitExplosion,
280ms**, and **5 SinkingShip, 1260ms**. The relay had those labels reversed.
Confirmed Warship finals retain both source emissions. Row 5 now displays
ShipArt's existing normal Warship cell, at the confirmed tile centre, in its
owner's colour and last confirmed heading (including a stopped ship). It tilts
22 degrees, squashes/sinks and fades over **1260ms**. Row 3 stays unchanged.
One gray plume from existing row 7 accompanies the new hull, sharing the global
particle cap. No new atlas, asset or image upload is needed for sinking.
The existing ship-image allocation fallback still uses source art.

The smoke counter previously included row 5, which is a hull. It now counts
actual fire/smoke **rows 6–9**, capped at **24 touch / 48 desktop** as before.
Sinking hulls and explosions use the ordinary effect pool: **25 new views/frame,
32 spares**, with controller-owned style reset/cleanup. Snapshots/duplicate
finals do not replay deaths. **Transports and Trade Ships have no death sprite
in the pinned source path; unchanged.**

**Measured changes, same final presentation:**

- First-time health bars and veterancy labels for existing ships now share the
  scene's **25-new-view-group allowance**. A bar group has two Frames; a pip
  label may include a UIScale. Pending adornments retry, without delaying ship
  positions, selection, commands or existing bars. A simultaneous 200-ship
  health/veterancy burst reaches its complete display within 16 logical frames
  in the regression, instead of allocating 800 components at once.
- Stable ship content/filter/tint/gradient state, pip layout and text sizes are
  retained. Combat ColorSequences are shared per owner colour and reset with
  the roster/renderer. Heading calculation is cached by confirmed tile/lastTile;
  **Rotation writes were already guarded**, and remain heading-change-only.
  Warship UIGradients and `ResampleMode.Default` remain: no native evidence
  justifies changing Bruno's accepted combat band or ship filtering.
- The existing FX atlas is prepared under full first paint, rather than
  synchronously decoded/uploaded on first combat. It still uses the single
  displayed-image slot. This moves about 19ms of first-use work in this host
  run under loading; it adds no atlas to a match that uses FX. Logical native
  FX backing is 660,960 bytes (.63MiB), now allocated earlier.
- Fallout's initial queue is implicit. Row flags initialize quickly; pixel
  production still resumes within **1024 pixels / 1ms per frame**. Changes to
  already-built or not-yet-built pixels remain exact. Caps, clipping, lifetime,
  upload sharing and mask memory are unchanged.
- Coast cells cache their four exact source RGBA samples. Broad delivered
  rectangles with unchanged colours skip pixel composition and upload. Shape,
  paint, schedules, caps and native pixels are unchanged. This adds **16 bytes
  per coast quad: .90MiB World / .22MiB Pangaea Compact**. Ready-at-load coast
  CPU buffers are now **14.06/44.37MiB World**, **3.17/10.25MiB Pangaea**, touch/
  desktop. Native coast pixels stay **10.47/40.62MiB** and **2.49/9.48MiB**.
- Pooled effects retain stable positions/sizes/frames/alpha where possible,
  and reset hull-specific content, tint, filtering and rotation on reuse.
  Defense range probes already resume within 2048 visits / 1ms, cache owned
  witnesses and use shared range budgets; their algorithm was left unchanged.

**Serial measurements:** desktop Lune, World, 844×390 touch policy, actual
renderer and decoded buffers with indexed child lookup/property counters.
Native layout, texture sampling/fill rate, GPU transfers, real phone hardware
and server/network execution are excluded. RecentPerf loads the five changed
map/FX modules plus CoastOverlay from read-only `git show 2a585db` for before;
everything else is shared. No source checkout is executed. Whole-call timings
include confirmed callbacks; `units`/`prepare` are renderer CPU scopes.

| RecentPerf scenario (240 frames) | Whole call mean ms, before→after | Relevant peak ms, before→after | Property assignments |
| --- | ---: | ---: | ---: |
| 795 idle views | .012→.012 | — | 35→35 |
| 600 moving ships + pan, 10Hz | 1.656→1.626 | units 5.152→4.712 | 29,713→29,713 |
| 200 damaged/combat warships | 1.421→1.198 | units 15.348→6.723 | 125,640→15,265 |
| 195 defense intersections | .076→.079 | whole call 5.575→5.804 | 4,256→4,256 |
| Four Hydrogen impacts + rest | .566→.418 | prepare 19.285→1.184 | 43,297→9,786 |
| 24 post destructions | .169→.165 | whole call 3.768→4.973 | 39,106→14,928 |
| 24 Warship sinkings | .123→.187 | whole call 3.186→4.045 | 30,890→23,186 |

The sinking case intentionally has the new hull animation plus capped smoke;
its extra **.064ms mean host CPU** is a cost, not an optimization win. Cases
run sequentially: impact masks/fire remain during the later destruction cases.
Range construction took the same 6,045 probe visits; steady range checks are
already cheap. Maxima vary with host scheduling/GC: no frame-time guarantee.
The final component counts match for idle/movement/health/ranges; 200 Warship
UIGradients remain. No ship Rotation writes occur in the idle/health-only guard.

Existing **ShipPerf**, with a `2a585db SceneOverlay` baseline and common remaining
modules: 600 ships / 60 owners, moving-pan mean **1.759→1.585ms**, p95
**7.380→6.990ms**, 600→600 ship ImageLabels / 1344→1344 GUI objects. Moving
positions still require the same writes. Treat these as modest proxy changes,
not a phone speedup ratio or evidence that new boats caused Bruno's lag.

Existing **CoastPerf**, 96 coastal submissions at 10Hz, 120 warmup + 240 measured
logical frames; the following totals also include draining the remaining queue:

| Map / policy | Whole call mean ms | Uploaded pixels | Recoloured quads | Drain frames |
| --- | ---: | ---: | ---: | ---: |
| World touch 2× | 1.346→1.262 | 224,352→133,854 | 19,994→5,784 | 9→6 |
| World desktop 4× | 1.278→1.035 | 565,744→350,696 | 9,546→2,292 | 21→14 |
| Pangaea touch 2× | 1.324→1.312 | 221,090→71,956 | 21,553→5,278 | 10→6 |
| Pangaea desktop 4× | 1.413→1.403 | 608,922→217,357 | 12,232→4,238 | 22→9 |

Native write-call count is not uniformly lower (Pangaea desktop increased);
smaller scattered rectangles trade calls against pixels. The phone World run
used 3946→3447 live rectangle writes. Idle/pan still do no coast recomposition
or upload. Native upload cost and translucent range/FX fill rate need Claude/
Bruno's device review. The old static-coast table below predates the colour cache.

Raw records: `tests/fixtures/OpenFrontRecent{,Coasts,Ships}.{before,after}.jsonl`.
Run serially, coordinating with Claude's Lune work:

```powershell
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontRecentPerf 2a585db
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontRecentPerf
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontCoastPerf 2a585db
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontCoastPerf working
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontShipPerf baseline 2a585db
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontShipPerf after
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/run OpenFront
```

**Exact functions changed:** FxState `deadUnit/unitUpdates/tick`, private
`sprite`; EffectOverlay `new/prepare/step/destroy`, private `rect/trim`;
SceneOverlay `setRoster/unitUpdates/step/destroy`, private
`textSize/newUnit/ensureBar/shipPose/shipCombat/smoothShip/drawUnit`;
CoastRaster `new/cell/prepare/bytes`; CoastOverlay `metrics`;
FalloutMasks `add/step`. No RenderPolicy, raster core, camera/input, shared/server,
OpenFrontClient, UI or gameplay config edits by Codex.

**Gates:** OpenFront **248/0**, including Recent **6/0**, Coasts **8/0** and
existing FX/finish/mobile/preview/raster guards (overlapping subsets).
Four new native regressions fail against `2a585db` modules in the read-only
baseline harness: FX prewarm, new sinking metadata/model, hull pool retirement,
and bounded adornment creation. Fresh sourcemap/full-src strict analysis,
Rojo build and whitespace pass. Claude's `Util.luau` work and unrelated
`weppy-project-sync/` remain untouched. No new full suite, Studio/device test,
upload, staging or commit by Codex. Claude's 582/0 full suite verifies the
preceding `2a585db` tree, not this new working round.

## Static curved coasts, 2026-10-29

Committed as `a480ec4`; this section records its original measurements.
The newer audit above supersedes colour-cache memory/performance figures.

Working tree over `0df6a17` (includes `ab76b53`). Bruno chose **“Smooth coasts
first”**: build the coast once at map load; territory boundaries stay stepped.
This supersedes the pending coast proposal in the older soft-edge section below.

**Enabled path:** `RenderPolicy.staticCoasts=true`, **2× touch / 4× desktop**.
`CoastGeometry` builds cubic isocontours from the fixed tile-centre land samples
and the source near-shore water band. Supersampled coverage/templates are
generated once in bounded slices, rather than filtering every raster update.
The second contour curves the pale-water band's outer edge too; otherwise it
would leave a conspicuous stepped blue outline around a curved land edge.
Only mixed coastal quads get art; terrain interiors retain their source pixels.

**Coverage contract:** terrain and political paint share the same curved
land/shore/ocean coverage, so a square territory fringe cannot poke outside it.
Original land/sea centres, terrain bytes, ownership, MatchSim, commands and
`screenToTile` stay authoritative. A true curve necessarily changes fractional
edge coverage; preserving every point of every square owned tile would restore
the staircase. This implementation preserves the tile-centre side and picking,
and clips paint consistently to the art contour. It does not claim the visual
boundary equals the square-grid boundary at every subpixel. Country-border
positions/owner sampling stay per tile; no live ownership contour is generated.

**Static geometry, changing colours:** `CoastRaster` reuses the immutable
templates when confirmed base raster rows change. It samples the already-painted
land/shore/ocean RGB values, so ownership, defended/hover/diplomacy colours,
terrain colours and patterns follow the ordinary raster. Sparse row indexes
invalidate only the quads sampling the delivered rectangle. Rest and pan/zoom
do **no contour generation or coast image writes**. Recolouring is required to
keep owned coastal land attached to the same curve; a permanently neutral RGBA
coast image would conceal ownership. Colours are queued per atlas page, deduped,
coalesced per patch and served fairly, using the newest base pixels when composed.

There is no per-tile GUI: 32×32-tile patches share packed EditableImage pages,
with extruded gutters. Image dimensions stay ≤1024. At scales below **.75px/tile**
the base raster supplies the subpixel-wide coast; medium/close views show the
curve layer. Existing patches inherit a single immediate world transform;
frustum work is at 10Hz. At most **16 patch entries/frame**, sharing the scene's
25-new-view allowance; **32 retirements/frame**, **32 spare views**, visible caps
**384 touch / 1024 desktop**. A cap overflow keeps the nearest patches and uses
the base raster elsewhere. World benchmark pan windows hit no cap (65/170
patches visible on touch/desktop). Source base pages are Z0, coast Z1, spawn Z2,
rails Z3: explicit [Sibling ordering](https://create.roblox.com/docs/reference/engine/classes/LayerCollector#ZIndexBehavior)
keeps spawn/ranges/ships/FX above the coast. Picking/input still reach the map.

**Budgets/cleanup:** geometry targets **8ms loading / 1ms incremental**. Initial
colour work targets 8ms / 4096 quads per frame, under the existing loading cover.
Full first paint waits for every coast page/colour queue and required visible
patch. Live recolouring targets **.75ms**, at most **256 touch / 512 desktop
quads**, **65536/131072 uploaded pixels**, **32/64 rectangle writes**. All writes
in one frame target **one image**, sharing the existing displayed-image slot
with base raster and other atlases; under base backlog coasts use at most one
in four frames. Native allocation/upload is non-preemptible and not timed by
the CPU budget. Optional native pixel caps are **16MiB touch / 64MiB desktop**;
allocation/write refusal falls back to the complete base raster. An unexpected
confirmed land/sea or sea-shore classification change hides/frees the static
layer rather than showing stale geography; ordinary terrain-colour changes
only recolour it. Native images/patches are destroyed with the renderer.

One content-validated geometry cache survives same-map reloads in the same VM,
with at most **16MiB explicitly counted geometry buffers** and no native images.
Full canonical terrain-byte comparison avoids map-ID/hash collision guesses.
Native pages/colours are always rebuilt for the new match. The cache aliases
active geometry; do not add `coastCacheBytes` again to `coastGeometryBytes`.
`coastCpuBufferBytes` counts colour backing/flags/scratch; add `coastGeometryBytes`
for total explicit coast buffers. Lua tables, engine overhead and GC peaks are
not included. Construction additionally uses temporary index tables and, on a
cache hit, a temporary map-sized validation buffer (2MB on World).
Live rectangle-copy scratch adds at most about .067MiB touch / .258MiB desktop
above the ready-at-load buffer totals below.

**Serial measurement:** `tests/OpenFrontCoastPerf.luau`, desktop Lune with actual
World and Pangaea Compact map bytes, two synthetic owners on all land, no units/
names/rails. Baseline is the same implementation with `Options.coasts=false`.
Touch uses 844×390 / touch CPU policy; desktop 1530×613. Host load times below
are tight-loop renderer CPU/wall work, **not native phone load seconds**.

| Map / policy | Added CPU buffers | Native coast pixels | Baseline load | Cold coast load | Cached-map load |
| --- | ---: | ---: | ---: | ---: | ---: |
| World 2000×1000, touch 2× | 13.16MiB | 10.47MiB | 1.55s | 3.91s | 1.95s |
| World, desktop 4× | 43.47MiB | 40.62MiB | 1.58s | 4.69s | 2.38s |
| Pangaea Compact 500×500, touch 2× | 2.95MiB | 2.49MiB | .55s | 1.00s | .62s |
| Pangaea Compact, desktop 4× | 10.03MiB | 9.48MiB | .55s | 1.27s | .83s |

World has **58,683 mixed coast/shore quads in 626 patches**. A full 4× World
RGBA image alone would be **128,000,000 bytes**, before CPU backing; sparse 2×
is the phone choice. The measured cold geometry/colour CPU was World 2×
**2017/312ms**, World 4× **2276/770ms**; Pangaea 2× **367/83ms**, 4×
**517/195ms**. Cached World geometry validation was **2.2–2.3ms** (Pangaea
**.2ms**); remaining reload cost includes fresh colour/native preparation and
the existing renderer. Max total loading step was about **47ms** on this host,
versus about **38–39ms** baseline: the 8ms target is a producer slice, not a
promise about the entire loading frame.

Per-frame windows: 120 warmup + 240 measured logical frames. World baseline→on
pan mean **.033→.052ms touch**, **.034→.076ms desktop**; idle on **.011/.012ms**,
with zero coast uploads/recomposition during idle or pan. Synthetic **96 coastal
tile submissions at 10Hz** (some already equal) produced World means
**.628→1.331ms touch**, **.650→1.324ms desktop**; Pangaea
**.640→1.368ms / .642→1.421ms**. These include base raster, callback and mock
buffer-copy work. Recolouring has bounded visual latency: after the last batch,
World took **11/23 logical frames** to drain touch/desktop, Pangaea **10/26**.
Those counts are not measured native display frames or GPU completion. Native
fill rate, API transfer cost, allocation success and real phone FPS need review.
[Raw records](../../../../tests/fixtures/OpenFrontCoasts.perf.jsonl) include queue
peaks, all counters and loading steps; do not turn them into phone speedups.

Reproduce serially from the repo root:

```powershell
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontCoastPerf
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontCoastPreview
python scripts/art/coast_preview.py
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/run OpenFront
```

**Review artifacts:** [desktop owned comparison](../../../../art/map/coast-owned-before-after.png),
[touch owned comparison](../../../../art/map/coast-owned-2x-before-after.png),
neutral comparisons and [provenance/reproduction](../../../../art/map/PROVENANCE.md).
These are exact contour/colour buffers composited with an approximation of
native filtering, **not Studio screenshots**. No image upload is needed.

**Exact functions changed:** EditableRenderer `writeDisplay`, `new` (sink/resize
closures), `step`, `applyTerrain`, `refreshCamera`, `metrics`, `destroy`, plus
`Options.coasts`. New CoastGeometry `template/new/step/bytes/clearCache/cacheBytes/visit`
and private `terrainAt/weights/seal/finish`; CoastRaster
`new/mark/cell/prepare/pending/bytes`, private `source/blend`; CoastOverlay
`new/build/mark/prepare/ready/setCamera/stepViews/invalidate/metrics/destroy`, private
`upload/root`; RenderPolicy's static-coast defaults/bounds. No RasterCore,
CameraTransform, MapInput, OpenFrontClient, screen UI, shared/server or gameplay
config edits by Codex. The one MatchPerf expectation now accounts for Bruno's
concurrent approved 70% transport scale; Claude's implementation is preserved.

**Gates:** OpenFront **241/0**, including Coasts **7/0**, MatchPerf **24/0** and
the existing raster/mobile/preview/warship/FX guards as overlapping subsets.
Fresh-sourcemap full-src strict analysis, Rojo build and whitespace check pass.
The new tests cover sliced/cache construction, class/atlas caps, curved coverage,
shared coastal paint, row/page seams, cold-vs-incremental colour results,
snapshot updates during initial colour preparation, one-image scheduling,
camera/picking/input, allocation refusal, changed-class fallback and teardown.
No new full suite, Studio/device run, upload, staging or commit by Codex.

## Smooth ships and earlier map-edge experiment, 2026-10-29

Historical round, committed as `ab76b53`. The static coast section above
supersedes this round's pending coast proposal; the soft filter remains off.

Working tree over `9787430` (includes Codex `a58f080`), preserving Claude's
concurrent OfActions/UiAssets/STATUS changes. Bruno chose original smooth
top-down ships with owner colour, dark outline and a small wake, plus smooth
coasts and political edges without changing terrain interiors or gameplay.

**Ships implemented.** `ShipArt.luau` draws original analytic masks for Transport,
Trade Ship and Warship. Four 256px cells include a dark-deck retreat variant.
One shared 516×516 EditableImage uses **1,065,024 logical native pixel bytes**;
the equal-size producer buffer is released after upload. All owners share it:
one ImageLabel per ship, no per-pixel GUI and no owner-palette atlas slots.
Normal hulls and wakes receive owner tint. A warship's owner-coloured bow/stern
surround a red midship combat band; one UIGradient per warship is created within
the existing 25-new-unit-view allowance. The source retreat cadence darkens the
deck. Health/veterancy remain upright. Ship images use bilinear sampling; this
finite-resolution atlas is not an infinite-resolution vector renderer.

`ShipArt.heading` derives rotation from confirmed tile/lastTile, retaining the
last angle when stationary. Only the sprite rotates. The 13-tile canvas, tile
centre, selection box/picking, confirmed patrolTile circle, source movement,
trails, combat outcomes and command paths are unchanged. The pinned Warship
ghost reuses this art at absolute .5 opacity, neutral while unvalidated and red
when confirmed invalid/unaffordable, with the existing patrol disc and no port
route. Existing source masks remain visible while the optional image builds or
if allocation/write fails. `RenderPolicy.smoothShips=false` retains that path.

The producer targets **1ms / 4096 pixels per live frame**, checking the clock
every 64 pixels; loading uses 8ms / 32768 pixels. Full-paint renderers prewarm
under their loading cover. Only the final atlas upload consumes a displayed
image slot, through `prepareFrame`; there is still at most one displayed image
updated per frame. Native upload/GPU cost and real-phone behaviour are unmeasured.
There are **no uploaded assets to arrange**. Original-art provenance and exact
runtime-byte review images: [art/ships](../../../../art/ships/PROMPTS.md),
[ship sheet](../../../../art/ships/preview.png).

**The earlier soft-filter prototype remains off on all devices.**
`RenderPolicy.softMapEdges=false` preserves source raster bytes/cost paths.
True enables a 3×3 [1,6,1] separable edge filter only where ownership or the
terrain land bit differs across neighbours. Terrain/water interiors remain
exact; spawn/trail overlays are applied afterward. Confirmed terrain, land mask,
ownership, picking and sim are untouched. A two-tile dependency halo and expanded
diplomacy invalidation retain incremental/full-repaint agreement across pages.
It uses existing full-resolution pages and the same one-page scheduler, with
no extra raster image. The extra samples and halo are too expensive in this
diagnostic to enable on phones (or desktop by default).

At one pixel per tile, this softens colours but **does not draw true sub-tile
curves**, especially at close zoom. Bruno subsequently chose static coast curves;
the implementation at the top of this README completes that map-side path and
retains stepped territory borders. This soft-AA comparison remains historical;
rounded live political contours were not selected. Do not
switch the whole map to bilinear filtering: that would soften land interiors.
[Exact source/prototype comparison](../../../../art/ships/map-soft-prototype.png)
is a real World terrain crop with synthetic owners, enlarged 4×; no Studio claim.

**Measurements.** Serial desktop Lune, not engine/GPU/phone timing:

- `OpenFrontShipPerf` compares historical `9787430` SceneOverlay via read-only
  `git show` with this scene, using current unchanged dependencies except the
  default-off raster experiment. Actual World, 844×390/touch CPU budget, 600
  ships/60 owners, 120 warmup + 240 measured frames/mode, moving ships at 10Hz.
  Stationary mean 0.0148→0.0140ms; moving/panning mean **1.398→1.535ms**, p95
  **6.330→7.012ms**, measured GUI count **1344→1344**, sprite images **600→600**,
  creations **8→8**, property writes **27,454→29,854**. These windows include
  source trail raster work. The separate cold full-load wall time was
  **1073→1279ms**, loading frames **25→40** (logical frames, not elapsed native
  frames); the new producer accumulated **303.8ms** CPU in slices. Shared atlas
  upload/heap overhead is not simulated. This is one host run, not a phone
  speedup/FPS claim.
- `OpenFrontRasterCosts baseline/off/soft` compares the `9787430` RasterCore via
  read-only `git show`, the current default, and the enabled experiment. Actual
  World terrain 2000×1000; synthetic ownership covers the whole grid, including
  water; 30 batches × 150 patches × 20 edits, all **90,000 changed tiles**.
  Each batch drains using the existing **2.5ms / 131072-pixel** budget. The sink
  copies real RGBA rows; it does not execute WritePixelsBuffer or GPU uploads.
  `probe=false` records are the comparison; `probe=true` adds instrumentation
  and must not be mixed with them. Cold paint is recorded separately.

| World diagnostic, non-instrumented | 9787430 | Current, off | Soft prototype |
| --- | ---: | ---: | ---: |
| 30 front batches, raster CPU ms | 538.6 | 540.6 | 5531.8 |
| 30 scattered batches, raster CPU ms | 1410.9 | 1425.8 | 15505.6 |
| Front batches, shaded/uploaded pixels | 296859 / 296859 | 296859 / 296859 | 539523 / 539523 |
| Scattered, shaded/uploaded pixels | 810000 / 4050000 | 810000 / 4050000 | 1438560 / 4606560 |
| Cold full paint ms, front case | 2403.4 | 2305.0 | 10010.1 |

Cold uploads are 2,000,000 pixels in every case. Delta sink-copy totals off→soft:
fronts **7.94→16.73ms**, scattered **14.48→29.61ms**. These are CPU buffer-copy
costs, not native upload times. Off→soft average logical drain frames/batch:
fronts **8.13→71.63**, scattered **19.77→201.10**. The two-tile halo expands dirty
work; neighbour classifications/shading add further CPU cost. Default-off
counts match baseline exactly, with ordinary single-host timing variation.

Raw records: [ships before](../../../../tests/fixtures/OpenFrontShips.baseline.jsonl),
[ships after](../../../../tests/fixtures/OpenFrontShips.after.jsonl),
[raster baseline](../../../../tests/fixtures/OpenFrontSmoothEdges.baseline.jsonl),
[raster off](../../../../tests/fixtures/OpenFrontSmoothEdges.off.jsonl),
[raster soft](../../../../tests/fixtures/OpenFrontSmoothEdges.soft.jsonl).

**Exact runtime functions.** New `ShipArt.column/sample/heading/new/build` and
`EdgeSmoothing.pixel` (private identity helper). SceneOverlay:
`new`, `newUnit`, `shipPose`, `shipCombat`, `smoothShip`, `drawUnit`,
`drawBuildPreview`, `prepareFrame`, `isFirstPaintReady`, `metrics`, `destroy`.
RasterCore: `new`, `setEdgeSmoothing`, `markAround`, `setRelations`, `mapPixel`,
`pixel`, `step`. RenderPolicy adds the ship build bounds and disabled map flag.
No OpenFrontClient, OfActions, OfHud, shared/server or gameplay config edits.

New regressions: original mask coverage/gutters/three types/producer bound;
one owner-tinted smooth image, rotation and stationary heading, upright health,
selection/patrol alignment, combat band, pinned invalid ghost opacity, optional
allocation fallback/cleanup, shared image slot, source-identical disabled map,
untouched terrain interiors/state, and cold-vs-incremental coast/ownership/
diplomacy/hover across block/page seams. The existing mobile-composition test
explicitly disables smooth ships to keep testing its source fallback path.
`OpenFrontSmoothLookPreview` + `scripts/art/smooth_look_preview.py` reproduce the
review PNGs from exact runtime buffers, without generated or external art.

No full suite, Studio session, upload, staging or commit by Codex in this round.
Claude owns full-suite review and Bruno owns the native appearance/playtest.
Final gates: **OpenFront 234/0** (including SmoothLook 7/0, Warships 9/0,
MatchPerf 24/0 and the relevant raster regressions; overlapping filters are not
summed). Fresh-sourcemap full-src strict analysis, Rojo build and whitespace
checks pass. These results apply to the working tree over `9787430`.

## Remaining RoWorld map hooks/effects, 2026-10-29

Working tree over `200a756`, preserving the uncommitted warship symbol/photo
round and Claude's concurrent HUD/settings work. Bruno accepted the ship
appearing/sailing in his phone emulator and authorized finishing the list;
that acceptance predates the label/defense/fallout work below.

**A — labels.** `renderer:setTerritoryLabelsVisible(visible)` defaults true,
works before attachState, and changes only the Names parent. Repeated values
return immediately. Names, troops, flags, crowns/status/emoji children hide
together; structures, ships, ranges, FX and the own spawn ring keep their own
layers. Named views/easing continue to update so HUD toasts retain anchors.

**B — toast anchor.** `renderer:playerNameScreenPosition(smallID)` returns the
last drawn eased name origin, projected through the current camera, in actual
screen pixels (including map parent AbsolutePosition). It adds no half tile
and scans nothing: O(1) cached view/pose/source-LOD/padded-frustum checks. Unknown,
dead/hidden, not-yet-drawn or source-culled names return nil/nil. Turning labels
off deliberately does not suppress this query. Convert to HUD canvas once using
the destination parent's origin/UIScale as for worldToScreen; the HUD owns toast
lifetime, text offset and layout.

**C — defense.** Confirmed `state.attacks` supplies outgoing target owners.
An active foreign post's actual config radius is shown red when at least one
viewer-owned tile lies within its Euclidean circle. A confirmed outgoing record
counts until removed, including a record marked retreating. No local command or
selected player creates coverage. DefenseRanges indexes post bounds in 128-tile
cells, compares unit metadata/target membership on confirmed updates and only
invalidates nearby posts for ownership changes involving the viewer. A retained
owned witness avoids rechecking/hiding valid coverage for other captures nearby.
Probes resume with **2048 tile visits / 1ms target per scene frame**; the clock is
checked between visits. Results/circle descriptors are cached, with 10Hz camera
culling maintenance and immediate inherited transforms. Creation shares the
existing 25-view scene budget; retired circles share the 16-delete/32-spare pool.
Large affected post sets may wait for probes or view creation; overlap fill-rate
is unmeasured. No territory sweep runs every display frame.

Final inactive Defense Post records also enlarge the existing explosion **2.5x**
and request four atlas fire/smoke sprites for **3000ms**. Removal alone and initial
inactive snapshot records do not emit effects. Duplicate finals do not replay.

**D — fallout.** Final inactive reachedTarget Atom/Hydrogen/MIRV-warhead/Mega
records enqueue bounded impact masks plus four lingering atlas fire/smoke
requests, with a **15000ms** cosmetic lifetime from receipt. Intercepts and
snapshot/removal-only records do not enqueue glow. The config outer magnitude
sets the mask region; only confirmed Core fallout bits can illuminate it.

| RenderPolicy bound | Touch-capable client | Other desktop client |
|---|---:|---:|
| Active impact masks | 4 | 8 |
| Global active fire/smoke sprites | 24 | 48 |
| Mask atlas dimensions | 256x256 | 512x256 |
| Logical native mask pixels | 256KiB | 512KiB |
| Maximum retained mask CPU buffers | 448KiB | 896KiB |

Every mask has 128x128 RGBA pixels, byte dirty flags and a u16 work queue.
The CPU accounting includes all three buffers; native driver copies, tables,
allocator/GC peaks and other renderer state are excluded. A full queue fits its
fixed buffers and later changes enqueue only affected cells. At saturation the
oldest mask slot is reused; additional fire/smoke requests can be omitted. The
global sprite counter includes existing nuke debris and warship-death smoke,
as well as the new effects. Ordinary explosions/flags/shockwaves retain their
existing paths and budgets; these numbers are not a cap on all FX types.

Mask generation shares **1024 mask pixels / 1ms target per prepare frame**
across all slots. Large blast bounds downsample conservatively: a coarse pixel
is filled only if every tile it covers is confirmed fallout and within the
blast radius. This can omit edge/isolated glow; it never marks a mask pixel
that includes clean terrain. Pixelated sampling avoids a filtered green halo.
Cleared/changed fallout cells hide their entire affected view immediately,
until current queued pixels are regenerated and uploaded. Pulse opacity fades
over 15s, while the mask also follows actual confirmed fallout removal. This
does not change fallout gameplay or the base political raster's catch-up policy.
Long-lived new fire/smoke is also hidden at positions without confirmed fallout.

One lazy native atlas serves every slot. Effects.prepare reserves the existing
displayed-image slot for at most one mask rectangle upload per frame. With
ownership queued, mask uploads use at most one in four frames. There is no
second raster/image upload in that frame. Views reuse the world transform and
fixed slots; atlas/views stay bounded and are destroyed with the match. If
optional mask allocation is refused, glow is disabled for that renderer while
gameplay and existing atlas FX continue (`falloutMaskAllocationFailed`). Initial
production/queued uploads can delay glow appearance. CPU targets, pixel masks
and proxy counts do not prove native GPU/fill-rate, memory or phone frame cost.

New metrics: defenseProbeTiles/defensePending, falloutMasks,
falloutMaskBufferBytes/falloutMaskNativeBytes, falloutMaskUploads/Visits and
falloutMaskAllocationFailed. Existing timing_* names remain unchanged.

Exact changed runtime functions for this round:

- EditableRenderer.new/attachState/applyTileStates; new
  setTerritoryLabelsVisible/playerNameScreenPosition.
- SceneOverlay.new/setLocalPlayer/setUnits/setRenderConfig/setCamera/
  tilesChanged/step/metrics/destroy; new setAttacks/drawDefense.
- FxState.new/sprite/deadUnit/tick/clear; new aftermath. Original source
  oracles still use Fx.new without the Roblox cosmetic options.
- EffectOverlay.new/prepare/step/destroy; new falloutTilesChanged/prepareMasks.
- New pure DefenseRanges.new/setTargets/setUnits/tilesChanged/step/clear and
  its invalidate helper; FalloutMasks.new/add/tilesChanged/expire/step/clear
  and its mark helper. RenderPolicy owns the new bounds/durations.

No Codex edits to OpenFrontClient, HUD/settings UI, PlayerSettings, shared/server,
Net or source mechanics. Earlier drawBuildPreview warship fixes remain in the
combined working tree. Tests: new OpenFrontFinish specs; conditional upload
recording/allocation refusal in the effects harness; a no-op setAttacks adapter
only in the archived attack-free wide-zoom baseline (measured scene code stays
unchanged). **Final working-tree gates:** `lune run tests/run OpenFront`
**227 passed / 0 failed**, including the new Finish **8/0** subset. Fresh
sourcemap/full-src strict analysis, Rojo build and whitespace checks pass.
One expected warning exercises warship listener-error isolation. The first
broader run was 226/1 solely because the archived wide-zoom scene lacked the
new setAttacks orchestration hook; the baseline-only adapter fixed that run.
No new benchmark sweep, full suite, Studio, device run, uploaded asset, staging
or commit by Codex. Claude owns the integration/full-suite/native review.

## Warship placement symbol follow-up, 2026-10-29

Over `200a756` (includes map hooks `fe92364`), Bruno's Studio phone-emulator
feedback: the pinned Warship preview had its patrol circle and 500K cost, but
no ship. **Cause:** drawBuildPreview's symbol branch accepted only
Visual.sprite's structure=true; Warship is a mobile sprite, so it skipped the
symbol while independent range/text branches continued.

drawBuildPreview now retains one four-band Warship symbol from the existing
open unit atlas (column 2, 13×13 bands), at the pinned/cursor tile centre with
the ordinary 13-tiles-wide mobile scale. All bands use absolute .5 opacity;
confirmed invalid/unaffordable placement is red and unvalidated geometry stays
neutral, as for the other ghosts. It inherits the Ground world transform for
immediate camera movement, shares the existing per-frame creation allowance,
and never enters confirmed-unit or composed-icon bookkeeping. No port route
line is introduced. Nil/type changes hide it; scene teardown clears it. At most
one root + four retained ImageLabels, using the existing atlas: no upload or
new image page. Existing building ghosts, range/cost, commands and camera rules
remain unchanged. Runtime changes: **SceneOverlay.drawBuildPreview/destroy**.

A new OpenFrontWarships regression first failed with the missing mobile symbol
on the pre-fix tree, then passed. It checks the four source crops, half-opacity,
red invalid/unaffordable tint, pin under UI, repeated redraw/type switches,
retained identity, no port route and clear/teardown. Final working-tree gates:
OpenFront **219/0**, including Warships **9/0** (subset, not additive), fresh-
sourcemap full-src strict analysis, Rojo build and whitespace checks pass. One
expected warning exercises listener-error isolation. No full suite or native
Studio/device check or upload by Codex; Bruno's screenshot report is the trigger,
not post-fix acceptance.

Separately generated one original recon photograph for Claude's card:
`art/dossier/warship_recon.png` (1024×704, fully opaque). Exact prompt, generated
original/hash, mechanical export and 110×76 visual QA are recorded in
`art/dossier/PROMPTS.md`. No external image input, code-drawn substitute or
upload; Claude owns the photo card and any approved upload.

## Warship card hooks and patrol range, 2026-10-29

Feature 13, over `a1814fd`. Claude agreed the proposal; Bruno's brief remains
placement confirmation, a tapped-own-warship card/patrol circle and the existing
next-water-tap move. This round does not change commands or selection mechanics.

```luau
local disconnect = renderer:onWarshipSelected(function(unitID: number?)
	renderer:setWarshipPatrolVisible(unitID)
	-- Claude opens/closes the stats card from confirmed ClientState records.
end)
-- Call disconnect on card/controller replacement; renderer destroy also clears it.
```

The callback emits only edges: the ID for WarshipSelection.tap's single select,
nil on move/clear/Escape/ButtonB, completed box selection (even one ship),
select-all, confirmed death/removal/capture/viewer change and active teardown.
It does not replay selection on subscribe or promote a surviving multi-selected
ship into a tapped card. Exceptions in a listener do not stop other listeners.
A second tap on the same ship is already a **move**, therefore emits nil rather
than repeating its ID. Select and move already consume the map tap before
OpenFrontClient's onTap: no tile_action or attack-card callback on either path.
The existing right-click clearSelection path uses the same nil edge.

The live disc is **explicit**, not automatically shown by selection: call
setWarshipPatrolVisible(id/nil) as above. It uses only the own active Warship's
confirmed `warship.patrolTile` (including zero), at the tile centre, with
`config:warshipPatrolRange()` (currently 100). Missing/invalid patrol tiles hide
it; there is no fallback to the moving ship. A later confirmed patrol change
updates the retained disc on the next scene step. Nil/death/capture/removal or
viewer change hides it immediately. Camera transforms move existing geometry
synchronously. One retained yellow .09-fill, 3px-outline circle costs three
Instances in the existing lazy range layer, shares its creation budget and
requires no image upload. An unchanged centre/radius/camera skips redraw; this
adds only O(1) lookup/config work to scene maintenance.

Warship draft and validated placement previews now show the same configured
patrol radius, including while pinned/under a card, with existing invalid/red
symbol behavior. **Deliberate presentation addition:** pinned OpenFront v0.35.2
BuildPreviewController.buildGhostPreviewData has no Warship range branch and
leaves its radius at zero. The upstream fixture is unchanged; this addition
does not grant placement permission or move a ship locally.

Exact runtime functions: WarshipSelection.new/clear/prune/tap/box/toggleAll and
new single edge helper; EditableRenderer.new/attachState/destroy, new
notifyWarship/onWarshipSelected/setWarshipPatrolVisible; SceneOverlay new
patrolUnit/drawWarshipPatrol/setWarshipPatrolVisible plus setLocalPlayer/setUnits/
setCamera/step/destroy; BuildPreviewController.draft/draw. OpenFrontClient/Main,
screen UI, shared/server/config and RenderPolicy are untouched by Codex; Claude
owns the card, placement title and OpenFrontClient callback wiring.

New OpenFrontWarships specs cover real renderer/input/ClientState paths under
the property shim: selection consumption and move edges, all clear routes,
confirmed invalidation, one/many box/select-all behavior, listener cleanup/error
isolation, confirmed-centre/config geometry and reuse, absent-centre refusal,
and pinned draft/validated/stale-query placement. No native layout, GPU/fill-rate,
real touch, network acceptance or real-phone cost is established. No Studio,
upload, staging or commit by Codex.

Final working-tree gates over `a1814fd`: `lune run tests/run OpenFront`
**218 passed / 0 failed**, including **8** new Warships cases (a subset, not
additive); fresh `rojo sourcemap -o sourcemap.json`, full-src strict analysis,
`rojo build -o build.rbxl` and `git diff --check` pass. One expected warning
exercises listener-error isolation. The initial group was 217/1 because the
source ghost oracle expected zero Warship range; its fixture remains unchanged,
and the comparison now explicitly checks source zero against the approved
config patrol-range presentation. No full suite or native check by Codex;
Claude's concurrent UI/HudModel/OfRunner test changes are preserved.

## Pinned placement, visible ghosts and preview cost, 2026-10-28

Working tree over `bbc60b8`, preserving Claude's concurrent OfActions banner,
upgrade-aware confirm title and OpenFrontClient queryBuild callback. Bruno
reported missing symbols/ranges and choppy placement/aim in the emulator.

**Confirmed symbol bug:** drawBuildPreview multiplied each cached part's
existing opacity by .5/.6 every display frame. Once composed styling stopped
resetting it, the symbol approached complete transparency. Ghosts now use
three retained finished-symbol masks from the existing open atlas, with
absolute .5 cursor / .6 upgrade-target alpha, full glyphs at world zoom, and
red tint/outline for invalid or unaffordable confirmed placement. They no
longer acquire composed-icon cache slots or enter confirmed-unit bookkeeping.
The floating cost remains. Unit/map sizes and the normal unit LOD are unchanged.

**Pending placement API:**

```luau
preview:setPendingTile(tile: number?)
preview:pendingTile(): number?
local disconnect = renderer:onCameraChanged(function() ... end)
local sx, sy = renderer:worldToScreen(worldX, worldY)
```

Pins use zero-based TileRefs, including 0, and render at the tile centre.
They survive pointer movement, UI exclusion, pan/zoom and resize. Moving,
clearing, changing type and teardown invalidate earlier replies. Clearing a
pin hides the preview and suppresses floating placement until another pin or
type is selected; it sends no command and does not change the UI's chosen
item. `setChosen(nil)` also clears the pin. One query remains in flight at
most. A valid pinned reply refreshes at most once per newly confirmed tick or
gold change (within the existing 50ms minimum interval); floating mode retains
its existing cadence. Confirmation remains server-authoritative.

While a tile query is pending, the controller draws **neutral, unvalidated
geometry** from confirmed config/costs. It does not borrow another tile's
permission, upgrade target, rail path or nuke aim. This removes blank ghost/
range frames when the pointer crosses tiles faster than a server reply.
Factory (110 tiles), SAM (level-dependent, new level 1 = 70) and Defense Post
(30) all have config ranges. Pinned world-zoom tests cover symbol/cost/range
under a blocking card. At close zoom, Factory/SAM circumferences can lie
outside the viewport: their actual radii are not shrunk to fit. Without the
seven screenshot files/state, this does not prove which cause explains each
of Bruno's frames.

**Silo circles:** this renderer creates no missile-silo range circle.
Choosing a bomb reveals SAM discs: own yellow, allied blue, enemy red.
Bomb preview inner/outer circles are at the target. Thin pulsing target rings
can also be live nuke telegraphs. Proximity to a silo alone cannot distinguish
these. New read-only `OpenFrontDebugClient:Invoke("preview")` returns range
keys/unit IDs/owners/tiles/radii, the ghost/trajectory and live nuke targets,
so Claude can attribute the next native capture without guessing.

**Camera callback/coordinates:** observers run after raster and map pass
transforms update, for real pan/zoom/fly-to/valid resize changes, and return a
disconnect function. Identical views do not fire; teardown removes listeners.
`worldToScreen` returns screen pixels including the actual map parent's
AbsolutePosition. It does not return safe-area HUD canvas units. For a direct
child of root.match:
`(Vector2.new(sx,sy)-root.match.AbsolutePosition)/root.scale.Scale`.
Use the actual target parent's origin/scale for nested cards; no fixed inset
subtraction. The cost label updates on that same camera callback. A retained
world-space trajectory follows pans immediately without rewriting 128 lines;
zoom refreshes screen-width/dash styling. Rebuilds happen only when its control
points, direction, ordered SAM inputs or zoom actually change.

**Historical integration note (completed in `095722d`):** OpenFrontClient.start's actionsActions now
has `buildPending(tile?)`, forwarding to setPendingTile. Add that optional
callback to OfActions.Actions, invoke with tile from _askBuild on open/move,
and nil from closeConfirm. Your existing buildChosen callback handles clearing
the type. For card following, register onCameraChanged when creating a renderer,
query the confirm tile's centre through worldToScreen, and reposition/clamp in
the HUD's canvas. Use the callback's disconnect on card/controller replacement.
This round does not edit OfActions or its new queryBuild/banner code.

### Measurements and limits

Serial comparison: `lune run tests/OpenFrontPlacementPerf bbc60b8`, then
without a revision. Historical modules load through read-only git show;
nothing executes in the upstream checkout. Full synthetic all-land World,
844x390, 400 structures (100 enemy SAMs), 73 names, confirmed updates at 10Hz,
120 warmup + 120 measured logical 60Hz frames/case, simulated 50ms query
replies. No ownership churn. Historical stationary means a fixed cursor;
current stationary uses the new pin. Moving cases cross many tiles while
waiting. Actual native layout/GPU, touch, network and server CPU are excluded.
The property shim's FindFirstChild scans all mock objects: caching direct
stroke references removes that amplification, so its timings are not native
speedup ratios. Counts/visible-data gaps are independent of host speed.

| Stationary chosen type | Renderer step mean ms, before → after | GUI writes / 120 frames | Query calls / 120 frames |
|---|---|---|---|
| City | 2.976 → .216 | 3,458 → 18 | 30 → 20 |
| Factory | 1.430 → .222 | 1,700 → 20 | 40 → 20 |
| SAM | 5.876 → .209 | 3,697 → 17 | 30 → 20 |
| Atom | 5.228 → .194 | 95,377 → 17 | 30 → 20 |

Before, stationary SAM collection/redraw averaged 5.062ms/frame in the shim;
Atom ghost/range/trajectory passes .873/3.505/.589ms. They are effectively
idle after caching (each <.002ms/frame in this capture). Atom controller mean
.136 → .006ms, while name work remains ~.035–.1ms/frame. Moving structure
cases have geometry on 120/120 frames versus 0/120 validated preview records
before. This is advisory draft continuity, not 120 accepted/valid placements.
Moving Atom has target rings immediately but waits for authoritative silo/
threat inputs before drawing an arc. The static pinned arc stays visible.
Raw records: tests/fixtures/OpenFrontPlacementPerf.{before,after}.jsonl.

Separate `lune run tests/OpenFrontBuildQueryPerf` calls the **actual current
Runner.buildPreview** on synthetic full World with two 60,000-tile rectangular
holdings, 100 enemy SAMs, one ready silo and **no rail stations**. Mean/p95 ms:
City 8.929/11.003, Factory 8.475/10.222, SAM 8.552/10.590, Atom .160/.287.
Almost all structure time is Player.buildableUnits; ghost rail path work is
<.017ms/call here. This does not cover a rail-heavy late match or native
Roblox server/network cost. Shared rules/query algorithms were not changed.
The client reduces duplicate pinned polling; the HUD's one-off queryBuild
can still duplicate the first preview request. Raw query records are in
tests/fixtures/OpenFrontBuildQueryPerf.jsonl.

New timing_* groups: previewGhost/previewRanges/previewTrajectory (scene CPU),
previewArc (threshold/control-point CPU), previewQuery (**round-trip wall time**
including InvokeServer yield, not server CPU). Existing groups stay unchanged.
SAM descriptors now rebuild on relevant confirmed SAM/affiliation changes or
10Hz active upgrades; camera-only SAM maintenance is 10Hz. Ghost ranges and
existing world geometry follow the camera immediately. No raster budget,
map resolution, rail work/fade or gameplay changes.

Exact runtime functions: BuildPreviewController clear/pointer/new/setChosen/
setPendingTile/pendingTile/sameSams/draft/draw/step/destroy; EditableRenderer
notifyCamera/onCameraChanged/new (resize closure)/refreshCamera/destroy;
SceneOverlay new/drawTrajectories/drawRange/drawSams/drawBuildPreview/setUnits/
sameGhost/setBuildPreview/setCamera/step/destroy; RenderTimings adds groups.
OpenFrontClient.start changes only probe.OnInvoke's read-only preview branch
and actionsActions.buildPending. Claude's queryBuild is preserved.

No full suite or native visual/performance acceptance is claimed. Official
Studio discovery/state/console were read only; Studio was in Edit. Codex did
not start/stop it or change emulator settings. The seven reported screenshots
were not available at a known path. Asset 203785492's existing console warning
remains unrelated/unresolved. No upload, staging or commit by Codex.

Final focused gates: Preview **16/0**, Ranges **6/0**, Raster **10/0**,
Mobile **10/0**, actual-start Orchestration **13/0**, Adapters **14/0**,
Effects **11/0**, RoundB **21/0**, MatchPerf specs **24/0**, existing WideZoom
**1/0**. Fresh-sourcemap full-src strict analysis and Rojo build pass.
The wide-zoom test retains its existing synthetic count/timing guard; no new
rail sweep or real-device claim follows from it.

## Own-conquest feedback and filled ranges, 2026-10-28

Working tree over `1e2c31e`, Bruno's RoWorld-inspired brief in STATUS. Only
OpenFront's open source/art is used. No competitor screenshot/art enters the
repository, and no competitor implementation claim is made.

**Conquest:** the existing FX atlas contains `FX_CONQUEST` (row 11, 21x20,
ten 90ms frames, holds the last frame). `FxState.conquests` ports the source
sprite's 2500ms lifetime, .1 fade-in and .6 fade-out fractions, including age
rejection. Gold uses WorldTextPass's +8 world-y offset, 2500ms linear fade,
six-unit world em and zero rise; existing SourceSans native text remains an
approximation of the source MSDF font. The renderer filters to the viewer's
own conqueror ID and resolves the conquered player's retained confirmed name
anchor. Missing players/anchors and snapshots create no conquest FX.

**Required Claude-owned integration:** `Replication.EVENT_TYPES` currently
omits `ConquestEvent`. Add it, then filter it in `eventsFor` to
`viewer ~= nil and viewer:id() == e.conquerorId`. Existing ClientState already
forwards this type via `DiplomacyEvents`; no wire schema/Net or ClientState
change is required. The renderer also supports a dedicated `Conquest` signal
if added. This round does **not** edit the allowlist or privacy filter, so a
real server cannot deliver the effect until Claude integrates that change.
Historical note: Claude completed this bridge, filtered to the conqueror, in
`bbc60b8`. The requirement above describes the original A/B delivery tree.

**Ranges:** Bruno's explicit presentation change replaces the native SAM
line chords with translucent filled discs and a 3px outline. Own/ghost/blast
is yellow, enemy red and friendly blue. SAM.collect's original current/target
upgrade radii and alpha remain; its new id/owner/offset metadata only keys
retained views. Pure source union-arc math and its oracle are unchanged.
Atom/Hydrogen/Mega aim shows both config inner and outer blast radii.
MIRV aim also reveals SAMs; it has no single detonation radius in Config, so
no invented inner/outer blast disc or new MIRV trajectory is drawn.

A tap on a displayed SAM/Factory/Defense Post shows its actual current
range and still reaches the UI's tap handler. Hit radius follows the existing
displayed icon size plus 3px; it does not pick an arbitrary nearest building
ten tiles away. Empty taps, a build preview and removed/inactive structures
clear inspection. Factories use trainStationMaxRange, posts defensePostRange,
and SAMs use level/upgrade range. Cities/ports/silos have no invented ranges.
Automatic defense coverage during an attack is proposal C, not implemented.

The shared range layer is lazy and uses the same immediate world camera
transform as other map layers. One radius costs one Frame + UICorner +
UIStroke, independent of circumference/zoom; the layer adds two Instances.
SAM descriptors refresh on confirmed changes or at 10Hz, not every display
frame. Existing circles move synchronously with the camera; entering circles
refresh on its next scene step. Offscreen circles allocate nothing. Circle
creation shares the scene's 25-view/frame allowance, with the chosen ghost's
radii before the SAM network. Recycled circles retain at most 32 spares after
bounded retirement (16 deletions/frame). No new EditableImage/upload or Part
emitters; RenderPolicy, rail scheduling/fade and raster budgets are untouched.
Large overlapping translucent discs can cost native phone fill-rate; the
headless count checks cannot prove that cost or visual appearance.

Exact runtime functions changed:

- EditableRenderer.attachState (confirmed conquest consumer), bindInput
  (range inspection before the existing UI tap/selection path).
- FxState.conquests (new), EffectOverlay.step (stationary conquest popup).
- RenderDefaults adds only source conquest FX values.
- SamGeometry.collect adds identity metadata; its geometry is unchanged.
- BuildPreviewController.draw adds innerRangeRadius from the same config.
- SceneOverlay.new/setLocalPlayer/setUnits/setCamera/destroy own range
  state/lifecycle; new inspectRange/conquests/rangeColor/hideRange/drawRange/
  structureRange; drawSams/drawBuildPreview/setBuildPreview/step integrate the
  retained discs. metrics adds rangeViews/visibleRanges/rangeSpareViews.

`tests/generate-openfront-effects.mjs` copies original TS methods/constants
into Temp and executes those copies. The fixture adds five conquest timelines
with original emission records and packed frame/alpha samples. Effects tests
also exercise the actual current ClientState generic event signal, own-only
filter, retained dead anchor, stationary gold and teardown. Ranges tests
check colors/radii, both blast rings, taps, zero settled allocation and a
120-SAM bounded creation/retirement workload. These are property/count and
pure math checks, **not** phone milliseconds, native layout or screenshots.

C remains proposals only, including exact signatures and object/buffer
estimates: [map/UI hook proposal](../../../../docs/openfront-port/MAP_UI_HOOKS_PROPOSAL.md).
No OpenFrontClient/Main/UI/shared/server edits, Studio actions, uploads,
staging or commits by Codex in this round. Claude's concurrent files remain
his work; the server conquest integration remains his required follow-up.

Final focused checks: Effects **11/0**, Ranges **5/0**, Preview **11/0**,
Adapters **14/0**, RoundB **21/0**, Mobile **10/0**, actual-start Orchestration
**13/0**, MatchPerf specs **24/0**, existing WideZoom regression **1/0**.
Fresh-sourcemap full-src strict analysis, Rojo build and diff whitespace
check pass on the combined working tree. No new performance sweep, full
suite, native Studio or device run. The WideZoom test's existing synthetic
timing/count comparison passes; it is not phone FPS evidence.

## Video 2: large-empire navigation regression, 2026-10-28

Working tree over `84a82ed`. Bruno reports that full bleed, map attachment
and front freshness now work on his iPhone 17 Pro Max; wide late-game camera
moves instead cause severe FPS drops. Findings:
`docs/playtests/2026-10-28-iphone-video-2.md`.

The regression was introduced by this renderer's `e62260c` changes. Source
rail fade 1..3 exposed thousands of individual GUI rail tiles at wide zoom;
every scale change rebuilt them. Full per-camera adornment redraws added
unit work. The older 700-rail benchmark did not expose a large rail network.
The new stress case reproduced **26,257 live GUI objects**, versus 4,689 on
`cba537a` in the same wide window. This is synthetic reproduction, not a new
native session or a direct measurement of the video.

**Explicit presentation tradeoff:** `RenderPolicy.sourceRailFade=false`
defaults to the previous Roblox **3..5** fade. Setting it true restores the
pinned source's **1..3**; `UnitVisuals.railFade` itself still implements that
source rule. This is the bounded fallback Claude offered in Bruno's brief,
for Bruno's decision about parity. Source fade still has a large GUI count
at wide zoom; this round does not implement a batched far-rail renderer.
No terrain/ownership resolution, sim mechanic or raster budget changes.

Rail topology is indexed into 128-tile cells on confirmed railroad changes.
The visible/overscan list, owner colors and continuous fade refresh at 10Hz;
visibility/detail threshold crossings can refresh it immediately. Existing
geometry follows the shared camera transform immediately. A fast pan may
wait up to 100ms for newly entering tracks, as before `e62260c`; this does
not delay the movement of existing rails or units relative to the map.
Cached owner/palette/kind/detail avoids repeated mask/color work. Rail
creation and excess-pool deletion are each bounded to **32 images/frame**.
A retained candidate-list cursor resumes pending creation without rescanning
the completed prefix. Hidden rails disappear with their pass immediately,
then retire in bounded batches to 32 spare views. This avoids thousands of
native creations/destructions during one zoom frame.

Names retain immediate source culling and the cap, but visibility uses cached
source scale rather than allocating `Labels.size` tables for the roster on
each camera frame. Camera-only adornment maintenance visits at most **32
units/frame**. Structure glyph/dot transitions use at most **64 unit visits
per frame**, applying the latest threshold state; positions still transform
immediately. Confirmed unit-record changes retain their ordinary update path,
so health, ownership and movement are not queued behind that cosmetic work.
First-paint readiness waits for pending rails/LOD; deletion and destruction
clear the pending work and its retained tables. All existing timing keys
remain. Added counters: railRebuilds/Visits/Creates/Deletes, adornmentVisits/
Refreshes, structureLodRefreshes.

### Reproduction and limits

Run serially with no other Lune measurement:

```powershell
lune run tests/OpenFrontWideZoomPerf cba537a
lune run tests/OpenFrontWideZoomPerf 84a82ed
lune run tests/OpenFrontWideZoomPerf
lune run tests/run OpenFrontWideZoom
```

The harness loads only our historical SceneOverlay/UnitVisuals using read-only
git show. It runs neither upstream code nor a second checkout. All variants
use the same current renderer/core/property shim, **synthetic all-land
2000x1000**, 1,000 units (700 structures), 170 names/flags, **21,600 rail
tiles**, 2064x943 viewport, confirmed ticks at logical 10Hz, fixed warmup and
180 measured frames each of wide (.85..2.55) and close (3.2..8) pan/zoom.
The headless first raster paint uses an unlimited budget and is excluded
from these steady-state windows; the game's 30ms loading policy is unchanged.
No ownership churn is included: this isolates the small-raster, expensive-
scene case from the recording. The spec uses 120 measured frames and asserts
GUI peak <= cba537a, plus mean/p95 frame costs within stated noise margins
(1.25x+1ms / 1.3x+2ms). The pre-fix spec failed on GUI count.

Final captured frame mean / p95 **unpaced Lune wall ms** and peak live GUI:

| Window | cba537a | 84a82ed regression | Working tree |
|---|---|---|---|
| Wide | 6.80 / 34.81; 4,689 | 220.85 / 465.52; 26,257 | 1.66 / 4.79; 4,689 |
| Close | 11.07 / 75.19; 10,457 | 65.43 / 130.75; 26,257 | 2.20 / 9.87; 7,219 |

Times varied across passes with host load; exact ratios are not device
speedups. Raw final records: `tests/fixtures/OpenFrontWideZoomPerf.{cba537a,
84a82ed,after}.jsonl`. Close-window GUI writes fall 556,403 -> 199,572 versus
cba537a. The new close window creates/deletes at most 32 GUI objects/frame;
the wide window can additionally create up to 72 unit annotations/frame.
The old regression created/deleted 21,568 GUI objects in a single wide frame.
This shim excludes native layout, hit testing, actual image transfers/GPU,
native instance memory/GC, network and phone hardware. It cannot prove the
new build holds 60 FPS or accounts for the video's memory changes.

The countdown drift remains **unreproduced**. An actual-start orchestration
regression feeds 12 seconds of idle spawn/countdown ticks: offset/scale stay
fixed, with no fly-to until startTick arrives. That rules out this tested tick
path, not native resize/input events in the recording. No speculative camera
change was made.

**Troop-label follow-up:** pinned `src/client/render/gl/passes/name-pass/index.ts`
`NamePass.updateNames` uses staggered 500ms troop buckets for every slot,
including the viewer, plus four-way tick slicing; there is no own-player
exception. Its normal frame upload passes `snap=false`. Our `drawTroops` uses
the same bucket; `EditableRenderer.attachState` delivers the confirmed
`StatsChanged` data to `Overlay.setStats`, while the HUD refreshes immediately
on that event. The observed ~470ms label/HUD difference fits source behavior.
No runtime cadence change was made. A controlled-clock RoundB regression
checks confirmed own/other troop cuts, their different stagger boundaries,
and an own-label refresh on a stats event inside the 100ms maintenance window:
there is no additional maintenance or cosmetic-budget gate on that event.
Follow-up focused result: **OpenFrontRoundB 21/0**; rail work is unchanged.

Exact runtime functions: SceneOverlay `Overlay.new`, `drawUnit`,
`rebuildRailTypes`, new `railFade`, `drawRails`, new `commitRails`/`trimRails`,
`drawNames`, `Overlay.setUnits`, `isFirstPaintReady`, `setCamera`, `step`,
`metrics`, `destroy`; RenderPolicy adds the four work limits and fade flag.
No Codex OpenFrontClient, Main, Ui/PerfOverlay, shared/server, raster, upload
or commit work in this round. Native phone FPS/frame tails, near-rail reveal,
queued glyph/adornment appearance and memory still need Bruno's check.

Final working-tree gates over `84a82ed`: **OpenFront 196/0** (includes WideZoom
1, MatchPerf 24, actual-start Orchestration 13 and RoundB 20; subsets are not
additive). Fresh-sourcemap full-src strict analysis, Rojo build and diff
whitespace check pass. No Codex full suite or native Studio/device run.

## iPhone video follow-up, 2026-10-28

Working tree over `acad575`, responding to Bruno's 18:40 solo World recording
of published `cba537a`. Video findings are in
`docs/playtests/2026-10-28-iphone-video.md`. This is not phone acceptance of
the new working tree. Codex did not start/stop Studio or touch PerfOverlay.

**Full-bleed map:** `OpenFrontClient.start` now explicitly sets the map
ScreenGui to `ScreenInsets.None`, `ClipToDeviceSafeArea=false` and
`SafeAreaCompatibility.None`. Previously `IgnoreGuiInset=true` selected
device-safe bounds, and default fullscreen compatibility could extend each
qualifying ImageLabel independently of its text and picking coordinates.
This explains the safe-area-sized raster alternating with stretched raster
while labels remain inset in `b2_pair.jpg`; it does not establish that the
parent's AbsoluteSize was alternating. Roblox documents that extension
depends on whether an object's bounds cover the safe area, and applies to
ImageLabel content as well as its background:
[ScreenGui](https://create.roblox.com/docs/reference/engine/classes/ScreenGui),
[SafeAreaCompatibility](https://create.roblox.com/docs/reference/engine/enums/SafeAreaCompatibility).
The HUD retains its own safe-area policy. Map passes explicitly use Sibling
Z ordering so a unit's health/progress children cannot sort above Names.
The actual-start orchestration test checks this ScreenGui policy; its shim
cannot reproduce native iOS compatibility transforms.

**Camera:** pages and scene transforms already update synchronously in
`refreshCamera`, without a confirmed tick or renderer step. The transform
regression now checks their alignment before that next step. Fractional
page-edge rounding can differ by under a pixel; no intentional frame lag was
found. Our touch adapter used 4x distance gain instead of the pinned
InputHandler's 2x and lacked its >1px accumulating threshold. Both now match
the source. No inertia, easing or new clamp rules were added: source pan
stops immediately, and large pinch deltas still use its nonlinear zoom.

**Own fronts:** priority previously selected an own block but could service
31 unrelated rows first. It now selects an own dirty row on the existing own
turns. Contiguous dirty-row masks determine the current upload rectangle,
excluding clean row gaps and obsolete dirty bounds. A two-step/32-pixel
regression failed before and now displays the own pixel. Relation changes
previously dirtied an owner's complete indexed territory, including interior
fill and nonadjacent diplomacy. They now compare cached cardinal-border
relations and dirty only affected border pixels. A 128x64 two-empire test
queues zero work for a nonadjacent alliance (previously four full blocks),
and shades exactly 128 touching-border pixels for an alliance across the
front; every final pixel matches a fresh repaint. Pending captures, partial
uploads and a relation change reentering the sink also match a fresh repaint.
These are deterministic service/pixel tests, not phone timings. A packed
foreign-border row cache avoids visiting interior/coastal pixels during
relation invalidation. It adds **258,048 bytes on World** (1,007,232 on
Giant), included in `rasterRowMetadataBytes`/`cpuBufferBytes`, and is cleared
on bulk terrain-only repaint and destruction. Relation invalidation remains
synchronous; native dispatch time needs measurement. Capture bursts can
still exceed live service capacity.
Stride 1, full maps, existing budgets and one displayed image page/frame stay.

`lune run tests/OpenFrontPhoneFollowupPerf before`, then without `before`,
loads our published `cba537a` Core via read-only git show versus the current
Core. Both use **synthetic all-land 2000x1000**, 95% owner 1 / 5% owner 2,
and a four-player relation matrix; this is not actual World geography or a
live match. No other Lune process was observed during these short runs.
Raw records: `tests/fixtures/OpenFrontPhoneFollowupPerf.{before,after}.jsonl`.

| Relation change | Before dispatch ms / dirty pixels / blocks | After dispatch ms / dirty pixels / blocks |
|---|---|---|
| Owner 1 allies with nonadjacent owner 3 | 20.88 / 1,920,000 / 1,920 | 4.96 / 0 / 0 |
| Owners 1 and 2 ally across their frontier | 23.70 / 2,000,000 / 2,016 | 9.22 / 2,000 / 32 |

These are **one unpaced Lune wall-time sample per case**, not native callback
or phone milliseconds. A provisional full-flag scan took 38..45ms and was
replaced before delivery. The final packed cache adds first-paint work:
cold raster-only wall time was **2.219s before / 2.413s after** in these runs.
This setup cost and the additional buffer are a deliberate tradeoff for
avoiding whole-empire repaint amplification, not a universal speed claim.
No GUI layout, image API/GPU, input feel or network is measured here.

**LOD:** rail fade was incorrectly implemented as zoom 3..5. The pinned
`RailroadPass.draw` fades from `railMinZoom-railFadeRange` to `railMinZoom`,
therefore 1..3 with the pinned settings. Fade/detail now refresh on zoom,
and pans beyond the retained 128px rail overscan refresh on that camera
frame. Name source visibility now follows zoom immediately instead of its
10Hz maintenance. Hidden source sizing gets its own updated zoom stamp;
otherwise a rapid out/in to a previously visible zoom could remain culled.
Adornment sizing also refreshes on camera frames. These changes do not add
per-unit projection to ordinary pan dispatch.

The source still has a hard structure glyph/dot threshold at 1.2, hard name
size culling, rail detail threshold 6, tile-sized zooming rails and black
local rails over bright territory. Those remain. The 15:56/17:44 native video
samples place apparent orphan health bars at ports; source structures draw
above ground sprites, but this is not proof that every reported missing boat
is port occlusion. Native sprite visibility, name/bar ordering, rail thickness,
first-countdown motion, grey-strip removal, close pinch/pan feel and front
ages still need Claude/Bruno's checks.

Exact production functions changed: `OpenFrontClient.start` (map ScreenGui
creation only); `MapInput.cancel`, `MapInput.new` (touch begin/change/end);
`RasterCore.new`, `setRelations`, new `neighborRelation`, `politicalPixel`,
`RasterCore.step`, `metrics`, `destroy`;
`SceneOverlay.drawRails`, `drawNames`, `Overlay.setCamera`, `Overlay.step`;
`UnitVisuals.railFade`. No Main, shared/server, UI or RenderPolicy edits.

Final working-tree verification over `acad575`: **OpenFront 192/0** after the
packed-cache change (includes HotFront 10, Mobile 10, Orchestration 12,
RoundB 20 and MatchPerf 22; these are subsets, not extra tests). Fresh-sourcemap
full-src strict analysis, Rojo build and diff whitespace check pass. Focused
regressions demonstrated failures before the viewport policy, pinch, own-row,
relation invalidation, rail fade and rapid-name fixes. No Codex full-suite
or native/device run; Claude retains those integration checks and commits.

## Phone follow-up: capped names and hot fronts, 2026-10-27

Over `3e591aa`, following Bruno's published iPhone 17 Pro Max match. He reports
small fast-pan/pinch hitches, instant HUD taps, and own-front freezes despite
60 FPS in the supplied frames. Claude owns Keep Playing/server/HUD changes.
This round changes Map, its tests, and the explicitly shared PerfOverlay only.

**Deliberate presentation difference approved by Bruno:**
`RenderPolicy.capNameScreenHeight=true`, `nameMaxViewportHeight=.08`. The name
em grows with territory up to **8% of the actual map viewport height** (31.2px
at 390px, 66.32px at 829px). Flag, troop row and status geometry scale with it;
the complete annotation stack is taller than the name em. Source culling,
target boosts, anchor easing and mechanics remain. Disabling the flag restores
source sizing. Capped geometry updates on the actual zoom/resize frame rather
than waiting for maintenance. Raw source sizing has a separate zoom cache;
a failing-then-fixed rapid-zoom regression protects source LOD visibility.

### Reproduced delay and fix

Old RasterCore retained a partial block until every row finished, then threw
away its progress when a new confirmed revision arrived. A block needing more
than six frames could be invalidated forever by 10Hz changes. A second issue
was FIFO ordering among visible blocks: own changes could wait behind a large
backlog on the same image, with no frame-rate drop required.

Completed rows now reach the sink in the same service step. Only successfully
committed masks clear; later edits retain dirty bits and row ages. A rotating
row cursor survives new revisions. Partial blocks rotate through their queue;
they cannot pin another page. Own-touched visible rows get priority on six of
eight raster service steps. Normal foreground and background work retain their
own turns and independent page cursors, including with a permanently hot own
front. Still **one displayed image page per frame**, full map dimensions and
stride 1; no increase to the phone CPU ceiling. More partial upload calls are
the tradeoff when a block cannot finish in one frame. Native API/GPU cost needs
Claude's Studio/device check.

`lune run tests/OpenFrontHotFrontPerf before`, then without `before`, compares
read-only `git show 3e591aa` against the working Core. No Temp export or git
mutation. Captures: `tests/fixtures/OpenFrontHotFrontPerf.{before,after}.jsonl`.
These deterministic **logical 60Hz / 10Hz input** tests bound service with a
pixel budget, not measured phone CPU time; Core's clock is controlled.

| Workload | Before | After |
|---|---|---|
| Hot 32x32 block, 2 rows/frame, 600 frames | 0 uploads | 600 uploads; first frame 1; max gap 1 |
| Same, 8 rows/frame | first upload 4; max gap 6 | first upload 1; max gap 3 |
| Same, whole block/frame | 100 uploads; max gap 6 | unchanged |
| Own pixel behind 206 visible blocks, 4096 pixels/frame | first shown frame 44 | first shown frame 1 |
| Whole backlog drain in that case | 44 frames | 44 frames |

The two-row workload's recent own row-wait p95/max is **16/16 frames**, despite
uploads every frame. Progress is continuous; this is not a claim that every
pixel is one frame fresh. The backlog case's own age is **1 frame**, while
other visible work reaches 44. Final quiescent pixels match a fresh repaint.
The existing late benchmark now checks `committedRevisions`: a partial row
upload alone must not claim the whole block reached its latest revision.

### Reading the new overlay

The lifetime `maxUploadAgeFrames` remains available, but is removed from the
readout. New metrics:

- `recentUploadP95Frames` / `recentUploadMaxFrames`, and `recentOwnUpload*`:
  the last two seconds' per-frame worst visible sink-upload row waits, up to
  512 upload-frame samples. Zero samples means no recent upload. Own includes
  edits involving local ownership and the associated halo/current own pixels.
- `visiblePendingBlocks`, `visibleOwnPendingBlocks`, `pendingVisibleAgeFrames`
  and `pendingOwnVisibleAgeFrames`: current unsent work, including a front
  that has not managed any upload. Own masks clear independently of enemy work.
- `ownTileUpdateGapMs`: since the renderer last received a changed packed tile
  involving local ownership, anywhere on the map. This can reveal a gap before
  raster processing; it is not network ping or server-to-display latency.

Wait starts at the earliest still-dirty edit in a row. Coalesced newer edits
can therefore be displayed sooner than the conservative wait number suggests.
Sink completion does not establish GPU presentation. Pending waits plus input
gap distinguish renderer backlog from lack of incoming own changes; a native
capture is still needed to identify Bruno's remaining real-device cause.

Screenshot 10 also exposed a display denominator error: "names 1.81" was per
name-draw invocation, while "frame 0.70" was per renderer frame. PerfOverlay now
divides every span by the same renderer-frame count and resets its baseline
on renderer replacement. **All `timing_*` keys and their meanings are stable.**

### Heap inspection and gates

The World constructor's explicit Core buffers are **16,815,488 bytes**, versus
16,287,296 before; new row/ownership/commit metadata adds **528,192 bytes**.
This excludes caller buffers, Lua tables, strings, native images and allocator
overhead. Paint LUTs remain capped at 4MiB; the 32x32 scratch-shape pool is at
most 1,115,136 bytes. Atlas native pixels are accounted separately. Current
map modules total about 2.33MB of source for World (not a heap measurement).
No confirmed 440MB renderer retainer was found by this source/accounting pass.
The overlay exposes buffer/LUT/index counts and icon queue storage; scene
metrics add `structureAtlasQueueStorage` / `mobileAtlasQueueStorage` so stored
queue prefixes can be checked natively. No speculative memory fix was made.

Focused working-tree gates: **OpenFront 183/0**, **Orchestration 11/0**,
**MatchPerf 22/0**, fresh-sourcemap full-src strict analysis and Rojo build pass.
New HotFront **7 cases**, NameCap **2**, and real PerfOverlay **1** cover row
progress, late visible priority, background fairness, input/age expiry,
reentrant edits, uniform cap geometry/flag-off, and the actual metric strings.
No full suite, Studio session, publish or commit by Codex in this round.

Exact production functions changed: RasterCore `Core.new`, `mark`,
`dirtyRect`, `markAround`, `Core.applyTileStates`, `prioritize`, `Core.step`,
`Core.metrics`, `Core.destroy`; new `scratch` and `recordAge`. LabelMath adds
`Label.limitHeight`. SceneOverlay changes `drawNames`, `Overlay.setCamera`,
`Overlay.metrics`; RenderPolicy adds the two cap values. PerfOverlay changes
`PerfOverlay.start`. Other production files and STATUS are Claude's work.

## Native flag regression and incremental names, 2026-10-27

Follow-up over `dfc0551`. Claude found persistent flag/name overlap in Studio
after the shared world-transform round. `drawFlag` no longer interprets native
`TextBounds` as logical coordinates. It caches `TextService:GetTextSize` for the
displayed string in SourceSansBold at size 100, then converts that width using
`namePixels/100`. Source flag size, aspect, alpha and adjacency are unchanged.
Measurement failure retains the open glyph-metric fallback. Cache ownership is
per scene; destruction clears it. Native screenshots must confirm the fix.

Names again use the prior padded frustum, expressed in world tiles (300px
horizontal, 100px vertical). Views remain allocated. Camera changes check
visibility and refresh entering names; full-map-to-full-map pans skip that
roster sweep. World transforms still move visible geometry immediately.
This adds count-dependent name visibility checks on partial-map camera views;
it is not a constant-cost camera-frame claim.

The name path now separates layout/status maintenance from visible active
anchor easing. Between maintenance/state changes, only those transitions
update their pose, or layout when the source integer size changes. The full
exponential tail continues until it reaches the target; hidden transitions
retain analytic start/target/time and refresh on maintenance/reveal. Source
size culling and targeted boost remain. Untargeted world geometry is reused
across zoom, with culling and screen-outline compensation at the existing
10Hz maintenance cadence. Source-LOD-hidden views can reappear after zoom
settles without requiring another state or camera event.

Status derivation remains confirmed-tick-driven. Decorations redraw only
when their data, geometry, config or atlas readiness changes. Incremental
draws replace only that name's flash entries; other alliance/traitor flashes
continue per frame. Troop text keeps the original roster-slot stagger and
half-second buckets. A magnitude/coefficient key skips decimal formatting
when the source formatter would produce the same text. No gameplay changes.
New cumulative counters are `nameVisits` and `nameStatusDraws`.

### Paired 473-name capture

`lune run tests/OpenFrontMatchPerf names before`, then `... names` runs
`OpenFrontNamesPerf.luau`. Before exports only SceneOverlay/NameStatusOverlay
from read-only `git show dfc0551` into a task-specific Temp directory and
removes those two exports afterwards. No git mutation or upstream execution.
Raw UTF-8 records: `tests/fixtures/OpenFrontNamesPerf.{before,after}.jsonl`.

Both variants: full World terrain, 1914x829, **473 allocated fit-visible names
and flags** (1 human, 72 nations, 400 tribes), source-visible tribe size 15,
10Hz confirmed troop/stat updates, 73 anchors easing after changes every
30 ticks, 120 warmup and 600 measured unpaced logical frames per window.
Idle means camera idle, not frozen confirmed state. There are no units or
ownership churn in this name-specific isolation. Baseline TextBounds are
synthetic nonzero values, exercising its normal bounds path rather than
repeated fallback glyph layout. TextService measurements are also mocked;
native font/layout, hit testing, GPU, network and phone hardware are excluded.
The existing 2,000-unit `late` benchmark/captures are unchanged.

| Camera window | Before names ms/frame | After names ms/frame |
|---|---:|---:|
| Idle | 2.114 | 0.400 |
| Pan | 2.575 | 0.458 |
| Zoom | 3.927 | 0.384 |

These are names-span totals divided by **all 600 frames**, including nested
status derivation, not mean time per name-pass invocation. All three proxy
means are below 0.5ms/frame; native Studio/device confirmation remains open.

Verification on this working tree: **OpenFront 172/0**, separately
**Orchestration 11/0**, **MatchPerf 22/0**; fresh-sourcemap full-src strict
analysis and Rojo build pass. RoundB is **17 cases**, adding flag zoom/long
name/replacement coverage, isolated easing/tail work, hidden freshness/flash,
troop formatting/bucket boundaries, source LOD reappearance and all seven
missile types' first-post-tick interpolation/pass retention. Shell trails are
checked across a 128-tile cell boundary and when becoming stationary. The
adapter's outline oracle is retained; its forced-refresh test also resets the
new maintenance clock. No Studio, full-suite run or commit by Codex here.

Exact production functions changed:

- `SceneOverlay`: `Overlay.new`, `drawFlag`, `drawNames`, `Overlay.setCamera`,
  `Overlay.step`, `Overlay.metrics`, `Overlay.destroy`; new `sameStatus`,
  `drawTroops`, `namePose`, `nameAnchor` helpers.
- `NameStatusOverlay`: `Decorations.beginFrame`, `Decorations.draw`,
  `Decorations.step`, `Decorations.destroy`.
- `LabelMath`: new `Label.troopDisplayKey`.

Screen UI, OpenFrontClient, shared/server and STATUS were not edited by Codex.

## Late-match rectangles and navigation, 2026-10-27

This round starts at `33d041b`, after Bruno accepted the icons and pause on
published PC/iPhone. His late-match choppiness and one-second colored boxes
remain the native acceptance criteria. **The changes below have headless
coverage; no native or published-game acceptance is claimed.** Older camera
projection/culling descriptions below are historical.

The box was a shell trail. `spritePart` sets a mask to fill its parent;
`drawUnit` called it *after* positioning a trail whose parent was Ground.
That replaced a 13px sprite rectangle with the entire viewport. The small
colored source pixel became a viewport/13 rectangle beneath the other unit
views, matching Bruno's captures. The regression first failed with
`ShellTrail.Size.X.Scale == 1`; ordering the mask before its geometry passed.
The final world-space trail remains a 13-tile sprite, independent of viewport.

Persistent passes now use world coordinates, **64 logical units per tile**,
so native integer GUI offsets retain sub-tile precision. A fixed set of
pass containers gets the camera translation and `UIScale = zoom/64`.
Separate sibling containers preserve the existing draw order under both
Roblox Z ordering modes; one common parent would group names below structures
in sibling mode. Shared transform writes are bounded independently of unit
count (tested with 10 and 1,000 structures). A fixed 128-tile culling grid
(128 cells on World; 528 on Giant) toggles occupied unit subtrees together.
Cell frames have actual cell bounds, avoiding full-map hit-test rectangles.
Smoothed missiles stay on the pass canvas so a long move can interpolate
across a culled target cell without disappearing. Roblox still lays out and draws
descendants; this is an O(1) **Lua camera dispatch**, not an O(1) GPU/engine claim.
Roblox's [size modifiers documentation](https://create.roblox.com/docs/ui/size-modifiers)
describes this native subtree scaling; actual engine/font costs still need
measurement. The stride-1 EditableImage pages keep their own existing, shared-edge-rounded
transform. Picking and safe-area conversion still use CameraTransform once.

Structures use a second shared transform, the accepted presentation size
curve divided by 64. Their root positions are normalized against a layer
whose extent compensates for that scale: centers move by map zoom while all
icons follow Bruno's existing curve. Source dot/level threshold 1.2 remains.
Ground sprites and names scale with map zoom, retaining source world sizes,
source name/target culling and status geometry. Cell visibility and native clipping retain
already-created offscreen views and their leases; returning to them needs
no delayed allocation. Hidden cells defer pose/style writes. Their stale members refresh from
latest confirmed state on reveal, before the next presented scene step;
missiles continue their source interpolation outside the cell mechanism. Confirmed state
and interpolating missiles still update individual views.

Name outlines, target/cull changes, annotation minimum screen sizes and rail
fade/detail/frustum refresh at 10 Hz, independently of the camera dispatch.
Thus a zoom can temporarily scale an outline/minimum before that refresh;
this timing differs from source GL uniforms. Name anchor easing, troop
buckets, source colors and source visibility equations remain. Native text
uses SourceSans/UIStroke rather than OpenFront MSDF, as before; inspect
sharpness and stroke changes on-device. Active screen-space drag/SAM/aim
telegraphs still do their bounded animation/projection work.

Mobile sprites now compose their four source bands into one image plus a
root, preserving owner palette, angry/retreat/flicker states, train loading,
health and veterancy. The optional reference-counted cache has 1,024 13px
cells with gutters in one 480x480 page (**921,600 native pixel bytes**).
Saturation/allocation refusal keeps complete layered sprites. Rails use a
source-derived atlas mask instead of seven detail Frames per tile, cull with
128px overscan, and retain at most 32 hidden images. Camera motion transforms
existing tracks immediately; a very fast pan beyond overscan can wait up to
100ms for a track-pool refresh. Style uploads rebind only pending views. Confirmed ground movement with
unchanged styling updates just its normalized pose and retained record;
health, owner, train loading, veterancy, progress and flicker still invalidate
that shortcut. Record comparison avoids allocating empty queue/warship tables.
Ownership drains before optional icon cache uploads; fallback icons remain
correct while a cache waits.

Camera projection itself does no per-unit work. Crossing the source 1.2 LOD
threshold still refreshes per-unit icon styles/levels; 10Hz annotation/status
maintenance and confirmed ticks also remain count-dependent. These are
remaining costs, not an assertion that the entire zoom frame is O(1).

Raster invalidation batches contiguous changed runs. Precise dirty-row masks
skip unchanged interiors when several sparse edits/trails share a block;
dense rectangles retain the tight loop. Retained per-page RGBA supplies the
unchanged upload pixels, and a byte per tile caches base border classification.
Ownership/terrain halos and relation changes invalidate that cache. Cached
numerical primitives, deduplicated neighbor relation reads and bypassing the
overlay wrapper on empty overlay rows reduce the hot loop. Source
political shading, highlight, defense, fallout and overlay ordering remain.
Tests compare every resulting pixel with a fresh full repaint after sparse
edits, trail changes, relations and hover. The first-paint staging aliases the
retained page backing (not a second allocation).

New counters: `shadedPixels`, `rasterComposeMs`, `rasterSinkMs`,
`rasterBackingBytes`, `railGuiObjects`, `mobileAtlasPixelBytes`,
`mobileAtlasSlots`, `mapInstances`, `mapGuiComponents`, `worldOverlayUnit`,
`unitBucketGuiObjects`, `visibleUnitBuckets`, `unitPoseDraws`.
Existing `timing_*` keys remain stable. Raster time/pixel totals are
cumulative over Core lifetime; use window deltas. `resetTimings` resets the
`timing_*` buckets. `shadedPixels` includes restarted computation; upload
counters describe completed rectangles. Upload-age counters now count actual
renderer frames, including frames reserved for atlases; pure Core callers
still advance one frame per step. Sink time is CPU time in the native call,
**not GPU completion**. `mapGuiObjects` includes all descendant GUI objects,
including Rails; components/total Instances are separately counted.

World adds **8,000,000 backing + 2,000,000 border + 260,064 mask bytes**;
Giant 4108x1948 adds **32,009,536 + 8,002,384 + 1,015,101 bytes** respectively.
These are explicit logical buffers, excluding tables/allocator overhead and
native image memory. Stride 1/full map dimensions remain unchanged. This
memory cost must be checked on Bruno's phone and through repeated matches.

Reproduce the late-match CPU/property proxy with
`lune run tests/OpenFrontMatchPerf late before` and then
`lune run tests/OpenFrontMatchPerf late`. The reference variant exports six
read-only modules from `33d041b` into `Temp/OpenFrontLateBaseline`; it does not
change git or execute in the upstream checkout. The same harness, full World,
101 names, 2,000 units (1,400 structures), 700 dense rail tiles and 3,000
ownership submissions/10Hz tick are used in both. Visit zoom8 before fit to
exercise retained rails, settle caches, then 120 warmup + 600 measured frames
per idle/busy-pan/busy-zoom window at 1530x613 and 844x390/touch budget.
The mock indexes parent/child destruction to avoid its general test harness's
quadratic inventory scan fabricating cache/rail hitches. Every live GUI and
component is counted, including hidden rails. Ownership batch latency follows
the block revisions actually sent to the sink; incomplete batches are reported.
A later revision establishes catch-up; coalesced intermediate ownership
states may never have been displayed.

`lune run tests/OpenFrontRasterCosts before` / no argument isolates 150 fronts
of 20 tiles and 3,000 scattered tile changes/tick. The before variant uses the
same exported reference; run the late-before command first. It reports actual
changed tiles, composed/uploaded pixels, blocks, CPU dispatch/composition/sink
cost and 2.5ms-budget drain frames. Its second pass instruments the border
section per pixel; timer overhead means that section's time must not be
subtracted from the uninstrumented run as an exact decomposition.

Neither benchmark measures native layout, glyph caches, GUI hit-testing,
EditableImage driver/GPU uploads, network dispatch, server time or real phone
hardware. Touch budget is a scheduler policy on this desktop CPU. The results
must not be called phone FPS, RoFront parity or proof of continuous growth.


### Paired capture results

Reference `33d041b` versus the final working tree. Times are **mean / p95 ms
per unpaced Lune step**. A logical clock advances at 60Hz; data arrives every
six logical frames. This does not model real network arrival when FPS falls.
Dispatch (synthetic confirmed updates and camera callbacks) is timed separately
in the raw files; it is excluded from the step columns below.

| Viewport/budget | Window | Reference step | Working-tree step |
|---|---|---:|---:|
| 1530x613 / 4ms max | idle | 0.31 / 1.88 | 0.31 / 1.87 |
| 1530x613 / 4ms max | pan | 20.14 / 28.01 | 4.82 / 17.27 |
| 1530x613 / 4ms max | zoom | 18.45 / 45.52 | 6.06 / 17.71 |
| 844x390 / 2.5ms max | idle | 0.33 / 2.03 | 0.34 / 2.03 |
| 844x390 / 2.5ms max | pan | 19.21 / 26.83 | 4.80 / 15.88 |
| 844x390 / 2.5ms max | zoom | 11.14 / 19.17 | 5.26 / 15.61 |

All GUI counts below include the entire renderer subtree, visible and hidden,
including Rails. They are **end-of-window counts**, not peak allocation claims.
Components (UIStroke/UIScale/etc.) are separate in the raw data.

| Case | Reference GUI | Working-tree GUI | Reference / working-tree rail pool |
|---|---:|---:|---:|
| desktop pan | 11,225 | 4,711 | 4,900 / 32 |
| desktop zoom | 12,814 | 6,133 | 4,900 / 32 |
| phoneBudget pan | 11,224 | 4,709 | 4,900 / 32 |
| phoneBudget zoom | 11,524 | 5,646 | 4,900 / 32 |

The one-to-two-frame ownership goal is **not met**. Batch catch-up below means
all affected block revisions reached the sink (later revisions may coalesce
intermediate states). Quantiles include completed measured batches only;
unfinished batches are explicitly retained in the last column.

| Case | Reference median / p95 frames | Working-tree median / p95 frames | Unfinished batches, reference / working tree |
|---|---:|---:|---:|
| desktop pan | 6 / 11 | 4 / 6 | 2 / 1 |
| desktop zoom | 118 / 253 | 5 / 6 | 20 / 1 |
| phoneBudget pan | 25 / 47 | 7 / 12 | 7 / 2 |
| phoneBudget zoom | 393 / 405 | 12 / 63 | 76 / 1 |

Ownership priority and the same 4ms desktop / 2.5ms touch ceilings are preserved.
The current one-displayed-image-per-frame path needs at least **two frames
for World's two pages**, or **ten for Giant's ten pages**, when all those pages
change. No stride or map-size change is proposed here. Live sparse work scales
with changed pixels and halo/block amplification; full map size also sets
first-paint, memory and page-count costs.

The isolated raster test submitted and changed 90,000 tiles in each scenario
(30 ticks). Both phases drained every batch completely, with no intervening
updates. Reference shading equals completed rectangle pixels in this test.

| Scenario / phase | Shaded pixels | Blocks | Dispatch ms | Raster ms | Raster us / changed tile | Raster ms / block |
|---|---:|---:|---:|---:|---:|---:|
| fronts / before | 296,859 | 7,902 | 315.6 | 982.5 | 10.92 | 0.124 |
| scattered / before | 4,050,000 | 4,500 | 274.5 | 11927.7 | 132.53 | 2.651 |
| fronts / after | 296,859 | 7,902 | 75.5 | 381.3 | 4.24 | 0.048 |
| scattered / after | 810,000 | 4,500 | 517.7 | 2054.8 | 22.83 | 0.457 |

Working-tree narrow-front composition took **335.3ms** and sink row copies
**6.5ms** out of **381.3ms** total raster time. Scattered composition took
**1,944.6ms**, copies **27.9ms**, total **2,054.8ms**. The remaining time includes
queue/deadline work and retained-page copies. The instrumented scattered
border section took **906.9ms** within **2,112.3ms** instrumented composition;
per-pixel clocks perturb those results. Native WritePixelsBuffer CPU time is
now observable via `rasterSinkMs`; it has **not** been measured by Codex in
Studio/on-device. GPU upload completion remains unmeasured.

The scattered case shades **80% fewer pixels**, but still sends the same
**4.05M rectangle pixels / 16.2MB** to the headless sink in both phases. Precise
CPU shading does not reduce those API rectangle bytes. Native transfer
coalescing may differ. The retained backing/border cache therefore buys CPU
speed for memory, not a demonstrated reduction in GPU work. Even the isolated
2.5ms-budget drain averaged **6.2 frames** for fronts and **27.4** for scattered
changes. Raising a phone's main-thread budget trades freshness against input
and frame time; this round retains the existing ceiling.

Raw paired captures:
[late before](../../../../tests/fixtures/OpenFrontLatePerf.before.jsonl),
[late after](../../../../tests/fixtures/OpenFrontLatePerf.after.jsonl),
[raster before](../../../../tests/fixtures/OpenFrontRasterCosts.before.jsonl),
[raster after](../../../../tests/fixtures/OpenFrontRasterCosts.after.jsonl).

The largest measured remaining structural cost is CPU political composition
and its image-update path, plus bursts of confirmed unit/style work. The pinned
OpenFront UnitPass uses a camera uniform and instanced draws; its border/color
work runs in GL passes. RoFront's implementation has not been inspected, so
its technology is not asserted here. The next bounded change should prototype
a worker-backed raster producer, retaining stride 1 and confirmed-state-only
input, while Claude captures native GUI/layout versus image-upload/GPU cost on
the same phone. That evidence should decide whether overlay batching is also
needed. A lower Lua step mean alone cannot establish RoFront-like performance.

### Changed source functions

Line numbers below refer to this working tree; existing entry-point and timing
key names remain stable. `OpenFrontClient`, Ui, shared and server production
files were not edited by Codex in this round.

- `SceneOverlay.luau`: `textSize` (58), `putRect` (68), `Overlay.new` (85), `unitParent` (157), `hideUnit` (207), `changedUnit` (220), `drawUnit` (237), `drawRails` (443), `drawRings` (484), `drawBuildPreview` (632), `drawFlag` (774), `drawNames` (804), `Overlay.setUnits` (962), `Overlay.prepareFrame` (1009), `Overlay.setCamera` (1094), `Overlay.step` (1139), `Overlay.metrics` (1248), `Overlay.destroy` (1274).
- `RasterCore.luau`: `Core.new` (37), `mark` (61), `dirtyRect` (94), `markAround` (107), `sparseChanges` (133), `Core.applyTileStates` (281), `ownerAt` (316), `composite` (323), `paint` (333), `politicalPixel` (360), `pixel` (437), `prioritize` (466), `Core.beginFrame` (491), `Core.step` (494), `Core.metrics` (615), `Core.destroy` (629).
- `StructureAtlas.luau`: `Cache.new` (58), `acquire` (64), `Cache.acquire` (90), `Cache.newMobile` (95), `Cache.acquireMobile` (100), `mobilePixels` (107), `Cache.prepare` (128).
- `SpriteAtlas.luau`: `Atlas.rgba` (15).
- `EffectOverlay.luau`: `Effects.new` (17), `point` (37), `visible` (46), `Effects.step` (94).
- `EditableRenderer.luau`: `Renderer.new` (68), `Renderer.step` (150), `Renderer.metrics` (317).
- `UnitVisuals.luau`: `Visual.isMissile` (18).

`SceneOverlay` removes the old per-segment/per-cell rail Frame helpers; its
step's hidden-cell check/reveal handling and pose-only path own the stale-view
cleanup. `EditableRenderer.new` changes its sink closure's staging ownership.
`RasterCore` also extends State/Page/Job bookkeeping for backing, masks, border
flags and actual renderer-frame ages.

Tests/benchmarks changed: OpenFrontMatchPerf.spec.luau (11 new cases and updated
camera/coordinate assertions), OpenFrontAdapters.spec.luau and
OpenFrontRoundB.spec.luau (projected results through shared transforms),
OpenFrontEffectsHarness.luau (native type/count support and cache refusal),
OpenFrontOrchestration.spec.luau (only the concurrent PerfOverlay import's test
double), OpenFrontMatchPerf.luau (late entry), plus new OpenFrontLatePerf.luau
and OpenFrontRasterCosts.luau and the four JSONL captures above.

Validation on the working tree over `33d041b`: shell regression **11 passed /
1 failed** before the fix (`Scale == 1`), then **12/0**; final map/client **166/0**,
Mobile **9/0**, actual-start Orchestration **11/0**, MatchPerf specs **22/0**.
The default MatchPerf benchmark and both late variants completed. Full suite
**496/0** during this round, including concurrent Claude work; fresh-sourcemap
full-src strict analysis and Rojo build passed. Diff whitespace check is part
of closing review. Native phone/PC feel, UIScale/text/flag alignment and draw
ordering, native API/GPU costs, repeated-match memory, Giant phone allocation
and live-network delivery remain unchecked. No commit, staging or Studio
session was performed by Codex.

## Match performance and smaller structures, 2026-10-27

Bruno reports smooth menus/spawn but poor sustained match performance on PC
and iPhone, and requested approximately half-size, smoothly zooming building
icons. This round is Map-only, over `0a84887`; Claude owns concurrent UI/server
work. No native FPS or published-game improvement has been verified here.

`SceneOverlay` now separates confirmed unit changes, actual camera changes,
and the small set of interpolating missiles. An unchanged tick does not redraw
every building. A translation-only camera change reuses the icon style and
updates its root position. Idle units are not scanned every display frame.
World-space bounds reject offscreen units before projection/style work; hidden
views release their composed-image cache lease and rebind it on return. The
nuke-ring pass retains its public unit list instead of scanning every unit
each frame. Source interpolation, flashing, owner colour, level/station,
deletion, construction, missile readiness and warship health remain visible.
Finished progress bars are destroyed; active source bars remain separate.

`StructureAtlas` composes the rim, fill and glyph into one ImageLabel inside
the existing root: **two base GUI objects instead of four**. Level/status/bar
objects are additional only when applicable. Cells have 64px content and a
1px transparent filtering gutter; analytic shape coverage and bilinear glyph
sampling replace binary shape edges. Structure images use `ResamplerMode.Default`.
The glyph source is the pinned **64px** `resources/atlases/icon-atlas.png`, not
the 13px mobile sprite atlas. No proprietary/high-resolution substitute was
introduced. Native glyph sharpness, especially at extreme zoom, still needs
inspection; a source-sized bitmap cannot promise arbitrary-resolution detail.

The reference-counted cache holds at most 450 styles in two lazy 990x990 pages,
**7,840,800 bytes / 7.48 MiB logical native pixels** at full allocation. It
evicts only unreferenced cells. Saturation or optional cache allocation refusal
retains the correctly coloured layered icon; it never hides a unit or drops
information (`structureAtlasFailed` reports refusal). Base-atlas decode
is reused. Up to 0.56 MiB of shared immutable source/template buffers is
retained, plus unmeasured table metadata. Every native page is destroyed with
the scene. Composition is checked after each cell against a 1ms live budget
(8ms under the loading cover), with at most eight cells on one page per frame.
One cell, template creation or native allocation can exceed that target.
When ownership is dirty, composition gets at most one in four upload slots;
fallback icons remain visible meanwhile. The map/status/FX/composed atlases
still share the **one displayed image per frame** rule.

### Source sizing and deliberate override

OpenFront v0.35.2 `GraphicsAdvancedSettings.ts` permits **40–70**, default
`render-settings.json` **60**. `structure.vert.glsl` uses scale .3 through zoom
1.2; zoom/3 through zoom3; a fixed size through zoom7; then zoom/7. Per-shape
scale also applies. Thus a City is 18px at World fit and 60px at zoom4.

`StructureMath.size` and its original-source tests remain unchanged.
`RenderPolicy.structureScale = .5` and `continuousStructureZoom = true` are
Bruno's explicit Roblox presentation override. The latter smoothly joins the
dot and full-icon regimes and grows gently through the old fixed-size plateau.
A City is **7.90px at .613 zoom**, **30.75px at zoom4**. Source glyph/dot and
level visibility thresholds remain. Set continuousStructureZoom=false and
structureScale=1 to restore source sizing. These are Map-local settings;
mechanics, hit testing, ranges and authoritative map resolution are unchanged.

### Raster scheduling

Live dirty queues are stably partitioned by the camera's visible world bounds;
visible pages/blocks precede queued background work. Every eighth raster step
admits background work. An already started rectangle finishes without losing
its partial rows; revisions still restart stale jobs. The native upload rule
still permits only one page per frame. Full first paint remains complete under
the loading cover, and stride stays **1**.

Without an explicit caller budget, pending work raises the 2ms raster target
to at most **4ms desktop / 2.5ms touch-capable devices**, and at most 131,072
pixels (touch ceiling implies 81,920). Explicit budgets remain authoritative.
These are bounded catch-up costs, not guaranteed latency. Phones trade more
Lua time and upload bandwidth for fresher ownership, and also pay the cache
memory above. Native image uploads/layout/GPU can exceed these CPU targets.
`rasterBudgetMs`, `rasterMaxMs`, `visiblePendingBlocks`, `lastUploadAgeFrames`,
`unitDraws`, `unitScans`, and `structureAtlas*` are exposed in metrics.

### Fixed before/after workload

Run `lune run tests/OpenFrontMatchPerf`. Exact records are
`tests/fixtures/OpenFrontMatchPerf.{before,after}.jsonl`. The before capture
uses `0a84887`; after uses this Map working tree. No other Lune test process
was running during either capture. The unchanged script uses full real World
terrain, synthetic ownership, 73 names/players, **480 structures + 120 mobiles**
(ten nukes), 24 construction bars, and **1,200 ownership edits each 10Hz tick**.
Viewport 1530x613; each mode has 120 warmup +600 unpaced logical frames.
The timers below measure renderer.step; dispatch time is separately recorded.

| Mode | Step mean before → after ms | Step p95 before → after ms | GUI property writes before → after | Max upload age before → after |
|---|---|---|---|---|
| Idle, no confirmed changes | .501 → .236 | 1.976 → 1.366 | 67,598 → 19,664 | 0 → 0 |
| Busy ownership, static fit | 3.461 → 2.381 | 12.492 → 8.214 | 1,638,402 → 126,077 | 8 → 4 |
| Busy ownership + pan | 10.780 → 5.374 | 14.812 → 9.963 | 8,658,260 → 457,610 | 10 → 6 |
| Busy ownership, zoom4 | 2.097 → 1.628 | 4.423 → 4.973 | 208,319 → 27,360 | 10 → 5 |

Age counts **raster step calls**, excluding reserved atlas frames; it is not
network-command latency or native display latency. Fit/pan retain all 600
visible views in both captures. Zoom4 has 28 →21 visible roots because smaller
icons no longer extend into the viewport from outside; all 600 views stay
allocated. This is the requested size/culling change, not an entity limit.
Structure GUI objects fall **1,968 →1,008**; total mock GUI **2,831 →1,871**.
Every measured window creates **zero new Instances**. Zoom4 p95 increases
while average cost and upload age improve: catch-up is deliberately allowed
more CPU time. No universal frame-tail improvement is claimed.

Cold full-paint capture: **56 →90 steps**, **2.276 →2.383s unpaced wall time**,
**1.836 →2.030s step CPU**, max step **78.43 →49.29ms**. The extra composition
work is real; do not multiply these steps by a frame interval or present them
as phone load times. Readiness still hides partial maps.

The property proxy adds overhead and excludes native GUI/layout, GPU, image
delivery/uploads, network, input hit testing, whole-game UI/server cost and
real phone hardware. This is synthetic stress, not the 472-player native
match. Native PC/iPhone frame tails, memory/allocation feasibility, largest
maps and Bruno's judgment of the smaller icons remain unchecked.

Verification: 155/0 OpenFront map/client tests, including MatchPerf 11/0,
Mobile 9/0 and Orchestration 11/0; fresh-sourcemap full-src strict analysis
and Rojo build pass. No full-suite run, Studio actions, uploads or commits.

Exact runtime entry points changed:

- `EditableRenderer`: `new`, `step`, `setRoster`, `metrics`; policy require/types.
- `RasterCore`: `new`, new `setViewport`/`visible`/`prioritize`, `step`, `metrics`.
- `SceneOverlay`: `new`, `putRect`, `spritePart`, new `hideUnit`/`changedUnit`,
  `drawUnit`, `drawRings`, `drawBuildPreview`, `setRoster`, `setLocalPlayer`,
  `setUnits`, `prepareFrame`, `setMoved`, `setRenderConfig`,
  `setHighlightStructureTypes`, `setCamera`, `step`, `metrics`, `destroy`.
- `StructureMath.presentationSize` (new); `UnitVisuals.unit` optional presentation
  argument. The exact source size function remains unchanged.
- New `RenderPolicy` constants and `StructureAtlas`: `setSource`, `distance`,
  `template`, `new`, `release`, `acquire`, `prepare`, `destroy`.

Tests: new `OpenFrontMatchPerf.spec.luau` (11 cases), benchmark and paired JSONL;
`OpenFrontRoundB.spec.luau` settles asynchronous icon preparation and checks the
composed style / destroyed finished bar; raster harness supplies TouchEnabled;
effects harness can refuse only the optional composed page. Screen UI, shared,
server, OpenFrontClient and Main were not edited by Codex.

## Landscape phone input pass, 2026-10-27

Bruno approved landscape-only phones; Claude owns `LandscapeSensor`, compact
HUD/drawer/sheets and hiding touch hover UI. This round changes map input only:

- `EditableRenderer.new`'s resize callback consumes held gestures and clears
  the retained preview pointer before a real viewport size/position change,
  including a transient zero size. Duplicate layout notifications retain a
  valid gesture. Camera equations/fit rules are unchanged.
- `EditableRenderer.screenToTile` rejects coordinates outside the clipped
  viewport before projecting onto the map. It still uses the actual parent's
  `AbsolutePosition` and `AbsoluteSize`, with no hardcoded safe-area/chrome inset.
- `MapInput.cancel` accepts optional `invalidatePointer`; `pointerPosition`
  keeps ghosts hidden during the one-finger remainder of a pinch. Normal touch
  release still retains the last map position for a chosen build.
- `MapInput.new` checks modal/Active-GUI exclusion in input events as well as
  on the next frame. A UI-owned second touch, either pinch finger crossing a
  sheet, a panel opening just before release, or a release consumed by Roblox
  UI consumes the map gesture (including CoreGui outside PlayerGui's hit list).
  The existing visible/Active-GUI hit testing and map-centre modal exclusion
  remain; no panel dimensions are encoded in Map.

`tests/OpenFrontMobile.spec.luau` exercises 874x402 and 667x375, offset picking,
floating queried ghosts, stale replies after resize, 800ms context/release
ownership, pinch/drag/tap/box cancellation, transparent Active side sheets,
processed motion/release and zero-size transitions. Nine cases pass in the property
shim. Vector2's native float precision is allowed in projection comparisons.
No screen UI,
shared/server/orchestration files or renderer density/stride rules changed.

`tests/OpenFrontMobileBench.luau` supplies the reproducible small-viewport
workload: real full World terrain, 473 fixed size-20 anchors and flags, 150
structures and 100 mobiles including ten nukes, confirmed updates at 10Hz,
874x402 / 844x390 / 667x375 at source fit and zoom 4. It uses 120 warmup and
600 unpaced logical frames per window, and reports density, GUI writes and
built-in timing spans. These are synthetic anchors/ownership/units, not an
actual match. CPU/property measurements exclude native GUI layout, GPU,
network, real asset delivery and phone hardware. The benchmark does not bind
MapInput or measure native `GetGuiObjectsAtPosition` cost. It cannot prove phone FPS
or readability. Native Studio checks are delegated to Claude, who owns the
active UI play session; Codex does not start/stop it. Real-device feel remains
Bruno's check.

Measured over `a9c1cec` plus this map patch and concurrent Claude UI edits
(2026-10-27). No other Lune test process was running during capture. The
property proxy adds counting overhead; these values are not native timings
or a comparison with the historical desktop benchmark.

| Viewport | Source fit step p50 / p95 / max (ms) | Zoom 4 step p50 / p95 / max (ms) | Fit name / flag / structure size (px) |
|---|---|---|---|
| 874x402 | 0.45 / 11.73 / 19.56 | 0.22 / 2.30 / 5.05 | 9.65 / 8 / 19 |
| 844x390 | 0.47 / 12.35 / 19.54 | 0.21 / 2.36 / 5.38 | 9.36 / 8 / 19 |
| 667x375 | 0.54 / 12.73 / 19.43 | 0.22 / 2.48 / 4.72 | 8.00 / 7 / 19 |

Sizes are median projected properties, not native glyph bounds. At fit all
473 names/flags, 150 structures and 100 mobiles have visible roots. Zoom 4
has 16/16/14 eligible name/flag roots and 3/3/2 structures respectively under
the existing padded source frustum; the shim does not model native clipping.
All 473 name/flag views stay allocated. Each case retained 3,036 mock map GUI
objects and created zero Instances during its measured window. Stride stays
1 with two World pages. Fixed-size synthetic anchors give dense 8–9.65px fit
names: native small-screen readability needs review, and zoom is available;
no new size floor, clustering, flag suppression or information cap was added.
The fit name span averages 11.67–12.05ms per invocation and is the largest
measured overlay span in this workload. Inclusive spans are not summed.

Verification: full suite **462/0** on the initial eight-case patch; final review
then added the failing-then-fixed processed-release regression. The final
OpenFront map/client group passes **134/0**, including **9/0** mobile cases.
Fresh-sourcemap full-src strict analysis and Rojo build pass after that final
guard. There was no second full-suite run after the one-line release guard.
No native Studio/device evidence was produced by Codex in this round, and
the native-check request to Claude has no result recorded here.

## Desktop frame-cost pass, 2026-10-25

Only `src/client/Map/` changed in this round. `EditableRenderer.new` accepts
`profile: boolean?` (default true). `resetTimings()` starts fresh counters;
`setProfiling(enabled)` toggles and resets them. `metrics()` exposes
`timing_<span>_{calls,totalMs,lastMs,meanMs,p50Ms,p95Ms,maxMs}` for `frame`,
`prepare`, `raster`, `scene`, `units`, `names`, `anchors`, `status`, `icons`, `fx`, and
`trails`. Totals/means are since reset; quantiles use the last at most 1,200
**invocations of that span**, with bounded controller-owned storage. No sample
tables are allocated during recording. Metrics queries sort copies on demand;
do not poll all metrics every frame during a performance capture. Spans are
inclusive/nested, so do not sum them. `status` is confirmed status derivation;
`icons` is per-frame opacity animation; icon layout is included in `names`.
`anchors` measures confirmed anchor ingestion; `trails` runs on confirmed
ticks outside the renderer frame callback. These are
CPU spans, excluding native layout/GPU and most client replication/UI work.

The scene skips unchanged unit GUI work between confirmed ticks/camera changes,
while source-smoothed missiles keep their sub-tick draws and final endpoint.
Level/station/deletion labels are allocated only when shown. Name geometry,
projection and colour styling are cached independently of live troop text;
interpolation reuses storage and retains the source easing tail. Sparse anchor
updates reuse unchanged owned targets rather than copying every player. Status
derivation is invalidated by ticks, state/relations/config changes; undecorated
names avoid allocating empty icon layouts. Source culling and information are
unchanged.

Controlled Lune/native-property-shim comparison: real World terrain, synthetic
ownership and 473 fixed anchors, 150 structures, 100 mobiles including 10 Atom
Bombs, confirmed updates at 10 Hz, 1914×829 viewport, 120 warmup then 1,200
unpaced logical frames. Property assignment counting uses proxy objects and
has substantial overhead; native layout, rendering, image upload and real
server traffic are excluded. Host contention also affects CPU spans.

| Measure | Before | After |
|---|---:|---:|
| GUI property assignments | 9,695,942 | 1,740,998 |
| Live map GUI objects in shim | 3,013 | 2,563 |
| New Instances during measured frames | 0 | 0 |
| Renderer CPU mean per logical frame | 22.91 ms | 9.69 ms |
| Unit span mean per frame | 13.76 ms | 3.00 ms |
| Name span mean per invocation | 53.61 ms | 35.24 ms |

The deterministic assignment reduction is 82%; 450 unused structure labels
were removed from this workload. This is **not a native FPS improvement claim**.
Claude's pre-change Studio baseline was World/public, ticks 2108–2309, 20 s,
1,077 frames: client frame p50 16.8 ms, p95 32.8 ms, max 73.9 ms, 3,753 GUI
objects across PlayerGui. Native after-change capture is pending. The temporary
benchmark, regression spec, raw before/after JSON and native probe script were
handed to Claude for adoption under `tests/`; none were written there by Codex.

`playerColor(smallID): Color3?` returns the map's primary territory fill before
terrain/alpha blending, or nil for unknown IDs/destroyed renderers. Store masks
keep that primary colour. Their secondary shade mixes 35% toward black for
light colours or white for dark colours, independently of the local grey
border. Explicit OpenFront cosmetic palettes retain their source secondary
colour. All 16 store masks/shift values were pixel-checked on light/dark fills
and inspected in generated swatches; no mask changes were needed. Native
resampling/readability remains a Studio check.

Names now render valid flags from the UI-owned `FlagArt` pages without editing
that module. Bare nation codes resolve to `f_<code>`; human `f_*`/`o_*` IDs are
preserved. Crops exclude the 2px padding. Source height (1.2×36×world scale),
128:85 slot and left-of-name placement share name culling/target sizing;
`ScaleType.Fit` preserves the supplied artwork. Native text bounds determine
the adjacent edge once available, with open Overpass metrics as the fallback
(109 width cases checked against copied original TypeScript). These metrics
come from `resources/atlases/msdf-atlas.json`, SHA-256
`90bf019d8fd20a47b69ed087a3e967f4bda0c87f7a115eed929aad20e246734c`.
Flag images share the creation budget, are reused and destroyed with name
roots. First paint waits for their GUI placement, but remote asset delivery is
still asynchronous. Native font and flag appearance need Studio confirmation.

`metrics()` also exposes map/viewport bounds, `flagImages`, `unitLabels`, actual
allocated `nameViews`, `rosterNames`, and native-only `mapGuiObjects`. Source
`centerAll` fits World at scale .829 in a 1914×829 viewport: map bounds
`(128,0)..(1786,829)`, equal 128px side margins. No camera crop/fit rule changed.
Use these bounds to distinguish letterboxing from a missing page natively.

The config-gated `Mega Nuke` is rendered with the Atom sprite, interpolation,
trail, status icon and impact/interception FX. Telegraph radii read its actual
Config magnitudes (24/60 fallback for pure hosts); the live ghost range reads
Config and the aim arc uses supplied silo/SAM data. Runtime motion still comes
from confirmed plans, so the renderer invents no speed. Atom-style decorative
debris/shockwaves are retained; gameplay blast rings use Mega's own radii.

## First-paint audit and design, 2026-10-24

Bruno's instant-map brief supersedes incremental loading. Before `e4ae7dc`,
`step` used the live 2 ms / 65,536-pixel budget for initial construction,
exposing partial 32-pixel blocks. The empty authoritative name-anchor table
also incorrectly allowed a local scan. Both paths are now corrected.

Implemented `firstPaint = "full"` as an explicit caller option: hide the map
root, compose terrain/politics/borders together in 30 ms slices, stage complete
pages, upload at most one image per frame, and wait for server-anchor label
placement plus a settling frame before revealing. Reserve separate frames for
atlas uploads. Expose `isReady`, cancellable `onReady`, and `loadProgress` to
Claude's loading screen. Preserve the existing incremental budgets after
reveal. No terrain cache yet: it would retain extra native backing and cannot
avoid the snapshot-dependent political composition. Compare the same real
World terrain and deterministic synthetic ownership/anchors headlessly; native
frame time and first-visible-frame evidence remain Claude's Studio checks.
Claude reported native World/public (473 players) loads of 437/449 ms in
10/9 frames, 137 ms first-paint step CPU, 31 ms max step and four image writes;
the revealed frame contained the complete map and 473 names. These are his
pre-round-B measurements, not a new Codex Studio run.

### Loading API

`OpenFrontClient.start` must explicitly pass `{firstPaint = "full"}` to
`Renderer.new` (omitting it preserves legacy incremental callers). Show the
loading cover before construction; attach the confirmed state and register:

```luau
local cancelReady = renderer:onReady(function()
	-- Hide the loading cover only here, for this renderer generation.
end)
```

`onReady` runs each subscribed callback once, immediately if already ready,
and returns a disconnect function. Destroy cancels pending subscriptions;
callbacks cannot prevent other callbacks by throwing. `isReady()` stays false
after destruction. `loadProgress()` is monotonic 0..1. Full mode requires
`attachState`; an empty `state.names` remains authoritative and never starts
the old local scan. Readiness covers visible source-culled names/status and
unit views, all full map pages and required atlases, then a settling frame.
Later deltas use the normal live budget without covering the map again.

`firstPaintBudgetMs` optionally overrides the 30 ms raster slice. It is a work
target, not a total frame cap: allocation, atlas decode, GUI layout and driver
work are not preemptible. Page staging retains `4 * width * height` extra bytes
at peak and releases its references on readiness, error or destroy. This is
temporary logical buffer accounting, excluding native copies/allocator cost.
The live `cpuBufferBytes` total includes current staging; the peak staging
counter is reported separately and must not be added to that total again.

`metrics()` adds `firstPaintFrames`, `firstPaintMs` (construction through ready,
including time between steps), `firstPaintCpuMs` (step work only),
`firstPaintMaxStepMs`, `firstPaintWrites`, `firstPaintStagingBytes`,
`firstPaintPeakStagingBytes`, and `loadProgress`. The CPU span excludes the UI's
ready callbacks. To read these natively, Claude can add a Studio-probe branch
`elseif kind == "render" and renderer then return renderer:metrics()` to his
existing `OpenFrontDebugClient`, then invoke it on the Client data model after
opening the same full World public setup. Capture the first frame after
`onReady`, verify every page/name, and compare cold/repeated loads. At tick
2000 also record client frame percentiles; these loading metrics alone do not
establish steady-state rendering cost.

### First-paint measurements and limits

Working tree over `5d9d627`, 2026-10-24. Sequential Lune native-property runs
used real 2000x1000 World terrain, a 1920x1080 viewport, 473 synthetic players
(1 human, 72 nations, 400 bots), deterministic land ownership and server-shaped
anchors at tick 2000. This is a loading proxy, not an actual public-match
capture: there are no units/attacks, and the full simulation suite was running
concurrently. The sink validates byte lengths but excludes native/GPU work;
EncodingService uses the existing Lua mock.

| First-paint mode | Legacy incremental | Full, hidden until ready |
|---|---:|---:|
| Step calls to complete raster / readiness | 675 | 52 |
| Map image write calls | 2,016 | 2 |
| All image write calls, including atlases | 2,018 | 4 |
| Step CPU total | 1,681 ms | 1,803 ms |
| Setup CPU | 399 ms | 397 ms |
| Longest step | 61.75 ms | 73.33 ms |
| Extra staging peak / retained at ready | 0 / 0 | 7.63 MiB / 0 |

This changes scheduling and native call batching, not the compositor's pixel
equations or its total work. Do not convert the step counts into 60 FPS load
times: the loading slices deliberately exceed a 16.7 ms frame. The full run's
30 ms raster target gave 30.20/49.98 ms p50/p95 total shim steps; the cold Lua
codec mock and overlay work can exceed that target. There is no native
frame-time, GPU, real-phone or steady-state speed claim here.

Nine focused temporary regressions pass: exact cross-page pixels versus a
fresh repaint, snapshot/anchor readiness and empty-anchor scan exclusion,
deferred visible labels/units, atlas upload exclusivity, uploaded-page
invalidation, callback cancellation, held-input cancellation across reveal,
allocation-failure cleanup and restoration of the live pixel budget. The
existing OpenFront regression suite and repository gates are reported in the
Claude relay. The test spec and benchmark are in Temp for Claude to adopt
into his tests tree; repository edits in this round stay in Map.

## Core renderer

2026-10-22, full-size map core and live OpenFront client overlay. `EditableRenderer.new` is the AssetService/RunService adapter; `attachState(state)` consumes decoded `ClientState`. The Map module owns mouse/touch/gamepad input and connection cleanup. Input is confirmed buffers and ordered records, with no packets, map-module requires, remotes or uploads. Full OpenFront map sizes remain the target; **stride is 1**, with no automatic resolution fallback.

| Files | Boundary |
|---|---|
| `Themes`, `RenderDefaults` | Ordered palettes and renderer defaults from the pinned JSON files. |
| `JsMath`, `ColorMath`, `PlayerColors` | IDs are strings; OpenFront player types are `HUMAN`, `NATION`, `BOT`. Palette RGB uses **0..255**, with unrounded internal components and alpha 0..1. `new()` owns each match's allocator state; allocation order is significant. Nation colours come from the nation pool; tribes use Bot grey unless classic bot colours are selected. |
| `PoliticalColors` | Shader-equation CPU counterparts. Input/output RGB and alpha are **0..1**, not bytes. Cardinal neighbour relations use 0/1/2, while returned border relation uses 0/.5/1. Caller supplies off-map owner 0 and optional Chebyshev owner samples. Combined fill and border share one political image. |
| `NameBoxCalculator` | Zero-based tile indices, column-major boolean grid, explicit map callbacks and confirmed player bounds/border tiles. `calculateFontSize` counts UTF-16 units like JS, including supplementary characters. Source shores/shallow-ocean/fallout admission and rectangle ties are retained. |
| `LabelMath` | Name shader sizing/culling, interpolation, troop refresh buckets and source number formatting. `nameShade` takes the renderer enum **0 human / 1 bot / 2 nation**. `size` takes matrix X scale, not raw CSS zoom; slot indices and time buckets are zero-based/seconds. |
| `CameraTransform` | Explicit viewport offsets and source TransformHandler offsets. Scale is CSS-equivalent pixels/tile. `goTo` takes milliseconds; the owner schedules it and supplies 16 ms for the first callback. Initial `centerAll` deliberately bypasses wheel clamps, matching the source. |
| `StructureMath` | Projected icon sizes are in backing pixels. Apply DPR conversion at the adapter. Effective classic icon defaults override the raw JSON defaults. |
| `NukeTrajectory` | Continuous control points with rounded destination for discrete threshold search, ordered SAM list, JS truncation and ten-step crossing refinement. This predicts a preview, never decides an actual interception. |
| `SpawnOverlay` | Source human-only filter, spawn colour selection and radial shader-equation samples. `breath` takes accumulated milliseconds. Kind 0 enemy / 1 self / 2 teammate. Ownership masks enemy highlights; self/teammate gradients are not land-clipped. |
| `TerrainColors` | `ColorUtils.encodeTerrainTile/buildTerrainRGBA`, including impassable background, sandy coast, depth shading and all elevation thresholds. LUT covers every terrain byte. Live RenderSettings highland RGB is `(220,203,158)`; the utility's nil-override fallback is `(200,183,138)`. |
| `RasterCore` | Pure, full-resolution terrain/politics producer. 1024-pixel pages, 32-pixel dirty blocks with tight subrects, neighbour/hover halo invalidation, fair one-page scheduling, row deadlines, revision-checked partial jobs and bounded colour LUTs. |
| `EditableRenderer` | Roblox image/controller adapter. Composes terrain and politics into one opaque image per page; Pixelated filtering, shared rounded page edges, map input and cleanup. |
| `UnitVisuals`, `SpriteAtlas`, `SceneOverlay` | Source unit atlas masks, six structure shapes, level/health/progress/veterancy overlays, rail geometry, nuke rings and confirmed motion courses; rendered in pooled GUI above the political image. |
| `MapInput` | Tap, drag, wheel, pinch, gamepad and 800ms touch/right-click context. Command callbacks and preview pointer state stay separate. |
| `BuildPreviewController` | Coalesced authoritative preview query, source ghost/range data, per-frame cursor follow and Atom/Hydrogen aim. Advisory intent never changes confirmed units. |

## Standalone API

2026-10-23 over `7932484`: `bindInput(...,onTap,onMove?,selectionAllowed?,onContext?)`
now includes `(tile:number,screenX:number,screenY:number)->()` context; `hasSelection()`
reads/prunes ship selection. `goTo(worldX,worldY,scale?)` owns source fly-to easing
and clears on manual camera changes/destruction. OpenFrontClient wires context
precedence, the buildChosen callback, the preview Query and both UI fly-to hooks.
The new BuildPreviewController retains touch position, rejects stale query
results and clears on modal/focus/teardown. Only Atom/Hydrogen get aim arcs;
impassable targets hide the ghost while retaining the blocked trajectory.
See [input/preview audit](../../../../docs/openfront-port/CLIENT_INPUT_PREVIEW_AUDIT.md)
for exact interfaces, original-TS evidence, concurrent UI integration and limits.

2026-10-23 follow-up over `bccc0d5`: final inactive records now drive live death
FX. `state.names`/NamesChanged replace local name scans; public allies/embargoes
and teams drive borders/telegraphs and separate SAM affiliations. Construction
bars use constructionStartTick and `state:config()`. Water tap/Shift-drag/gamepad
warship selection sends the existing move intent through the caller; it never
moves units locally. Build/SAM preview APIs await the UI's authoritative query hook.
See [the current adapter audit](../../../../docs/openfront-port/CLIENT_ADAPTERS_AUDIT.md)
for exact files, source oracles, observed native World/zoom/drag frames and remaining
approximations. It supersedes older missing-input claims below; historical
measurements retain their original provenance.

```luau
local Renderer = require(pathToOpenFront.EditableRenderer)
local map = Renderer.new(viewportFrame, terrainBuffer, width, height)
map:setRoster(orderedPlayers)
map:setLocalPlayer(mySmallID) -- 0 for spectator
map:setRelations({size = relationSize, data = relationBuffer})
map:applyTileStates(confirmedStateBuffer) -- full snapshot
map:attachState(decodedClientState) -- units, rails, names and stats
map:bindInput(playerGui, mapGui, function(tile) sendTileAction(tile) end)
-- On later confirmed commits:
map:applyTileStates(confirmedStateBuffer, changedTileRefs)
-- On match teardown:
map:destroy()
```

| Method | Contract |
|---|---|
| `new(parent: GuiObject, terrain: buffer, width, height, options?)` | Exact `width*height` terrain bytes. Owns copies of terrain/state, a clipped child Frame, connections and lazy image allocations. Initial view fits the parent. Image construction/painting progresses over subsequent render frames. |
| `setRoster(players)` | Full **ordered** array of `{id:string, smallID:1..4095, playerType:"HUMAN"\|"BOT"\|"NATION", team:string?, cosmetics:PlayerColors.Cosmetics?, pattern:Pattern?}`. Call on roster/cosmetic changes, not stat ticks. Replays colour allocation in source order. Pattern is an optional already-decoded `{width,height,scale,bytes:buffer}` bitmask; bit 1 selects secondary. Copies metadata/masks. No skins/assets are loaded by this core. |
| `applyTileStates(stateBuffer, changedTiles?)` | Exact `width*height*2` u16 buffer. Owner `raw & 0xfff`, fallout `0x2000`, defence `0x4000`. Nil list copies full state and queues a full repaint; empty list does nothing; nonempty list copies only those refs and invalidates tight neighbour/halo bounds. TileRef 0 is valid. Later caller mutation cannot change the render state without this call. |
| `setRelations({size, data})` | Copies row-major u8 `size*size` matrix: 0 neutral, 1 friendly, 2 embargo. Caller supplies source symmetric effective relationships. Missing/out-of-range IDs are neutral. Queues a full repaint. |
| `setLocalPlayer(smallID)` | Resolves own focused border through the original cosmetic precedence. Queues a repaint; team/pattern rules remain source-driven. |
| `setHover(smallID)` | 0 clears. Invalidates the previous/new owners' indexed blocks, using the original fill contrast and Chebyshev border halo. The conservative index can include former owners after a partial patch; full-block paints prune them. This adds work without missing pixels. |
| `setCamera(view)` | Copies a `CameraTransform.View`; map width/height must match, viewport/left/top describe the parent. Repositions labels only. Adjacent image edges use the same rounded transformed coordinate. |
| `pan(dx,dy)`, `zoom(screenX,screenY,delta)`, `centerAll(fit?)` | Call the ported CameraTransform equations then update label transforms. No terrain/political writes or image allocation. No input bindings are installed. |
| `applyTerrain(terrainBuffer, changedTiles?)` | Optional water-nuke path. Same nil/full and empty/no-change semantics, for the existing map dimensions. Copies changed terrain bytes and invalidates affected pixels. |
| `step(budgetMs?, pixelBudget?)` | Automatic once per RenderStepped by default. Default **2 ms**, **65,536 pixels**, one displayed image/page per call. `autoStep=false` supports a caller-owned frame driver; then call exactly once per frame. It resumes partial rows/jobs and coalesces later confirmed changes. |
| `metrics()` | Pending blocks, page count, pixel/upload counts, maximum dirty-to-upload age in step calls, explicit CPU buffer bytes and logical/allocated image pixel bytes. |
| `destroy()` | Idempotent. Disconnects listeners, destroys every native image/label/root and releases CPU buffers/caches. Root destruction triggers cleanup too. |
| `attachState(state)`, `bindInput(playerGui,mapGui,onTap)` | One decoded ClientState scene and one input controller per match. Both disconnect and release on renderer destruction. `screenToTile(x,y)` and `worldToScreen(x,y)` expose only map transforms; packet interpretation and command sending stay with the caller. |
| `setNukePreview(data?)` | During targeting, pass the `NukeTrajectory.buildNukeTrajectory` result (or nil to clear). Draws 128 source Bezier samples and interception/dash colours above the map; the future targeting UI owns when this preview appears. |
| `setBuildPreview(data?)`, `setHighlightStructureTypes(types?)` | Source-shaped validated GhostPreviewData renders ghosts, range, costs, provided rail paths and SAM circle-union ranges. Highlight types dim other structures. No buildability/cost/path decision is made by the renderer. The UI/action hook must supply/query those inputs. |
| `bindInput(..., onTap, onMoveWarships?, selectionAllowed?, onContext?)` | Optional move callback enables water-tap selection; selectionAllowed lets build mode take priority. Optional context receives tile and screen coordinates separately from taps/moves. Shift-drag boxes, gamepad Y/B and dead/captured pruning are map-owned. |
| `hasSelection()`, `goTo(worldX,worldY,scale?)`, `clearTarget()` | Read/prune current ship selection; fly to source world tile coordinates at optional pixels/tile scale; cancel a flight. No half-tile adjustment for name anchors. Manual camera changes cancel flight automatically. |

The unit mask data is generated by `tests/generate_openfront_sprite_masks.py` from v0.35.2 `resources/atlases` (CC BY-SA 4.0, credit OpenFront). It occupies one shared 512×192 EditableImage with 0.375 MiB logical pixels. Visible unit views are created at most 25 per frame. The latest World 844×390 headless GUI-property run in `tests/OpenFrontOverlayBenchmark.luau` covers 150 structures, 100 mobile units, 400 name anchors and a visible 221-tile rail: p50 4.051 ms, p95 7.353 ms, max 21.824 ms over 240 frames, with 2,293 mock GUI objects. At 6 px/tile, detailed rails produce 994 visible cells and the same workload measures p50 2.284 ms, p95 3.729 ms, max 5.104 ms over 90 frames, with 2,873 mock GUI objects. This excludes Roblox native GUI/layout/GPU and cannot establish a 60 FPS result. That measurement is historical: server name anchors, construction start ticks/durations and effective relation edges are now integrated. Authoritative anchors, including an empty table, suppress the local scan. The [own-territory comparison](../../../../tests/fixtures/OpenFrontOwnTerritoryOptions.png) is a headless design mockup, not a Studio screenshot or a selected palette.

The historical local-name fallback took 686 frames at 60 FPS equivalent (about 11.4 seconds) to scan full World and place 400 border-cluster names under a 4 ms scan budget. Its overlay CPU p95 was 13.343 ms, max 16.476 ms; spawn-tile labels appear immediately. Current authoritative anchors remove this scan from the integrated client.

Options are `{autoStep:boolean?, budgetMs:number?, pixelBudget:number?, onError:((string)->())?, firstPaint:("full"|"incremental")?, firstPaintBudgetMs:number?, profile:boolean?}`. A failed native allocation/upload stops and destroys the controller, records `lastError`, and invokes `onError` once (or warns once). It **does not silently shrink the map**. Budget checks run between rows; native allocation/upload, colour-LUT creation, snapshot copies and roster/relationship invalidation are non-preemptible, so 2 ms is a work target rather than a hard frame-time guarantee. Camera/tile picking can use a copy of `map.camera` with CameraTransform.

## Resolution, scheduling and measurements

One source tile is one image pixel. World uses **2** pages; Compact World **1**; Giant World **10**, including exact-size edge pages. Terrain is cached as byte→RGBA lookup data and recomposed only inside dirty rectangles. Combining opaque terrain and translucent politics into the displayed page halves pixel backing versus two full layers. A shared processed-colour LUT cache is capped at **4 MiB**; grey tribes share entries. Beyond the cap, the same blend is calculated directly.

Roblox documents a **1024×1024** maximum, opaque device-specific client memory limits, and **one displayed EditableImage updated per frame**. The scheduler writes only one page per frame and rotates among pending pages. This is a native presentation constraint, not a reason to change the simulation map. [EditableImage reference](https://create.roblox.com/docs/reference/engine/classes/EditableImage)

Final headless probe over `8682cfe` plus this working tree, on Windows/Lune with a rectangular buffer-copy sink. Raw source map loading and synthetic state preparation are excluded. Roster: one human and 399 tribes; ownership is a synthetic grid on passable land. Churn: 1,200 changed TileRefs every sixth step, 360 simulated 60 Hz steps, hover enter/leave at steps 121/241. No other Lune process was observed immediately before this run. Exact records: `tests/fixtures/OpenFrontRasterBenchmark.json`.

| Map | Dimensions / pages | Terrain build CPU | Political full repaint CPU | 1,200-ref dispatch p50 / p95 / max | Dispatch + worker frame p50 / p95 / max |
|---|---|---|---|---|---|
| World | 2000×1000 / 2 | 406 ms | 1,248 ms | 1.75 / 2.12 / 2.67 ms | 0.77 / 3.70 / 5.00 ms |
| Compact World (`map4x`) | 1000×500 / 1 | 97 ms | 304 ms | 1.61 / 1.97 / 2.22 ms | 0.001 / 3.69 / 4.24 ms |
| Giant World | 4108×1948 / 10 | 1,664 ms | 4,899 ms | 1.69 / 2.41 / 2.53 ms | 1.64 / 2.88 / 4.42 ms |

Constructor CPU: 6.37 / 2.99 / 27.13 ms; roster/invalidation: 9.43 / 8.79 / 18.74 ms; snapshot copy/invalidation: 3.34 / 0.82 / 12.73 ms, respectively. These are separate from worker totals. Every churn run ended with **zero pending work**. Peak backlog was 65 / 56 / 78 blocks. Maximum dirty-to-upload age was **19 / 19 / 28 calls**, or approximately **317 / 317 / 467 ms** if driven at 60 Hz; native display latency is additional and unmeasured.

**Historical incremental full-repaint latency:** under the 2 ms budget, terrain required 203 / 49 / 830 calls and politics 618 / 151 / 2,425 calls. At 60 Hz those political repaints would span **10.3 / 2.5 / 40.4 seconds**, not the CPU totals in the table. The integrated full first-paint mode now composes behind a cover with 30 ms slices, independently of that live-update budget. These old repaint figures are not current match-opening latency. No stride exception has been selected or hidden.

| Map | Renderer-owned explicit CPU buffers | Logical native pixel backing (4 bytes/pixel) | Caller buffers retained by this probe, additional |
|---|---|---|---|
| World | 6.79 MiB | 7.63 MiB | 6.72 MiB |
| Compact World | 2.49 MiB | 1.91 MiB | 2.43 MiB |
| Giant World | 24.03 MiB | 30.53 MiB | 23.90 MiB |

CPU buffers include the renderer's terrain/state copies, relation matrix, dirty metadata, scratch rectangles, patterns and current colour LUTs. Pixel backing is a **lower-bound accounting estimate**, not a measured native allocation. The copy sink allocates that many bytes headlessly. Lua table/allocator overhead (including 3,463 / 1,947 / 7,987 owner-index entries), Instances, driver/GPU copies, the rest of the client, and phone memory limits are excluded. This grey-tribe probe used only 3 KiB of paint LUTs; varied player colours can use up to the 4 MiB cap. Giant's allocation feasibility on a phone remains unknown; allocation failure is explicit and tested.

```powershell
node --experimental-strip-types tests/generate-openfront-terrain.mjs
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/run OpenFrontRaster
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontRasterBenchmark ../reference/openfront-v0.35.2 giant
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/OpenFrontRasterPreview ../reference/openfront-v0.35.2 "$env:TEMP/ConquestOpenFrontPreview"
```

Preview exports terrain and fake confirmed nation discs as raw 2000×1000 RGBA for direct PNG encoding. Pixel inspection found the pale terrain/depth bands, nation fills, own border and hover boundary coherent across the 1024 seam. This is headless evidence, not a native screenshot. Map data remains OpenFront CC BY-SA 4.0 with credit “OpenFront”; no asset was uploaded.

Studio MCP found the correct Conquest place; Play was started and returned to Edit. **`execute_luau` was rejected because it requires approval while this session's approval policy is `never`.** The core demo could not be executed, so native allocation, presentation/seams, screenshot, frame cost and phone feasibility remain unverified. The shim tests cover constructor/error cleanup, one-image scheduling and camera geometry, without substituting for those native checks.

## Verification

2026-10-24 status follow-up: `PlayerStatus` derives crown, traitor/disconnected, direct-alliance/request, bilateral embargo, friends' targets, active-nuke and recipient-filtered emoji indicators from confirmed ClientState. `NameStatusOverlay` places the open packed artwork above the existing anchors, with source row layout, alliance drain/flash and target cull boost. `traitorUntil` supplies the source expiry flash. The lazy 640×448 atlas uses native Base64/Zstd decoding and the reserved image-upload frame; its GUI images share the scene creation budget. Reconnect emoji/target history and exact TargetPlayer creation ticks are still missing. See `docs/openfront-port/CLIENT_STATUS_ICONS_AUDIT.md` for source distinctions, asset provenance, functions and verification limits.

2026-10-24 readability follow-up: player names and troop counts now share the source's dark human/nation/bot fills and opaque territory-colour outlines. Font projection uses the open Overpass atlas's 48-unit em, with its 36-unit baseline retained for line spacing/culling; native SourceSansBold remains an approximation. Finished local structures now use their territory colour for the rim, with source construction greys and opaque shape coverage. `renderer:setOwnSpawnRing(active: boolean)` exposes the source tutorial's post-spawn self ring; it defaults false and is not automatically activated. The source small-player aura is a separate, still-missing territory-mask bloom. Evidence, exact changed functions, integration hook and remaining limits are in `docs/openfront-port/CLIENT_READABILITY_AUDIT.md`.

`tests/generate-openfront-renderer.mjs` copies pure reference code into a fresh system temporary directory, transforms import/type boundaries, and executes the copies under Node 24.14.0. It never executes code in the reference checkout. `tests/fixtures/OpenFrontRenderer.json` records the pinned commit and SHA-256 of each source file used. `tests/OpenFrontRenderer.spec.luau` checks the Luau results.

Compared against **original TypeScript execution**: UTF-16/hash cases; 50 seeded first RNG draws; 90 rectangle grids; 27 name/spawn placements spanning all sampling thresholds; 126 camera trace steps across phone/desktop/small-map viewports; 168 nuke trajectories/interception thresholds; 90 number-format cases; 24 first palette assignments. The first allocator oracle passes hex tokens through the original constructor/seed-selection path; it never calls a substitute perceptual-distance function.

Terrain adds **768 byte vectors** (all 256 bytes under live, utility-fallback and custom overrides) from copied original `ColorUtils.ts`. Ten raster/adapter tests cover page coverage, one-image-per-step scheduling, cross-page/row/block deltas versus a fresh repaint, shared political equations, revision restarts, input-buffer ownership, pattern/paint-budget paths, water-nuke edits, camera seams without pixel writes and allocation-refusal cleanup. The CPU framebuffer blend and GPU sine/float precision have not been compared against WebGL pixels.

**Colour oracle completed:** Claude supplied the locked **Colord 2.10.0** package in `../reference/openfront-run/node_modules/colord`. The generator copies that package and the original allocator/theme/player-colour TS into Temp before executing them. The fixture records the pinned package-lock integrity and SHA-256 of the package metadata, core, LAB and LCH modules. Colord's MIT notice is retained in `Colord-LICENSE.txt`.

Regenerate the oracle (the package path defaults to the supplied sibling `openfront-run/node_modules/colord`):

```powershell
node --experimental-strip-types tests/generate-openfront-renderer.mjs ../reference/openfront-v0.35.2 ../reference/openfront-run/node_modules/colord
& "$env:USERPROFILE/.luau-tools/lune.exe" run tests/run OpenFrontRenderer
```

The six colour tests compare every exported ordered palette/constant in both themes, **780** human/nation/tribe allocations including exhaustion, **1,154** generated variants across 20 team palettes, **176** team assignments/cache checks, **882** RGB/LAB/LCH/hex/darkening conversions, **82** explicit perceptual-selection/delta cases, **119** structure/defended-border pairs and **40** cosmetic precedence cases. The fixture's `colord.verified` is now **true**, with the Luau comparisons passing. Without the locked package, regeneration explicitly records false and its reason; the tests then fail rather than silently dropping colour coverage.

The oracle caught and corrected the earlier provisional code: use Colord's separate sRGB→D65→Bradford D50 matrices and XYZ clamps, preserve the reverse adaptation, round hex alpha to two places on parse and three before serialization, require the hash prefix, and wrap rounded LCH hue. Team variation colours are compared at the rounded RGB boundary consumed by the original renderer; LAB/LCH/delta are compared at Colord's public rounding boundary. Internal floating-point bit equality is not claimed. Four source structure-contrast inputs hit its iteration-limit warning; the resulting colours match, and the source stop rule is retained.

**GLSL-derived functions:** territory/border/hover/checker, label size/cull, structure LOD and spawn gradient were checked against the source equations with boundary/property fixtures. They have not been run in WebGL or compared against native Roblox screenshots. CPU doubles, GPU float precision and GPU sine/noise can differ. No visual, upload, frame-cost, real-phone or touch-parity claim follows from these tests.

No shared/server/UI/Main changes were made by Codex in that historical foundation round. The confirmed-state adapters for player metadata, anchors, tile state and relations are now integrated; remaining data gaps are tracked in the client audits and handoff.

Checks over `8682cfe` plus this working tree: **26 pure renderer tests and 10 raster/adapter tests pass**. The complete suite reports **325 passed, 0 failed**. Full `src/` strict analysis is clean after a fresh sourcemap, and `rojo build` succeeds. Shared/server/UI/Main files were untouched by Codex. The agreed renderer state proposal is in `docs/openfront-port/RENDER_CONTRACT.md`.
