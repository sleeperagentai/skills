# Feature-flag lifecycle (adding, flipping, removing)

Rollout flags in OpenStudio touch EIGHT sites. When removing a flag at GA, every site must change in one commit; when adding, place the hooks before enabling. The pattern is identical for every flag; this file is the canonical checklist.

## 1. Config field

`services/config/config.go`:

```go
// struct Config {
    FeatureX bool
// }

// in Load():
    FeatureX: getenvBool("FEATURE_X", !prod),
```

Default-off-in-prod is the usual rollout stance (`!prod`). On removal, delete BOTH the field and the `Load` row.

## 2. API read surface — TWO `/me` endpoints emit features (CRITICAL)

Both of these ship an identical `features` map; missing one is the single most expensive bug in flag work.

- `apps/api/me.go` (`/api/v1/me`): `features["feature_x"] = s.cfg.FeatureX` with a nil-cfg fallback to `true` for bare table-test states.
- `apps/api/main.go` `handleInternalMe` (`/internal/me`): an IDENTICAL `features` emission that the web bundle actually reads.

The web uses the second one. Leaving the first synced but the second stale (or vice versa) produces "API says on, UI says off" with no error anywhere. When patching, grep `features\["feature_x"\]` to confirm every emission site is hit.

## 3. Enforcement sites

Each gated handler:

```go
if s.cfg != nil && !s.cfg.FeatureX {
    writeErr(w, errs.New(errs.CodeConfigMissing,
        "Feature X isn't available for this workspace yet."))
    return
}
```

The nil-check is REQUIRED — table-driven tests build a bare `state{}` with no cfg and expect the surface to work. Count the enforcement sites before removal; captioned-clip had TWO (`caption_upload.go` and the `handleRenderProject` branch in `main.go`).

## 4. Web consumption

- `apps/web/.../page.tsx` gates on `features?.X` fetched via `serverFetch<Me>('/internal/me')`.
- Format-card lists filter by a `feature: 'X'` string that matches the API map key.
- On removal, drop the `feature` field, the `Me` type's `features` field (if it becomes unused), the `serverFetch` call, and any `visibleFormats` filter.

## 5. OpenAPI docs — TWO copies

- `docs/openapi/openstudio.yaml` (source).
- `apps/web/public/openapi.yaml` (served copy).

After editing the source, `cp docs/openapi/openstudio.yaml apps/web/public/openapi.yaml` or edit both by hand. The two must agree — the served copy is what the dashboard renders.

## 6. Feature-prose docs

- `docs/features/<name>.md`: the feature itself. Strip the "Feature flag" subsection on GA removal; keep the admin runbook and troubleshooting.
- `docs/features/<name>-rollout.md`: per-workspace rollout checklist. On GA removal, DELETE this file.
- `README.md` may mention the gate under the feature's section.
- `docs/plans/<yyyy-mm-dd>-<name>.md`: historical plan — DO NOT edit on removal (plans are history).

## 7. Tests

A regression test often pins the 503 "flag off" path (e.g. `caption_render_test.go` existed solely to assert `CONFIG_MISSING` surfaces when the flag is off). On removal, DELETE it rather than invert it; nothing meaningful remains to test.

## 8. Verify complete removal

```
grep -rln FEATURE_X\|FeatureX\|features\.<name>\|use_<name> \
  --include="*.go" --include="*.ts" --include="*.tsx" \
  --include="*.md" --include="*.yaml" --include="*.sh" --include="*.env*"
```

Expect only the historical plan doc. Anything else is a straggler.

## Shell gotcha when testing the removal

If the user's shell exports `NODE_ENV=production`, `prod := env == "production"` evaluates true in `services/config/config.go` and every `getenvBool(KEY, !prod)` default stays off even after the field is removed. Start the api with `env -u NODE_ENV go run ./apps/api` to probe cleanly. See references/local-dev-and-routing.md for the general rule.
