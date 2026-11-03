# Cast character catalog — adding, re-sourcing, seeding

The 7 seed characters live in `content.characters` with `is_presenter=TRUE, workspace_id=NULL` (public catalog). Adding an 8th, or re-sourcing images/voices for the existing 7, touches six wire points below. Miss one and the character silently loads with placeholder assets that look correct in the UI but ship as fake content.

## Wire points (all six, atomic)

1. **DB seed** — `apps/api/dashboard.go` presenter loop. Struct literal carries `{id, name, voice, color, desc, short}`. Description is prose (tooltip); `short` is 3-4 comma-separated descriptor words (`Dim, Lovable, Dad`) capped at 64 chars by the `short_description_len` CHECK constraint.
2. **Voice alias** — `services/ai-gateway/elevenlabstts/elevenlabstts.go` `voiceAliases` map: `voice_seed_<char>` → 20-char ElevenLabs permanent voice ID from Voice Design promotion (see `references/elevenlabs-voice-design.md`).
3. **Character alias set** — same file, `characterVoiceAliases` (a `map[string]bool`). MUST include every character voice or the operator's `ELEVENLABS_DEFAULT_VOICE_ID` will override the character-specific voice and collapse every character to the same sound. Stock aliases (`voice_seed_narrator`, `voice_seed_male_std`) intentionally stay OUT of this set so operators can still pin a default for the standalone voices.
4. **Sprite upload** — `mc cp <char>-{closed,open}.png local/openstudio-public/presenters/`. The API's `handleListPresenters` composes `MEDIA_PUBLIC_URL/presenters/<char>-<state>.png`.
5. **Sample MP3 upload** — `mc cp <char>-sample.mp3 local/openstudio-public/cast-samples/`. Set on the DB row via `sample_url = MEDIA_PUBLIC_URL + "/cast-samples/<char>-sample.mp3"` in the seed loop.
6. **Repo fixture cache** — `cp <char>-*.png fixtures/presenters/`. A fresh clone rebuilds MinIO from these; skipping means the character works on your VM but is missing on a teammate's.

## Render stuck in a Temporal retry loop with `EncodingError: The source image cannot be decoded` → MinIO bucket is empty, re-mirror the fixtures

Symptom: `content.renders` row sits at `status=running, progress=0.889` for
minutes with no advance; `temporal workflow show` shows `renderRemotion`
activity scheduled and not completing; motion-renderer log repeats
`[Tab N] EncodingError: The source image cannot be decoded` + `Error
loading image with src: http://localhost:9000/openstudio-public/presenters/<char>-{open,closed}.png`.
The DB row references the sprite key correctly; MinIO is just empty
(fresh brew MinIO after a cluster re-init, a `mc rm --recursive` that
over-reached, or a wipe migration).

Recovery (does NOT need the workflow to be terminated — Temporal retries
keep re-trying `renderRemotion`, so a successful attempt after the fix
completes the render in place):

```bash
cd /Users/sa-vm/Workspace/openstudio/openstudio
mc cp --recursive fixtures/presenters/ local/openstudio-public/presenters/
# verify one URL is 200 + a real PNG
curl -sI http://localhost:9000/openstudio-public/presenters/<char>-open.png
```

