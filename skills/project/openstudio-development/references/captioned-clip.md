# Captioned Clip surface (`kind=captioned_upload`)

The non-vendor captioned-clip kind: user uploads a short, ASR produces
word timings, planner groups them into display chunks, Remotion renders
captions over the source. Not a vendor-rendered kind — the renderer is
our own motion-renderer. This file carries the standing product rules
and the registry gotcha that re-burned time.

## Registry wire-up: every new kind needs the registry entry AND the client URL

`apps/api/main.go` holds a `kindByRoute` slice literal that drives
per-kind HTTP route generation — adding a kind here mounts
`POST /api/v1/{route}/projects`, `.../projects/draft`,
`.../projects/{id}/render`, `.../progress`. **A new kind without a
registry entry has handlers but no routes; every call returns 404.** The
entry shape is `{kindID, route, composition, mediaType, enabled}`;
non-vendor Remotion kinds set a real `composition` id, non-Remotion
kinds set `""`. For captioned-clip:
`{"captioned_upload", "captioned-clip", "", "video", true}`.

**The client URL does NOT have a `/kinds/` prefix.** Every other kind
posts to `/api/v1/{route}/projects/{id}/render`; a wizard that was
copy-pasted from a bad reference and uses `/api/v1/kinds/{route}/...`
404s even after the registry entry lands. When a Render button 404s on a
newly-registered kind, grep the wizard for `/kinds/` before touching the
server again:

```
grep -rn "/api/v1/kinds/" apps/web/app/\(app\)/create/
```

If anything matches, the client is wrong.

## Auto cadence must be dynamic — pause-aware, capped, display-rate-floored (standing user rule)

Standing product decision for every look: looks pick **layout** (anchor,
color, animation), never **word-grouping**. The 'megaphone forces 1 word'
and 'karaoke forces 2 words' hard-codings in
`packages/compositions/src/primitives/Captions.tsx` (`forcesWordsPerWindow`)
are out — do not add them back for new looks. The web `FORCED_CADENCE`
map in `card-tune.tsx` is also out; the Tune picker is never greyed on
the cadence row.

Auto cadence runs on the planner side and emits display chunks on the
plan JSON. Rules the chunker enforces (`apps/worker-core/activities/caption_plan_chunks.go`):

- **Hard cap: 5 words per chunk.** A long pause-free run breaks on the
  cap regardless of what the speaker is doing.
- **Pause threshold is derived per-video**, not hard-coded — 75th-percentile
  of positive inter-word gaps, clamped to `[150, 600]` ms. A fast speaker
  gets a tight break, a slow one a looser break; the clamp protects
  against an outlier gap distribution (an all-silent prologue skewing
  the percentile) and prevents sub-breath splits.
- **Display-rate floor: 150 wpm counting pauses.** After chunking by
  pause + cap, each chunk's `endMs` is extended so that chunk-duration
  ≥ `60000 / 150 * len(words)` — but never past the next chunk's
  `startMs`. One-word chunks that would otherwise flash hold until the
  next chunk starts.

**When the plan shape changes (new field on `CaptionPlan`, new chunking
rule, new per-scene field), bump the cache-key version prefix** in
`cacheKeyFor` (`v1:` → `v2:` → …). The composition reads the plan
verbatim; a stale `v1` plan served to a composition that expects `v2`
chunks will render fine but with the old word-grouping. If you only
bump the chunker and forget the version, every existing project
continues to show pre-dynamic cadence until someone deletes
`content.caption_plans` rows by hand.

To force a replan on a specific project without clearing the whole
table: `DELETE FROM content.caption_plans WHERE project_id = '...';`
The next render dispatch rebuilds the plan under the new version.

## Composition contract: scene owns position/color, chunks own grouping

The plan carries `scenes[]`, `words[]`, and `chunks[]`. Scenes own
layout metadata (`position`, `color`, `cadence` label — label only,
not structural), words own the raw ASR tokens, chunks own what's
displayed at once. The composition slices chunks per-scene by
`startMs/endMs` overlap and shifts timings to be sequence-relative
before handing them to the Captions primitive; the look is a pure
presenter over the active chunk + active-word index.

**Looks must never read `cadence` to decide how many words to render.**
If a look wants a single-word presentation effect (giant screen-filling
word, karaoke pop), it should accept the chunk it is given and render
one word at a time by picking by `activeWordIndex` — not by demanding
`forcesWordsPerWindow: 1` on the dispatch map.

## Overflow: wrap inside the safe area, do not shrink to one line

