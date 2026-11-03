---
name: openstudio-riso-rebuild
description: OpenStudio Riso pixel-perfect UI rebuild (feat/riso-design).
---

# OpenStudio Riso rebuild

Active branch: `feat/riso-design`. Nuclear rebuild of `apps/web` to match the “OpenStudio — Riso” design canvas.

## Source of truth

- **Primary (newer) on-disk source**: `/Users/sa-vm/Workspace/openstudio/openstudio-designs/` — four self-contained HTML bundles (`design-system.html`, `app-screens.html`, `app-motion-graphics-wizard.html`, `marketing.html`, ~92 MB total). Each bundle is a single page whose body renders every board inside a `blob:null/...` iframe. The parent-origin `document.body` is a 3-div React mount with no readable content on its own.
- **Secondary (older, 28 Sep) source**: `docs/design/openstudio-riso-design-boards/` — 97 `.dc.html` files + `canvas.json` + `README.md`. These are the artifact-editor source (inline styles + `renderVals()` with L/light + D/dark objects). Wrappers (`<dc-import>`) delegate to a base board with props — always resolve the base file. Use this when the newer bundle is overkill (grep for a specific token / string).
- **Online Claude artifact** (https://claude.ai/artifact/GAvHy3mjVTN5PpiAJxDhGE and https://claude.site/artifact/…): accessible from a signed-in cookie session only; the `/public/artifacts/<id>` form 404s for private artifacts. From the Hermes browser, Claude's bot filter rewrites the `/artifact/<id>` HTML shell to a 404 body when the default headless Chrome UA is seen — fix is `cdp("Network.setUserAgentOverride", userAgent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", platform="MacIntel")` BEFORE `new_tab()`. Even then the artifact body says "Sign in to see this artifact's data" without an auth cookie, so prefer the on-disk bundles.
- Boards are the **pixel spec** — they beat `DESIGN.md`, `tokens.css`, this skill, and any sibling doc when they disagree. Match inline styles + `renderVals()` output (L=light, D=dark objects) exactly.
- Build brief: `docs/design/claude-design-brief.md`. Master task list: `docs/design/openstudio-riso-pixel-perfect-build-prompt.md`.
- Tokens live in `apps/web/styles/tokens.css` (Phase 1). Every component/page must read from there — no hard-coded hex or oklch anywhere else.

## Extracting board content from an `openstudio-designs/*.html` bundle

The body is 3 empty divs; all content is in `<script>` blobs the React runtime renders into same-page iframes with `blob:null/...` sources. Steps:

1. `goto_url("file:///…/openstudio-designs/<bundle>.html")`, then poll until `document.querySelectorAll('iframe').length` reaches the expected count (16 for `design-system.html`, 34 for `app-screens.html`, 14 for `wizard`, 33 for `marketing`).
2. **Do not** try `iframe.contentDocument` — `blob:null` is an opaque cross-origin, parent reads throw. CDP `Target.attachToTarget` returns a sessionId the pre-imported `cdp()` helper does not forward either, so attached-session `Runtime.evaluate` runs against the parent, not the iframe. Both approaches look like they work and silently return parent data.
3. **Working method**: from the parent page JS, `await fetch(iframe.src)` and read `.text()`. The blob is still live, same-process, so fetch succeeds and returns the inner HTML (self-contained, ~500 KB–1.2 MB per board including its own runtime).
4. For a text-only pass, render each saved board file in its own tab (`goto_url("file://…/<board>.html")`) and read `document.body.innerText` after the runtime renders (poll `innerText.length > 300 && innerHTML.length > 3000`).
5. The index page of each bundle also mounts board 0, so the first `.txt` capture of every bundle is the board-index list, not real content — ignore `__xx__🐴_OpenStudio_—_Riso.txt` duplicates when walking the output set.

## Storybook 10 quirks

- Framework is `@storybook/react-vite` v10. Config is ESM — use `import.meta.url` + `fileURLToPath`, not `__dirname`.
- **v10 dropped the auto React plugin.** `.storybook/main.ts` MUST include `plugins: [react({ jsxRuntime: 'automatic' })]` from `@vitejs/plugin-react` inside `viteFinal`, or every story fails with `ReferenceError: React is not defined`.
- `@vitejs/plugin-react@6` needs Vite 6+. Storybook 10 ships Vite 5, so pin `@vitejs/plugin-react@^4`.
- Story files import from `@storybook/react-vite`, not `@storybook/react` (renamed in v10).
- Titles auto-derive from file path (`components/blocks/reel.stories.tsx` → `Molecules/Reel`). The v8 IDs (e.g. `riso-atoms-button--primary`) are NOT the v10 IDs — real IDs come from `curl http://localhost:6006/index.json`.
- Runtime: `pnpm --filter @openstudio/web storybook -- --no-open --host 0.0.0.0 --port 6006`.
- Storybook’s built-in `iframe.html` contains static template text ("failed to render properly") that `curl | grep` will match even when the story renders fine. Only a real browser check confirms — use `browser_exec` to load the story URL and read `document.body.innerText`; the first 100 chars should be the actual component text. Real failure signatures inside `innerText`: `React is not defined` (JSX runtime issue — add plugin-react), `Couldn't find story matching 'X'` (story ID is stale, get real IDs from `curl http://localhost:6006/index.json`), `Missing Context/Providers` (add a decorator in `preview.tsx`).

## Provider traps hit during Motion Graphics work

- **ElevenLabs Free tier** blocks premade / Voice-Library voices via API (402 `paid_plan_required`, code `voice_not_found` on unknown IDs). Only voices from a user’s **My Voices** (generated/cloned) work. Set `ELEVENLABS_DEFAULT_VOICE_ID` in `.env` to a personal generated voice; the alias resolver in `services/ai-gateway/elevenlabstts/elevenlabstts.go` falls through to it for every unknown seed id.
- ElevenLabs API keys can be scope-limited. `text_to_speech` and `voices_read` are separate scopes; check both when integrating.
- ElevenLabs adapter returns `DurationMs: 0` (their endpoint doesn’t report duration). Both `apps/worker-core/activities/tts.go` and `apps/api/live_tts.go` **probe with ffprobe** as a fallback, then estimate ~180ms/word as a last resort.
- **Anthropic model** default is now `claude-sonnet-4-5`. The old `claude-3-5-sonnet-20241022` returns 404.
- `PROVIDER_TEXTGEN=local` in `.env` forces local llama.cpp even when `ANTHROPIC_API_KEY` is present. Local server = `llama-server -m ~/.cache/openstudio/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf --host 127.0.0.1 --port 8080`.

## Convention reminders

- Stack: Next.js 15 App Router, Tailwind 3.4 (NOT 4, despite the prompt saying “Tailwind 3 or 4”), `next-themes` with class-based `.light`/`.dark`, `lucide-react` icons at `strokeWidth={1.75}` (never inside coloured squircles).
- Fonts via `next/font/google`: Unbounded 600 (wordmark), Bricolage Grotesque 400–800 opsz (display), Onest 400–700 (UI/body), Geist Mono 400/500 (mono).
- API surface for the wizard stays: `POST /api/v1/motion-graphics/projects`, `POST /api/v1/motion-graphics/projects/{id}/render`, `POST /api/v1/live/scripts`, `GET /api/v1/scripts/{id}`, `POST /api/v1/live/tts`. Rename **UI copy only**, not endpoints (Shape ≠ aspect-ratio in the request body — that field stays `aspectRatio`).
- UI copy renames: Aspect ratio → Shape, Template → Look, AI write → Write it for me, Paste script → I have my words, Get quote/Confirm & render → Price shown automatically → Make video, Renders/Projects → Library.

## Auditing the web app against the boards

- A full-app audit (shell + overlays + ~15 pages + ~5 primitive dirs + repo-wide greps) does NOT fit in one `delegate_task` child — the 50-call iteration cap trips at ~30 files. Split by territory in parallel: (a) shell + nav + overlays + `tokens.css` + `components/ui/riso/*`, (b) `app/(app)/` pages (home / create / library / videos / series / cast / influencers / boards / settings / admin), (c) marketing + signin + help + error pages + repo-wide copy/vendor/colour greps. One child per bucket.
- Each child must receive the Riso source paths (`riso-rendered/`, `riso-boards/`, `docs/design/openstudio-riso-design-boards/README.md`, `apps/web/DESIGN.md` once it's rewritten) directly in its context — children do not see parent conversation history.
- Finding format that composes cleanly across children: `BLOCKER/HIGH/MEDIUM/LOW/NIT` severity + `file:line` + Observation + board citation (`design-system__NN__…` or `app-screens__NN__…`) + concrete fix (prop/class/token). Numbering continues across the merged report (B1→B9, H1→H23) so partial-pass follow-ups can slot in without renumbering.
- When a sub-agent reports it hit the iteration cap WITH findings inline but no file written, write them to the agreed report path yourself from the summary — do not re-dispatch the same bucket just to recover the markdown.
- The on-disk `DESIGN.md` can drift from the boards and must be deleted + regenerated from the extracted boards before trusting audit findings about colour / type / fonts — grading structural issues against a stale doc produces retracted findings (e.g. "accent is green, pink is wrong" when the real system is Riso pink; "220/56 sidebar collapse missing" when the real rail is a fixed 88px).
