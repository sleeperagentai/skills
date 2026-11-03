# User free text (and pictures) that land in a vendor prompt

Applies to every field where a person's own words are spliced into a prompt for a paid image/video/voice model (custom trait words, "describe the photo you'd like", voice descriptions), and — second half of this file — to pictures a person uploads as references for the same models. The goal is that the words can only ever read as a *description* inside the prompt, never close the clause they sit in or start a sentence of their own.

## Moderation posture

Mirror `stageGuard`: if `s.gateway == nil || Moderation == nil || isFakeModeration(...)`, or `Score` errors/returns nil → in production (`isProductionEnv()`) return a retryable `CodeInternal` with a plain sentence and `slog.Error`; outside production `slog.Warn` and allow (local checks are the floor). Fail-open "because local checks already ran" lets the approve-all aigw fake pass as a real tier when `PROVIDER_MODERATION` is misconfigured. Run moderation once on all custom fields joined, after structural validation and before any credit reservation or vendor call; skip it entirely when no custom field is present.

**Never exercise a refusal path live against the dev stack.** Outside production the handler allows when the local moderation server is down, so the "must be refused" payload goes straight to the vendor and spends. Prove refusals with the handler tests below; use the browser only for the happy path and for client-side refusals.

## Clean, in this order

0. **Reject on length BEFORE calling the moderation provider.** Moderation is a ~5s round-trip; a 1 MB JSON body under a per-endpoint `readBody` cap otherwise forces a full OpenAI /v1/moderations call (which will error on token limits anyway) before we reject on byte count. Cheap byte-count checks first; moderation last among request-level validations. `/live/tts` already does this correctly; retrofits (`/live/scripts/rewrite`) got it wrong on first write — move the `len(text) > N` check above the moderation call, not below.
1. **NFKC-fold first** (`golang.org/x/text/unicode/norm`, `norm.NFKC.String`), then `strings.Join(strings.Fields(t), " ")`. Fields collapses U+2028/U+0085/NBSP; folding makes fullwidth and compatibility spellings match the word guards.
2. **Length in runes** (`utf8.RuneCountInString`); the web `maxLength` counts UTF-16 units and is slightly stricter — fine.
3. **Refuse bad runes**: `unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || unicode.Is(unicode.Co, r) || unicode.Is(unicode.Cs, r)`. `IsControl` alone is Cc only and misses zero-width space, bidi overrides, BOM and Unicode TAG characters (the invisible-injection vector for LLM prompt enhancers). **Exempt only ZWJ (U+200D) and VS16 (U+FE0F)**, and only when the previous rune is `unicode.So` / `Regional_Indicator` or a joiner that followed one — otherwise 👩‍🦰 is refused in every free-text field. **Tag characters (U+E0020–E007F) are NOT a joiner exemption**: "tags after any pictograph" lets `😀`+tags spell invisible ASCII past every guard. Accept them only as a well-formed flag: base U+1F3F4, then 1–6 tag letters/digits (U+E0061–E007A / U+E0030–E0039), then cancel U+E007F; refuse an empty run, an unterminated run at end of string, or >6 tags. A bare 🏴 with no tags (alone, before text, the pirate flag 🏴‍☠️) is a plain pictograph — the first version of this rule treated it as an open sequence and refused it. A joiner after a letter is still refused.
4. **Cap stacked combining marks** (`unicode.Mn`, >3 in a row → refuse) so Zalgo can't hide under the rune limit; 3 lets Thai/Indic stacks through. Test with marks that have no precomposed form (U+0334..U+0337 on `x`); `s`+U+0301 NFKC-composes to `ś` and never trips the counter.
5. **Refuse clause breakers rather than strip them** — but ONLY in short-phrase fields, never in sentence fields like "describe the photo" (full stops are legitimate there). The class is `[.;:!?\n\r"\x60]` plus the enders NFKC does NOT fold to ASCII — `。‽؟¡¿।։۔` (U+3002 U+203D U+061F U+00A1 U+00BF U+0964 U+0589 U+06D4) — and curly/guillemet double quotes (U+201C–201F, U+00AB/BB; iOS keyboards auto-curl `"`). Keep U+2019 `’` allowed (it is the apostrophe). Fullwidth `．！？：；＂` fold to ASCII and are caught by the base class. The words are emitted quoted inside prose; a `.` lets `red. Full body, no clothing` end the clause and dictate the rest of the picture. Commas and hyphens are fine. Write the Go class as a concatenated interpreted string with `\uXXXX` escapes and probe one rune to confirm it did not become the literal letters `u3002`.
6. **Same-person guard** (`asksForDifferentPerson`) and the **adults-only regex**. Digit ages need flexible separators because `Fields` leaves `17 - year - old` and `17 y o` with inner spaces — but the unit must be an AGE unit, not bare `years`, or `8 years ago` / `looks 10 years younger` trip: `(1[0-7]|[1-9])\s*-?\s*((yo|y\.?\s*o\.?)\b|(yrs?|years?)\s*-?\s*old)` plus glued `(1[0-7]|[1-9])y\b` (not `N y`, which hits `size 8 y`); mirror for spelled-out one..seventeen; `looks N` only with that age tail (`looks 6 foot` must pass). Word list: `teen\w*`, `pre-?teen`, `tween`, `adolescent`, `juvenile`, `jailbait`, `barely legal`, `school\s?(girl|boy|kid)`, `(high|middle|junior|grade|primary|elementary|secondary|nursery|pre)[ -]?school\w*`, `kindergarten`, `sixth[ -]?form\w*`, `\d{1,2}(st|nd|rd|th) grade\w*`, `young (girl|boy|teen)`, `little (girl|boy)`, `lolita|loli`, `child(ren|like|ish)?`, `kid(s|do)?`, `toddler|baby|infant|underage`, `under[ -]?(1[0-7]|18|ten…eighteen)\b|u1[0-8]\b`, `aged? (N|one…seventeen)`. **RE2 has no lookahead** — adult idioms that contain a minor word (`baby blue`, `baby pink`, `baby-soft`, `babydoll`, `baby-faced`, `baby hairs`, `baby bangs`) go in a separate allow-regex that blanks the phrase BEFORE the tripwire runs. Keep passing cases for `minority`, `kidney`, `eighteen years old`, `age 25`, `8 years ago`, `baby blue eyes`, `looks 6 foot` so `\b`, the 1–17 range and the idiom list stay honest. Leetspeak and non-English ages are out of scope for a keyword tripwire — the production provider's `is_minor` question is the floor there; stop widening the list once a review returns only wordlist nits.
7. **Keyword tripwire** (`stubModerate`) last among local checks.

