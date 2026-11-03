---
name: nextjs-app-router-production
description: "Ship Next.js App Router apps end-to-end."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [nextjs, app-router, build, cors, deploy]
    related_skills: [frontend-ui-engineering]
---

# Next.js App Router — production build & integration playbook

Always-on rules for shipping App Router apps (13+, verified on 15.x). Details in `references/build-failures.md`, `references/api-integration.md`, `references/storybook-setup.md`.

## When to Use

Load this skill when any of the following is true:

- Running or debugging `next build` / `next dev` for an App Router (13+) project.
- Wiring an App Router UI to a separate-origin JSON API (CORS, auth headers, idempotency).
- Adding a client-only third-party viewer/widget (doc renderer, diagram lib) and the build starts failing.
- Adding or deleting routes and typecheck starts complaining about generated `.next/types` shims.
- Handling API keys or session tokens in a browser dashboard.

## Standing rules

1. **Set `NODE_ENV=production` explicitly when running `next build`.** Next 15 emits a warning about “non-standard NODE_ENV” if the shell exports `NODE_ENV=development` (common in monorepos where a Node app has set it globally), and static generation of `/404` / `/500` then crashes with the misleading `<Html> should not be imported outside of pages/_document`. The build is fine — the env is. `NODE_ENV=production pnpm build` is the fix. `NODE_ENV=development` is required back for `pnpm dev`.
2. **Before blaming your diff for a build failure, reproduce on the previous commit.** `git stash -u && rm -rf .next && pnpm build` on HEAD~1. Same error = pre-existing, own the fix but not the diagnosis. Different or absent = your changes.
3. **After deleting an app-router route, `rm -rf .next` before running `pnpm typecheck`.** Next writes generated type shims under `.next/types/app/**/page.ts` for every route it has ever seen; the shim outlives the source file and TypeScript errors with `Cannot find module '.../page.js'` on the deleted route.
4. **Never store an API key in a cookie, query string, log, or analytics event.** For a client-side dashboard, put it in `localStorage` under a single namespaced key (e.g. `<product>.apiKey`) and send it ONLY as `Authorization: Bearer <key>`. On a 401, wipe the storage entry and redirect to a setup page — a rotated key otherwise leaves the UI permanently broken.
5. **Mint a fresh `Idempotency-Key: crypto.randomUUID()` per user action on every POST.** Do NOT reuse across actions — the server’s idempotency table happily returns the first response forever. StrictMode double-fires and double-clicks become safe as a side effect.
6. **CORS with credentials refuses `*` origin.** When the API is a separate origin, echo the exact request `Origin` in `Access-Control-Allow-Origin`, add `Vary: Origin` (so caches don’t cross-pollute), set `Access-Control-Allow-Credentials: true`, and enumerate every custom header in `Access-Control-Allow-Headers` — `authorization, content-type, idempotency-key` at minimum. Preflight (`OPTIONS`) must return 204 with these headers before any real request will fly.
7. **Third-party doc / renderer libraries that pull in Next's page runtime pollute the server chunks and break static generation.** `next/dynamic({ ssr: false })` is NOT enough — the module still enters the server graph. If a viewer (Scalar, similar) causes the pages-runtime `<Html>` error even after isolation, remove the npm dep entirely and mount the third-party viewer via a CDN inside an `<iframe srcDoc=...>`. Redoc's CDN standalone bundle is a working substitute for Scalar.
8. **In Next 15, `dynamic(loader, { ssr: false })` is FORBIDDEN inside a Server Component and fails compilation with an Ecmascript error on the `dynamic(` call site.** The option is only valid in Client Components (`"use client"`). If a server component imports a client-registry module that calls `dynamic({ ssr: false })`, the module transitively enters the server graph and the build refuses it. Fixes, in order of preference: drop the `{ ssr: false }` option (the loader's target module is already a client component with `"use client"` — hydration on the client is automatic and `ssr:false` was redundant); OR move the `dynamic()` call into a `"use client"` module and have the server component import that indirection. Do NOT convert the entire server component to `"use client"` just to keep `ssr:false` — you lose the server data-fetch benefit.
9. **Every App Router root MUST ship `app/error.tsx`, `app/global-error.tsx`, and `app/not-found.tsx` — nested `app/<segment>/error.tsx` is not enough.** Without all three at the root, Next 15 flashes `missing required error components, refreshing...` in the browser and re-renders the tree on every unhandled error, breaking dev-mode navigation. Nested `error.tsx` only catches errors under its own segment; the root file catches everything above it, and `global-error.tsx` runs when the root layout itself throws, so it must render its own `<html>`/`<body>` (the broken layout is not available). `not-found.tsx` at the root handles 404s from `notFound()` calls in server components. All three are `"use client"` components; the error variants receive `{error, reset}` props.
10. **Session cookies from a separate-origin dev API never reach the browser on the Next origin — proxy `/auth/*` and `/api/*` through Next.** When the Next dev server is on :3001 and the API on :4000, a `Set-Cookie` from a login POST directly to :4000 is stored ONLY for :4000; subsequent :3001 page loads have no cookie and the dashboard sees a permanent 401. The fix is `async rewrites()` in `next.config.js` mapping `/auth/:path*` and `/api/v1/:path*` to `process.env.API_ORIGIN`, plus a `lib/api.ts` base that is `''` (same-origin) in the browser and the real API origin only on the server (`typeof window === 'undefined'` gate). Add `credentials:'include'` on every browser fetch and `EventSource(path, {withCredentials:true})` for SSE — same-origin means cookies just work.

    **Enumerate EVERY prefix the browser fetches, not just the obvious two.** `/auth/*` and `/api/*` are the ones everyone remembers; an internal/admin/settings prefix (`/internal/*`, `/bff/*`) is routinely forgotten, and the symptom does not look like a proxy problem — the request hits the Next app itself and returns a **404 HTML page**, which the client surfaces as whatever its error path says ("Couldn't load your profile. Not Found"). Derive the list mechanically from the client rather than from memory:

    ```bash
    rg -oN --no-filename "fetch\\(['\"]/[^'\"]+" apps/web/app apps/web/components apps/web/lib \
      | grep -oE "/[a-z0-9-]+" | sort -u
    ```

    Any first path segment in that list which the Next app does not itself serve as a route needs a rewrite. Verify with `curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:<next-port>/<prefix>/<probe>` — a JSON content-type means the proxy is live, `text/html` means you are reading Next's 404 page.

    **`redirects()` is evaluated BEFORE `rewrites()`, so a redirect whose source sits under an API-proxied prefix silently swallows the API call.** A legacy entry like `{ source: '/auth/verify', destination: '/signin' }` turns the sign-in POST into a 307 to `/signin`: the request never reaches the API, the `Set-Cookie` it would have returned never exists, and the user bounces back to the sign-in form having entered a *valid* code. Nothing errors — the client sees a 200 from the redirected GET. This is invisible to `next build`, to `tsc`, and to every unit test; it reproduces only through the dev server.

    Rules: never add a redirect whose source collides with a path the API serves, and when adding a proxy prefix, audit the existing `redirects()` block for sources already under it. A real web page that happens to live under the prefix (`/auth/signin`) is fine — it is the API's own route names that must not be shadowed. Leave a comment at the redirect block saying so, because the next person to add a legacy redirect has no way to know. Guard it with a test that parses `next.config.js` and asserts no redirect `source` starts with a proxied prefix; config-level bugs have no other automated home.
11. **`pnpm up <pkg>@<range>` will NOT change the pin when package.json specifies an EXACT version.** A dep pinned as `"next": "15.1.3"` (no `^` / `~`) is treated by pnpm as already satisfying every range starting with `15.x`, so `pnpm up 'next@^15'` runs to completion and reports success without touching either package.json or the lockfile. To bump an exact-pinned dep: (a) hand-edit the version in package.json to a range like `"^15.5.0"` (or the exact new version if you want to stay pinned), then (b) `pnpm install` — pnpm updates the lockfile against the new spec. Verify with `grep -E "^\s+version:\s.*<pkg>" pnpm-lock.yaml` afterwards; the reported top-line and the lockfile can disagree in transient states.
12. **A dashboard's data-fetch fallback must not substitute fixture rows for an unauthenticated response.** The pattern `if (items.length === 0 && NODE_ENV !== 'production') return FIXTURES` looks harmless in Storybook, but in the real app it fires on 401 too — the server component swallows the auth error, renders fixture cards with mock IDs (`prj_MOCK1`), and the user clicks one and hits a real detail endpoint that 404s with no explanation. Distinguish the states: if `serverFetch` throws `OpenStudioApiError` with status 401, render a `Please sign in` empty-state and a link to `/auth/signin`; if it returns an empty array, render `You have no <thing> yet` with a create CTA; only fall through to fixtures in Storybook / a dedicated demo route, never in the production dashboard path. Same rule for `/dashboard/renders`, `/dashboard/series`, etc.
13. **In Next 15, dynamic-route pages and layouts receive `params` and `searchParams` as `Promise<{...}>` — the old sync destructure fails `next build` even when `tsc --noEmit` passes clean.** The build has its own `PageProps` constraint check that runs AFTER typecheck and reports `Type '{ params: {...}; searchParams: {...}; }' does not satisfy the constraint 'PageProps'`. Fix: make the page async and `await` both. Signature:
    ```tsx
    export default async function Page({
      params,
      searchParams,
    }: {
      params: Promise<{ id: string }>;
      searchParams: Promise<{ q?: string }>;
    }) {
      const { id } = await params;
      const { q } = await searchParams;
      // ...
    }
    ```
    Same for `layout.tsx`, `default.tsx`, and `loading.tsx` when they consume params. `generateStaticParams` still returns synchronous rows — only the page-function shape changed.
14. **Playwright `page.screenshot()` hangs against Next.js dev when the context has `addInitScript` set.** Adding ANY init-script (even a single-line `localStorage.setItem`) makes screenshot() time out after ~10s with `Timeout <N>ms exceeded... - taking page screenshot`. Cause: init-scripts run before Next's HMR/Fast-Refresh bootstrap and something in the handshake never resolves the paint-stable check. Without init-scripts, the same page screenshots in <1s. Consequences and workarounds:
    - For theme control, use Playwright's built-in `colorScheme: 'light' | 'dark'` on `newContext()` — that maps to `prefers-color-scheme` without touching page scripts. Works with any theme system that honours the media query (`next-themes` with `defaultTheme: 'system'`, or CSS `@media (prefers-color-scheme:dark)`).
    - For animation freezing, either use `animations: 'disabled'` on the screenshot call OR inject a `<style>` element AFTER the page has loaded (`page.addStyleTag` after `page.goto`) — do NOT use `addInitScript` for CSS.
    - Never combine `addInitScript` + `animations: 'disabled'`; they interact and both time out. Pick one.
15. **`page.screenshot()` with `fullPage:false` on a very tall Next.js dev page still crashes Chromium with a `Target crashed` error — the whole DOM is rendered even for a viewport crop.** Marketing pages that stack sections can be 6000–10000px tall. Chromium's headless renderer OOMs before the crop is taken, and the surrounding Playwright script hangs on the dead tab. Fix: pass an explicit `clip: { x:0, y:0, width, height }` matching the viewport. The clip variant tells Chromium to render only that region, not the whole document. Also: kill runaway `chrome-headless-shell` processes between runs (`pkill -f chrome-headless-shell`); a crashed tab can leave a renderer at 100% CPU / 6+GB RAM that spoils the next attempt.
16. **A `next-themes` MutationObserver that watches `<html>` class changes AND adds a class in response fires forever.** The observer sees its own added class as a mutation and re-triggers, so the guard runs on every animation frame. Compounded with a `.theming-in-progress` CSS rule using a universal selector (`html.theming-in-progress *:not(svg):not(path):not(circle):not(rect) { transition: bg,color,border,shadow 200ms }`), every re-fire restyles tens of thousands of DOM nodes on a large page. Symptom: the marketing home renders through the hero and first section, then hangs mid-paint on section 2 and eventually crashes the tab — `document.readyState` never reaches `complete`, browser probes time out on `Runtime.evaluate`. Fixes, both required:
    - **Filter the observer to real theme changes only.** Track the last known theme in a ref; only fire the guard when `dark`↔`light` actually flips, not on every class mutation:
      ```tsx
      let last = root.classList.contains("dark") ? "dark" : root.classList.contains("light") ? "light" : null;
      new MutationObserver(() => {
        const now = root.classList.contains("dark") ? "dark" : root.classList.contains("light") ? "light" : null;
        if (now && now !== last) {
          last = now;
          root.classList.add("theming-in-progress");
          setTimeout(() => root.classList.remove("theming-in-progress"), 220);
        }
      }).observe(root, { attributes: true, attributeFilter: ["class"] });
      ```
    - **Narrow the transition selector to `html` + `body`.** The cross-fade users notice is the canvas colour — leaf elements inheriting their palette via `color: var(--text)` are already covered by cascade repaint. `html.theming-in-progress, html.theming-in-progress body { transition: background-color 200ms, color 200ms }` is enough; the universal selector variant is a performance trap on any page with a few hundred nodes.

    General shape of the bug — an effect that both observes and mutates the same target — recurs whenever a class or attribute is used as both signal and side effect. If you use next-themes' `disableTransitionOnChange={false}` and want a guarded cross-fade, this exact pattern breaks it because next-themes has no "theme changed" callback to hook (only the class mutation). Wait for one to land upstream before removing the observer.

17. **A runtime VALUE imported from a `"use client"` module is a client-reference proxy on the server, not the real object.** A server component that reads a field off an imported constant gets `undefined` and dies with `Cannot read properties of undefined (reading '<field>')` pointing at a line that is obviously correct. Type-only imports (`import type { ... }`) are erased at compile time and cross the boundary fine; values do not. Two consequences:
    - **Pure-function modules must NOT carry `"use client"` just because their neighbours do.** Validation rules, serialisers, and state<->storage transforms with no hooks and no browser APIs belong on both sides. Marking one client-only makes any server page that calls it fail with `Attempted to call <fn>() from the server but <fn> is on the client.` — which reads like a bug in the function, not in a one-line directive.
    - When a server-rendered path needs defaults that also live in a `"use client"` state module, **re-declare them locally and add a client-side test asserting the two agree.** Importing the value is impossible; duplicating it silently drifts, and only a test that can see both copies catches it.
18. **`tsc --noEmit` passing is not evidence that the page compiles — the bundler has its own parser, and on a parse error the dev server keeps serving the LAST GOOD build.** The symptom is not an error: a button does nothing, no toast appears, the browser console is empty, and the server log shows no request, because the handler that would fire is in code the browser never received. Type-level checks and the SWC/Turbopack/webpack parse are separate gates, and a malformed argument list or an extra object literal can satisfy the first while failing the second. **When a UI action silently does nothing, read the dev-server log for `Syntax Error` BEFORE re-reading your handler.** Pair with rule 13: the same split exists in the other direction for `next build`.
19. **A JSON request body is untyped at the client/server boundary, so when an endpoint gains a REQUIRED field, TypeScript will not find the call sites that omit it.** Each hand-assembled `body: { ... }` object literal stays valid; the failure arrives at runtime as the server's rejection message, shown to a user who can do nothing about it. Fix the class, not the instances:
    - Route every request body for that endpoint family through ONE typed helper that injects the field and throws when it is absent, naming what was attempted — so the failure is a developer-actionable console message instead of an API error surfaced as a product fault. Write the injected field LAST in the returned object so a caller's spread cannot blank it.
    - Add a **structural test** that reads the source files in the directory and asserts no file posts to one of those endpoints without routing through the helper. Neither the compiler nor a unit test of the helper can catch a call site that simply does not use it.
    - Scope that test to the **enclosing call**, not a fixed character window: an inline handler argument (an SSE `onEvent`, a callback) can push the body literal thousands of characters past the URL string, and a window wide enough to reach it also lets one compliant call vouch for a non-compliant sibling below. Walk forward balancing brackets instead. Also assert the test FOUND call sites, or it passes by examining nothing.
    - Prefer passing such a value through context over threading a prop down several component levels; a tab or panel added later inherits the gap from its siblings and fails in front of a user rather than at compile time.

20. **One state value must not gate two unrelated activities.** A single `busy`/`loading` variable holding `"saving" | "previewing" | null`, tested as `busy !== null` on every control, means a read-only action disables the primary mutating one — pressing an audio/video preview greyed out the submit button for the length of the media. Split the state by what it GUARDS: a submit guard (prevents double-fire of something that mutates) and a playback/preview flag (mutates nothing and must never block anything). Then assert the separation, because the regression reappears the moment someone adds a third activity: for controls whose enablement cannot be reached in a headless browser (anything behind a real `play` event — autoplay is refused without a user gesture, so the gate is unreachable), read the component source in a test and assert the submit control's `disabled` expression does not reference the preview flag, plus that no combined `busy` state has returned. Check the test found both controls first, or it passes by examining nothing.

21. **Coordinate concurrent media elements through a registry, not mutual callbacks — and render durations from data you already have.** Two failures of one list of per-item `<audio controls>` players: starting item 3 while item 1 was still playing gave two voices at once, because nothing coordinated the elements; and every row showed `0:00` until played, because `preload="none"` fetches no metadata. Fixes: (a) keep ONE element for the list and have each player register a stop function in a module-scoped registry, calling `stopOthers()` before it starts — "only one thing is audible" then holds ACROSS components (a separate full-length player above the list is a different element and would otherwise play underneath), whereas passing callbacks in both directions means either side can forget; (b) if the API already returns each clip's duration, format it from that rather than switching to `preload="metadata"`, which issues one request per row on render to display numbers you were already sent. Put the registry and the formatter in a plain `.ts` module with no JSX — a vitest config that cannot parse `.tsx` from a `.ts` test reports `0 test` in a suite that looks like it passed.

## Verification checklist before saying a Next app “builds”

- `pnpm --filter <app> typecheck` clean.
- `NODE_ENV=production pnpm --filter <app> build` succeeds AND lists the expected routes (static ○ vs dynamic ƒ).
- Boot `pnpm --filter <app> dev` and `curl -s -o /dev/null -w '%{http_code}' http://localhost:PORT<path>` every user-visible route. Anything less than 200 on a route you added is a regression.
- **Grep the dev-server log for `Syntax Error` even when every route returns 200.** A parse error leaves the previous build serving, so pages render fine while your change is simply absent (rule 18).
- **Exercise the actual user action, not just the route that hosts it.** A 200 on the page proves the page loads; it says nothing about whether the button on it still posts a complete request body (rule 19). When driving the UI by visible text, disambiguate the match — a tab and its primary action button routinely share a label, and clicking the tab looks like "clicked, nothing happened".
- Kill the dev server (`lsof -i :PORT -t | xargs kill`) when done, not before verification.

## Common rationalisations

| Excuse | Reality |
|---|---|
| “The build worked in dev, the prod failure is a Next bug.” | Almost always the env or a dep, not Next. Check `NODE_ENV`, check HEAD~1, check server-chunk imports before filing an issue. |
| “I wrapped the heavy viewer in `dynamic({ ssr: false })`, that’s enough.” | It isn’t. The module is still resolved into the server graph at build time; iframe + CDN is the escape hatch. |
| “Typecheck fails on a deleted route, that’s weird.” | Not weird — stale `.next/types` shim. `rm -rf .next` and rerun. |
