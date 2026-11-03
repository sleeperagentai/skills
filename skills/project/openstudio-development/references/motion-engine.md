# Scene-graph motion engine (`services/motion`, `schemas/motion`, `packages/motion-engine`)

Read ADR `docs/adr/0019-codegen-scenes.md` (supersedes 0011 and reverses 0018 Decision 1), the plan `docs/plans/2026-10-20-motion-codegen-scenes.md` (its Phase 1 table carries verified `path:line` anchors; there is no separate steps file), then the newest `docs/plans/*-handover.md` for status (see Handover documents below). The older `2026-10-18-motion-graphics-engine.md` plan describes the kit era; its M1–M5 pipeline survives, its M6–M8 tables were re-targeted.

- **Go side:** `services/motion`, plus a worker-core child workflow, owns the creative stages.
- **Node side:** `packages/motion-engine`, plus the motion-renderer `engine*` activities, owns rendering.
- **Hand-off:** the two sides exchange a `BuildManifest` by S3 key through Temporal activities, never over HTTP.

## Codegen series — the user's standing rules (ADR 0019)

These are decided. Plan from them; do not re-ask them.

- **There is no element kit, ever.** Every render designs its visual components from the story and the theme. A fixed vocabulary, a "fast lane" kit beside codegen, or a 100-kind parametric library are all rejected shapes. The kit (`src/elements/*`, `limits.json`, the audit, `services/motion/scenes`) is deleted; do not extend any section below that describes it.
- **The pipeline stays; only the scenes stage changed.** transcript word clock → storyboard → design → concept (Opus) → assets → scene code (Sonnet) → `engineSceneCheck` → vision critique, ≤3 rounds → manifest → one Remotion render. The beat stays the unit of timing, caching, critique and regeneration.
- **A scene is N bespoke components, no cap on N**, composed freely in the frame by the LLM — no layout enum, no slots. Overflow, safe zone, overlap and contrast are audited on the rendered DOM, not from precomputed tables.
- **Components are real visuals, not text blocks**: three/R3F, d3-geo over bundled TopoJSON, Lottie/Rive/Skia, shapes/paths/noise, effects, generated vectors and photos, clips, the presenter, kinetic type. Everything is a pure function of the frame (`interpolate`/`spring` on `wordToFrame`).
- **Assets are v1, not a later phase**: Recraft vectors (new adapter), Higgsfield photos and clips (existing adapter), a curated offline Lottie/Rive library (never LLM-generated Lottie), the project's existing cast sprite pair for the presenter (no new vendor). Maps never use `@remotion/maptiler` (API key + tiles over the network from the render Chrome). A scene never fetches; `staticFile` is allowed only through `props.assets`.
- **"Claude Design" means an Opus-class model via the API** doing brief + per-beat concept (+ `DesignSpec` on Max only); Sonnet writes code and critiques. Claude Design itself has no API — say it once and move on.
- **Spend cap USD 8 per build** (integer micro-USD, LLM + asset lines). A beat that fails 3 rounds gets a host-owned safety-net scene and the build report flags it; a build is never silently cheaper or silently blank.
- **The director provider is deleted and `engine` became the default in the same commit**; the `tsx` provider goes in the last phase of the series. Rive/Skia WASM must be proven to load offline from the bundle (request interception) or that capability is dropped with evidence — never shipped with network open.
- Generated scene modules reach Remotion through a **per-build round bundle** (scratch copy of `packages/motion-engine`, `gen/scenes/<beatId>.tsx` + `gen/registry.ts`, one gate + `tsc` + bundle per round, stills for every scene from that bundle). A stable host bundle that `import()`s esbuild output was rejected: duplicate React instances, no whole-project `tsc`, a runtime loader in the sandbox.

### Milestone / phase branches

- The FIRST commit on each branch grounds that phase against what actually landed: every task row in the plan's table gets verified `path:line` anchors and DRIFT-corrected names, in the plan itself — not a separate `<plan>-p<N>-steps.md`. Step-level detail lives in each task's dispatch brief and commit body.
  - **Ground-truth with a read-only subagent that returns findings through `output_schema` (`drift_found[]`, one string per `DRIFT: <plan says> → <path:line of what exists>`), not through a file it must write at the end.** A child asked to verify 20+ tasks against the monorepo AND write a long document spends its whole call budget on the research and writes nothing; findings in the schema survive that truncation, and the parent folds them into the plan table with a scripted replace (`assert s.count(old) == 1` per edit). Brief files go in the scratch dir (`~/.hermes/cache/scratch/<feature>/brief-*.md` — never under the repo root, where they are not git-ignored and show up in every `git status`); plan text with JSON braces goes via that file, never inline `context`.
  - **Per-task briefs carry a `Verified repo facts (do not re-explore)` block** — the parent greps the symbols, signatures and line numbers the task touches (a few cheap calls in the parent against 10–15 in the child) — then `Deliverable`, `Verify` (one shell block with expected tails), `Rules` (ownership list, the do-not-touch trees of concurrent siblings, one commit by explicit file list, no stash). Run up to three such tasks in parallel only on disjoint directory trees (e.g. `services/motion/spec` + `schemas/motion`, `services/ai-gateway`, `services/motion/llm`).
  - **When one task's change spans a producer and its consumers (a schema rewrite plus every package that decodes it), split it into part A (producer: sources, generator, its own package tests, fixtures — explicitly NO commit, consumer packages expected red) and part B (consumers + the single commit).** One child cannot carry both within its budget, and the one-commit-per-task rule still holds because only part B commits.
  - **When the plan carries an `Open decisions` table, resolve every row in ONE clarify call at the moment the user says build, before branching.** They shape the schema and deletion tasks, so guessing them forces a rip-up; rewrite the table as `Decisions` in the plan before the first commit.
  - Before coding, grep what the renderer actually reads (`grep -rhoE "design\.[a-zA-Z]+(\.[a-zA-Z0-9]+)?" src | sort | uniq -c`, plus which palette keys appear as `color:` vs `background:`/`fill`). Planned tables were written before the code existed.
  - Record a numbered "decisions at start" list under the milestone in the plan. Drop planned schema fields that nothing draws or nothing supplies, because a schema lists only what the running stack renders. Move inputs that only a stage consumes (brand overrides) out of the render contract.
  - **Any decision that changes what the user or a viewer sees (what a toggle does, what the layout looks like) is the user's call.** Ask before building on it, with a recommendation. Don't decide it in the decisions list and announce it afterwards. Internal engineering choices (table layout, hashing, test strategy) stay yours.
- **Plan stays as-built:** when implementation changes a task's design, rewrite that task's section in the plan in the same commit. The next milestone is planned from the plan file, not from chat.

## Schema-as-contract: edit → regenerate → check

1. Edit only these source files:
   - `schemas/motion/src/*.schema.json`: a restricted dialect; the rules are in `schemas/motion/README.md`.
   - `schemas/motion/tables/*.json`: layouts, intents, fonts, icons.
   - fixtures under `schemas/motion/fixtures/{valid,invalid}/<Type>/`.
2. Regenerate with `bash scripts/motion/schemagen.sh` (it wraps `go run ./cmd/schemagen` in `services/motion`). This writes:
   - Go structs `services/motion/spec/spec_gen.go` and the embedded copies under `spec/embed/`;
   - Zod 4 `packages/motion-engine/src/spec/generated/*.gen.ts`;
   - the flat schema `schemas/motion/gen/motion.schema.json`;
   - the per-call LLM projections `schemas/motion/gen/llm/{storyboard,scene.<intent>}.json`.
3. Run `schemagen.sh -check`. It exits non-zero on drift, and CI runs it. Never hand-edit a generated file.
   - **Before concluding YOUR edit caused drift, verify against `main`.** `git stash && git checkout main && bash scripts/motion/schemagen.sh -check` — generated files on `main` can be stale (e.g. a hash function narrowed in an earlier squash merge without regenerating the stored hash), and your branch inherits it. If `-check` is already red on `main`, fix the stored value verbatim as a ride-along in your current commit; do not debug your own diff for it.
4. Run `go test ./...` in `services/motion`:
   - the fixture tests check that valid fixtures pass, that each invalid one fails at its expected path, and that Go round-trips valid fixtures unchanged;
   - the schemagen tests check the LLM projections against Anthropic's strict-schema budgets (see `anthropic-adapter-quirks.md`).

