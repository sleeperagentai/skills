# Temporal workflow + visuals-seam patterns

Deep rules for editing `apps/worker-core/main.go` workflow code and the `services/visuals/*` adapter seam. Load when adding a new scene-visuals provider, bumping `scene-visuals-seam`, or touching the parallel-vs-serial dispatch inside `GenerateVideoWorkflow`.

## Workflow coroutines and channels

**`workflow.Channel.Send(ctx, v)` blocks the sending coroutine until a receiver calls `Receive`.** The test-env virtual clock then advances to its ScheduleToClose deadline (visible as a 10-year `Auto fire timer` log line) and the workflow fails with `deadline exceeded`. Use `workflow.NewChannel` ONLY to hand a result from a `workflow.Go` goroutine to the main coroutine that will later `Receive`. For synchronous dispatch inside the main coroutine (do work, use result right here), skip the channel and set a plain Go bool/variable — the join block downstream reads that flag instead. Mixing the two shapes in one block is fine as long as the serial path never calls `Send`.

## Versioning a per-caller behaviour switch

**When bumping `GetVersion` max to add a per-caller behaviour switch, keep the switch INSIDE the new version so existing callers' event logs don't reorder.** `workflow.GetVersion(ctx, id, workflow.DefaultVersion, 2)` returns 2 for every new workflow, so a `switch seamVersion >= 2 && provider == X { … }` keeps non-X callers byte-identical to v=1. Branching on `seamVersion` alone (without a caller-level predicate) rewrites every provider's event sequence and invalidates every captured replay fixture at once.

Sibling rule already in the main SKILL.md: keep `workflow.DefaultVersion` in the floor so histories recorded before the change-id existed still replay.

## Per-video adapters must fan out to every brief id

**A visuals adapter that produces ONE SceneVisual for the whole video must fan it onto every brief id, keeping a `__video__` (or similar) synonym.** The workflow's hydration loop matches activity results by brief id (`idxByID["s1"]`, `"s2"`, …); a lone synthetic key would never match and `hydratedScenes[i].ResolvedVisual` stays nil — the renderer sees no visual and the whole feature silently no-ops.

Shape:

```go
func fanOut(v visuals.SceneVisual, scenes []visuals.SceneBrief) map[string]visuals.SceneVisual {
    out := make(map[string]visuals.SceneVisual, len(scenes)+1)
    out[SyntheticVideoID] = v
    for _, b := range scenes {
        if b.ID == "" { continue }
        out[b.ID] = v
    }
    return out
}
```

Both the fresh-generate path and the `prog.Resume()` seed path must go through the same helper, or resume replays will diverge from fresh runs.

## Routing: no env override for single-provider kinds

**Don't add `VISUAL_PROVIDER_OVERRIDE_<KIND>=…` (or any `KIND_PROVIDER_OVERRIDE_*` knob) for a kind that has one real provider.** `KindProviders` + `KnownProviders` is the complete routing surface. An override for a kind with no alternative is a dead safety net — nothing to fall back to.

Rollout for a single-provider replacement:

1. Register the new adapter in the registry (both maps admit the name).
2. One-line flip of `KindProviders["<kind>"] = "<new>"`.
3. Rollback is reverting that commit while the old adapter is still registered.

Only add the override when two real adapters coexist for the same kind (the pluggable-scene-visuals shape, where motion ↔ footage can genuinely swap during an outage).

## Where the dispatcher goes when adding a new render kind

For a visual whose render path differs from the Remotion-compositions bundle (e.g. a Claude-authored TSX render that compiles its own entrypoint): put the dispatcher at the top of `renderRemotion`, not as a sibling Temporal activity.

```ts
const tsxHit = extractTSX(input);
if (tsxHit) {
  const res = await renderClaudeTSX({ … });  // function call, not activity dispatch
  return mapToRenderRemotionResult(res);
}
// … existing bundle+render path …
```

Function-call delegation keeps the Temporal event log flat (one `ActivityScheduled`/`Completed` for `renderRemotion`); a nested activity dispatch doubles the events and complicates every future replay fixture. The `kind → compositionId router` in the SKILL.md's "6 wire points" list stays authoritative for compositions-bundle kinds; this is the escape hatch for a kind that renders its own bundle.
