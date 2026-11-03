---
name: storybook-component-library
description: "Add or upgrade Storybook for React+Vite apps."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [storybook, component-library, design-system, vite]
    related_skills: [frontend-ui-engineering, nextjs-app-router-production]
---

# Storybook component library setup

Class-level playbook for adding, upgrading, or debugging Storybook in a React + Vite (or Next.js App Router) app. Storybook has silent version-mismatch traps between its own bundled Vite and the `@vitejs/plugin-react` you add for the JSX runtime; getting them wrong wastes 20 minutes staring at `React is not defined` while the config compiles green.

## When to Use

- Adding Storybook 8+ to an app for the first time.
- Upgrading across a major version (esp. 8→10) — the internal Vite version, the framework package name, and the addon set all change.
- Diagnosing `React is not defined`, `__dirname is not defined`, or `Couldn't find story matching …` after the config boots green.
- Wiring app-wide tokens/themes into Storybook decorators.

## Standing rules

1. **Storybook 10 ships Vite 5 internally, but `@vitejs/plugin-react@^6` requires Vite 6+ and will refuse to load with `ERR_PACKAGE_PATH_NOT_EXPORTED: Package subpath './internal' is not defined by "exports" in .../vite/package.json`.** Pin `@vitejs/plugin-react@^4` alongside `@storybook/react-vite@^10` and Storybook's bundled Vite 5. When Storybook next bumps its internal Vite to 6+, revisit the plugin-react major together — the two version families must move in lockstep.

2. **Storybook 10's `@storybook/react-vite` preset does NOT wire a React plugin into the Vite pipeline — you must add `@vitejs/plugin-react({ jsxRuntime: "automatic" })` in `.storybook/main.ts`'s `viteFinal` yourself.** The preset only registers react-docgen, not the JSX transform. Without the explicit plugin, every story file that uses JSX crashes at runtime with `ReferenceError: React is not defined` even though `tsc --noEmit` passes clean (TypeScript with `jsx: "preserve"` defers the runtime to the bundler, and Vite alone treats `.tsx` under the classic runtime that needs an explicit `import React`). Storybook 8 bundled the plugin; the migration silently drops it. See `references/main-ts-template.md` for a paste-in config.

3. **Storybook 10 loads `.storybook/main.ts` as ESM — `__dirname` is undefined and boot crashes with `SB_CORE-SERVER_0007 (MainFileEvaluationError): ReferenceError: __dirname is not defined`.** Replace with `const here = path.dirname(fileURLToPath(import.meta.url))` and use `here` for every `path.resolve()` inside the config. Storybook 8 loaded main.ts as CJS, so pre-existing configs silently break on upgrade at boot, not at typecheck.

4. **Storybook 10 splits the framework types out of `@storybook/react`. Every existing story file must switch its `Meta`/`StoryObj` import from `"@storybook/react"` to `"@storybook/react-vite"`.** The old package is deprecated in v10 and no longer resolves; missing the rename leaves stories compiling under TypeScript but failing at Storybook boot with `Cannot find module '@storybook/react'`. macOS bulk-rename: `grep -rl '"@storybook/react"' components/ stories/ | xargs sed -i '' 's|"@storybook/react"|"@storybook/react-vite"|g'` — the empty-string after `-i` is required on BSD sed; on Linux use `sed -i 's|…|…|g'` without the arg.

5. **`@storybook/addon-essentials` is gone in v10 — its members (actions/backgrounds/controls/docs/measure/outline/toolbars/viewport) are baked into core.** Remove it from `.storybook/main.ts`'s `addons` array before booting v10 or the config load fails. `@storybook/addon-a11y` and `@storybook/addon-themes` remain separate — keep those if in use.

