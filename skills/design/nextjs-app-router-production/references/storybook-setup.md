# Storybook 10 in a Next.js App Router monorepo

Wiring Storybook into an existing Next 15 app is version-sensitive at the plumbing layer even when the story files look right. Hit these gotchas up-front instead of debugging "React is not defined" or "Couldn't find story" from an idle boot that logs no errors.

## Framework + version pairing

- **Storybook 10 dropped its bundled React-Vite JSX plugin.** `@storybook/react-vite@10`'s preset only ships `plugin-react-docgen-typescript` — NOT `@vitejs/plugin-react`. Stories with JSX then fail at runtime with `ReferenceError: React is not defined` because Vite treats `.tsx` under the classic JSX runtime by default. Add the plugin explicitly in `.storybook/main.ts`:

  ```ts
  import react from "@vitejs/plugin-react";
  export default {
    // ...
    async viteFinal(base) {
      return mergeConfig(base, {
        plugins: [react({ jsxRuntime: "automatic" })],
      });
    },
  };
  ```

- **Match `@vitejs/plugin-react` MAJOR to Vite major.** v6 requires Vite 6+ (imports `vite/internal`); v4 works with Vite 5. Storybook 10 currently ships Vite 5, so pin `@vitejs/plugin-react@^4`. v6 fails at boot with `ERR_PACKAGE_PATH_NOT_EXPORTED: Package subpath './internal' is not defined by "exports" in vite/package.json`.

- **`@storybook/addon-essentials` was removed in v10.** Older docs still reference it. Enable individual addons in the `addons:` list (controls, actions, viewport, a11y, themes, etc.) — there is no meta-addon anymore.

## ESM main.ts loader

Storybook 10 loads `.storybook/main.ts` as ESM. `__dirname` throws `ReferenceError: __dirname is not defined` at boot. Derive it from `import.meta.url`:

```ts
import path from "path";
import { fileURLToPath } from "url";
const here = path.dirname(fileURLToPath(import.meta.url));
// then path.resolve(here, "..") for the app root
```

## Type-import syntax the story indexer rejects

Storybook 10's acorn-based story indexer trips on mixed value + type imports on the same line:

```ts
// ❌ Fails silently — story disappears from index.json with
// "Could not parse import/exports with acorn" logged once.
import { Widget, type WidgetVariant } from "./widget";

// ✅ Split into two imports
import { Widget } from "./widget";
import type { WidgetVariant } from "./widget";
```

Symptom: `curl http://localhost:6006/index.json` doesn't include a story ID even though the file exists on disk. Grep every `*.stories.tsx` for `, type ` on an `import { ... }` line before assuming a component is missing.

## Type-import path renamed in v10

`Meta<T>` / `StoryObj<T>` moved from `@storybook/react` to `@storybook/react-vite` in v10. Every story file needs the updated path or typecheck fails. One-shot sweep across all story files:

```bash
grep -rl '"@storybook/react"' components/ stories/ | xargs sed -i '' \
  's|"@storybook/react"|"@storybook/react-vite"|g'
```

## preview.tsx wiring

Use `withThemeByClassName` from `@storybook/addon-themes` to swap the same `.light` / `.dark` class the running app uses — that way `tokens.css` (or equivalent) resolves to the correct palette in both story previews. Load the app's real global CSS (`../app/globals.css` in App Router setups) at the top of `preview.tsx`; without it stories render with UA defaults and every colour looks wrong.

## "Couldn't find story" is usually an ID rename

Story IDs are auto-derived from the `title:` field. A rename from `Riso/Atoms/Button` → `Atoms/Button` shifts every ID from `riso-atoms-button--primary` to `atoms-button--primary`. When a URL that used to work returns "Couldn't find story matching '<id>'", pull the current inventory before assuming a broken build:

```bash
curl -sf http://localhost:6006/index.json | jq -r '.entries | keys[]' | grep -i <fragment>
```

"Failed to render" text inside the iframe's static HTML is Storybook's fallback template — always present, hidden when a story actually loads. Don't grep for it as evidence of a broken story; open the URL in a real browser and read `document.body.innerText` after JS runs.

## Verification

- `curl -sf http://localhost:6006/index.json | jq '.entries | length'` returns the expected story count.
- Open any story's `iframe.html?viewMode=story&id=<id>` and inspect the DOM — should show real component text, not the fallback "Missing Context/Providers" template.
- `pnpm --filter <app> build-storybook` must exit 0 before considering the setup done. `storybook dev` will hide many wiring errors that only surface at build time.