Standing product rule: **captions must never overflow the frame.** The
safe area is `videoWidth * 0.9` (5% inset per side). When the planner's
active chunk is wider than one line of safe area, the primitive
(`packages/compositions/src/primitives/Captions.tsx`) WRAPS it onto up
to 3 lines before shrinking the font — never drop or reword tokens, the
planner's chunk is the contract. Both the outer wrapper and `WordRow`
(`primitives/caption-highlights/shared.tsx`) already set `flexWrap:
'wrap'`; the budget must be `safeWidth * maxLines` so wrapping actually
kicks in. A single-line budget forces an aggressive shrink that still
overflows on long chunks + wide glyphs because the character-advance
estimate (~0.58 × fontSize) under-counts uppercase and condensed sans.

Shrink floor stays at ~0.5 of `baseFontSize` only for the pathological
case where 3 lines still would not fit. Looks that scale the active
word (Megaphone renders it at 1.6×) must bill that scale PER-WORD in
the width estimate — scaling the whole chunk by 1.6× over-estimates by
the neighbour count and triggers unnecessary shrinks.

Theme modules in `primitives/caption-highlights/*` that build their own
flex container (Letterbox, Megaphone) MUST also carry `flexWrap: 'wrap'`
+ `whiteSpace: 'normal'` on that container, otherwise the dispatcher's
wrap budget is honoured by the outer div but the look still renders a
single non-breaking line inside it. This is the OPPOSITE requirement
from the burned-in caption themes in `primitives/themes/*` (see
`references/caption-themes.md`), which are single-line + `nowrap` to
match their design-of-record preview SVG — do not conflate the two
module trees.

## Word-count semantics in the Review surface

`plan.words.length` is 'one row per ASR token' — Whisper may split
hyphenated words or attach punctuation to the previous token. The
number shown in Review is this raw count; it is NOT 'unique spoken
words' or 'words after punctuation strip'. Do not quietly collapse
punctuation-only tokens: the composition's active-word index would
drift against the planner's chunk indices. If a user asks 'why does it
say 86 words', the answer is 'raw ASR tokens, one per Whisper output' —
not a bug.

Cadence (the user setting) does NOT change word count. It only affects
chunk grouping at render time.

## Resumable wizards: URL IDs are a pointer, not state — fetch the project

The captioned wizard URL carries `projectId`, `assetId`, `step` as
resumable pointers. **Hydrating only those IDs is not enough**: Upload /
Pick a look / Fine-tune render summary rows from `state.title`,
`state.look`, `state.position`, `state.color`, `state.cadence` — if the
mount-time hydration never fetches `GET /api/v1/projects/{id}`, all
those rows are blank when the user clicks Edit on an existing project.
For every resumable wizard that accepts a `?projectId=` entry point,
add a one-shot effect keyed on the URL id that fetches the project and
dispatches a `HYDRATE` with `title`, `settings.look`, `settings.position`,
`settings.color`, `settings.cadence`, `settings.sourceAssetId`. Guard
against re-fetching the same id on every re-render with a `useRef`
sentinel; a cross-workspace 404 must be a silent no-op (the wizard
still works, just with blank summaries) because leaking that the row
belongs to another workspace defeats the API's own 404-not-403 rule.

## `POST /caption/plan` is a settings patch, NOT a planner trigger

The handler at `apps/api/caption_plan.go` POST path (`handleSetCaptionPlan`)
is commented verbatim "Does NOT enqueue a render" — it writes the
merged settings and returns. The planner (`CaptionPlanActivity`) only
runs inside the render workflow dispatched by `POST /api/v1/captioned-clip/projects/{id}/render`.
A UI button labelled 'Generate plan' or 'Preview captions' that posts
to `/caption/plan` will silently do nothing — settings land, no plan
appears, the empty-state renders again. If you need a plan-only path
(review the chunks before rendering), add a dedicated endpoint that
queues the planner workflow without the render step; do not shoehorn
it onto the settings-patch handler.

## Dev auth gotchas when probing the API

The dev-login endpoint signs cookies into the `rebel@openstudio.dev`
workspace. A project created in the browser via real signup lives in a
different workspace. The API returns 404 (NOT 403) on cross-workspace
project reads to avoid leaking existence — so a `curl -b /tmp/cookies.txt
/api/v1/projects/<id>/caption/plan` that 404s does not mean the project
does not exist; it may mean 'exists, wrong workspace'. Confirm with a
direct DB query:

```
psql -h localhost -U sa-vm -d openstudio -c \
  "SELECT id, workspace_id FROM content.projects WHERE id='<id>';"
```

If `workspace_id` differs from the one dev-login signs into, you need
to re-render through the browser (which carries the real session) or
read the plan directly from `content.caption_plans`.