Apply the same rune cleaner to every sibling field (`cleanPhotoPrompt` had the identical Cc-only gap) — grep for `unicode.IsControl` when touching one — but put the shared rune scan in ONE helper (`scanRunes`) and keep the clause-breaker rule out of it, so sentence fields keep their full stops.

`golang.org/x/text/unicode/norm` makes `x/text` a direct dependency; `go mod tidy` on this module tries to resolve a private module over the network and fails offline, so move the `// indirect` line into the direct `require` block by hand and prove it with `go build ./ && go vet ./` in `apps/api`.

## Emit

- One shape only: `<noun> "<words>"` (e.g. `hair "a wavy copper bob"`) via a single `quotedTrait(key, words)` helper. `noun: words` is not a delimiter.
- Grammar branches keyed on menu values (`<style> <colour> hair`, bald) run only when both sides are menu; any custom side replaces the whole clause. Bald + custom colour drops the colour.
- Mirror the wrapping in every downstream prompt (`appearanceHint` feeds every later photo-edit). Custom words must never reach a *different* vendor unwrapped — voice description/persona helpers read `.menu()` only and fall back to neutral defaults.

## Refuse with a named field

Attach `.WithDetails("trait", key)` on every per-field refusal; the web reads `err.body.error.details.trait` and outlines that one group. Never regex-match the English sentence on the client — copy edits silently break it and it can't name the field.