Pitfalls:
- **Decode schema sources with an ordered token walker, not `map[string]any`.** Generated struct field order and `$defs` order must follow the source, and map decoding loses key order. The result is generated output that churns and fails `-check` for no reason.
- **Validation is `services/motion/schemacheck`, a small in-house validator for the restricted dialect. It is not a third-party JSON Schema library.** Adding a dialect feature means updating the generator, schemacheck and the README together.
- **schemacheck must fail closed and agree with Go decoding and with Zod:**
  - Compile from an allowlist of the keywords it implements and error on anything else, because a skipped keyword is silently unenforced. Reject `$ref` cycles at compile time.
  - Parse each number literal once as float64, and report an out-of-range exponent as an issue. `big.Rat.SetString` returns nil on a huge exponent, which panics, and on `1e999999` it builds a million-digit integer, a CPU denial of service.
  - `type: integer` requires the integer lexical form. Go's `encoding/json` rejects `1.0` and `1e2` for int64 fields and gives no JSON pointer, so the repair loop cannot act on the error.
  - Require `io.EOF` after the value. `dec.More()` returns false at a stray `]` or `}`, so trailing garbage would pass.
  - Reject duplicate object keys, in documents and in schemas. Go struct decoding applies every occurrence of a key, so an earlier invalid one still fails, while a map keeps only the last. Validating just one value accepts documents that `spec.Decode` then rejects with no pointer.
  - Compile also refuses an empty `#/$defs/` ref, duplicate `required` entries, `minimum > maximum` and unanchored patterns.
  - The fuzz contract is "accepted ⇒ decodes into the generated struct". It lives in `spec/fuzz_test.go` (`FuzzValidateMatchesDecode`, with a map from type name to constructor). Fuzzing against `json.Unmarshal(doc, &any)` cannot see lexical-integer or duplicate-key mismatches.
- **The generator rejects any construct the emitters can't reproduce identically in Go and Zod:**
  - patterns outside a portable ASCII subset: POSIX classes, `(?…)`, letter escapes, unescaped `.`, negated classes `[^…]` (Go matches a rune, JS a UTF-16 unit, so they disagree on emoji), and top-level `|` (`^a|b$` anchors each alternative at only one end);
  - `enum` combined with other constraints, because Zod emits `z.enum` and drops them;
  - standalone `null` defs and inline unions, which make the emitters panic;
  - property names that collide as Go fields.

  Table numbers are canonicalised before hashing, so a hash depends on values, not on spelling. The rejection tests live in `cmd/schemagen/dialect_test.go`.
- **For each generator rule, add a test that feeds a schema breaking that rule and asserts it is rejected.** An `err = parseX(...)` inside a `switch` that is overwritten before it is checked silently accepts bad schemas. Only a rejection test catches that.
- **Adding a required field to a type that a committed generated table must satisfy (e.g. `maxWordChars` on `LimitsTable`) deadlocks regeneration.** schemagen validates the old table against the new schema and fails, while the table generator needs the regenerated types. Move the table out of the repo, run schemagen, regenerate the table, then run schemagen again so its embedded copy is current. Update that type's valid/invalid schema fixtures in the same commit.
- **Renaming or removing a schema field:**
  - Transform every fixture holding the object with a script. `json.dump(indent=2, ensure_ascii=False)` plus a trailing newline keeps the diff to the changed lines.
  - Keep at least 2 valid and 3 invalid fixtures per type; the fixture tests enforce those counts. Replace an invalid fixture that tested the removed field with one asserting the field is now rejected.
  - Grep Go and TS tests for the field. Delete helpers that become unused, because `go vet` fails on an unused closure.
  - Rerun `make-fixture-manifests.sh`: fixture manifests stamp the schema and font hashes.
- **You can check generated Zod before `packages/motion-engine` has a `package.json`:**
  1. Make a scratch dir and symlink `node_modules/zod` to `<repo>/node_modules/.pnpm/zod@<v>/node_modules/zod`.
  2. Add a `package.json` containing `{"type":"module"}`.
  3. Run `tsc --noEmit --strict --target es2022 --module esnext --moduleResolution bundler --allowImportingTsExtensions --skipLibCheck *.gen.ts`.
  4. Run a `node --experimental-strip-types` script that parses every fixture through the generated schemas.

## Transcript assembly (`services/motion/transcript`)

`Assemble(turns, offsetsMs, audioKey, totalMs)` produces one absolute `spec.Transcript`. Each word's text is the SCRIPT token, and its timing comes from the ASR.

- **Triggers are word indices, and "numbers come from the beat's words".** So the transcript must hold what the user wrote (`$3.5M`), not what Whisper printed.
- **Turn offsets come from `tts.StitchResult.SegmentOffsetsMs`, never from summed durations.** The stitcher inserts pauses between turns.
- **Align characters, not words, and don't expand numbers to words.** whisper.cpp breaks every word-level heuristic:
  - it splits sub-words (`"C"` + `"aching"`);
  - it mis-hears (`"page 99"` for `p99`);
  - it splits numbers (`"20"` + `"26"`);
  - it spells units out (`"million"`, `"times"`).

  The method, in order:
  1. Build alignment keys from letters and digits, and expand spoken symbols to their word on BOTH sides (`%`→`percent`, `$`→`dollar`, `&`→`and`, `+`→`plus`, `@`→`at`, `€`/`£`→`euro`/`pound`; `#` stays literal because it is ambiguous). whisper.cpp prints the same speech as `87` + `%` in one sentence and `40` + `percent` in the next, so keeping the symbol as a symbol leaves one form unaligned. Spread each ASR token's time evenly over its keys.
  2. Align script characters to ASR characters with an affine-gap (Gotoh) edit alignment.
  3. A token counts as aligned when at least half its characters match.
  4. An aligned token takes the span of its ASR characters, extended through unclaimed characters up to the next token, but only when that next token is aligned too.
  5. Unaligned tokens are interpolated between their neighbours by character count.
- **Use affine gaps, not unit gaps.** With unit gaps, a skipped word lends its letters to its neighbours.
- **Drop script tokens that have no alignable character (`—`, `…`).** They cannot be timed, and they would show up as a caption word of their own.
- **Make the output times monotonic, non-zero-length and clamped to the narration as the last step.** ASR output contains reversed and overlapping pairs.
- **Keep a committed randomized property test.** It runs thousands of cases (unicode, punctuation-only tokens, reversed, overlapping or out-of-range ASR, empty ASR, negative durations) and asserts no panic, every invariant, and the Transcript schema. Example tests miss DP traceback bugs: a swapped argument order in the alignment's row-0 initialisation crashed on about 40% of random inputs, including an ordinary leading filler word.
- **Size the alignment cell cap from realistic dense prose: 600 words × about 10 key characters on each side.** The perf test must use such prose and assert it exceeds the previous cap. Short synthetic tokens hide a cap that rejects real 3-minute turns.
- **Stop span extension at a pause, i.e. a gap of more than 300 ms between unclaimed ASR tokens.** Otherwise whisper's trailing hallucinations stretch the last word across silence. Contiguous runs (`$3.5` + `million`) still extend.
- **`conf 0` is reserved for interpolated words, so floor aligned conf at 0.01.**
- **Reject turn offsets that overlap the previous turn**, allowing a small stitch slack. Compare without adding (`off > total || dur > total-off`) so huge values cannot overflow into a pass.

### Whisper fixture recipe (no vendor spend)

1. `say -v Samantha -o t.aiff '<number-heavy sentence>'`, then use ffmpeg to make a 16 kHz mono WAV.
2. `whisper-cli -m ~/.cache/openstudio/models/ggml-base.en.bin -f t.wav --output-json-full --split-on-word -l en -np -of full`.
3. Clean the tokens:
   - trim whitespace;
   - drop `[_…_]` and `<|…|>` tokens, and zero-length tokens;
   - KEEP punctuation-only tokens (`%`, `$`), because the assembler aligns them.

   `services/ai-gateway/localwhisper.cleanToken` drops punctuation-only tokens, so never describe the fixture as localwhisper-cleaned. Keep a test that assembles the localwhisper-cleaned input as well: symbol words may be interpolated, but they must stay close to their full-ASR times.
4. Commit the result as `testdata/*.json` together with the script and the measured duration.

**Use the token-level times as ground truth.** Segment output (`-ml 1`) is coarser and gives wrong expected values. Assert exact spans for tricky tokens, and check that `conf` reflects how closely the written text matches what was heard.

### Full fixture set (narration → transcript → manifests)

The committed fixture lives in `fixtures/motion/` and is regenerated by two scripts. Both outputs are committed, so they only run when the script or the beats change.

1. `scripts/motion/make-fixture-narration.sh`:
   - `say -v Samantha -r 175 -f fixture-script.txt` (fixed voice AND rate, so timings repeat);
   - ffmpeg to MP3 with `-map_metadata -1 -fflags +bitexact -flags:a +bitexact`, so re-running gives identical bytes (check with `md5` twice);
   - `go run ./cmd/fixture-transcript` runs whisper-cli with localwhisper's flags, keeps punctuation tokens, and feeds the assembler. Read its report: interpolated words with `conf 0` show where alignment still fails.
   - After any assembler change, rerun the script and compare `md5` before and after. The transcript must come out byte-identical unless the change is meant to move timings.