Remotion's in-render image retries (`Could not load image ..., retrying
again in 2000ms`) will pick up the newly uploaded sprites within the
next retry window and the current activity attempt succeeds. Confirm by
watching the log for `Retry successful - ... is now loaded` and the DB
row moving to `status=done, progress=1.000`.

Same recovery pattern applies to any catalog bucket whose fixtures live
in the repo: `fixtures/presenters/`, `fixtures/<look>/`, etc. `cast-samples/`
(sample MP3s) is NOT in the repo fixtures — its contents come from Voice
Design generation (see `references/elevenlabs-voice-design.md`) and a
missing sample MP3 breaks only the /cast preview UI, not renders.

Reseed pattern: the seed loop guards on `CountPresenters(ctx) == 0`. To pick up new descriptions or a new character list, write a migration that `DELETE FROM content.characters WHERE is_presenter = TRUE AND workspace_id IS NULL` — the next API boot's seed runs cleanly via `ON CONFLICT DO NOTHING`. This is safer than `UPDATE` because it exercises the same code path as a fresh install.

## Sourcing real character images (Wikipedia > Fandom > aggregators)

Aggregator sites (pngkey, clipartmax, pinterest, pngwing) all wrap the image behind a click-through/anti-hotlink layer — programmatic download returns HTML, not PNG. Skip them.

Fandom (`static.wikia.nocookie.net`, `<char>.fandom.com/wiki/Special:FilePath/...`) sometimes serves clean PNGs but hotwalls unpredictably with 403 even with a browser UA. Not reliable enough to script.

**Wikipedia's `upload.wikimedia.org` is the reliable source.** Fair-use character portraits are hosted there for infobox display. Two-step scrape:

1. Fetch the character's Wikipedia article HTML with a browser UA + Referer:
   ```bash
   UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15'
   curl -sSL -A "$UA" "https://en.wikipedia.org/wiki/Homer_Simpson" | \
     grep -oE '//upload.wikimedia.org/wikipedia/(en|commons)/[^"]+\.(png|svg|jpg)' | head -3
   ```
2. Download the first infobox-shape hit (`https:` + the extracted URL) with the same UA + `Referer: https://en.wikipedia.org/`. Save to `/tmp/os-char-src/<char>.png`.

For characters where the article scrape misses (e.g. SpongeBob has ensemble shots not a solo portrait on en.wp), try `simple.wikipedia.org/wiki/<Char>_(character)` — Simple English uses Commons freely-licensed images instead of fair-use, and often has cleaner solo portraits.

The MediaWiki `pageimages` API (`?prop=pageimages&pithumbsize=600`) does NOT surface fair-use images — it returns `NONE` for most cartoon characters. Direct URL extraction from the article HTML is the working path.

## PIL circular avatar composite (closed + open variants)

The Remotion `Presenter` primitive alternates `spriteClosedUrl` / `spriteOpenUrl` on a 3-frame cadence to fake mouth movement. Both must be the SAME character at the SAME crop; the difference is a subtle vertical stretch on the open variant. 4-6% y-scale on the closed image reads as a talking wiggle without needing a real second frame.

```python
from PIL import Image, ImageDraw

SIZE = 512
PADDING = 40  # breathing room inside the circle

def tight_crop(im):
    if im.mode != "RGBA": im = im.convert("RGBA")
    bbox = im.getbbox()
    return im.crop(bbox) if bbox else im

def fit_into(im, target, padding):
    max_side = target - 2 * padding
    w, h = im.size
    scale = min(max_side / w, max_side / h)
    return im.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

def make_avatar(src_path, bg_rgb, mouth_open=False):
    src = tight_crop(Image.open(src_path))
    if mouth_open:
        w, h = src.size
        src = src.resize((int(w * 1.02), int(h * 1.06)), Image.LANCZOS)
    src = fit_into(src, SIZE, PADDING)

    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, SIZE, SIZE), fill=255)

    bg = Image.new("RGBA", (SIZE, SIZE), (*bg_rgb, 255))
    canvas.paste(bg, (0, 0), mask)

    cw, ch = src.size
    x = (SIZE - cw) // 2
    y = (SIZE - ch) // 2 + int(SIZE * 0.02)  # sink slightly so head touches top of circle

    tmp = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tmp.paste(src, (x, y), src)
    canvas.alpha_composite(Image.composite(tmp, Image.new("RGBA", (SIZE, SIZE), 0), mask))
    return canvas
```

Background colour must match `nameplate_color` on the DB row — the /cast card renders the avatar over a `background: nameplateColor` div and any mismatch reads as a visible ring around the character. Colours live in the seed loop struct literal in `dashboard.go`; changing one requires updating both places.

## Vision-verify before uploading