6. **Story IDs auto-derive from the file's title path, NOT the folder tree — but they lowercase-kebab-cased.** A story file with `title: "Atoms/Button"` yields IDs like `atoms-button--primary`, regardless of whether the file lives at `components/ui/riso/button.stories.tsx`. When probing a specific story, fetch the authoritative index instead of guessing: `curl -s http://localhost:6006/index.json | jq -r '.entries | keys[]' | grep <needle>`. Guessing an ID like `riso-atoms-button--primary` and getting HTTP 200 does NOT mean the story exists — see rule 7.

7. **`curl` cannot distinguish a real render failure from Storybook's built-in error UI — both return HTTP 200 with the same iframe.html shell.** The generic "The component failed to render properly…" text is baked into the shell HTML and shows whenever a story ID misses or the component throws. `curl -sf iframe.html?...&id=<X>` returning 200 tells you nothing about whether `<X>` actually renders. Real verification: drive a headless browser (Playwright/browser_exec/CDP) and read `document.body.innerText` — real component content (button labels, avatar tiles, dialog headings) will appear; a broken story shows the fallback panel. Grepping the raw HTML for `React is not defined` is a valid signal only because that specific string comes from the JSX-runtime error path, not the generic shell.

## Recommended install (fresh, Storybook 10 + Vite 5)

```bash
pnpm --filter <app> add -D \
  storybook@^10 \
  @storybook/react-vite@^10 \
  @storybook/addon-a11y@^10 \
  @storybook/addon-themes@^10 \
  @vitejs/plugin-react@^4
```

Minimal viable `.storybook/main.ts` in `references/main-ts-template.md`.

`.storybook/preview.tsx` type import must be `import type { Preview } from "@storybook/react-vite"` — not `"@storybook/react"`.

## Migrating from Storybook 8 → 10

1. Remove v8 devDeps in one edit. `pnpm remove` sometimes hangs if a shell guard thinks the command is a long-lived process; edit `package.json` directly and `pnpm install` instead.
2. Add v10 devDeps (list above, including `@vitejs/plugin-react@^4`).
3. Update `.storybook/main.ts`:
   - Drop `@storybook/addon-essentials`.
   - Import `react from "@vitejs/plugin-react"` and add `plugins: [react({ jsxRuntime: "automatic" })]` inside `viteFinal`'s `mergeConfig(...)`.
   - Swap `__dirname` for `fileURLToPath(import.meta.url)`-derived path.
4. Update `.storybook/preview.tsx`: `Preview` type from `@storybook/react-vite`.
5. Bulk-rename stories: BSD sed `grep -rl '"@storybook/react"' components/ stories/ | xargs sed -i '' 's|"@storybook/react"|"@storybook/react-vite"|g'`.
6. Verify: boot Storybook, then drive a headless browser against 2-3 different-family stories (an atom, a molecule, an overlay) and confirm real innerText — one of them will expose any residual JSX-runtime or config error.

## Common failure signatures

| Symptom in log/browser | Root cause | Fix |
|---|---|---|
| `ERR_PACKAGE_PATH_NOT_EXPORTED: Package subpath './internal' is not defined by "exports" in .../vite/package.json` | `@vitejs/plugin-react@^6` against Vite 5 | Downgrade to `@vitejs/plugin-react@^4` |
| `ReferenceError: React is not defined` in the story iframe body | Missing react plugin in `viteFinal` under v10 | Add `plugins: [react({ jsxRuntime: "automatic" })]` |
| `ReferenceError: __dirname is not defined` at Storybook boot | `.storybook/main.ts` loaded as ESM in v10 | Replace with `fileURLToPath(import.meta.url)` |
| `Cannot find module '@storybook/react'` | Story files use v8 import path | `sed`-rename to `@storybook/react-vite` |
| Iframe shows "Couldn't find story matching '<id>'" | Wrong story ID (title-derived, kebab-cased) | Fetch `/index.json`; do not guess |
| Iframe shows "The component failed to render properly…" but curl says 200 | Storybook's fallback error UI — real component error only visible in-browser | Load with a headless browser, read `document.body.innerText` |