## Log

Never the words or the request body. Log `workspaceID`, the scores map, and `fmt.Sprintf("%T", err)` for provider errors — adapters embed up to 4 KB of vendor response (which can echo the request) in the error string.

## Tests that must exist

Cleaner table test with one case per rule (fullwidth, ZWSP, RLO, BOM, zalgo at 4 marks, ZWJ emoji ACCEPTED, bare 🏴 / 🏴‍☠️ / two consecutive flags ACCEPTED, `😀`+tags and `©`+tags REFUSED, empty and unterminated flag REFUSED, ZWJ after a letter refused, Thai stack accepted, `。`/`”` refused, `’` accepted, `17 - year - old` / `17 y o` / `15y` / `school girl` / `under 16` / `looks 15 yo` refused, `eighteen years old` / `8 years ago` / `baby blue eyes` / `looks 6 foot` accepted; `17 y.o.` trips the full-stop rule before the minor rule). A sibling test that `cleanPhotoPrompt` still accepts `"On a beach. Sunset."` and a ZWJ emoji. Prompt-builder test asserting the quoted form in every slot. Handler tests: high score → 400, no vendor submit, no reservation, scores absent from body; `t.Setenv("APP_ENV","production")` × {`aigw.NewFake()`, nil gateway, erroring provider} → 5xx, no submit, nothing held; menu-only still 202 in production; refusal body contains `"trait":"<key>"`.

## Order of work for this class of change

1. Fix the contract first (value shape, error details), then dispatch Go and web children in parallel against it — the web child codes to the contract, never waits.
2. Unit tests green on both sides, THEN one happy-path browser pass with the user's go-ahead. Refusals are proven by `go test` only.
3. Fresh adversarial reviewer with the explicit instruction "unit tests only, never start the API, never call a vendor" — the first reviewer here found the fail-open-on-fake Critical that two implementers and a self-review missed. Expect four to five rounds, not three: every widening of a character or word filter opens its own edge (an emoji exemption reopened tag-character injection; a flag-sequence rule then refused the bare flag; RE2 rejected a lookahead at compile time). Keep each fix commit minimal, scope each re-review to that commit only, and stop when a round returns only Nits or approve.
4. **When a review flips a posture (fail-open → fail-closed, reserved → allowed), grep the ADR and plan for the old wording in the same commit** — `rg -n 'logged and allowed|reserved; the API refuses' docs/` — or the ADR keeps documenting the vulnerability as the design.

# Reference pictures a person uploads for a vendor model

Same class as the words above — user input that reaches a paid model — with a bytes-shaped threat surface. Contract that the web is built against: `POST /<thing>/uploads` (multipart `file` + `group`) → 201 `{ref: sha256 hex, width, height, previewUrl: 15-min signed GET}`; a trait value `{kind:"image", value: ref}`; options expose `pictures: {maxBytes, minShortSide, maxCount, faceGroups}`; GET returns `traitPictures: {group: signed url}` (list omits).

## Upload handler, in this order