2. `scripts/motion/make-fixture-manifests.sh` (`-check` for drift): manifests are built in Go (`cmd/fixture-manifest`), not hand-written JSON.
   - Reference every trigger as `w.at(i, "text")`, which panics if word `i` is not `text`. A regenerated transcript then fails loudly instead of moving triggers onto the wrong words.
   - Write through `spec.MarshalManifest`, so the fixture passes schema and semantic checks.
   - Its test asserts the fixtures are current, the engine hashes match, and every element kind, layout and intent appears at both aspects. Extend that list when the vocabulary grows.

## Stage runner (`services/motion/stage`)

A stage is a pure `Run(ctx, *RunContext, I) (O, error)` with a `Name` and a `Version`. `Exec` hashes the stage name, version and canonical input, then reads or writes `motion/{ws}/{project}/artifacts/{stage}/{hash}.json` in the private bucket.

- **Canonical JSON** means:
  - keys sorted at every level;
  - `SetEscapeHTML(false)`;
  - decoding with `UseNumber`;
  - integer literals written verbatim;
  - fraction and exponent literals normalised (`2.0` → `2`, `0.50` → `0.5`), only when the conversion is exact;
  - invalid UTF-8 rejected, because it collides with U+FFFD.

  Never round-trip integers through float64: distinct int64s above 2^53 collapse to one key, and `Exec` returns another input's artifact. Without these rules, equal inputs hash differently or different inputs hash the same.
- **Bump `Version` whenever `Run`'s behaviour changes.** Otherwise stale cached outputs are served.
- **A stage whose `Salt` depends on live tables uses `init()` to populate it, and `Run` must NOT reference the exported `Stage` var.** Go reports an initialization cycle when `Stage` references `run` (its own `Run`) and `run` reads `Stage.Name` (or any other `Stage.*` field) — the compiler analyses the var's whole transitive graph. Use a string literal for the stage name in log attrs (`"stage", "director"`), not `Stage.Name`. The design-time salt init pattern is `init() { Stage.Salt = salt(spec.LoadTables()) }`, which is fine because `init` writes a FIELD after the var is built.
- **Keep build ids out of the key.** That way, two builds with identical inputs share artifacts.
- **Check every precondition before calling `Run`:** a validator is registered and knows the output TYPE, `Run` is non-nil, the input is valid, and the context is not cancelled. `Run` may be a paid LLM call; a typo'd output type would otherwise pay on every retry and cache nothing.
- **Validate the output before `Put`.** The store must never hold an invalid artifact.
- **On a cache hit, re-canonicalise the decoded value and require it to be byte-equal to the stored body.** Anything else is a miss: the stage re-runs and the body is overwritten. That covers bodies that won't decode or validate, `null`, `{}` and trailing bytes; none of them cause an error. Decoding only the first JSON value used to serve corrupt bodies as hits.
- **On a miss, return the value re-decoded from the stored bytes.** Callers must never see in-memory-only values that a cache hit would not reproduce.
- **Artifact writes are first-writer-wins (`ArtifactStore.PutIfAbsent`).** Keys exclude the build id, so concurrent builds of one input both miss and both run a stage that is not deterministic. With a plain overwrite, the first caller returns bytes the key no longer holds.
  - S3 uses `If-None-Match: *` (minio-go `opts.SetMatchETagExcept("*")`). A 412 `PreconditionFailed` means another writer won.
  - The loser re-reads the key and returns the stored artifact.
  - Plain `Put` is used only to replace an unreadable artifact.
  - Test with two goroutines released together after both have passed their `Get`.

## LLM providers (`services/motion/llm`)

- Tests run without the network: `httptest` servers plus sha256-keyed replay files in `llm/testdata/recorded/`.
- **An `httptest` handler that blocks (to test a timeout or cancel) must also `select` on a test-owned `release` channel, closed by a `defer` registered AFTER `defer srv.Close()`.** `Close` waits for in-flight handlers, and `r.Context()` is not reliably cancelled when the client gives up, so a handler that waits only on `<-r.Context().Done()` hangs the whole package.
- **Read the response body fully, with a size bound, before decoding it.** A read failure becomes `ctx.Err()` or a retryable transport error, never `ErrInvalidJSON`. Otherwise a mid-body timeout turns into a permanent failure and the billed usage is lost.
- **The recording key hashes every request field that can change the output:**
  - model;
  - system prompt and messages;
  - the schema, canonicalised with keys sorted;
  - max tokens after defaulting;
  - temperature.

  Then a recording never replays for a different model or token budget.
- **`Resolve` never falls back silently.**
  - When Anthropic config (a key or a model) is set, it returns the constructor's error.
  - Outside tests it uses a local server only when `LLAMACPP_URL` is set (or `MOTION_LLM=local`). Otherwise anything answering on the default localhost:8080 becomes a provider that bills zero credits.
  - The recorded provider runs only when selected explicitly, or under tests. Tests are detected with `testing.Testing()` behind an `underTest` seam, so a test can simulate production.
- **Retry classification:**
  - `context.DeadlineExceeded`, bare or wrapped, is retryable: a per-call deadline means a stalled vendor. `context.Canceled` is not.
  - Success needs a finished turn on every provider: Anthropic `end_turn`/`stop_sequence`, OpenAI-compatible `finish_reason: "stop"`.
  - Length or context-window stops map to `ErrTruncated`, and content-filter stops and refusals to `ErrRefusal`. Any other stop reason is a non-retryable `stop_reason` error.
- **Price by an allowlist of exact model ids, not by prefix.** A `claude-opus` prefix priced older Opus models at a third of their real cost.
- **Refuse cross-host redirects, and redact the API key in `String`/`LogValue`.** Go's HTTP client forwards custom headers such as `x-api-key` on redirect; it strips only Authorization and Cookie.

## Storyboard (`services/motion/storyboard`)

- **Measure beat durations as DISPLAYED, never from word start/end:** beat 0 from 0 ms, each beat to the next beat's first-word `StartMs`, the last to `durationMs`. Silence before word 0 and between sentences belongs to a beat.
- **Validator problems go back to the LLM verbatim:** each says what is wrong, what is wanted and the numbers. Round shown seconds towards the side that keeps the message true (1199 ms reads 1.1 s, 8001 ms reads 8.1 s), or the model is told "1.2 s, want at least 1.2 s".
- **Measure contiguity against the highest in-range last word so far, not the previous beat's.** Otherwise one nested or overrunning beat also blames its innocent neighbour.
- **A beat that is a whole speaker turn skips the 1.2 s minimum (never the 8 s maximum).** A short interjection ("Exactly.") has no same-speaker neighbour to merge with, so without the exception the fallback for a dialogue is invalid and the stage can never accept any storyboard for it.
- **Few-shot examples must be the prompt's own rendering:** test that each example's `words` equals `wordsBlock(transcript)` for a transcript built in the test (fixture or synthetic), and that its beats pass `Validate`. Hand-typed word lines drift from the real format.
- **Model stages return provider errors instead of falling back.** `Exec` stores nothing when `Run` errors, so Temporal retries the activity; a fallback stored on a transient 529 would be cached forever. Only rejected replies (decode or Validate problems) count towards the fallback.
- **A fallback property test must cap narration time, not just word count.** 60 beats × 8 s covers at most 8 minutes, and 600 words at 0.1–1.2 s + 0–0.8 s gaps average about 10 minutes, so "always valid for 1–600 words" is impossible there. The test caps at 4 minutes (600 words at 150 wpm), adds dense cases so 600 words still fit, and asserts its own coverage (max words, beats at the cap, two-speaker share).

## Manifest semantic checks (`services/motion/spec/check.go`)

The schema covers shape. Any rule that relates two fields belongs in `CheckManifest`, for example:
- canvas size matches the aspect, and duration matches the transcript;
- beats cover the words exactly;
- each slot exists in its layout and is used once;
- the element kind suits the beat's intent;
- word references stay inside their beat;
- diagram edges point to real nodes, and chart series match the categories.

- **Report every issue, each with its JSON pointer (`*CheckError{Issues}`), not just the first.** The LLM repair loop and the person writing fixtures both need the full list in one pass.
- **Consume `CheckManifest` errors programmatically via `errors.As(err, *spec.CheckError)` + range `ce.Issues`.** String-splitting the error message on `": "` and `"; "` is fragile — any `Problem.Msg` containing those separators (quoted identifiers, URLs, nested paths) mis-splits and the resulting bogus path/msg pair gets filtered out, silently dropping real validation findings. The `Issues` slice is already exposed on the error type; a wrapping stage filters by path prefix (e.g. `strings.CutPrefix(is.Path, "/beats/0/scene")`) rather than reparsing the aggregated message.
- **Manifests enter and leave Go only through `spec.DecodeManifest` / `spec.MarshalManifest`.** Both run the schema and the semantic checks, so an unchecked manifest can't reach the renderer.
- **Each rule gets a mutation test:** take a valid fixture, break one field, and assert the expected pointer and message.
- **A formula used on both sides (`DurationInFrames` = ceil(ms·30/1000), at least 1) is tested on both sides against the same case table.** Go and TS drifting apart by one frame breaks the render.
  - The strongest form runs the real TS function from a Go test (see `TestZeroFrameBeatsMatchTS` in `spec/check_review_test.go`):
    1. The Go test builds the cases and records Go's verdict for each.
    2. It writes the cases as JSON to `t.TempDir()`, along with a throwaway `probe.ts` that imports the real function by absolute path.
    3. It runs `pnpm exec tsx probe.ts cases.json` in `packages/motion-engine` with `NODE_ENV=development`, and compares the verdicts.
    4. It calls `t.Skip` when that package's `node_modules` is absent.
