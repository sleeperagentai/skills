# Anthropic (Claude) adapter quirks

Read when touching `services/ai-gateway/anthropictext/` or any Go code that calls `aigw.TextGen` against a real Anthropic model (today: the stage-1 script generator and the `services/visuals/motion` SceneSpec designer).

## Sampling parameters are deprecated on newer models

**Anthropic removed `temperature`, `top_p`, and `top_k` starting with Claude Opus 4.7 and Claude Sonnet 5. Sending the field at all — even `0.0` — returns HTTP 400 `temperature is deprecated for this model`.** The 400 propagates all the way out, Temporal retries exhaust, and any activity that depends on the call silently falls back (the workflow's broll → presenter-only path hides the failure entirely).

When the model rejects temperature:

- `float64` + `omitempty` **does not help** — Go's zero value for a plain float64 still serialises as `temperature: 0` on an explicit set (and omits it only when `in.Temperature == 0`, which is NOT how you want the policy decided). The field must be `*float64` so an omitted pointer genuinely disappears from the JSON wire. Non-nil `0.0` on an accepting model is a valid, meaningful deterministic sampling request and MUST still be emitted.
- Policy decision belongs in a helper (`temperatureFor(model, in.Temperature) *float64`): returns `nil` to omit when the model rejects temperature, otherwise returns a clamped `[0,1]` pointer. Both `Generate` and `GenerateStream` must share it; divergent copies make the same work bill (and succeed) differently.

**Model-gate the omission — do not blanket-drop.** Older models (Opus ≤4.6, every Sonnet 4, every Haiku, Claude 3) still accept temperature in `[0,1]`, and the clamp behaviour matters:

- Anchor the model-match regex on word boundaries so `octopus-4-8` is NOT read as Opus 4.8.
- Tolerate the 8-digit date suffix on legacy ids: `claude-opus-4-20250514` must parse as Opus 4.0 and keep temperature.
- Case-insensitive match.
- **Unknown model shapes default to accepting** (regressing to a 400 on a never-seen future model is strictly worse than letting Anthropic surface a clearer error). Document a new denylist entry when a future rejecting model lands.

Tests must pin the on-the-wire shape (httptest-captured request body) alongside the policy helper — a unit test of `modelAcceptsTemperature` alone passed while the JSON tag was still wrong.

## JSON responses come wrapped in Markdown code fences

**Claude Sonnet 5+ frequently emits structured output inside a ` ```json … ``` ` fence**, especially now that `temperature` can no longer nudge it toward raw JSON. A bare `json.Unmarshal(resp.Text, ...)` then fails with `invalid character '`' looking for beginning of value` and the whole batch fails — even though the fenced body is perfectly valid JSON.

Strip the fence defensively before parsing. Rules:

- Only strip when BOTH an opening ` ```[lang] ` and matching trailing ` ``` ` are present. A half-fenced truncated response (opener, no close) must pass through untouched so the JSON parser surfaces a specific, debuggable error instead of a mis-stripped buffer.
- Allow optional language tag (` ```json `, ` ```javascript `, bare ` ``` `).
- Tolerate surrounding whitespace.
- Non-fenced raw JSON passes through unchanged.

Factor the fence-strip into its own file (`fence.go` + `fence_test.go`) so the behaviour can be unit-tested without the full adapter wire-up. Pin the end-to-end behaviour with a test that drives the adapter's `Generate` through a fake `TextGen` returning a fenced envelope and asserts every expected scene / spec is parsed.

`response_format: {"type": "json_object"}` is not an Anthropic `/v1/messages` parameter. For free-text calls, strip fences defensively as above. When the output shape must be guaranteed, use strict structured outputs (`output_config.format` with a JSON schema, or strict tool use) within the constraints below, and keep the fence-strip anyway.

## Strict structured outputs reject most JSON Schema validation keywords

A schema sent as the structured-output format, or as a strict tool `input_schema`, returns 400 if it contains any of these:
- `minimum`, `maximum`, `exclusive*` or `multipleOf`;
- `minLength` or `maxLength`;
- array constraints beyond `minItems` of 0 or 1 (`maxItems`, `uniqueItems`);
- `additionalProperties` set to anything but `false` (every object needs `false`);
- recursive `$ref` or external `$ref`.

Simple `pattern` regexes work; lookarounds and backreferences do not. Zod 4's `.int()` emits safe-integer `minimum`/`maximum`, which trips the rejection on its own.

Large unions fail separately with `compiled grammar is too large`. `$ref`/`$defs` don't help, because the grammar is compiled with every reference expanded inline. A schema-as-contract design (one file feeding Go, Zod and Claude) therefore needs two things:

- a derived schema for the LLM with validation keywords stripped (optionally restated in `description` text), narrowed per call to only the variants that call may emit (e.g. the element kinds allowed for one beat's intent);
- full validation of the response against the ORIGINAL schema afterwards, re-prompting with the validation errors on failure (bounded attempts, then a deterministic fallback).

There are also hard per-request budgets across ALL strict schemas in one request: at most **24 optional parameters** (any property not in `required`) and at most **16 union-typed parameters** (`anyOf` or type arrays like `["string","null"]`). Exceeding them, or the internal grammar-size limit, returns 400 `Schema is too complex for compilation` (180 s compile timeout as the last stop). Make every property required (express optional as an explicit nullable value the model must fill), and have the schema generator count optionals/unions per projection and fail the build before any request does.

The first call with a new schema waits while the grammar compiles; compiled grammars are cached for about 24 h. Changing the schema itself (not just names or descriptions) invalidates that cache and the prompt cache.

## Prompting a model whose output is schema-validated

When the Go side validates every spec against an embedded JSON Schema (`//go:embed scenespec.schema.json`), partial-success is the right contract: schema-invalid specs are omitted from the Result and `Degraded=true`, but a non-JSON response (parser failure) is a batch failure — there is no safe way to recover individual scenes from garbled output. Only fail the batch unconditionally when EVERY spec fails validation.

Map vendor-rejection error strings (`"moderation"`, `"content_policy"`, `"rejected"`) to `visuals.ErrContentRejected` so the workflow surfaces a typed non-retryable error instead of eating all 3 retries on a prompt the model will never answer.
