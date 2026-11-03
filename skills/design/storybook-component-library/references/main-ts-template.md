# `.storybook/main.ts` template — Storybook 10 + Vite 5 + React 18

Drop-in config that survives all the standing-rules traps in the parent SKILL. Adjust the `stories` glob and the alias for your project layout; leave the rest.

```ts
import type { StorybookConfig } from "@storybook/react-vite";
import { mergeConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";
import { fileURLToPath } from "url";

const here = path.dirname(fileURLToPath(import.meta.url));

const config: StorybookConfig = {
  stories: [
    "../components/**/*.stories.@(ts|tsx|mdx)",
    "../stories/**/*.stories.@(ts|tsx|mdx)",
  ],
  addons: [
    // NOTE: @storybook/addon-essentials is removed in v10 (baked into core)
    "@storybook/addon-a11y",
    "@storybook/addon-themes",
  ],
  framework: { name: "@storybook/react-vite", options: {} },
  staticDirs: ["../public"],
  typescript: { reactDocgen: false },
  async viteFinal(base) {
    return mergeConfig(base, {
      // Storybook 10's react-vite preset does NOT include a react plugin —
      // only react-docgen. Vite alone treats .tsx under the classic runtime
      // which needs `import React`. Adding plugin-react in automatic mode
      // means component/story files don't need to.
      plugins: [react({ jsxRuntime: "automatic" })],
      resolve: {
        alias: { "@": path.resolve(here, "..") },
      },
      css: {
        // If your project has postcss.config.js at the app root, point at it.
        postcss: path.resolve(here, ".."),
      },
    });
  },
};
export default config;
```

## Companion `preview.tsx` (theme switching via addon-themes)

```tsx
import type { Preview } from "@storybook/react-vite";
import { withThemeByClassName } from "@storybook/addon-themes";
import "../app/globals.css"; // or wherever your tokens.css / tailwind entry lives

const preview: Preview = {
  parameters: {
    layout: "padded",
    a11y: { config: { rules: [{ id: "color-contrast", enabled: true }] } },
  },
  decorators: [
    withThemeByClassName({
      themes: { light: "light", dark: "dark" },
      defaultTheme: "light",
      parentSelector: "html",
    }),
    // Optional wrapper to apply the app's canvas bg + text tokens
    // so stories don't render on a naked white background.
    (Story) => (
      <div style={{ background: "var(--canvas)", color: "var(--text)", minHeight: "100vh", padding: 24 }}>
        <Story />
      </div>
    ),
  ],
};
export default preview;
```

## Companion `package.json` scripts

```jsonc
{
  "scripts": {
    "storybook": "storybook dev -p 6006",
    "build-storybook": "storybook build"
  }
}
```
