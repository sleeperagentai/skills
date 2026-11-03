# Static-asset catalogues (music beds, voices, backdrops, SFX)

Recurring shape for "user picks one of N royalty-free / vendor-neutral assets baked into the public bucket". Every new catalogue repeats the same seven pieces; skip one and the asset ships broken or billable but unusable.

## Seven pieces, in order

1. **`infra/seed/<catalogue>/manifest.json`** — the source of truth. Flat array of entries; each entry carries at minimum `slug` (stable kebab-case id — this is what the API accepts, not the filename), `title` (shown in the dropdown), `file`, `durationMs`, `sha256`, `licence`, plus kind-specific fields (`vibe`, `bpm`, `loopable` for music; `gender`, `locale` for voices; etc.). Keep an empty-but-valid manifest in the repo so the catalogue loader has something to parse on a fresh checkout.
2. **`infra/seed/<catalogue>/manifest.schema.json`** — JSON Schema with `slug` regex (`^[a-z][a-z0-9-]*$`), enum for vibe/locale/style, hex-64 for sha256. The uploader validates against this before pushing anything, and the API loader can reuse it in tests.
3. **`infra/seed/<catalogue>/LICENCES.md`** — the acceptable-licence policy (e.g. Pixabay Content License — free commercial, no attribution required) PLUS a per-track provenance table (track → source URL → licence name → downloaded-on date) PLUS the "how to add one" runbook. Attribution-required licences (CC-BY, Uppbeat Free, FMA by-attribution) are REJECTED at this layer, not at upload — they would require an attribution surface the UI does not have.
4. **`scripts/dev-native/seed-<catalogue>.sh`** — idempotent uploader. For each manifest entry: `shasum -a 256 <file>` and refuse if the hash doesn't match the manifest; `mc cp <file> <alias>/openstudio-public/<catalogue>/<file>` (or equivalent for your bucket); print a one-line result per entry. Must exit 0 on an empty manifest with the message `seed-<catalogue>: manifest is empty (no entries to upload)` so pre-provisioned infra scripts can call it unconditionally.
5. **Public GET endpoint — `GET /api/v1/<catalogue>`** — a dedicated `apps/api/<catalogue>.go` file (don't co-locate with the create-render handler), with: a package-level cached loader keyed on manifest path, an env override (`<CATALOGUE>_MANIFEST_PATH`) so tests can point at a temp dir, a `<Catalogue>Exists(slug) bool` helper used by the validator, and the handler returning `{"entries": [...]}` wrapped — never a bare top-level array (future-proofs for pagination / metadata). Register the route near `/presenters` in `apps/api/main.go`; this endpoint is intentionally public — do NOT add it to the fail-closed unauth sweep.
6. **Create-time validation** — the create-project / create-render request accepts the slug (e.g. `musicBedSlug`). Validate against the loaded manifest at the **UI-facing create endpoint** (`handleCreateMotionGraphicsProject`), returning 400 `error_code: unknown_<catalogue>_slug` on miss. Do NOT rely on validation inside `buildMGRenderPayload` or similar render-time hot-path builders — their errors are logged and swallowed by the caller (they fall back to the pre-storyboard payload), so a bad slug would silently ship as "no asset" instead of surfacing to the user who picked it.
7. **Propagation path (one field at each layer)** — the slug rides through:
   - `apps/api` request DTO → persisted into project settings JSON → `mgRenderPayload.<field>Slug`
   - `apps/worker-core` `MGPayload.<field>Slug` → `DirectVideoInput.<field>Slug` (set in `buildDirectVideoInput`)
   - `apps/worker-render/motion-renderer/src/director/types.ts` `DirectVideoInput.<field>Slug?` (JSON tag matches Go PascalCase)
   - `src/activities/renderRemotion.ts` reads the slug and resolves to a URL via `storage().publicURL(\`<catalogue>/${slug}.<ext>\`)`, threading `<field>Url` into composition inputProps
   - `packages/compositions/src/render-input/index.ts` adds `<field>Url?: string` to `RenderInputMotionGraphics` (URL, not slug — the composition should never resolve bucket paths itself)
   - The composition (`MotionGraphics.tsx` etc.) mounts the asset at the **composition root** when the URL is set, so it plays through title cards and silent turns, not inside a Sequence

## Director-sidecar path (scratch workspace)

The director runs in a scratch Remotion project (`src/director/workspace.ts`), separate from the shared composition. For an asset that the agent-authored `Video.tsx` needs:

- Download the asset into the project's `public/` directory in `prepareWorkspace` (`storage.get('public', key)` → `writeFile(path.join(project, 'public', '<asset>.<ext>'), data)`).
- Treat a download failure as "no asset" rather than failing the render — a missing public asset must degrade gracefully, not kill the render. Set a local `hasAsset = false` on catch.
- Thread the boolean into BOTH the starter `Video.tsx` (so a never-edited starter still mounts the asset) AND the generated `brief.md` (so the agent knows the asset exists, where it is, and the fixed volume policy).
- The brief must state the volume policy as a hard constraint, not a suggestion: "mount it as `<Audio src={staticFile("music-bed.mp3")} volume={0.08} loop />`; the starter Video.tsx already does this. Volume is FIXED at 0.08; do not change it or add ducking." Ducking is explicitly out of scope for v1 of every background-asset catalogue — the agent will introduce it as a creative flourish if the brief doesn't ban it.

## OpenAPI

- Operation goes under the `motion-graphics` tag (or the matching feature tag) with `operationId: list<Catalogue>` and a one-paragraph description that mentions (a) the catalogue is the single source of truth for the slug, (b) unknown slugs are 400 at create-render time, (c) `{entries: []}` when empty. Reference the `<Catalogue>` schema under `#/components/schemas/`.
- Define the component schema with `required: [slug, title, file, url, durationMs, licence]` (every real entry has them), kind-specific enums (`vibe`, `locale`), hex-64 for `sha256`, `format: uri` for `url`.
- Run `pnpm --silent exec redocly lint docs/openapi/openstudio.yaml` before considering the OpenAPI update done; the linter catches dangling `$ref`s and the "required-but-not-defined" trap.

## Testing

- Pure unit tests over the loader + handler + `<Catalogue>Exists` validator, no DB / network / MinIO. Write a temp manifest, point the loader at it via the env override, and assert: empty manifest → `{entries: []}`, missing manifest → `{entries: []}` (NOT an error — a fresh checkout has none), bad JSON → 500 with a logged load error, populated → correct entries, unknown slug → `false`, known slug → `true`. Round-trip the real on-disk manifest once as a schema-parses smoke.
- The web.spec / Playwright side of the renderer is NOT a gate for these changes; `apps/worker-render/motion-renderer`'s `web.spec.ts` fails on `makeWebTools: resolveOverride is a test seam and must not be used in production` whenever `NODE_ENV=production` is set in the shell (common after a prior sidecar smoke test). `unset NODE_ENV` before `pnpm test` if you need that spec green; otherwise it is a known pre-existing failure and does NOT block a catalogue PR.

## Don'ts

- **Don't fabricate asset files or claim to have downloaded them.** The user drops real licensed files at the path. The scripts and schema are built so a `./seed-<catalogue>.sh` run on an empty manifest exits cleanly, which proves the plumbing works without inventing content.
- **Don't co-locate catalogue state in the create-render handler.** A dedicated `<catalogue>.go` with its own tests keeps the handler small AND lets the catalogue grow a background refresh / S3-list path later without a rewrite.
- **Don't let the composition resolve bucket paths.** The composition is a pure function of its inputProps; URL resolution lives in `renderRemotion.ts`. A composition that calls `publicURL()` cannot be rendered standalone from the Studio and breaks the single-renderer-path invariant.
- **Don't thread the slug all the way to the composition.** The slug is an API identity; the composition needs the URL. One hop in `renderRemotion.ts` separates the two concerns.
