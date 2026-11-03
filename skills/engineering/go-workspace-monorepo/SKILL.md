---
name: go-workspace-monorepo
description: Use when adding intra-repo imports in a Go monorepo.
---

# Go multi-module / workspace monorepos

Applies to repos where each service has its own `go.mod` and they refer to each other by full module path (e.g. `github.com/org/repo/services/foo`), coordinated via `go.work` and/or per-module `replace` directives. The trap that always bites: `go mod tidy` tries to *fetch* an intra-repo path over HTTPS unless a `replace` steers it to the local checkout, and on a private host that fetch fails with `terminal prompts disabled` / `could not read Username`.

## Adding a new intra-repo service import

1. Add the import statement in Go code first (`import "github.com/org/repo/services/newthing"`).
2. **Before `go mod tidy`**, append the replace to the *consuming* module's `go.mod`:
   ```
   replace github.com/org/repo/services/newthing => ../../services/newthing
   ```
   Path is relative to that `go.mod`'s directory. One `replace` per consuming module — `go.work` at the repo root is not enough when the module also declares its own `replace`s, because tidy uses the module's own graph.
3. THEN run `go mod tidy`. The `found ... v0.0.0-00010101000000-000000000000` line confirms it resolved locally. If you see `git ls-remote ... exit status 128`, step 2 was skipped or the relative path is wrong.
4. `go build ./...` inside the consuming module to confirm.

## Pitfalls

- **Never rely on `go.work` alone for a module that carries its own `replace` block.** The per-module replaces win for that module's `tidy`; a workspace-only setup silently works until someone adds one `replace` and everything downstream must follow the same pattern. Match the pattern already in the module — inspect the existing `replace` lines before adding yours.
- **Do not run `go mod tidy` speculatively on a module you haven't touched** in a private-host monorepo. Tidy will happily rewrite the `require` block and try to fetch anything it can't resolve, leaving the module in a worse state than it started. Only tidy modules you actually changed.
- **`replace` paths are relative to the go.mod file, not the repo root.** `apps/api/go.mod` reaching `services/webhooks` is `../../services/webhooks`, not `./services/webhooks`. Getting this wrong yields the same private-fetch error as omitting the replace entirely.
- **Sibling test modules that share code need their own replace too.** A `_test` package under a different module (e.g. an integration-tests module) won't pick up parent `replace`s.

## Running `go build`/`go test` across all modules

`go build ./...` and `go test ./...` from the repo root fail in a workspace repo with `pattern ./...: directory prefix . does not contain modules listed in go.work` — the `./...` pattern is resolved against the CURRENT module, and the repo root is not itself a module. Loop over `go.work` instead:

```bash
for m in $(grep -oE './[^)]+' go.work | tr -d ' '); do
  (cd "$m" && go test ./... 2>&1 | tail -3)
done
```

Or `cd` into each module and run `go build ./...` / `go test ./...` there. Do not try to add the root as a module to "fix" this — the workspace design is correct; the invocation is wrong.

## Diagnostic

When `go mod tidy` prints `git ls-remote -q --end-of-options https://<host> ... fatal: could not read Username`, the fix is almost always a missing `replace` in the current module's `go.mod`, not a credentials problem. Add the replace and retry before touching auth.