After compositing, spot-check one avatar visually — LSP/type checkers can't catch a character that composites off-centre, clips at the chin, or lands on the wrong background colour. Load the PNG into vision (`vision_analyze` in this environment, or eyeball in Preview) with a prompt like "Is this a clear circular avatar of X on solid <color> background with no clipping?" Fix at the PIL stage before touching MinIO — re-uploading over the same key doesn't invalidate browser HTTP cache, so a botched image sticks around until a hard-refresh.

## Voice/character coupling — enforced at THREE layers

Not in this file (see `references/web-app-nextjs.md` § Presenter+voice bundle coupling), but the reminder: after adding a character, verify all three coupling layers agree — DB CHECK constraint accepts the row, `characterVoiceAliases` contains the alias, wizard dispatches BOTH `SET_PRESENTER` + `SET_VOICE_ID`. Miss any and the character loads but the voice diverges silently under some code path.

## Workspace-scoped variants (custom presenters, custom voices)

Users upload their own presenter via `POST /api/v1/presenters` (multipart) — same table, different rowset. The pattern extends cleanly to any "seeded catalog + user-scoped variant" surface (custom voices, custom looks) so codify it once:

- **Same table, `workspace_id NOT NULL`.** `content.characters` already supports the union (`workspace_id IS NULL OR workspace_id = $1` in `ListPresenters`). No new table needed. The existing `presenter_needs_voice` CHECK constraint applies uniformly — user rows must still carry a `voice_id`.
- **Sprite key namespacing.** Store `sprite_key_closed = 'ws-<workspaceId>/<presenterId>-closed.png'` (NOT the full URL). `presenterView.spriteClosedUrl` composes `MEDIA_PUBLIC_URL + sprite_key`, so the URL builder is uniform for seeded (`presenters/<char>-closed.png`) and user (`presenters/ws-<workspaceId>/<presenterId>-closed.png`) rows. Uploading to the public bucket under a workspace-prefixed key is simpler than presigned private-bucket URLs and matches the seeded playback path — HTTP range requests, MinIO CORS, browser caching all Just Work.
- **Bundle-voice rejection at the API layer.** Custom presenters must NOT be allowed to point their `voiceId` at a character-bundle voice (`voice_seed_homer`, `voice_seed_rick`, ...) — that would let a user hijack Homer's likeness while calling it their own. Enforce with an explicit deny-list check in the POST handler against the same set that `characterVoiceAliases` covers. Return `400 bundle_voice_locked` with a plain-English message. Do NOT rely on the DB alone; the CHECK constraint accepts any `voice_id` string.
- **Rate-limit uploads per workspace.** Sprite uploads are cheap but a user script can hammer the endpoint; wire the `live_ratelimit` pattern (5/min/workspace is generous) — reject BEFORE parsing the multipart body so runaway clients don't pay the decode cost.
- **UI marks user-owned rows with `ownedByWorkspace: true` on the wire.** Set it in the presenter view when `pr.WorkspaceID != ""`. The `/cast` client keys the delete-affordance and edit-affordance off this flag; seeded rows (workspace_id NULL) MUST never expose delete/edit even to a workspace admin — they're global catalog.
- **Delete = soft-delete + prune sprites.** `deleted_at = NOW()` on the row leaves the sprites orphaned in MinIO. Ship a `mc rm` call in the delete handler (best-effort, log-on-fail — the delete succeeds either way) or a periodic sweeper. Sprites stay reachable for as long as the URL is guessable, which matters if the user uploaded something they later regret.
- **UI card frame reuse.** The "+ Add your own" card sits at the end of the presenter grid with the SAME dimensions and shell as a real presenter card — dashed border + Plus icon inside a dashed circle. Uses the same modal that would edit an existing custom presenter. Don't invent a separate "upload page"; the flow needs to feel like picking a card.
- **Preview-before-submit.** The upload form must show a thumbnail of the selected sprite (`URL.createObjectURL` + revoke in cleanup) — users misjudge crops constantly and a form that only reveals the result after submit produces botched avatars that then need to be deleted and re-uploaded. Cap file size client-side (5MB feels right for 512×512 PNGs; anything bigger is either uncropped source or malicious).
