# Workspace-scoped analytics loops (ComputeInsights pattern)

For any feature of the form “nightly aggregate historical outcomes per
workspace → feed back into a future vendor prompt as metadata → measure
lift against a holdout”. First instance: `content.publication_insights`
+ scheduler `ComputeInsights` + `services/systemprompts` auto-injection.
Future candidates: ad-copy insights, retention-pattern insights,
scheduling-time insights, voice-pick insights.

## Shape

Four cooperating pieces, one per layer:

1. **Canonical table** `content.<entity>_insights` keyed on
   `(workspace_id, feature, value, version)` with `score_z double`,
   `effect_size double`, `sample_size int`, `degraded boolean`,
   `holdout boolean`, `computed_at timestamptz`, `version int`. RLS
   scopes to `workspace_id`. Grants to `openstudio` after CREATE.
2. **Store CRUD** `services/db/store/insights.go` exposing
   `UpsertInsight`, `LatestInsightVersion`,
   `ListTopInsightsForWorkspace`, `ResolveWorkspaceInsights`,
   plus a feature-join query (`GetPublicationsWithFeaturesSince`) that
   returns one row per past asset with the features we score.
3. **Scheduler job** `apps/scheduler/compute_insights.go` running on a
   24h cadence (or whatever matches the signal’s staleness tolerance).
   Reads the feature-join query, computes scores (next section),
   writes top ≤ N rows per workspace at a new monotonic version.
4. **systemprompts hook** reads the latest version via
   `ResolveWorkspaceInsights(ctx, workspaceID)` on every Compose() call
   and injects it as a metadata slot keyed `workspace-insights:<ws>`.
   The holdout fraction (20%) is applied here — deterministic hash of
   the asset id selects whether this call sees insights or baseline.

## Scoring math

For each `(feature, value)` grouping over the workspace’s past assets:

- Workspace-wide mean + stdev of the SIGNAL metric (views, retention,
  revenue — one metric, chosen deliberately).
- Variance clamped `≥ 1` to survive tiny samples without NaN.
- `raw_z = (group_mean - workspace_mean) / stdev`.
- **Shrinkage toward 0** with `α = n / (n + k)` where `k` is a fixed
  prior-strength constant (10 works well for 10–500-sample workspaces):
  `effect = raw_z * α`. One-shot wins can’t dominate.
- Skip groups with `n < 2` entirely — a singleton has no variance
  signal, including it as an “insight” encodes noise.
- Sort by `|effect|` descending, keep top 3.

## Degraded flag (thin samples)

Emit insights even when the workspace is too young for them to mean
much, but mark `degraded = true` so the UI can show “collecting data…”
and the systemprompts hook can skip injection entirely:

- Fewer than `insightsMinPublications` (10) assets in the join query, OR
- `WorkspaceFirstPublication` is less than `insightsMinAgeDays` (14) ago.

Still write the rows — the UI benefits from showing an empty-state with
the degraded badge, and skipping writes entirely masks “we are learning
but not confident yet” as “we have no data”.

## Deterministic holdout for lift measurement

The hook that injects insights into prompts applies a 20% holdout
keyed off `hash(asset_id) % 100 < 20`:

- Same asset always gets the same bucket → retries don’t escape the
  holdout, and A/B balance is stable over time.
- Persist the bucket + version on the asset row (`scripts.insight_version`
  for the first instance) so after-the-fact lift can be computed with
  a simple `AVG(signal) WHERE insight_version IS NULL vs IS NOT NULL`.
- Never apply the holdout at the scheduler side — the holdout decides
  USE, not COMPUTE. The scheduler writes every top-N insight at the
  new version; the hook chooses who sees them.

## Monotonic version

`version = LatestInsightVersion(ws) + 1` on every run keeps old versions
queryable for lift analysis without a separate audit table. The hook
always reads the HIGHEST version via `ResolveWorkspaceInsights`; older
rows live on for forensics. Do NOT truncate old versions — lift
measurement needs them.

## Pitfalls encountered

- **A feature-join query that is global for query-planner friendliness
  must be scoped to the current workspace client-side before scoring.**
  Pattern: query is `WHERE published_at <= $1 LIMIT 5000` (one trip to
  Postgres with the index that already exists), then the scheduler
  filters to the current workspace in Go. The alternative — per-workspace
  query inside the loop — shreds the planner cache.
- **Features MUST emit `(feature, value)` tuples where value is
  non-empty.** An empty-value grouping (character_id = “”, series_id = “”
  on assets that have no character/series) silently buckets 100% of
  the orphan rows under one meaningless key. Guard with
  `if value == "" { skip }` in the add() helper, not downstream.
- **Hook-text extraction needs lowercase + first-word truncation BEFORE
  grouping.** `scripts.scenes[0]->>'narration'` is free text; without
  normalisation every variant of “Hey everyone, today…” bucketises
  separately and no group reaches `n ≥ 2`. Lowercase, take the first
  token up to any whitespace/punctuation, and compare on that.
- **Duration bucketing with hard-coded ms thresholds beats continuous
  distance.** `short < 45s`, `mid < 75s`, `long otherwise` groups
  cleanly; computing z-scores against a continuous duration conflates
  three distinct audience behaviours (hook-first short-form, standard
  mid-form, long-form retention) into one noisy signal.
- **Workspaces with zero publications in the feature-join window must
  skip the write entirely — don’t emit degraded zeros.** The hook
  treats an absent insights row as “compose without the metadata slot”,
  which is the correct default; writing degraded zeros instead gives
  the hook three noise rows to inject.

## Verifying the loop works end-to-end

`go test` on the scoring function pins shrinkage math (small-n group
shrunk below its raw z-score, singleton groups skipped, zero-stdev
safety). It does NOT pin the systemprompts injection — that needs an
integration test that:

1. Seeds the publications + metrics table with known distributions.
2. Runs the scheduler job once (`jobComputeInsights(ctx)`).
3. Reads the compose output and asserts the metadata slot appears.
4. Flips the asset into the holdout bucket (deterministic hash means
   choosing an id that falls in `< 20`) and asserts the slot is
   ABSENT.

Skipping step 4 ships a loop whose holdout logic is unverified; the
honest lift measurement that justifies the whole machine depends on it.