- **Anything the composition throws on must be rejected before Chrome, on both sides.** A throw inside Chrome is a plain Error, which gets retried; a parse failure is a non-retryable `EngineManifestInvalid`.
  - Go `CheckManifest` mirrors the renderer's formulas: zero-frame beats as `beatFrames` computes them, safe zones that leave a content area, and every sub-event trigger at or after its element's enter.
  - TS `parseManifest` runs the composition's own pure helpers after Zod: `beatFrames`, trigger→frame, slot lookup, wordRange bounds, and canvas vs aspect.
- **Asset keys are tied to the workspace.** `audioKey` (and every asset key added later) must start with `motion/<workspaceId>/` (engine objects) or `workspaces/<workspaceId>/` (workspace assets, as built by `packages/storage` `AssetKey`). They must contain no empty, `.` or `..` segments, because the renderer presigns them in the private bucket.
- **Derive dependent values from the source of truth, not from the field being checked.** For example, beat end frames use `DurationInFrames(transcript.durationMs)`, not `m.DurationInFrames`. That way one wrong field produces one issue rather than a cascade, and the exact-count test in `TestCheckErrorListsEverything` stays meaningful.
- **Gate dependent rules on their prerequisites, so each problem is reported once.** `TestCheckDoesNotCascade` asserts the issue counts.
  - Run the frame-span and trigger-timing checks only when the beats tile the words. TS `parseManifest` skips `beatFrames` the same way.
  - Skip a trigger's timing check when the trigger is outside its beat; that is already an issue of its own.
  - Skip "before the element enters" when the enter word itself is outside the beat.

## Composition (`packages/motion-engine`)

