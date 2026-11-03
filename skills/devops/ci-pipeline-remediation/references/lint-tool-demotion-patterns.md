# Lint-tool demotion patterns

Concrete config snippets for turning a specific rule from `error` into `warn` (visible but non-failing) across common linters. Use when the backlog is too large to fix in one PR and the CI gate needs to go green now.

Always include a comment in the config naming the deferred-migration PR / cleanup PR so the demotion is tracked, not forgotten.

## biome.json

```json
{
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "suspicious": {
        "noExplicitAny": "warn",
        "noArrayIndexKey": "warn"
      },
      "style": {
        "noNonNullAssertion": "warn",
        "useTemplate": "warn",
        "noUnusedTemplateLiteral": "warn"
      },
      "complexity": {
        "useOptionalChain": "warn",
        "noUselessSwitchCase": "warn"
      },
      "a11y": {
        "useSemanticElements": "warn",
        "noLabelWithoutControl": "warn",
        "noSvgWithoutTitle": "warn"
      }
    }
  },
  "files": {
    "ignore": [
      "**/dist/**",
      "**/.next/**",
      "**/generated/**",
      "**/.turbo/**",
      "**/node_modules/**",
      "**/storybook-static/**",
      "**/.agents/**",
      "**/build/**"
    ]
  }
}
```

To verify which rules are still at `error` after demotion:
```bash
pnpm exec biome check --diagnostic-level=error --max-diagnostics=10000 . 2>&1 \
  | grep -oE 'lint/[a-zA-Z0-9/]+' | sort | uniq -c | sort -rn
```

## redocly.yaml

```yaml
# Baseline for CI. Hard structural rules stay at `error` (recommended
# preset); demote style-only lints to `warn`.
#
# Pre-existing debt tracked here:
#   - lint/struct errors on `nullable: true` (OAS-3.1 moved it into
#     type arrays — [type, "null"]).
#   - missing operation-summary across catalog schemas.
# Follow-up PR will migrate; drop these demotions when it lands.
extends:
  - recommended

rules:
  struct: warn
  operation-summary: warn
  operation-operationId: warn
```

Redocly can also disable rules outright with `off`, but `warn` is strictly better — you still see the diagnostics locally.

## eslint (flat config, v9+)

```js
export default [
  {
    rules: {
      '@typescript-eslint/no-explicit-any': 'warn',
      '@typescript-eslint/no-non-null-assertion': 'warn',
      'jsx-a11y/label-has-associated-control': 'warn',
      'react-hooks/exhaustive-deps': 'warn',
    },
    ignores: [
      '**/dist/**',
      '**/.next/**',
      '**/storybook-static/**',
      '**/build/**',
    ],
  },
];
```

Legacy `.eslintrc.json`: same shape under `rules`, same severity strings (`"warn"` / `"error"` / `"off"` or `0`/`1`/`2`).

## ruff (pyproject.toml)

```toml
[tool.ruff.lint]
select = ["E", "F", "W", "B", "UP", "SIM"]
# Keep the real-bug rules at error (default).
# Demote the noisy style/complexity backlog:
[tool.ruff.lint.per-file-ignores]
"legacy/**/*.py" = ["B008", "SIM102"]
```

Ruff doesn't have `warn`-severity in the same sense — you either enforce or ignore. For "visible but non-failing" effect, keep `ruff check` as a reporting job (non-blocking) alongside the enforcing `ruff format --check` job, and only hard-enforce a tight subset. Document the split in the workflow.

## golangci-lint (.golangci.yml)

```yaml
linters:
  enable:
    - govet
    - staticcheck
    - unused
    - errcheck
  disable:
    # Demoted during <topic> cleanup; re-enable after PR N lands.
    - gocyclo
    - lll
    - gochecknoglobals

issues:
  exclude-dirs:
    - vendor
    - internal/generated
```

Same as ruff: golangci-lint has no `warn` severity. Model it as "disabled with a reason comment pointing at the cleanup PR" and bring linters back online one at a time.

## General rule for ANY linter

If the tool supports per-rule severity, demote to `warn`. If it only supports on/off, disable with a header comment naming the deferred cleanup PR — never silently drop a rule. Someone later will read the config and need to know whether the rule is genuinely unwanted (delete it) or deferred (re-enable it).