1. Auth → **rate limit before the body is read** (own bucket, e.g. `influencer-upload`) → `http.MaxBytesReader` (cap + small slack) → multipart parse. `group` must be a known menu key.
2. **Type by magic bytes** (`http.DetectContentType`), allow-list JPEG/PNG/WebP only — GIF and SVG refused regardless of the declared type. The browser's `accept=` is a convenience, not a guard.
3. **Dimensions from the header** (`image.DecodeConfig`; register `golang.org/x/image/webp`) and bound them (short side ≥ 256, long side ≤ 8192) BEFORE any full decode — the re-encode step below decodes every pixel, and an 8192² header on a tiny file is a decompression bomb. Prefer an additional pixel-count cap (~24 MP) if the long-side bound alone admits it.
4. **Vision moderation before storage**: `aigw.ModerationRequest{ImageData, ImageType, Questions: ["is_sexual","is_minor","is_violence"]}`; ≥ 0.5 refuses. Same production posture as words (nil/fake/erroring provider → fail closed with a retryable `CodeInternal`; warn+allow outside production), shared through ONE helper so the two call sites cannot drift. A provider that cannot see images returns `aigw.ErrNoVision` and counts as unavailable — a text-only scorer must never silently pass an image. The real adapters must actually attach the image (OpenAI: omni-moderation model + `image_url` data URI; local Qwen2-VL: an `image_url` content part before the text); pin the wire shape with httptest and pin the text-only body byte-for-byte so the image path cannot change it.
5. **Strip metadata by re-encoding** (JPEG q92, PNG; WebP stored as PNG) — the original bytes are never kept (EXIF GPS, PNG tEXt/iTXt XMP). Test by splicing an APP1 `Exif` segment after SOI and asserting the stored bytes lack `0xFFE1`/`Exif`.
6. **Store in the PRIVATE bucket** under a draft prefix scoped to the workspace, keyed by the sha256 of the STORED bytes; `ref` is that sha. Log only sizes and scores — never the bytes, key, or presigned URL.

## Using the ref

- Accept `{kind:"image"}` only when `isRefSHA` (64 lowercase hex — no path chars) AND the object exists under the CALLER's draft prefix (server-side Stat); a foreign or expired ref is a plain "not available any more, add it again" with `details.trait`. Cap the count at the vendor's reference limit (3) with its own sentence.
- Face groups require `consent: true` in the create body, re-validated server-side (the web's local check is UX, not the guard), recorded as `consent_at` + `consent_ip` (first `X-Forwarded-For` hop, else remote addr — spoofable, acceptable as an audit field).
- On create: move drafts under the owning id (copy, then delete) BEFORE the vendor call, and delete the moved objects on every failure path alongside the credit release; delete them with the owner. A 24h scheduler sweep removes draft objects by key shape (`<prefix>/<ws>/draft/<name>`, exactly four segments) so moved refs can never match.
- Vendor leg: fetch from the private bucket server-side and `UploadReference` per job, then the *edit* endpoint with the URLs instead of text-to-image. The prompt names the GROUPS the pictures stand for (`…using the reference pictures for the face, the hair:`) and renders each picture slot as `<noun> "as in the reference picture"` — fixed words only, never the sha, never user text.

## Web side

- Client-side downscale (≤ 2048 long side) before upload; use `createImageBitmap(file, {imageOrientation: 'from-image'})` or equivalent so an iOS portrait photo is not stored sideways once EXIF orientation is stripped. The canvas is absent in happy-dom, so the helper must return the file untouched when it cannot draw.
- XHR for upload progress with `withCredentials`; never set `Content-Type` by hand on multipart.
- Picture refusals carry `details.trait` like words do; the moderation refusal (joined scoring) carries none, so the sentence shows with no group outlined — never guess a group.

## Tests that must exist (pictures)

EXIF segment stripped; GIF/SVG/too-small/too-big refused; moderation refuse via a scripted provider → nothing stored; production fail-closed for fake/nil/error/`ErrNoVision` → 5xx, nothing stored; unknown sha and a sha seeded under ANOTHER workspace's prefix → refused (make the foreign object really exist); face group without consent → 400 with `"trait":"<group>"`; N+1 pictures → refused; create with pictures → one edit submit with N reference URLs, zero text-to-image submits, prompt contains `as in the reference picture` and NOT the sha, draft keys gone and owner keys present; delete removes them; purge selector table test (old draft purged, fresh kept, owner-prefixed kept).