- **Remotion stitches the beats; Go stitches the audio.** `MotionBuild` mounts every beat in a `<Sequence>` on one timeline over one `<Audio>` and the captions, and `engineRender` renders it in a single `renderMedia` call (its parallel chunks are Remotion's own concurrency, not a stitch step). Narration audio is concatenated by Go `tts.Stitch` before the build. Never ffmpeg-concat per-beat MP4s — that was the old `tsx` provider's shape, and it loses cross-beat transitions and continuous captions. The codegen stage changes only what is mounted inside each `<Sequence>`; generated modules reach the bundle through the per-build round bundle (see Codegen series above).
- **Beat spans:** the first beat starts at frame 0, so the intro is never blank. Each later beat starts at its first word's frame and ends where the next one starts, so spans cover `[0, durationInFrames)` exactly. Throw when a beat would get zero frames instead of silently dropping it.
- **Everything animated is a pure function of the frame**, including background drift (a sine of `frame / fps`). Never use wall-clock time or `Math.random`, because the frame-hash determinism test depends on it.
- **Slot rects** are the canvas, minus the design's safe-zone insets, minus the caption band when captions are on, then scaled by the slot's fractions. The user's rule: with captions off, the band goes back to the content. Do not reserve it permanently.
  - A taller slot can pick a bigger font and wrap differently, so a budget measured with captions on does not cover a captions-off render. Key `limits.json` by typeset AND caption mode, one entry set per mode; `Limits.For(design)` picks the mode. Do not keep "the tighter of both modes" per field: count variants differ by mode (chart categories, code lines), and the tighter-of rule left 1,480 drawn fields with no budget, which failed the audit. The audit and the overflow test cover both modes.
  - Test that every fixture slot rect falls inside the canvas, and that turning captions off only grows the height.
- **Visual check before committing composition work:**
  1. Render stills with `pnpm exec remotion still src/entry.ts MotionBuild out.png --frame=N`.
  2. For a different manifest, pass `--props=<path to a JSON file>`. Inline JSON in a shell argument breaks easily.
  3. Combine the stills into one image with ffmpeg (`hstack`) and look at it with vision, checking for the right beat, overflow and overlap.
- **Before committing:** run `pnpm exec biome check --write packages/motion-engine`, then `pnpm -s typecheck` and `pnpm -s test` in the package.
- **After adding a workspace package, check the lockfile:**
  - `grep -n "^  packages/<name>:" pnpm-lock.yaml` must find the importer. Anchor the pattern; an unanchored or miscounted grep has reported a present importer as missing.
  - Read every foreign hunk in `git diff origin/main...HEAD -- pnpm-lock.yaml`. The known-benign one: pnpm 11 re-resolution drops the optional `(postcss@8.5.28)` peer suffix from `@remotion/bundler` / `@remotion/cli` / `@remotion/studio-server` / webpack / css-loader keys. postcss itself stays resolved under css-loader, so nothing changes at runtime.
  - Prove it the way CI does, in a scratch worktree OUTSIDE the repo: `git worktree add --detach <abs scratch path> HEAD`, then `pnpm install --frozen-lockfile --offline` (must exit 0 and leave `git status` clean), then `pnpm exec remotion bundle src/index.ts --out-dir <scratch>` in `packages/compositions`. Finish with `git worktree remove --force <path> && git worktree prune`.
  - Always give `git worktree add` an absolute path. A relative path after a failed `cd` creates the worktree inside the repo.

## Package layout (`packages/motion-engine`)

- **Keep `entry.ts` (calls `registerRoot`, used by the Remotion bundle and studio) separate from `index.ts` (library exports).** Importing a module that calls `registerRoot` from Node code registers a root as a side effect.
- **Node consumers import `@openstudio/motion-engine/node`, never the package root.** That subpath exports bundling, rendering, the measuring helpers and `parseManifest`. It keeps React components out of the worker's module graph. Composition ids live in `src/ids.ts` so Node code can name compositions without importing `.tsx`.
- **Use extensionless relative imports (`./time`, not `./time.ts`).** Workspace packages are consumed as TS source, so the consumer's tsconfig type-checks them, and the worker's tsconfig does not allow `.ts` import suffixes.
- **Within one directory, module basenames must differ by more than case.** For example, `Measure.tsx` next to `measure.ts`: with extensionless imports they resolve ambiguously on case-insensitive macOS and differently on Linux CI. Use distinct names (`MeasureComposition.tsx`, `textMeasure.ts`).
- **Bundle cache key:** `getBundle` keys on a content hash of every bundle input. That includes the resolved versions of remotion, @remotion/*, react, react-dom and zod, plus the Node major version, because ranges like `^18.3.1` can move with no source change. It writes to a temp dir, renames it into place and marks it with `.complete`.
- **Bundle pruning** is best-effort and must never break a live worker:
  - rank bundles by a `.last-used` mark that every hit touches; the build mtime is never refreshed, so ranking by it deletes a long-running worker's bundle;
  - never delete a bundle used in the last 24 h;
  - remove `.tmp-<pid>-*` dirs whose pid is dead or that are more than an hour old.

  Don't skip pruning: each content change leaves a full webpack bundle (about 50 MB) on disk.
- **When installing a bundle, treat a dir without `.complete` as debris.** Nothing else ever writes one; a crash during prune's `rm` leaves it behind. `installBundle` removes it and retries the rename once. Otherwise `rename` fails with `ENOTEMPTY` on every call, and the hash is wedged forever, rerunning webpack each time.
- **Measure text with the browser's own layout, never with a JS re-implementation of line wrapping.**
  - `measureItems` lays each text out in a hidden block `maxWidthPx` wide, styled with `TEXT_LAYOUT_CSS` (pre-line; overflow-wrap and word-break normal), inside the render Chrome with the bundled fonts.
  - Line count is block height ÷ line height. Width is the widest client rect of the text node, from `Range.getClientRects`.
  - `TEXT_LAYOUT_CSS` sets `hyphens: none`. Under `manual`, Chrome breaks at a soft hyphen (U+00AD) and draws a hyphen that no DOM rect reports, neither the Range's nor a wrapping span's. Measured widths would then undercount rendered ones.
  - Every CSS property that changes line breaks or glyph widths must be a `MeasureItem` field, and must be applied by the one style helper that the measurer and the element components share. The measure box forces every other property to `normal`. Tracking (`letterSpacingEm`) and uppercase are already fields; add any new such property the same way, on the Zod, Go wire and golden-file sides together.
  - Every text element spreads the same `TEXT_LAYOUT_CSS`.
  - A `/\s+/` splitter broke lines at NBSP and missed the breaks after hyphens, at ZWSP and between CJK characters. Font metrics computed in Node would disagree with the browser too.
- **Test text measurement in real Chrome with JetBrains Mono** (every glyph is 0.6 em wide), so widths are exact. A fallback face gives the same widths for every family.

## Element vocabulary (Milestone 2) — DELETED by the codegen series

Kept only for reading kit-era code during the deletion and for the budget/measurement techniques that the DOM audit reuses. Do not add kinds, fields or budgets.

- **Each kind has a pure `<kind>.layout.ts` (`KindLayout`): copy-independent `fields(ctx)` plus `texts(body)`.** The component draws every string through `fieldSpec(layout, ctx, field)` and `textCss(textStyle(design, role, fontPx))`. The limits generator, the overflow tests and the real-Chrome fixture check (`test/elements.chrome.spec.ts`) all read the one `KIND_LAYOUTS` registry, so a budget can never disagree with what is drawn. A string drawn outside `texts()` escapes every budget.
- **When a field's width depends on structure (category count, node count, line count), declare one field per count** (`categories[n=3]`, `line[n=2]`), never a fixed fraction of the maximum. A fixed `w/8` label overflowed with 2 categories.
- **Budget height as well as width for every field, and draw each text run in exactly the box its field declares.**
  - Size from the type scale, capped by the rect height (lines × line height + icon + gaps must fit the cell) and by width where words cannot wrap (short labels about 10 chars, code 52 columns). A cap on one axis only lets labels spill into neighbouring elements and the caption band.
  - Draw every string through the shared `FieldText` component, which sets the field's width and a line clamp. A flex child sized by its siblings (legend entries, edge labels between nodes) ends up narrower than the width that was measured, so text within budget still overflows.
  - When a field cannot reach `MIN_TEXT_PX` (16) in a slot, the layout omits the field instead of shrinking it, and the kind is unusable there. limits.json has no entry, TS `parseManifest` rejects the element, and Go `Lookup` returns `ErrUnusable`. A layout must never emit a sub-minimum or negative `fontPx`: the limits run then crashes in `FontFaceSet.check`.
- **Run the render-contract audit before a milestone review and after every layout change.**
  - The test is `test/audit.chrome.spec.ts`. For debugging, `NODE_ENV=development pnpm exec tsx scripts/audit.ts [Kind]` writes grouped issues, and `scripts/audit-still.ts <layout> <slot> <aspect> '<body json>' out.png` renders one case for a vision check.
  - It renders every kind × layout slot × aspect in real Chrome, at worst-case budget text and maximum array sizes. It fails when text leaves the slot, runs to more lines than `maxLines`, or has a word wider than its field. Components tag each text run with `data-field`, so every issue maps to a field.
  - Layout unit tests, the overflow test and the fixture check all passed while the audit found thousands of overflows, because they measure fields in isolation rather than the drawn component.
  - Loop: group the issues by kind × type with a script, fix the largest group, regenerate limits, then audit again.
- **Number formatting:**
  - Pin `en-US`, and round to the shown precision before formatting; a raw `-0.4` at 0 decimals prints `-0`.
  - Compact notation keeps at least one fraction digit above 1000 (`1.5M`, not `2M`).
  - Budget every string a tween can show (the endpoints and each magnitude in between), not just the endpoints.
- **Short slots trade a second line for size** (BigText: 2 lines only if the 2-line size is at least 75% of the 1-line size). Otherwise a 16:9 header gets tiny type.
- **Audit debugging pitfalls:**
  - Measure the drawn line count with `offsetHeight` (layout), not `getBoundingClientRect` (axis-aligned). A rotated Stamp's bounding box is taller than its lines, and reported false "3 lines > 2".
  - A still script that disables captions makes slots BIGGER than the measured ones. Keep captions on in every debug render, or the picture won't match the audit.
  - Put one-off debug scripts under `scripts/` (scratch `.ts` outside the package fails to transform), and delete them before committing. Useful drivers: `audit-case.ts <id prefix>` (measured vs drawn), `audit-body.ts <layout> <slot> <aspect> '<body>'`, `caption-still.ts <frames>`.
- **Wall-clock bounds in Go tests must scale under `-race`** (a `raceSlowdown` constant from `//go:build race` / `!race` test files). A 3 s bound on a 0.35 s path failed at 3.7 s with the race detector on.
- **Demo video on request ("generate a video"):**
  - Run `NODE_ENV=development pnpm -s demo:fixture [--aspects=9x16,16x9] [--look=<DesignSpec fixture id>]` in `packages/motion-engine`, in the background. Each aspect takes about 70 s; MP4s land in `out/fixture.<aspect>[.<look>].mp4`.
  - It uses the committed narration (`fixtures/motion/fixture-narration.mp3`), so there is no vendor spend. A new topic needs a new narration (paid TTS); ask permission before doing that.
  - `--look` swaps in another design. It refuses a design whose `type` or `safeZones` differ from the fixture's, because those budgets were never measured.
  - Check the result by eye. Pull a strip of frames with `ffmpeg -v error -y -i x.mp4 -vf "select='eq(n\,60)+eq(n\,250)+…',scale=360:-1,tile=6x1" -frames:v 1 strip.png` and look at it with vision.
  - Before calling something clipped, check 3–4 successive frames (`crop` the region): an enter animation (wipe, fade) caught mid-way looks exactly like clipping.
  - Tell the user what is generated and what is hand-written: until the storyboard and scene stages exist, the script and scene plan are the hand-written fixture.
- **Visual review is mandatory and catches what tests miss.** Use `scripts/stills.sh out.png <frames…>` (both aspects, hstack) for one element, and `pnpm contact-sheet` (one frame per beat) before review. A `<Freeze>` of MotionBuild inside another composition renders blank, because beat Sequences gate on the outer timeline. Render real stills and lay them out instead. The local ffmpeg has no `drawtext`.
- **Cap every layout's font so a `MIN_WORD_CHARS` (10) word fits on one line (`wordCapPx`), and record the guarantee as `FieldSpec.minWordChars`.** Make the limits generator STRICT: it must fail when Chrome says a declared field can't hold that word, never drop the field silently. Otherwise Go and the layouts disagree about which slots a kind can use.
- **Budget numbers on digit strings, not corpus words.** Digits are wider than average letters, so Counter, Meter and chart values that were budgeted on prose overflowed.
- **A budget needs three numbers: `maxChars`, `maxWordChars` and `lineChars`, plus one greedy-wrap rule** (words packed into lines of `lineChars` must fit `maxLines`). Total length and longest word alone accept copy like "Mere Microseconds. M" that wraps to an extra line. Implement the rule once per language (`src/budget.ts` `fitsBudget`, Go `LimitEntry.Fits`) and test both against ONE golden file (`schemas/motion/fixtures/budget-cases.json`). Feed the audit only copy that the rule accepts, so the audit tests the same thing Go enforces.
- **Text budgets (`pnpm limits`)** are measured per kind × field × layout slot × aspect, in Chrome, with a batched binary search of 400 items per Measure call.
  - `maxChars` is the worst case over many corpus windows (16) minus a 5% margin, never a single prefix. One prefix's glyph mix is not the widest, so text taken from other offsets overflowed.
  - `maxWordChars` is the longest length L such that EVERY distinct corpus word of length ≤ L fits on one line. One sample word per length misses wider glyph mixes of the same length.
  - Unusable fields are left out of the table. Go treats a missing entry as unusable, never as unlimited, and returns an error for an unknown kind or field name, because a typo would otherwise read as "no limit". `LimitEntry.Fits` checks both limits, counting runes.
  - schemagen embeds limits.json outside the hashes, because it is generated from them. `spec.LoadLimits` refuses stale hashes.
  - Measure the batches in parallel: 16 windows dropped from about 11 min to about 80 s. Still run it in the background, because the tool timeout (420 s) kills the Chrome session of a long foreground run.
  - A worst-of-N budget sits deliberately below the best window, so `test/overflow.spec.ts`'s "maxChars + 8 must not fit" upper bound has to be loosened to match. It still checks that sizes match the layouts.
- **Captions** page themselves (`captions/pages.ts`) and need no dependency.
  - Time in whole frames, and show every word for at least one frame. ASR can give a word a 1 ms span that rounds to no frame.
  - Cut pages by what fits the band in the caption style (measured), not only by word count and time. Break inside a word only when that one word is wider than the band. Pages cut by count overflowed at large sizes with long words.
  - Wait for the font gate before cutting pages, so paging is deterministic.
  - Captions sit only in the bottom band until a layout reserves space elsewhere. Any other position overlaps content slots.
  - **Highlights must not take layout space.** A padded `box` highlight changed line breaks and pushed text out of the band. Draw it with `box-shadow` and lay the text out narrower by the pad (`HIGHLIGHT_PAD_EM`). An inline background also covers ascent + descent (about 1.32 em), which is taller than the 1.15 line box, so subtract that overhang when computing lines per band.
  - **Clamp the caption size to the band height** (one line plus the box overhang). For a lone word wider than the band, draw it smaller, scaling by measured width but never below 16 px, instead of breaking it mid-word.
  - **Cache pages by VALUE (JSON key), not with `useMemo`.** MotionBuild re-parses the manifest every frame, so an identity-keyed memo re-paged and re-measured on every frame. A 64-design caption audit timed out at 420 s; after the fix it ran in 7 s.
  - **Audit captions in real Chrome over a grid of designs** (sizes 28–96 px, upper and mixed case, every highlight, every aspect, plus 16–20 character words), every N-th frame, through a frame-driven `CaptionsAt` that renders without a Remotion timeline. Check the highlight box's rect plus its pad as well as the text block.
- **The Go↔Zod parity corpus** (`fixtures/motion/parity/cases.json`) is generated by `scripts/motion/make-parity-corpus.py` (`-check` in CI), so raw lexical forms (`1.0`, duplicate keys, trailing bytes) survive. `goOnly` marks cases JSON.parse erases.
- **Shared-file task splits:** when several element kinds land in one shared module, commit the module once and switch each kind on in the registry in its own commit (script the registry edits and restore the final file from a saved copy).

### Writing a stage that produces element bodies (scenes-beat)

- **A scene validator does NOT reimplement slot/intent/duplicate/atWord rules; it wraps `spec.CheckManifest` with a one-beat skeleton manifest** and layers scene-local rules on top (per-field text budget via `limits.Lookup` + `entry.Fits`, numbers-must-come-from-the-beat's-words for Counter/Meter/Chart, icon-id lookup via `spec.Tables.HasIcon`, exactly-one-primary element). Any rule the manifest-level checker already enforces is one place to maintain, not two.
- **The intent → kind allow-list has quirks the fallback MUST respect:**
  - `Stamp` is primary-only for `state` and nowhere else. A fallback that puts `Stamp` as supporting fails validation for every other intent.
  - `Callout` is in `supporting` for every intent EXCEPT `enumerate`, which allows only `BigText` as supporting. An intent-blind fallback that always picks `Callout` supporting bricks `enumerate`.
  - `Callout.tone` enum is `info` / `warn` / `good` / `bad`. `neutral` is not a value; defaults go to `info`.
- **A scenes-beat stage's `Salt` = sha256(SchemaHash, vocabularySignature(tables), DesignSpecJSON).** `vocabularySignature` fingerprints the intent allow-lists, typesets and icon set independently of their formatting, so a token-equivalent reshuffle doesn't invalidate the cache but any change in what the prompt vocabulary names does.
- **Script LLM replies by schema shape, never by call order.** A stage with a retry loop re-calls the same stage after a validation failure, so a provider that returns canned replies indexed by call count serves the storyboard reply to a scenes call on retry. Match on a distinctive key in the request's schema (`properties.beats` → storyboard, `properties.styleId` → director, `properties.elements` → scene) and return the right canned payload each time.

## Design tokens, fonts and contrast (Milestone 3)

- **Draw surface decoration (stroke, shadow, accent edges) as `box-shadow` layers through one helper (`elements/surface.ts` `surfaceStyle`), never as border, padding or margin.** Box-shadows paint outside the box, so a design's shape cannot change a slot's text budget. Test that the helper's style has no layout-affecting keys.
- **Adding a font:**
  1. Check versions and weights at `https://api.fontsource.org/v1/fonts/<id>`.
  2. Download each face from `https://cdn.jsdelivr.net/fontsource/fonts/<id>@latest/latin-<weight>-normal.woff2`, and the licence from `https://raw.githubusercontent.com/google/fonts/main/ofl/<familynodashes>/OFL.txt`.
  3. Re-download one existing face and `cmp` it, to prove the source reproduces the committed files.
  4. Add the family to `fonts.json` with its sha256 per face and its `roles`, then update the `public/fonts/README.md` table.
  - Roles: body and caption need a workhorse face, so condensed and script faces are display-only. `mono` needs a monospaced family, because `CODE_COLS` assumes fixed-width glyphs. schemagen refuses a mono role on a non-mono family and a family without its licence file. `CheckManifest` and `parseManifest` both enforce roles.
- **Any font change moves `fontSetHash`, so `limits.json` goes stale on purpose.** Go `TestLimits*` and the Node overflow/audit tests then fail until `pnpm limits` regenerates the table. Copy `limits.json` to scratch before schemagen, say in the commit message that the table is stale, and regenerate it in the budgets task.
- **Font loading retries, then fails the render.** Give each face 3 attempts with backoff, then `cancelRender(err)`. Never fail open: a frame in a fallback font has metrics no budget or QA measurement saw. Don't cache a rejected load promise.
- **Contrast fixer (`services/motion/design`):**
  - Build the pair list from what the components paint: text needs 4.5:1, non-text graphics (chart series, tone bars) need 3:1.
  - Move only the foreground colours' OKLCH lightness. Keep hue, gamut-map chroma, and never touch bg or surface, which are the look.
  - Test every candidate on the rounded 8-bit hex it will store; a float colour that passes can fail after rounding.
  - Fix must be idempotent. When no lightness passes against all of a colour's backgrounds (a black bg with a near-white surface), it returns an error and the caller falls back to a library style.
  - Tests: 30 palettes (template themes, deliberately failing ones, and seeded random ones on dark and light bases), asserting that at least 10 needed fixing so the table keeps exercising Fix. Also an OKLCH round trip over random colours, hue preservation, and known WCAG values (#777/#767 on white).
- **Text on a filled box takes fg or bg, whichever contrasts more with the fill** (Go `design.OnColor`, TS `src/color.ts` `onColor`, with mirrored case tables). fg on accent cannot pass with a light accent.
- **Shipped palettes must pass without the fixer.** When a fixture fails, grep for the colour and apply the fixer's output to every file that uses it.
- **Embedded copies of big generated tables are byte copies, not re-rendered JSON.** schemagen's `renderJSON` pretty-printed the 31k-entry `limits.json` into 450k lines (about 13 MB in the binary). Copy the canonical file verbatim instead; `pnpm limits --check` keeps it canonical. Check `git diff --cached --numstat | sort -nr | head` before committing generated output.
- **Review the style contact sheets at full size too** (`scripts/style-still.ts <style> <frame>` then a vision crop). Sheet tiles are too small to show a word-gap problem. Heavy caps faces showed a caption box highlight touching the next word and the line's dark glow smudging dark text on the box. The fix: 0.08 em side spread and no text-shadow on the highlighted word.

## Visuals provider wiring (routing / pricing / workflow)

Adding a new visuals provider (`director`, `engine`, future) is a 3-site change in one commit; miss any one and requests 400 with no useful log.

- **Register in `services/visuals/routing.KnownProviders` AND `services/pricing/pricing.go` augment lines in the SAME commit.** The router accepts the provider name, pricing prices its augment units. A `KnownProvider` without a priced augment line passes routing then panics in the quote step; a priced augment that isn't in `KnownProviders` is unreachable. Tests in both packages catch the half-wired state.
- **Workflow dispatch pattern (mirror the director):** in `GenerateVideoWorkflow` declare `useX := false` next to `useDirector := false` BEFORE the motion-graphics block; inside the block decide `useX = seamVersion >= N && provider == "X" && workflow.GetVersion(ctx, "X-sidecar", DefaultVersion, 1) >= 1`; if the provider is set but the version gate failed, return a non-retryable error (`provider is set but the X-sidecar workflow version is not active`) so a replay on an older worker fails loud rather than silently falling back; dispatch via `return runX(ctx, in)` after the common prep, parallel to `runDirector`.
- **Keep the orchestrator pure Go, wrap it in one activity.** The pipeline (`storyboard → director → design.Library → scenes-per-beat → spec.CheckManifest`) lives in a `services/motion/<provider>engine` package as a `Build(ctx, Deps, Input)` function with no Temporal dependency; worker-core's `<Provider>BuildActivity` wires LLM + store + logger + metrics and calls it. Pure-Go `Build` is unit-testable without Temporal; a scripted-LLM test asserts the assembled manifest passes `spec.CheckManifest`. The thin activity returns the manifest JSON + a `Report` struct with per-stage attempts/fallback counts; a second activity uploads the manifest to `motion/<ws>/<buildId>/manifest.json` in the private bucket; `runX` then schedules the existing `engineRender` activity on the render-engine task queue with the manifest key.
- **The engine render task queue is NOT a literal — mirror motion-renderer's `engineQueue()` formula and resolve it inside the activity.** The Node side in `apps/worker-render/motion-renderer/src/activities/engine.ts` computes `ENGINE_RENDER_TASK_QUEUE || "${RENDER_TASK_QUEUE || 'render'}-engine"`; any Go workflow dispatch that hard-codes `"render-engine"` silently times out on any deployment that overrides either env var. The queue must be returned from the Build activity (`EngineRenderQueue` field on the result), not read in the workflow goroutine — `os.Getenv` inside a workflow function is non-deterministic and breaks replay. Pattern: `resolveEngineQueue()` helper lives in the activity file, called when building the result; the workflow passes `built.EngineRenderQueue` to `workflow.WithActivityOptions{TaskQueue: ...}`.
- **Audio key wiring: `GenerateVideoInput.AudioKey` is the stitched key for the whole video; `MGPayload.Turns[].AudioKey` is per-turn.** A new visuals provider that pipes the first turn's `AudioKey` as the manifest's audio asset ships the wrong (unstitched) audio for any multi-turn video. The engine Build input must prefer `in.AudioKey`; fall back to `Turns[0].AudioKey` ONLY for `len(Turns)==1`; error loudly otherwise (`"motion-engine: no stitched AudioKey on input; the upstream stitcher must set GenerateVideoInput.AudioKey before dispatch"`) so a mis-wired dispatch surfaces at the activity instead of pointing the renderer at silent-overlapping audio.
- **ArtifactStore for an engine Build is `stage.NewMemoryStore()`, not S3.** Every stage in one build runs inside a single activity invocation, so inter-stage caching across activity attempts has no benefit and MinIO round-trips add latency with no cache-hit upside. The S3-backed store is for cross-run artifact reuse, which the Build orchestrator doesn't currently exploit.
- **Metrics sink is an interface, not a Prometheus import.** `services/motion/metrics.Sink` has `BuildStart`/`StageDone(name, attempts, fallback, extra)`/`BuildDone(id, totals)`; default is `NoOp`, `SlogSink{Log}` emits one `motion-X:metrics` structured log per event. The activity wires `SlogSink` so dev traces fallback rates per build without a collector; a Prom adapter is added only when there's live data worth graphing.
- **Do NOT flip the `motion-graphics` default to a new provider ahead of its wiring.** When the user says "flip to X now", push back if any of these are missing: (a) `KnownProviders["X"]` exists; (b) pricing has an augment line for X; (c) a workflow dispatch branch is registered in `main.go` for X. A flip ahead of (a)-(c) returns 400 at the API. The quality gate (d) — eval sample size, overflow rate, QA sign-off, user review — is the user's call to waive: put it to them as a numbered open decision with a recommendation (the codegen series flipped at the director's deletion, with the eval gate measuring quality afterwards). Never waive it silently.

## Asset vendors (codegen series)

Generated assets are resolved by `services/motion/assets` before the first codegen round and reach a scene only through `props.assets` (see Codegen series). Vendor facts that shaped the adapters:

- **Recraft** (`services/ai-gateway/recraft`, the `VectorGen` capability; `RECRAFT_API_KEY` unset = fake): `POST https://external.api.recraft.ai/v1/images/generations/vector` (SVG) and `/generations/raster` (PNG/WebP), JSON body, `Authorization: Bearer`. Body: `prompt`, `n`, `model` (vector models end in `_vector`, e.g. `recraftv4_1_vector`; raster `recraftv4_1`), `size` as `WxH`, `style_id` (UUID) XOR style reference images (both at once is rejected; we never send references), `style` (`vector_illustration`) only when there is no `style_id`, `style_match` (`flexible`/`precise`) only when there is one, `random_seed`, `response_format` `url`|`b64_json`, `image_format` `png`|`webp` (raster only), `controls.colors[{rgb:[r,g,b]}]` + `background_color` for a palette. Response `{created, credits, data:[{url|b64_json, image_id}]}`: bill `credits` as integer credits; download the URL with no auth header, a content-type check and a byte cap; never wrap the signed URL into an error. 402 and 4xx are not retried; 429/5xx get bounded backoff. SVG sanitisation is the assets stage's job, never the adapter's.
- **Higgsfield** raster and clips reuse the existing adapter; its image submit URL is `base + "/" + model`, so the assets stage passes its own model rather than the portrait `ImageModelPath` default.
- **Maps never use `@remotion/maptiler`** (API key plus tiles over the network from the render Chrome): d3-geo over bundled TopoJSON.

## Render activities (motion-renderer `engine*`, render queue)

`engineRender`, `engineRenderStill` and `engineMeasure` in `src/activities/engine.ts`.

- **Input is a manifest S3 key (private bucket).** Validate it with `parseManifest`, then compare its schema and font hashes with the engine's before doing anything expensive.
- **Failure classes:**
  - a missing manifest, an invalid manifest, a frame out of range and bad measure input are non-retryable `ApplicationFailure`s;
  - schema or font hash skew is retryable, so a worker on the matching version can pick the task up during a rollout. Read the hashes with a loose parse BEFORE the strict Zod parse; otherwise a newer manifest's added field turns skew into a non-retryable invalid-manifest failure;
  - storage outages propagate unclassified, so the retry policy handles them.
- **Heartbeat only when the integer progress percent changes.** Remotion's `onProgress` fires once per frame, and heartbeating on every call gave about 1200 heartbeats for a 40 s video where about 76 do the job. Pass the cancellation signal through to the render.
- **Make a `mkdtemp` dir per call and remove it in `finally`.** Upload the output, then return the real byte count, frame count and duration.
- **Get the output's size and hash by streaming:** `stat`, plus `createHash` over a read stream. Never `readFile` the whole MP4.
- **Once the activity's cancellation signal has fired, rethrow any error as `CancelledFailure`.** Remotion rejects with a plain `Error('…got cancelled')`, which Temporal would record as a retryable failure.
- **Bound Chrome usage:**
  - Stills and measures share one lazily opened browser per process, used through `createSharedBrowser(...).use(fn)`.
    - It reopens after a crash, and closes after `MOTION_ENGINE_BROWSER_IDLE_MS` (30 s) with no users.
    - Without sharing, every call launches Chrome. A browser that lives for the whole process keeps Remotion's per-browser process listeners forever.
  - `engineRender` is limited at Temporal, not only in-process.
    - It runs on its own task queue, `ENGINE_RENDER_TASK_QUEUE` (default `<RENDER_TASK_QUEUE>-engine`), on a second `Worker` with `maxConcurrentActivityTaskExecutions = MOTION_ENGINE_RENDER_SLOTS` (default 1).
    - A semaphore alone lets one worker accept up to 100 renders and hold them heartbeating while other replicas sit idle. Keep the `Slots` semaphore as a backstop.
    - The Go workflow must schedule `engineRender` on that queue.
  - Heartbeats run on an interval for the whole activity, not only inside `onProgress`, since a cold bundle and the upload produce no progress events.
    - Tick every `heartbeatMs/2`, and skip a tick when the last beat is less than `heartbeatMs/2` old. The gap then stays near `heartbeatMs` (5 s).
    - The Go `HeartbeatTimeout` must be at least 3× that.
- **Pass `browserExecutable: engineBrowserExecutable()` to every Remotion call** (openBrowser, selectComposition, renderStill, renderMedia).
  - Remotion resolves its browser cache from `process.cwd()`: the nearest dir with a `package.json`, plus `node_modules/.remotion`.
  - A browser installed by `pnpm --filter @openstudio/motion-engine exec remotion browser ensure` is therefore invisible to a worker started from another directory, which re-downloads it.
  - `MOTION_ENGINE_BROWSER` overrides the resolved path.
- **Validate `engineMeasure` items with Zod**, so bad input is a non-retryable `EngineMeasureInput` failure rather than a TypeError that gets retried.
  - Bound every field: text at most 2000 chars, fontPx 4–1000, maxWidthPx 1–8192, maxLines 1–100.
  - Reject 0 measured lines for non-blank text.
  - Extreme values otherwise come back as plausible but wrong results, returned as data.
- **Wire contract:** `apps/worker-core/engine_wire.go` and `engine.spec.ts` assert against the same golden files in `apps/worker-core/testdata/engine_wire/*.json`. Change a shape on both sides and update the golden files in the same commit.
- **Test layers:**
  1. `engine.spec.ts` (in `pnpm test`): golden files, failure classes with a fake store and renderer, and a real-Chrome measure and still.
  2. `engine.live.ts` (opt-in): real MinIO and Chrome inside `MockActivityEnvironment`. Run it with `set -a; . ../../../.env; set +a; STORAGE_LIVE=1 NODE_ENV=development pnpm exec tsx engine.live.ts`. Check that the still's sha matches across runs, and that the render heartbeats more than 5 times and ends at progress 1.

  Run every motion-renderer test with `NODE_ENV=development`. The shell may export `production`, and an existing spec (`web.spec`) refuses to run under it.

## CI and lint

- **The CI `motion-engine` job (ubuntu-24.04, Node 22, Go 1.25, pnpm 11.1.2) runs:**
  - `pnpm install --frozen-lockfile` with no `|| pnpm install` fallback, because the fallback hides lockfile drift;
  - `schemagen.sh -check` and `make-fixture-manifests.sh -check`;
  - `remotion browser ensure`, then `pnpm --filter @openstudio/motion-engine test`;
  - `pnpm --filter @openstudio/storage build`, then `engine.spec.ts`.
  
  Remotion bundles its own ffmpeg, so no apt install is needed. The Go job already loops over every module.
- **Every new workspace package that an image depends on needs its `package.json` COPY'd into the Dockerfile deps stage** (`docker/motion-renderer.Dockerfile`). Otherwise `--frozen-lockfile` fails in the image build.
- **The motion-renderer image:**
  - Runs the worker with `CMD ["node", "--import", "tsx", "apps/worker-render/motion-renderer/src/worker.ts"]`. Workspace packages export raw `.ts` with extensionless imports and `dist/` is never built, so plain `node .../dist/worker.js` cannot start.
  - COPYs the `package.json` of every workspace package in the worker's import graph into the deps stage: storage, compositions, motion-engine, obs-node and schemas. A missing one leaves that package's dependencies uninstalled, and its import fails at boot.
  - Runs `remotion browser ensure` and `pnpm --filter @openstudio/motion-engine run bundle` at build time, so the first activity neither downloads Chrome nor runs webpack. `CHROME_PATH` has no effect on `@remotion/renderer`.
  - Relies on `.dockerignore` so that `COPY . .` does not lay host-platform binaries over the image's own install. It excludes `**/node_modules`, `**/dist`, `**/.cache`, `**/.remotion` and `.env*`. Keep `.git`, because the Go builds use `-buildvcs`.
- **Without a Docker daemon, simulate the image build:**
  1. In a scratch dir, copy only the manifests the deps stage copies.
  2. Run `pnpm install --frozen-lockfile --ignore-scripts --offline`.
  3. Copy the sources, minus the `.dockerignore` patterns.
  4. Build storage.
  5. Load the worker's modules with `node --import tsx -e "import(...)"`. The CI `motion-engine` job runs this same module-load step.

  Say plainly that the real `docker build` is still unverified.
- **`.gitattributes` pins the byte-compared generated files to LF**, so `-check` passes on autocrlf checkouts.
- **Repo-wide `pnpm biome check .` is not clean on `main`, so don't aim for zero.** The gate is: no file in `git diff --name-only origin/main...HEAD` appears in biome's diagnostics. Add machine-written JSON (schema `gen/`, `tables/`, fixtures, embeds, testdata) to `biome.json` `files.ignore`. Format hand-written schema sources, then re-run `schemagen.sh -check` to confirm the generated output is byte-identical.

## Closing a milestone

After the last task commit, dispatch up to 3 fresh-context, read-only adversarial reviewers in ONE `delegate_task` call. Split them by layer: schema pipeline / Go runtime (transcript, stage, llm) / Node render side (package, activities, wire, CI).
- Give each reviewer ARTIFACT plus CONTRACT. Leave out the author's claims.
- Each must delete any temporary repro files it creates, so `git status --short` ends clean apart from `test-remotion/`.
- Ban `STORAGE_LIVE` and vendor calls.
- Ask for demonstrated evidence, with an `output_schema` of `findings[]` (severity, location, issue, evidence, fix).

While they run, settle open PR blockers that don't depend on them, such as the frozen-lockfile proof.
To go faster (the user asks for parallel subagents), overlap the review with the NEXT milestone's independent tasks:
- Run builders in a worktree cut from the feature tip. Each builder owns new packages only (for example M4 `services/motion/storyboard/`) and gets a brief file whose decisions are already made.
- The reviewers stay read-only on the main checkout.
- Write briefs for dependent tasks up front (4.3/4.4 need 4.2), and dispatch them when the first builder returns.
- After the review fixes land, rebase the next-milestone branch onto the merged tip.

After the findings return:
1. **Write a triage ledger** next to the plan (`docs/plans/<plan-name>-m<N>-review.md`). It maps every finding to FIXED (sha or track), DEFERRED (the milestone task that owns it) or ACCEPTED (and why). Leave nothing unclassified.
2. **Fix blockers in the parent first**, one commit each, with the reviewer's repro as a test. Prove the test fails without the fix. With no track worktrees yet, `git stash push <file>`, run the test, then `git stash pop`. Once worktrees exist, swap the file instead (see delegate-task-tool), because the stash is shared.
3. **Split the remaining fixes into at most 3 tracks by FILE ownership.** For example: schemacheck plus check.go; stage plus llm; the render package plus its activities.
   - Give each brief at most 4 items. Queue a second brief per track rather than one 6-8 item brief or steered add-ons, since all such tracks truncate.
   - Each track gets its own worktree, branched off the same commit.
   - In every worktree run `pnpm install --offline --frozen-lockfile`, and copy `packages/motion-engine/node_modules/.remotion` (the downloaded chrome-headless-shell) over from the main checkout.
   - Each brief is a file listing owned and do-not-touch paths and, for each item, the reviewer's evidence plus your DECISION. Fixers then implement decisions instead of re-arguing them.
   - The generic dispatch mechanics are in delegate-task-tool.
4. **While the tracks run, the parent fixes only findings in files no track owns** (generator, transcript, text measurement, CI/Docker). An item found later in an owned file goes to that track by steer, never as an edit from the parent.
5. **After regenerating anything, rerun the fixture generators.** Confirm the output is byte-identical, or explain every diff.
6. **Merge each track, then run every suite.** Rebase it onto the feature tip, run the suites, fast-forward, and remove it, following delegate-task-tool.
   - The merge verification includes the steps truncated fixers skip: `go test -run='^$' -fuzz=FuzzValidate -fuzztime=60s ./schemacheck/`, the TS `spec.spec.ts`, and both `-check` generators.
   - Write the ledger's SHAs only after merging, because the rebase rewrites them.
   - Then re-review the fixes with fresh reviewers. Only then open the PR.
7. **Round 2 reviews the fix diff only** (`git diff <last-task-commit>..<fix-tip>`), with two reviewers: one for Go, one for TS + CI + Docker.
   - Each CONTRACT names the new code paths and asks for regressions that the fixes introduced.
   - The render contract includes "the production entrypoint starts", with a one-line proof: `node -e "import('@openstudio/motion-engine/node')"` from the worker dir. A test suite run through tsx never exercises how the image starts.
   - Keep one ledger per round (`-review.md`, `-review-r2.md`).
8. **Count dispositions from the ledger file with a script before quoting totals.** Counting FIXED / PARTIAL / DEFERRED / ACCEPTED by hand misreports them.
9. **Recovering reviewer findings after a context compaction:** the delegation logs truncate the final summary. Search for the full `{"findings":[…]}` JSON with `sqlite3 ~/.hermes/state.db "select id from messages where session_id='<sid>' and content like '%<phrase from a finding>%'"`, then parse it from that row.
10. **Opening the PR:** write the body file fresh in the same step that uses it. `write_file` refuses to overwrite a scratch file it hasn't read, and `gh pr create --body-file` then silently posts the OLD draft. Always re-check the posted body (`gh pr view N --json body`) for stale numbers and placeholders, and fix it with `gh pr edit N --body-file`.
11. **Before merging,** verify that a clean checkout of HEAD builds (a detached `git worktree` outside the repo, with `node_modules` symlinked from the main checkout; `go build`/`vet` + `tsc --noEmit`). This proves nothing in the build depends on uncommitted files.

## Handover documents

When the user asks whether the work is documented, or a context reset is near, write a FRESH handover file, `docs/plans/<date>-<topic>-handover.md`, rather than a chat summary, and link it from the plan. A new context must be able to continue from that file alone. The plan stays the authority for WHAT each milestone builds; the handover is a status snapshot.

1. **Gather status by running commands, not from memory:** `git log --oneline main..HEAD`, `git status --short`, `gh pr list --state all --limit 5`, `go vet ./...` and `go test ./...`, the package test suites, and the latest audit or generator logs. Write down real pass/fail counts and the actual error line for each failure.
2. **Sections, in this order:**
   - where everything is: repo, plan, ADR, ledgers, branch, code areas, skills to load;
   - a milestone status table: merged (PR and squash sha), in progress, or not started;
   - the commits on the branch;
   - review findings and the state of each;
   - uncommitted work, grouped by area;
   - what is not working, as a table of problem / evidence / fix;
   - next steps, numbered in order;
   - items carried forward to later milestones;
   - open decisions for the user, each with a recommendation;
   - the environment and repo rules.
3. **Scratch dirs are pruned after 24 h idle.** Anything a successor needs goes into the doc or the repo, not just a scratch path.
4. **Commit only the doc and the plan pointer** (a `docs(motion): …` commit). Leave in-progress code uncommitted, as the doc describes it.
