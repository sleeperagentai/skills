# apps/web (Next.js 15) — browser-side pitfalls

Rules that only bite once the code runs in a real browser tab against the dev stack. `go test` and `tsc --noEmit` are both green for every trap here.

## CSP: adding a browser feature is a two-file change

`apps/web/next.config.js` ships a Content-Security-Policy header. `default-src 'self'` does NOT cascade to media/font/image/connect — each has its own directive that falls back to `default-src` only when unset. Adding an HTML5 `<audio>` / `<video>` element with a `src` on `http://localhost:9000` (MinIO) needs `media-src` on the CSP; adding a `fetch(...)` to a new origin needs `connect-src`; adding an `<img>` needs `img-src`; a `<link rel=stylesheet>` needs `style-src`.

Diagnostic tell: **empty MediaError object `{}` in the console** (`e.error` is null, `networkState`/`readyState` are 0). CSP blocks the fetch BEFORE the media element populates any error code — so the standard `code: 4 = SRC_NOT_SUPPORTED` never appears; the element just refuses silently. If a media element errors with a truly empty object and the URL is reachable via `curl` (200 OK, correct MIME, CORS headers present), assume CSP first and grep `next.config.js` for the appropriate directive before touching the media code.

Current MinIO-facing CSP shape (as of migration `00016`):

```js
const CSP = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: http://localhost:9000",
  "font-src 'self' data:",
  "media-src 'self' blob: http://localhost:9000",
  "connect-src 'self' http://localhost:4000 http://localhost:9000",
  ...
].join('; ');
```

When adding a new external origin (a CDN, a new provider, a swapped MinIO endpoint), update EVERY directive that will fetch from it — not just the one you're immediately touching. Next requires a full dev-server restart to reload `next.config.js`; HMR does not cover config-file changes.

## `next.config.js` routing: redirects run BEFORE rewrites

The single most deceptive class of bug in this app, because the build is green, `tsc --noEmit` is clean, every unit test passes, and the API is correct — the failure only exists in the dev/prod server's routing layer.

**A redirect whose `source` sits under a path the API serves swallows the request.** `/auth/*`, `/internal/*` and `/api/v1/*` are proxied to the Go API by `rewrites()`, but Next evaluates `redirects()` first. A legacy entry like `{ source: '/auth/verify', destination: '/signin' }` turns the sign-in POST into a 307 before it ever reaches the API: the API's `Set-Cookie` is never issued, the browser stores nothing, and the user lands back on the sign-in form having just entered a *valid* code. Nothing logs an error on either side.

**Every browser-side path prefix must appear in `rewrites()`.** `/internal/*` backs all of `app/(app)/settings/*` (profile, workspace, plan, notifications, developer keys). Without a rewrite those fetches resolve against the Next app itself and return a **404 HTML page**, which the client surfaces as a plausible domain error ("Couldn't load your profile. Not Found") rather than a routing bug. Diagnostic that separates the two instantly — a proxied route returns JSON, an unproxied one returns HTML:

```bash
curl -s -o /dev/null -w 'status=%{http_code} ct=%{content_type}\n' http://localhost:3001/internal/me
# proxied+unauthed → status=401 ct=application/json
# NOT proxied      → status=404 ct=text/html
```

Guard both in CI by reading `next.config.js` as text: assert no `redirects()` source starts with an API-proxied prefix (whitelisting genuine web pages such as `/auth/signin`), and assert `'/internal/:path*'` appears in `rewrites()`. Prove each guard fails against the old config before trusting it.

`next.config.js` is not covered by HMR — restart `next dev` after any change here, or you will test the previous routing table.

## HTML5 `<audio>` — cleanup race and CORS-mode trap

Two failure modes that both surface as "the play button doesn't work":

1. **`crossOrigin = "anonymous"` breaks plain playback with `NotSupportedError`.** This attribute forces CORS-mode on every range request the media element issues while streaming. MinIO answers the preflight but subsequent pipelined range requests fail the strict CORS check in Safari/Chromium and the element bails with a `play() rejected: NotSupportedError` on the promise. Only set `crossOrigin` when the audio bytes will be piped through Web Audio API or drawn to a canvas — for plain `<audio>` playback of a same-project MinIO object, leave it unset. The CSP `media-src` allowlist is the correct security layer; CORS-mode is a different (and unnecessary) layer.

2. **Reusing one `HTMLAudioElement` ref across cards races state.** When user clicks card B while card A is playing, the natural cleanup (`a.pause(); a.src = ""`) fires an async `error` event on the OLD element (because `src = ""` is an invalid URL). If that element's `onerror` handler is still attached, it calls `setPlaying(null)` — clobbering the state you just set for card B. The correct teardown order:

```ts
const stopCurrent = React.useCallback(() => {
  const a = audioRef.current;
  if (!a) return;
  a.onended = null; a.onerror = null; a.onplay = null; a.onpause = null; a.oncanplay = null;
  try { a.pause(); } catch { /* noop */ }
  a.removeAttribute("src");   // not `a.src = ""` — that fires onerror
  a.load();                    // drains any pending fetch
  audioRef.current = null;
}, []);
```

Then drive the pause/play icon from the media element's own `onplay`/`onpause`/`onended` events, not from the click handler — the icon can never lie about actual playback that way. Keep a `useRef` mirror of the currently-playing id for click-toggle logic; reading React state inside the click handler is stale by one render.

Audio source strategy: prefer a static MP3 URL (`sampleUrl` on the DB row) over `POST /live/tts` synth-on-click for previews the user hears repeatedly. The MinIO fetch is 1-2ms; the synth path burns TTS quota on every click.

## Turbopack + `next/font/google` — fallback to webpack

Next 15.5.26 with `--turbo` intermittently crashes on `Bricolage_Grotesque` / `Onest` / `Unbounded` imports with `next/font/google queries have exactly one entry` inside `<NextFontGoogleFontFileReplacer>` — a Turbopack internal that has no user-facing config. The page returns 500 on `/` while Google Fonts CDN is reachable via `curl` (rules out network). Fallback: run `next dev` without `--turbo` (webpack dev) — the same font imports work identically and HMR is only marginally slower. Package.json still ships `next dev --turbo -p 3001`; override at launch when the trap fires:

```bash
cd apps/web && npx next dev -p 3001
```

Make this the boot default for any session that needs `apps/web` up until Turbopack ships a fix; don't waste diagnostic time on `next/font/google` errors when webpack is one flag away.

## Wizard `FALLBACK_*` arrays hide missing API integrations

Wizard files (`apps/web/app/(app)/create/*/wizard.tsx`) ship with hardcoded `FALLBACK_VOICES`, `FALLBACK_PRESENTERS`, `FALLBACK_LOOKS` arrays that render if the corresponding `apiFetch` fails or is missing entirely. This makes it possible to ship a wizard that has never once called the real API — the SVG faces and archetype IDs (`presenter_scholar`, `presenter_hype`) look like a real product because the fallback data is opinionated.

When touching a wizard step, grep for the `FALLBACK_` constant AND for `apiFetch` in the same file. The user's standing rule is that app-facing fixtures do not ship: delete the `FALLBACK_*` arrays, start state as `[]`, and render a plain-words empty/error message when the fetch fails (never opinionated fake options). Then:

- If `FALLBACK_*` exists but no `apiFetch` for its endpoint exists → the wizard has NEVER consumed the API. Add the fetch before deleting the fallback, or the step becomes empty.
- If both exist → verify the fetched shape matches: the fallback often defines a subset of fields (e.g. `{id,name,description}`) while the API returns the full row (`{id,name,voiceId,sampleUrl,shortDescription,...}`). Mixing them silently drops the new fields in the fallback code path.
- The wizard's dispatched action shape (`SET_VOICE_ID`, `SET_PRESENTER`) must accept the API's ID format (real 20-char provider IDs, prefixed opaque IDs like `presenter-homer`), not just the fallback shape (`presenter_scholar`). A backend that emits `presenter-homer` while the reducer only recognises `presenter_scholar` accepts the click but writes the fallback ID into project state.

Ship verification for a wizard change is not "the UI renders" — it's "a project created through the UI carries the API-returned IDs into `POST /projects` request body, and a subsequent `GET /projects/{id}` reflects them".

## Dead affordances: menu/nav items with no destination

A menu, dropdown, or nav list whose items are built from a config array renders perfectly while doing nothing. The shape of the bug: the item type declares `href?` and `onSelect?` as OPTIONAL, the factory that builds the default items supplies neither, and the renderer calls `it.onSelect?.()` — so every click closes the menu and nothing else happens. It looks correct in Storybook, in a screenshot, and in any test that asserts the items render.

Audit any item-array-driven surface by checking that every entry has a destination, not that it renders:

```bash
rg -n 'id:\s*"' apps/web/components/overlays/account-menu.tsx   # every item
rg -n 'href:|onSelect:' apps/web/components/overlays/account-menu.tsx  # every destination
```

Unequal counts = dead rows. Then confirm each `href` resolves: collect them and check a `page.tsx` exists for each route, since a menu entry pointing at a route nobody created is a 404 the menu itself cannot reveal.

```bash
rg -oN --no-filename 'href="/[^"]*' apps/web/app apps/web/components \
  | sed 's/href="//' | cut -d'#' -f1 | sort -u
```

Related trap on the same shell: a shared surface (top bar, settings header, card header) that accepts props which duplicate work now owned by a sibling component. The identity triple on the app top bar is the canonical example — `AppTopBar` accepted `account`/`workspace` props that rendered their own avatar and workspace square, next to a sibling `<AccountMenu/>` the shell already composed. Three identity controls stood side by side; the "inert" ones looked clickable. The fix is to DELETE the props from the component's interface, not pass `undefined` or add a comment telling callers not to use them — props that still exist get re-wired by the next refactor pass or a subagent that reads the type and fills in all the fields. Pair the deletion with a one-line docstring note explaining which sibling now owns that responsibility, and update the component's stories so there is nothing to copy from.

Two rules for the fix:

- **Navigation items render as `<Link>`, not a click handler that pushes.** Use Radix's `asChild` (`<DropdownMenu.Item asChild><Link href=...>`) so middle-click, cmd-click, "open in new tab", and hover-preview all behave like links. A handler calling `router.push` silently breaks every one of those.
- **Sign-out needs a full document navigation, not `router.push`.** After the logout POST clears the cookie, a client-side push keeps the React tree — and its already-fetched session data — mounted, so the UI still shows the signed-in user until a manual reload. Use `window.location.assign("/")` so the server re-evaluates auth from scratch. Guard the handler with an in-flight flag; a double-click fires two logout requests and the second races the redirect.

## Config-gated UI must ask the API what is enabled

An affordance for a feature that depends on server-side configuration (an OAuth provider, a paid integration) must not be rendered unconditionally. If the backend returns `501 Not Implemented` when unconfigured, a hardcoded button sends users into a dead end with no recoverable error. Expose a small capability probe (`GET /auth/providers` → `{"email":true,"google":false}`), fetch it on mount, and render the affordance only when the capability is true. This also means the button starts working the moment credentials are added, with no frontend change.

## A fetch without a status check turns a 404 into a convincing success

`try { await fetch(url, ...) } finally { setBusy(false) }` — with no `res.ok` branch — advances the UI on a 404, a 500, or an error response body. On a sign-in form this is maximally deceptive: the user sees "Check your email" and waits for a code that was never issued, and the frontend reports no error anywhere. Every `fetch`/`apiFetch` in a flow that gates a UI transition must check `res.ok`, surface the server's message in an error element rendered near the control, and leave the user on the current step. `tsc` cannot catch this; only reading the handler or exercising the real failure does.

## HTML5 `<video>` previews — hover-to-play pattern

Catalog grids (Look tiles, template picker, variant swatches, Library thumbnails) benefit from a real motion preview instead of a static poster. The correct shape: `<video muted playsInline loop preload="metadata">` inside the card, with playback started on `mouseenter`/`focus` and stopped on `mouseleave`/`blur`. Requirements:

- **`muted` is mandatory for autoplay.** Every browser (Safari, Chrome, Firefox) blocks `.play()` on an audio-carrying element without a user gesture; the mute attribute is the only way to get a hover autoplay through. If the preview needs audio, gate the unmute on a separate click — do not try to unmute inside the hover handler.
- **`playsInline` is required on iOS.** Without it, Safari on iOS enters fullscreen playback the moment the element starts, which is the wrong UX for a grid card. The desktop tell that this is wrong is muted playback works; the iOS tell is fullscreen takeover — test both.
- **`preload="metadata"`, not `"auto"`.** A grid of 8 look cards with `preload="auto"` starts 8 background byte fetches on page load — every one of them ends up in the browser network waterfall competing with the actual page. `preload="metadata"` fetches only the moov atom (dimensions, duration) so the element has enough shape to render the poster frame; the actual bytes only stream on hover. On a slow connection this is the difference between a snappy grid and a stalled one.
- **Reset `currentTime` on both ends of the interaction.** `v.currentTime = 0; v.play()` on hover, `v.pause(); v.currentTime = 0` on leave — otherwise repeated hovers resume mid-clip and the loop point jitters. A ref-per-video (or a `querySelector('video[data-library-video]')` on the card container keyed by a `data-*` attribute) is enough; no state hook needed since the media element owns the current-time. Catch the `.play()` promise rejection — browser autoplay-policy denials are not errors to surface, they're normal when the user hovers before the first user gesture on the page.
- **Catch `AbortError` on `.play().catch(…)`.** Hovering fast enough to trigger a leave before `.play()` resolves rejects with `AbortError`. Swallow it; it is normal flow, not a load failure.
- **The `<video>` must be `pointer-events-none` under the overlay layer.** Native video controls auto-render only when `controls` is set, but the element still catches events — if clicks land on it instead of the parent `<Link>`, the card stops routing. Keep the thumbnail `<video>` strictly presentational; use the parent card as the single click surface.

Detect video URLs by extension (`.mp4 | .webm | .mov`) inside the card component and fall back to `<img>` for image URLs — a component that used to take `poster: string` for image previews can grow the video branch as a conditional without changing its API. See the `LookCard` `isVideoUrl` helper in `apps/web/components/media/look-card.tsx` for the canonical form.

CSP: `<video src="http://localhost:9000/...">` uses `media-src`, not `img-src` or `connect-src`. The MinIO-facing CSP shape above already includes `media-src`; when adding a new video-serving origin (a CDN, staging MinIO), extend `media-src` too or the video silently fails to load with an empty `MediaError` (see the audio section above — the diagnostic is identical for video).

## Tailwind tokens: only use what `tailwind.config.js` actually defines

`apps/web/tailwind.config.js` extends the palette with these surface-family names: `canvas`, `surface`, `surface-2`, `hairline`, `ink`, `ink-dim`, `ink-mute`, `accent`, `accent-ink`, `accent-soft`, plus the semantic aliases (`background`, `foreground`, `card`, `popover`, `primary`, `secondary`, `muted`, `destructive`, `border`, `input`, `ring`). **`surface-0`, `surface-1`, `surface-3` are NOT in the config.** Classes like `bg-surface-0`, `bg-surface-1`, `border-surface-1` compile — Tailwind just emits no rule for them — so the element paints transparent, which reads in review as “layout is broken, cards overlap, columns bleed into each other.” `tsc --noEmit` is green, `pnpm lint` is green, Storybook renders fine against surrounding `--canvas`; the bug only shows against the real page.

Subagents writing new UI consistently invent `surface-0`/`surface-1` from pattern guessing. Mitigations:

- When dispatching a UI subagent, list the exact allowed surface names in `context` (quote them from `tailwind.config.js`) and tell it to map intents explicitly: page background → `canvas`, card/panel → `surface`, elevated/overlay → `surface-2`.
- Audit after any new UI lands: `rg -nE 'bg-surface-[013]|border-surface-[013]|text-surface-[013]' apps/web/{app,components}` must return zero. Repair with sed: `surface-0` → `canvas`, `surface-1` → `surface` (there is no `surface-3`).
- The `.surface-1` CSS class in `app/globals.css` is a legacy utility class, NOT a Tailwind token — `className="surface-1"` works, `className="bg-surface-1"` does not. Don’t rely on either in new code; use `bg-surface`.

## Design system source of truth

`apps/web/DESIGN.md` is gone — it was a pre-Riso snapshot that drifted into direct conflict with shipped code (claimed signal-green accent + Geist-only + fully-neutral neutrals while every page uses Riso-pink, Bricolage display, and mint-tinted neutrals) and the user deleted it. Do not recreate it from memory and do not resurrect findings written against it.

The authoritative design system now lives in two places that agree with each other by construction:

- `apps/web/styles/tokens.css` — every colour, radius, shadow, motion and type token. Nothing in a component reads for colour, type or shadow outside this file; a `bg-emerald-500` or raw `#…` / `oklch(...)` literal in a component is the review finding, not the design.
- `apps/web/docs/design/openstudio-riso-design-boards/*.dc.html` — 16 Riso design boards (DSColor, DSType, DSFoundations, DSComponents1/2, DSMedia, DSMore, DSNotify, each with a `Dark` variant). `tokens.css` cites them by filename in its header; they are the visual spec the tokens are derived from.

When auditing a page against "the design system", compare it to the token names used (not raw colours) and spot-check the matching board for shape/spacing/shadow motifs (sticker-shadow CTAs, Bricolage display headings, mint/pink/dark triplet). If a reviewer flags "wrong colour" based on a doc other than tokens.css + the boards, the doc is wrong — fix the audit, not the component.

Parallel UI audits: split by surface (shell+overlays / create+library+videos / everything else) rather than by file type, give each child the exact token names from tokens.css and the forbidden list (raw hex, raw Tailwind palette, arbitrary `text-[Npx]` outside the pinned scale, model/vendor knobs leaking into chrome), have each write ONE markdown report to a scratch dir. Three disjoint reports consolidate cleanly; a single sweeping child hits its iteration cap before finishing the second surface. If the user has their Claude design artifact exported as HTML bundles (e.g. `openstudio-designs/*.html`), each file is an SPA with 3 empty divs — the real board content lives inside `<section class="board"><iframe src="blob:null/...">`. The parent cannot access `contentDocument` (opaque origin) but CAN `fetch(iframe.src)` to get each board's full HTML, then open each extracted file in a fresh tab to let its runtime render; dump `document.body.innerText` for text, `document.documentElement.outerHTML` for structure. Feed the extracted dir to subagents as the authoritative input alongside tokens.css.

### Riso primitives vs shadcn — wrong-ancestry pages

The repo ships two parallel primitive sets:
- `components/ui/riso/*` — Riso: `border-2 border-[color:var(--text)]`, 16–20px radii, `shadow-[6px_6px_0_var(--accent)]` offset shadows, uppercase badge chips. This is the design.
- `components/ui/*` (plain) — shadcn: `rounded-sm`, 1px hairline borders, muted/outline badge variants, admin-table chrome.

A page importing `@/components/ui/{dialog,input,select,badge,button}` instead of the `riso/` siblings paints visually off even though every colour comes from a token and every test passes. The visual tell is "SaaS admin panel" chrome where Riso wants "creative tool" chrome. Grep before merging a new page:

```bash
rg -nE '@/components/ui/(dialog|input|select|badge|button)(["/]|$)' apps/web/app apps/web/components
```

Every hit is either a legacy page waiting for conversion or a new regression. Fix is mechanical: swap imports to `riso/{overlays,input,select,badge,button}` (Riso `Dialog` takes `trigger`/`title`/`footer` props, not `DialogHeader`/`DialogContent` subcomponents; Riso `Select` takes an `items={[{value,label}]}` array, not `SelectTrigger`/`SelectContent` children), rewrite cards as `rounded-[20px] border-2 border-[color:var(--text)] bg-[color:var(--surface)]` with `shadow-[6px_6px_0_var(--accent)]` on primary surfaces, and drop any `rounded-md`/`rounded-sm`/`border border-hairline` chrome on interactive surfaces. The Riso scrim and dialog shadow come from the overlay primitive — do not restyle them per page.

### Decorative non-palette colours — promote to tokens, do not inline

When a surface needs a colour that is not in the semantic palette — a yellowed poster paper for a preview card, a mint head glyph on a sticker, a fabricated navy balance card — the fix is NOT an inline `oklch(...)` or `#hex` on the component. Add a named token to `styles/tokens.css` with both the light-mode (`:root`) and dark-mode (`:root.dark` AND the `@media (prefers-color-scheme: dark)` block) values, then reference it via `bg-[color:var(--your-token)]` or `style={{ fill: 'var(--your-token)' }}`. Pattern used in-tree: `--preview-paper` + `--preview-head` for the SummaryAside preview card. Inline oklch literals cost a theme-independence bug when the component is reviewed in the other mode (the user runs both); every raw colour in a component also fails the standing "no raw colour literals" review rule.

When the decorative palette grows to ≥5 tokens, group them under a prefix (`--preview-*`, `--card-*`, `--chip-*`) so the dark-mode block stays readable — but each still gets its own `--name` entry in all three token blocks. Never set only the light value; the dark block's missing entry inherits whatever the previous `:root` scope resolved to, which is almost never what you want on dark.

### Fixing an audit finding whose root cause is in Go, not the component

A UI audit that stops at "backend-dependent, nothing to fix in web" is a half-finished pass — the user treats the audit as a task on the whole stack, not on `apps/web`. When a finding needs a field the API doesn't return, a column the schema doesn't have, or a route that doesn't exist, add the migration + store method + handler + wire the UI in the SAME session unless the user has explicitly scoped you to one domain. The standard sequence:

1. Grep `services/db/migrations/` for the table and `apps/api/*.go` for the handler before concluding anything is missing — the schema often already has what you need (e.g. `content.series_episodes` existed when the audit flagged "no episodes endpoint"; only the API handler was missing).
2. If a column is missing, add it as JSONB when there are 2+ related fields coming (`defaults_json` instead of three columns for voiceId/lookId/shape) — later additions don't need a new migration per field.
3. If the LATERAL subquery in `store/lists.go::ListProjects` already selects a row, adding ONE more column from it (e.g. `latest.progress`) is a 3-line change: extend the SELECT, extend the struct, extend the `Scan`. Project-level fields that let the UI avoid a per-row GET belong here.
4. Apply the migration against the live dev DB (`cd services/db && goose -dir migrations postgres "$DSN" up`) before writing the Go code that reads the new column — a failing migration beats a failing test.
5. Run `go test -count=1 ./services/db/store/... ./apps/api/...` with the migrated DB, then `tsc --noEmit` + `vitest run` on web, then one commit for the whole slice. The user wants one coherent diff over the stack, not three.

What to NOT do: don't invent a `GAP(api-field-missing)` note and move on, don't leave the frontend using a hardcoded placeholder with a `TODO`, don't close the audit finding as "needs backend work" without actually doing that work. Audit findings close by shipping; a GAP note is a scar from a session that ran out of budget.

### Phase-3 rename-sweep canaries

The Riso micro-copy pass renamed the primary verbs, but earlier doc copy leaked into prose, headings and tab labels. These are the strings to grep before shipping any UI change — all pass typecheck:

- `"Make"` as a NAV LABEL — Riso nav uses `Create`; `Make` is the verb on the primary button only. Grep rails/tabs/palette entries.
- `"Advanced"` as a settings tab — Riso labels it `Developers` (API keys + webhooks + connections). The URL stays `/settings/developers`; only the tab/heading/function name change.
- `"Edit & make a new version"` on the project page — Riso says `Make another like this`.
- `"That one didn’t finish"` on a failed render — Riso says `That one didn’t work` + `It wasn’t anything you did. Try again, or pick a different voice.`
- Leaked rename-map prose that looks like UI copy: `"Have a look. Price shown automatically → Make video."` and similar `A → B` sentences. These are rename-map transcriptions accidentally rendered.
- `"What kind of video?"` — Riso says `What do you want to make?` + a one-sentence lead-in that previews the four input modes.
- Script tab labels — Riso: `An idea / My words / A link / A document`. Earlier variants (`Write it for me / I have my words / Give me a link / Attach a PDF`) read as instructions, not nouns.

One grep per release:
```bash
rg -nE 'Make a video|Advanced|Edit & make|didn.t finish|Price shown automatically|What kind of video|Write it for me|I have my words|Give me a link|Attach a PDF' apps/web/app apps/web/components
```
Strip every hit that is user-facing (nav label, heading, button, inline prose). Server-side nouns (`template` as an API field) stay — they are not UI copy.

## `useSearchParams()` / `useParams()` MUST be wrapped in `<Suspense>`

Next 15 App Router: any client component (`"use client"`) that calls `useSearchParams()` at the top level suspends during prerender. Production build fails with:

```
Error: useSearchParams() should be wrapped in a suspense boundary at page "/<route>"
```

`tsc --noEmit` is green; `pnpm dev` renders fine; only `pnpm build` (prerender pass) catches it. Diagnostic tell: the error names a client-only route AND the stack trace points at Next's `prerender` worker, not the component.

**Fix shape — do NOT put the hook inside the default export.** Rename the component to `<Name>Inner`, keep its body unchanged, and make the default export a thin `<React.Suspense fallback=...>` wrapper:

```tsx
function InviteAcceptInner() {
  const params = useSearchParams();
  // ...
}

// Fallback MUST render the exact same shell as the loading state of the
// loaded component — same <main> classes, same card classes, same heading,
// same copy — or the Suspense swap flashes a different layout on hydration.
function InviteAcceptFallback() { /* mirror the status === "loading" branch */ }

export default function InviteAcceptPage() {
  return (
    <React.Suspense fallback={<InviteAcceptFallback />}>
      <InviteAcceptInner />
    </React.Suspense>
  );
}
```

`useRouter()` does NOT suspend. Server components that destructure `{ searchParams }` as a prop do NOT need Suspense — the hook is the trigger, not the concept.

Audit before accepting a new page: `rg -nE 'useSearchParams|useParams' apps/web/app` — every hit on a client component must have a Suspense ancestor. The parent layout IS allowed to supply it, but a page-level wrap is the common form and reads clearest in review.

## Sentry source-map upload — `OPENSTUDIO_VERSION` MUST be inlined into the browser bundle

`@sentry/nextjs`'s `withSentryConfig` uploads client source maps under a `release.name` computed in `next.config.js` (CI reads `OPENSTUDIO_VERSION`, so the release is tagged `web@<github.sha>`). The client-side `sentry.client.config.ts` tags events with its own `release` string — also read from `process.env.OPENSTUDIO_VERSION`.

**Next.js does NOT inline a bare `process.env.FOO` into the client bundle unless FOO is prefixed `NEXT_PUBLIC_` OR declared in `next.config.js`'s `env:` block.** A plain `OPENSTUDIO_VERSION` set in the CI env substitutes to `undefined` in the browser, so client events ship tagged `web@0.0.0` while the uploaded maps live under `web@<sha>` — the symbolicator never finds them and client stack traces stay minified. The bug is silent: Sentry quietly fails to resolve and shows the minified frames; nothing errors.

Add to `next.config.js` `env:`:

```js
env: {
  OPENSTUDIO_VERSION: process.env.OPENSTUDIO_VERSION ?? '0.0.0',
  OPENSTUDIO_ENV: process.env.OPENSTUDIO_ENV ?? 'development',
},
```

Runtime side: Fly/Vercel MUST also set `OPENSTUDIO_VERSION` to the same value used at build time (CI pins to `github.sha`) so server-side Sentry events tag the same release. Omit this and server events default to `web@0.0.0`, same mismatch.

### CI gating — upload only on main-branch pushes

A job-level `SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}` on the Node CI job uploads a release per PR commit — pollutes the Sentry releases list and burns org artifact quota. Gate it on the branch:

```yaml
SENTRY_AUTH_TOKEN: ${{ (github.event_name == 'push' && github.ref == 'refs/heads/main' && secrets.SENTRY_AUTH_TOKEN) || '' }}
```

Fork PRs ALSO lose the secret (GitHub strips secrets from forked PR runs), so the plugin falls through to `sourcemaps.disable=true` (`!process.env.SENTRY_AUTH_TOKEN`) and the build still succeeds — just without upload.

### `deleteSourcemapsAfterUpload: false`, let `.gitignore` / `.dockerignore` carry the leakage guard

`sourcemaps.deleteSourcemapsAfterUpload: true` deletes the local `.map` files after the plugin thinks upload succeeded. A partial upload failure (network blip, scope drift, rate-limit) with deletion ON leaves an incomplete release AND no retry path — the maps are gone and CI is ephemeral. Keep deletion OFF and rely on `.next` being in `.gitignore` + `**/*.map` in a future `.dockerignore` so the maps don't ship to production anyway.

### Release name fallback — dev sentinel, not `web@0.0.0`

`release.name: \`web@\${process.env.OPENSTUDIO_VERSION ?? "0.0.0"}\`` means every local `pnpm build` with the token set clobbers the shared `web@0.0.0` release on every laptop upload. Use a dev-only sentinel instead:

```js
release: {
  name: process.env.OPENSTUDIO_VERSION
    ? `web@${process.env.OPENSTUDIO_VERSION}`
    : `web@dev-${Date.now()}`,
},
```

### Token scopes

The `SENTRY_AUTH_TOKEN` secret must be a Sentry USER auth token (not an org token) with at least:
- `project:releases` — release create + artifact upload
- `project:read` — plugin project lookup
- `org:read` — required for `@sentry/nextjs` v8+'s debug-id / artifact-bundle path

## Design tokens on dark overlay surfaces — use theme-independent colors

`--canvas` and `--text` INVERT between light and dark modes:

- `--canvas` = mint `oklch(0.96 …)` in light mode, dark navy `oklch(0.22 …)` in dark mode (defined in `apps/web/styles/tokens.css`).
- `--text` is the paired ink — navy in light, mint in dark.
- `--scrim` is dark navy with alpha in **both** themes (it is a scrim, not a surface — its contract is "darken whatever is beneath", so it stays dark).

Media chrome and overlays also sit on theme-independent dark backdrops: the `<video>` control-bar gradient (`bg-gradient-to-t from-black/…`), the Library thumbnail scrim, Error/Buffering/Ended overlays over `--scrim`. The foreground on those surfaces is dark in BOTH themes, so **the chrome must use `text-white` / `border-white`, never `--canvas`.** Using `--canvas` renders fine in light mode (mint on dark reads correctly) and vanishes in dark mode (navy on navy is invisible) — a bug class that only surfaces when a reviewer actually toggles the theme on the running app.

The rule, stated as a predicate on the surface:

- Backdrop varies with theme (e.g. `bg-[color:var(--surface-2)]`, `bg-[color:var(--canvas)]`) → use theme-tracking foreground (`text-ink`, `text-[color:var(--text)]`). The pair flips together and stays legible.
- Backdrop is theme-independent dark (hard-coded `black/XX` gradients, `--scrim`, baked media) → use theme-independent light foreground (`text-white`, `border-white`, `bg-white` for pill backgrounds). YouTube/Vimeo convention and the only shape that reads in both themes.

Affected components to audit when touching chrome: `components/media/video-player.tsx` (control bar, state overlays, Try-again button border, center Play/Replay ring borders, hover-preview pill), any card that overlays a `<video>` thumbnail (Library grid, Look cards). A quick grep for the trap:

```bash
rg -n 'bg-\[color:var\(--scrim\)\].*text-\[color:var\(--canvas\)\]|from-black.*text-\[color:var\(--canvas\)\]' apps/web
rg -n 'border-\[color:var\(--canvas\)\]' apps/web  # ring borders on dark buttons
```

Verify every change by toggling `document.documentElement.classList` between `light` and `dark` in Storybook's iframe view (`/iframe.html?id=…`) — the toplevel Storybook chrome's "light theme" toggle is Storybook's own theme, not the app's token switcher.

## Destructive confirmations use the Riso ConfirmDialog, never `window.confirm`

`window.confirm()` is modal in a way that blocks every browser tab, paints
in the browser's native chrome (so colours, fonts, focus ring and shadow
all diverge from the Riso surface), has no customisable buttons (OK /
Cancel only — no "Delete" verb, no destructive styling), serialises badly
on mobile, and can be suppressed by the user on repeat prompts. A product
for non-technical users cannot ship a destructive action behind a modal
that looks like someone else's app.

**Rule.** Every destructive or otherwise consequential confirmation goes
through `useConfirm()` from `components/ui/riso/confirm-dialog.tsx` —
never `window.confirm`. The provider is mounted once in `app/layout.tsx`
around `<Toaster/>` + `{children}`; call sites stay one-liners:

```tsx
const confirm = useConfirm();
// ...
const ok = await confirm({
  title: "Delete this video?",
  description: "Every version of this video goes with it. This can’t be undone.",
  confirmLabel: "Delete",
  tone: "destructive",
});
if (!ok) return;
```

**Shape rules the dialog enforces (don't rebuild them per site):**

- `tone: "destructive"` maps to the `destructive` Button variant (danger
  fill); `tone: "primary"` to the `primary` Button variant.
- Cancel button is `secondary` and autofocused — Escape and Enter both
  cancel by default, so a reflexive keypress never deletes. Only after
  the user tabs to the confirm button does Enter trigger the destructive
  action.
- Backdrop click, Escape, and the close X all resolve the promise with
  `false`. There is no "close without choosing" state; the awaiter
  always gets a boolean.

**Pin invariants with a grep in review.** The rule only holds if nothing
ever slips back:

```bash
rg -nE '\bwindow\.confirm\b' apps/web/app apps/web/components
```

Must return nothing but hits inside `confirm-dialog.tsx` (the doc comment
references `window.confirm` to explain what it replaces — those are fine).
A new site that reaches for `window.confirm` because the author doesn't
know about the hook is the common failure mode; the grep catches it.

**Why imperative-via-hook, not a `<ConfirmDialog open=...>` component.**
An imperative `await confirm({...})` keeps the destructive branch and
the guarded action in ONE function, in order — the Riso dialog state
still lives in a real React tree inside `ConfirmProvider` so focus,
portal and ARIA are handled by Radix. A per-site `<ConfirmDialog/>`
invariably collects local open-state + "what action was this?" plumbing
that gets forgotten on the second instance; the hook keeps the common
case a one-liner.

## Hydrating a wizard / builder from a server-chosen draft (`?draft=<id>&target=<kind>`)

When one feature produces a payload another form consumes (Ideas → New-X convert flow, template → fresh project, duplicate-and-edit), the payload rides on query params and the destination page prefills from them. The naive shape — client component with `useSearchParams()`, `useEffect` that fetches, N `setState` calls to prefill — ships fast, triggers the Suspense wrap trap above, cannot be unit tested without jsdom, and buries the field mapping inside a 1000-line wizard. Three rules make this pattern reusable across wizards.

**Fetch the draft on the SERVER, inside the page.tsx.** The destination route's `page.tsx` already receives `{ searchParams }` as an async prop in Next 15; call `serverFetch<DraftResponse>('/api/v1/ideas/:id/draft?target=:target')` there, build the initial state once, and pass it as a prop to the client wizard. One round-trip in the SSR pass, no client-side spinner for the prefill, no `useSearchParams()` + Suspense dance for the draft payload itself. The wizard still uses `useSearchParams()` only to read the IDs it needs to echo back later (the `draftIdeaId` for the ledger POST).

**Put the mapping in a pure sibling module named `<feature>-hydration.ts`.** The payload-to-WizardState (or payload-to-FormDefaults) translation is the entire interesting part — field preference between target shapes (project `title` vs video `title`; project `hook` vs video `angle`; description as fallback), empty-string joiners, clamping of numeric ranges, enum coercion. Export two functions: `buildInitialStateFromDraftPayload(payload)` returning the full state slice, and small clampers / coercers (`clampTargetSeconds`, `pickKind`) as named exports so the test can hit them directly. `page.tsx` and `<feature>-hydration.test.ts` both import from it; the wizard stays untouched. One pattern in-tree is `apps/web/app/(app)/create/motion-graphics/idea-draft-hydration.ts` + its vitest file — mirror its shape for cinematic and captioned when they get hydration.

**Record the conversion from the SUCCESS path, not the mount path.** The ledger POST (`POST /api/v1/ideas/:id/conversions` with `{target, targetId}`) belongs AFTER the `created.id` comes back from the create-draft call and BEFORE `router.push`. Mount-time registration double-counts on refresh and attaches a conversion to a project that never saved; success-path registration ties the conversion to a real `targetId`. Guard with `if (draftIdeaId)` so plain users (no `?draft=`) stay on the normal path, and swallow the ledger error (`.catch(() => {})`) — a 500 on the ledger must not block navigation to the just-created project.

**Pitfalls specific to this shape.**

- vitest in `apps/web` cannot run tests that import `.tsx` from a module path crossing the Suspense boundary (see the oxc/jsx rule later in this file). Keep the hydration module pure `.ts` — no JSX, no `use client` — so the test file can be plain `.test.ts` and runs under node, not happy-dom.
- The draft-cache GET must agree with the POST on which message is "last" (ORDER BY ASC + `msgs[len-1]` on both sides, not `msgs[0]` on GET). Covered by the Go handler's regression test; mentioned here because the wizard side will 404 silently if they diverge again, and the UI symptom is "the first time I open the wizard it works; the second time my prefill is gone".
- The `/create` picker page is a server component with `searchParams: Promise<{...}>` — `await searchParams` once, then read fields. A client-component picker that reads via `useSearchParams()` loses the server-side draft fetch and forces the Suspense wrap for no benefit.
- When a payload field drives a client-side identifier used for routing or highlighting (the picker's "Suggested" chip reads `payload.kind` and matches against enabled route slugs), the enum rule under "Non-technical product rules" applies to the generating prompt — do not let the model emit a slug the picker's route table has never heard of.

## Multi-step wizard flow gating

A wizard whose Next button is always enabled is not a flow — it is five pages the user can skip through, arriving at Review with no voice, no look and no script, then posting a project the API rejects on a field they were never asked for. Three rules, learned the hard way:

**Flow rules live in pure functions, not in JSX.** Put `WIZARD_STEPS`, a `requirements(state)` predicate per step, and a `canAdvance(state, step)` in a sibling `wizard-flow.ts`, and have the component call them. Rules embedded in `disabled={...}` expressions cannot be unit-tested, and the tests that matter assert the RULES ("Review is unreachable until audio is reviewed") rather than whether a button happens to be greyed out.

**One source of truth, or the step list and the validator drift.** The wizard had its own local `STEPS` array that did not include a newly added step, plus its own `validate()` that disagreed with the shared rules about which fields a generated script needs. Both rendered fine. Whenever a step is added, grep the wizard for a second `STEPS`/`validate` definition and collapse it onto the shared module — duplicated flow definitions fail by disagreeing, not by erroring.

**Say WHY Next is disabled, next to the button.** A disabled control with no reason reads as a broken app. Surface the unmet requirement as text beside it.

## Streaming LLM output into the UI (SSE over POST)

`EventSource` is unusable here: it is GET-only and cannot send an `Authorization` header or a JSON body. Consume the stream with `fetch` + `body.getReader()` instead — see `apps/web/lib/sse.ts`.

- **Buffer across chunk boundaries.** A TCP chunk is not an SSE frame; a frame routinely splits mid-JSON. Treating each chunk as a frame works in local testing (small fast responses) and drops text in production. Accumulate into a string, split on `\n\n`, and keep the trailing partial for the next read.
- **The terminal `done` event REPLACES the accumulated deltas — it does not append.** Deltas carry raw model output including markdown scaffolding (`## Hook`, `**bold**`); `done` carries the cleaned text. A client that keeps its accumulated deltas displays the markdown and, worse, hands it to TTS, which reads "hashtag hashtag hook" aloud.
- **Handle a `notice` event for providers that cannot stream.** Streaming is an optional capability, so a non-streaming provider sends a notice and then one final payload. Without handling it the spinner reads as a stall instead of a deliberate wait.
- **Give the user a Stop button** (`AbortController`), and treat an abort as a normal outcome rather than an error.

## Review gates must observe the real event, not the user's intent

When a step requires the user to actually inspect an artifact before an expensive irreversible stage, derive the flag from the artifact's own event — for audio, the media element's `play` event, not the click handler on your play button. A click handler fires even when playback fails (CSP, 404, decode error), so the gate certifies a listen that never happened.

Invalidation is the half that gets forgotten. Clear the reviewed flag when the inputs change AND when the artifact is regenerated — without the regenerate case, the user approves take 1, regenerates, and ships take 2 unheard. Distinguish `generated` from `reviewed` in the state machine; collapsing them re-opens the hole the gate exists to close.

## Presenter+voice bundle coupling (product invariant)

A Cast character on `content.characters` (with `is_presenter=TRUE`) MUST carry a `voice_id`; enforced by the `presenter_needs_voice` CHECK constraint in migration `00014`. The UI has two coupling responsibilities on top of that:

- Wizard: selecting a presenter tile must dispatch BOTH `SET_PRESENTER` (with the presenter ID) AND `SET_VOICE_ID` (with `presenter.voiceId`). Leaving the voice picker enabled while a presenter is selected lets the user pick Homer's face + Female Bright voice — the DB accepts it because the coupling isn't enforced at the render-input layer.
- `/cast` page: standalone Voices tab must hide the 7 character-bundled voices (filter out IDs present in `presenters.map(p => p.voiceId)`). Otherwise the same Homer voice appears in both tabs and it looks like the character voice is separately usable — undermining the bundling promise the wizard is enforcing.

The `characterVoiceAliases` map in `services/ai-gateway/elevenlabstts/elevenlabstts.go` mirrors this at the adapter layer: character aliases (`voice_seed_homer` et al) beat `ELEVENLABS_DEFAULT_VOICE_ID`, so pinning an operator default doesn't collapse every character to the same voice. Stock voice aliases (`voice_seed_narrator`, `voice_seed_male_std`) still defer to the default.

## Testing a Radix `Dialog` and file uploads under happy-dom

- **Radix Dialog works in happy-dom, but it sets `aria-hidden` on everything outside the portal while open.** `screen.getByRole("radiogroup", { name })` for the page behind the dialog then throws "Unable to find an accessible element". Pass `{ hidden: true }` to queries that reach past an open dialog (and to the `within(...)` chain beneath them); queries inside `screen.getByRole("dialog")` need nothing special.
- **`fireEvent.change(input, { target: { files: [file] } })` is enough to drive `<input type=file>` in happy-dom** — no `DataTransfer` needed. Wrap it in `await act(async () => …)` when the handler awaits (shrink → upload) and `waitFor` the next visible state.
- **Canvas is absent in happy-dom** (`canvas.getContext` is not a function), so a client-side downscale helper must return the original file untouched when it cannot draw, and the test should assert exactly that — otherwise the upload path is untestable.
- **Mock `lib/api` with `importOriginal` and keep `OpenStudioApiError` real:** `vi.mock("@/lib/api", async (orig) => ({ ...(await orig()), apiFetch: vi.fn(), apiUpload: vi.fn() }))`. Tests then build real error instances to exercise the "server sentence vs plain fallback" branch, and `instanceof` checks in the component still hold.
- **Unit-test an XHR-based upload helper by stubbing `XMLHttpRequest` with a plain constructor function** (`vi.stubGlobal`) exposing only the members the helper touches (`open/send/setRequestHeader/getResponseHeader/upload.onprogress/onload/status/responseText/withCredentials`). Subclassing the real XHR fights TypeScript over readonly `status`/`responseText` and `this` typing on `upload`; the plain object is shorter and type-safe. Same trick works in a Storybook `play` to fake a 201.

## vitest cannot parse `.tsx` tests until oxc is told the JSX runtime

vite 8 transforms with oxc and ignores `@vitejs/plugin-react`'s esbuild `jsx: automatic`, falling back to tsconfig's `jsx: preserve`; vitest then fails every `*.test.tsx` with "Failed to parse source … make sure to not set jsx to preserve". Pure `.ts` tests pass, so the trap stays latent until the first component test lands. `apps/web/vitest.config.ts` carries `oxc: { jsx: { runtime: "automatic" } }` for this reason — keep it when touching the config, and add the same line to any new vitest project in the monorepo. Stories under `app/**` need their own glob in `.storybook/main.ts` (`../app/**/*.stories.@(ts|tsx|mdx)`); the default only scans `components/` and `stories/`.

## Visual assets from subagents: look before you commit

SVG/illustration/glyph work produced by a subagent is only "done" after someone has SEEN it rendered at the size it ships. Code that typechecks and passes "renders without throwing" tests can still draw hair as a beanie and bodies as dress forms. Procedure: the child renders every asset to a contact-sheet PNG (react-dom/server → `.svg` → `rsvg-convert`/`sharp`) and inspects it with vision before committing; the orchestrator then screenshots the live page per group, saves the PNGs to scratch, and dispatches an art-pass child WITH those screenshots in `images` and a numbered list of what reads wrong. Riso style rules for new illustrations: viewBox `0 0 96 96`, 2px `currentColor` strokes with `vector-effect: non-scaling-stroke`, fills only `var(--accent-soft)` or `currentColor` at ≤0.4 opacity, no gradients, one shared head/torso helper so a set reads as one family; must survive the selected-tile inversion (dark ink on light bg).

## Picker / builder pages — review checklist

The adversarial reviewer finds the same five things on every swatch/tile chooser; check them before dispatching the review.

- **Never index a plain object literal with an API-supplied string.** `GLYPHS[name]` walks the prototype chain: `"__proto__"` / `"constructor"` come back as functions and the render throws, so a bad options payload blanks the whole client page. Guard with `Object.prototype.hasOwnProperty.call` (or build the table with `Object.create(null)` / a `Map`) and put the prototype names in the unknown-name test.
- **Render responsive variants once, not twice.** `md:hidden` + `hidden md:flex` copies of the same form section leave two `<input id>`s and two `aria-live` regions in the DOM — screen readers announce every change twice and `getByLabel` hits strict-mode violations. Render the section once and reposition it with grid/`order-*`; the only duplicate allowed is a purely visual echo marked `aria-hidden`.
- **Anything sticky inside the app shell must clear the shell's own sticky chrome.** The desktop top bar is `sticky top-0 z-30` (~78px) and the rail is `sticky top-0 h-screen self-start`; a summary aside with `md:sticky md:top-6` pins correctly in Storybook and slides under the top bar in the real app. `AppShell` publishes `--app-top` on the scrolling column — stick with `md:top-[calc(var(--app-top,0px)+1.5rem)]`, never a hard-coded `top-N`, and cap the card with `md:max-h-[calc(100vh-var(--app-top,0px)-3rem)] md:overflow-y-auto` so it still pins on short windows (a sticky element taller than the viewport scrolls away with the page). Probe in the browser after `scrollTo(0, 800)`: `aside.getBoundingClientRect().top` must equal the top bar's `bottom` + margin. The same rule applies to the Motion Graphics `SummaryAside` — fix the token, not one consumer.
- **A phone bottom bar must clear the app shell's tab bar.** The shell renders a `fixed bottom-0 h-16` MobileTabBar; a `sticky bottom-0` bar inside the form sits under it. Use `fixed inset-x-0 bottom-16 z-20` with plain `py-3` — do NOT add `env(safe-area-inset-bottom)`, the tab bar already pads for it and a second inset leaves ~34px of dead space on notched phones — and pad the form bottom (`pb-24`) so the last group, the name input and the error alert can all scroll clear. Verify at 375px inside the real AppShell — Storybook renders without it.
- **Dim choices, not labels, and never below 75%.** Opacity on the whole fieldset drops legend/hint text below 4.5:1 on the light theme while the group stays interactive; opacity on the radiogroup container alone still carries the 13px tile labels, which fail AA at 60% (~3.8:1) and pass at 75% (~5.9:1 text, ~3.4:1 borders). Keep the legend at full contrast, use `opacity-75` on the container, and make the nudge audible: `aria-describedby` → an `sr-only` "choose X first" span placed as a fieldset SIBLING of the legend, not inside it (inside the legend it is read twice), with wording derived from which required groups are still missing. Add `aria-required` on the `role=radiogroup` — a disappearing Required badge is visual-only.
- **The error alert must reach the person, every time.** On phones the single `role=alert` lives below the last group, so a tap on the fixed Create bar fails silently. Key a `useEffect` on an attempt NONCE (`setErrorNonce(n => n + 1)` wherever the message is set, `key={errorNonce}` on the alert so it remounts and re-announces) and `scrollIntoView` + `focus({preventScroll:true})` the alert — keying on the message string alone never re-fires for an identical consecutive error because React sees no state change. Pick `behavior` from `matchMedia('(prefers-reduced-motion: reduce)')`; the global CSS reduced-motion override covers transitions, not programmatic smooth scroll.
- **Storybook treats every named export as a story.** A shared `options` fixture exported from a `.stories.tsx` becomes a broken `--options` story in the sidebar. Move fixtures to a non-story module or set `excludeStories`.

## `.next/types` goes stale across branch switches and stashes

`pnpm tsc --noEmit` consults `.next/types/app/.../page.ts` stubs that `next dev` wrote on the previous branch. Checkout another branch (or `git stash` a page out), then rerun tsc, and you get `TS2307: Cannot find module '../../../../../../app/(app)/<route>/page.js'` against routes that are no longer on disk. The source files are fine; the stale stub still references them. Diagnostic tell: every error is a `.next/types/...` path, not an `app/...` path. Fix: `rm -rf .next` before trusting tsc on a different branch state. Required whenever the baseline you are checking is NOT the state `next dev` last compiled against — branch-swap, stash, worktree in a sibling dir.

## Booting the web app for UI work without spending money

- **Ports:** `:3000` is Remotion Studio, not the web app. Run the web app on `:3001` (`cd apps/web && set -a && . ../../.env && set +a && npx next dev -p 3001`, backgrounded with its log redirected). Check `lsof -iTCP:3001 -sTCP:LISTEN` and the log before assuming it is up.
- **No-spend mode:** when the user says "no runs", start only the API (`go build -o <scratch>/os-api ./apps/api`) with `unset HIGGSFIELD_API_KEY` and NO worker. Nothing can start a render, and every read path still works. First check no worker is already running with the key (see dev-services-and-ports.md) — an old watcher plus a `queued` backlog defeats this mode.
- **Delegating page sweeps:** when a subagent audits Settings/Cast/Series/Admin while you rebuild the main flow, give it a strict disjoint file list and forbid git writes; it may hit its iteration cap, so re-run `tsc --noEmit`, vitest and a browser pass yourself before trusting its summary. Check its output for vendor/provider names leaking into pages and API payloads (e.g. a voice `provider` field returned to the browser).
- **Browser sign-in:** open `/signin`, `fetch('/auth/dev/login', {method:'POST'})` from that page, then navigate. Restarting the API drops the session, so re-login after every API rebuild. Dev sessions have also lapsed between consecutive `browser_exec` calls with no restart — put sign-in and the thing you are checking in the SAME call, and check `location.href` is not `/signin` before asserting on page content. The user-path alternative (exercises the real form): submit an email on `/signin`, read the 6-digit code from local Mailpit — `GET http://localhost:8025/api/v1/messages?limit=1` → `GET /api/v1/message/{ID}`, regex `\b\d{6}\b` over `Text`+`HTML` — focus the first of the six `input[type=text]` boxes and type the digits with `cdp('Input.dispatchKeyEvent', type='keyDown', text=ch, key=ch)` per character (`fill_input` on one box does not advance the focus chain), then click the submit button. It is a code, not a magic link; grepping the mail for an `http` URL finds nothing.
- **Layout bug the user sees but the harness cannot reproduce → stale dev build, not a CSS bug.** Turbopack keeps serving old classes for shell/layout files (`components/app-shell/*`, `components/layout/*`) after an edit, so the user's tab shows the previous stickiness/positioning while a fresh headless tab shows the fix. Before diagnosing further or reaching for a "real browser" (safaridriver/AppleScript — needs Safari's Allow Remote Automation and is not worth the detour), kill `next dev` and the API, `rm -rf apps/web/.next`, restart both (API first — sessions die with it, so re-login), and ask the user to hard-refresh. Do this FIRST when two browsers disagree about the same commit.
- **Compile failure on every route:** `instrumentation.ts` statically importing the OpenTelemetry Node SDK makes the bundler resolve it for the edge runtime. Keep `instrumentation.ts` to `if (process.env.NEXT_RUNTIME === "nodejs") await import("./instrumentation-node")` and put the SDK imports in `instrumentation-node.ts`.

## Non-technical product rules (standing user decisions)

- **An LLM system-prompt enum that drives a UI picker must be a tested subset of the picker's real route slugs.** When a prompt tells the model to return `kind: motion-graphics|voiceover|reddit|brainrot|ai-clip-reel|captioned-upload` but the `/create` picker only has routes for `motion-graphics|cinematic|captioned`, the model happily returns `ai-clip-reel` and the UI's "Suggested" chip / card highlight never matches — nothing crashes, no test fails, the convert flow silently degrades to a plain picker. Keep the enum in the prompt as the EXACT set of enabled picker slugs (grep `apps/web/app/(app)/create/page.tsx` for `enabled: true` entries and quote them verbatim into the prompt body). Pin with a test that reads the migration's prompt body and asserts every enum value appears as a real route directory under `apps/web/app/(app)/create/<slug>/`. Same trap for any other model-filled payload field whose value is used as a client-side identifier (cadence, format slug, kind): either enforce in the Go validator before caching, or test the enum against the live surface.
- **No engineering knobs in the UI:** no model/vendor pickers, model paths, resolution or format choices. The backend picks the cheapest reliable model that satisfies the request. The form asks a vendor-free capability endpoint (e.g. `GET /api/v1/cinematic/options` → max length, shapes, sound available) and offers only what the server will accept. Grep new UI for `model` and vendor names before finishing.
- **Errors in plain words:** a sentence a non-technical person can act on, never a status code or raw API message.
- **Choices are seen, not read (standing user preference).** A menu of traits/options is never a wall of text pills: colours are swatches, everything else is a picture tile, and the page composes a live plain-English sentence of what the person has chosen so far (`describeTraits`-style pure function in `lib/`, unit-tested for the grammar edge cases: article a/an, "bald" suppressing a colour clause, colour-without-style). Every option group also gets a "Something else…" escape hatch — short free text first, a reference picture second — so the menu never traps someone; the server sanitises, moderates and splices custom values as `"<group>: <text>"` so they read as description, not instruction. Menu metadata lives in Go (`visual: swatch|glyph`, `hex`, `glyph: "<group>-<value>"`, group `layout`/`hint`); the browser owns the drawings and picks the gender variant itself, so the API stays one static menu and prompt phrases never leave the server. Keep the two sides honest with ONE fixture: a Go test marshals the menu to `apps/web/lib/<menu>.fixture.json` under `UPDATE_FIXTURES=1` and FAILS (never skips) when the file is stale or missing; the web glyph test asserts the drawing manifest equals the fixture's glyph set and Storybook imports the same file. Two hand-typed copies pass every test while a new menu entry renders the fallback tile in prod. Review checklist for this class of page is in "Picker / builder pages — review checklist" below.
- **Project-centric IA:** a PROJECT is what the person describes and edits; each Make press adds a VERSION (render) under it. Library lists projects (poster + status of the newest version); the project page plays the newest finished version, lists every version, offers Edit → new version (old ones kept), Stop, Delete, Download, Copy link. Old per-render routes (`/videos/{id}`, `/videos/{id}/making`) become server redirects to `/projects/{projectId}?v={id}` so shared links survive.
- **Missing thumbnail / stuck "in progress" triage:** (1) `fetch` the list/detail API in the browser and confirm `posterUrl`/`outputUrl`/`status` are present; (2) count `document.querySelectorAll('img,video')` — zero means the component never renders the field (a UI bug, not a data bug); (3) derive card/page state from the newest version's status in ONE pure function (`lib/projects.ts`) shared by Library, Home and the project page, so "ready" cannot mean different things on different screens.
- **Polling:** poll only while a version is in flight, clear the interval when it lands, and auto-select the new version unless the person picked another. Prefer SSE as the primary channel — `apps/web/lib/events.ts` (`getEventStream()`) already consumes `/api/v1/events/stream` and emits `render.progress|completed|failed|cancelled` and `project.updated|deleted`. Shape of a correct in-flight sync: subscribe to the relevant event types, refetch on each hit, AND run a 15–20s safety poll for stream drops. Scope the event handler to the IDs the surface actually cares about (`evt.data.projectId === project.id`, or the matching `renderId`) — the event bus is workspace-wide, so a Library tab refreshing on every unrelated render in the workspace is wrong even though it looks right locally. The 3–4s polls on `/api/v1/projects?limit=200` and `/api/v1/projects/{id}` that this replaces fetched hundreds of KB per tick and violated the GAPS allowlist.
- **Fixture sweep (app-facing fakes):** `rg -n 'credits=\{[0-9]|FALLBACK_|sample|demo|placeholder' apps/web/app apps/web/components` — replace hardcoded balances and fake sample content with real API data, or hide the element when the data cannot load. Never show a guessed number.
- **Server-side guards:** a disabled button is not a guard. Deleting a project with a render in flight must also be refused by the API (`requireProjectEditable`).
- **Download:** a cross-origin `<a download>` is ignored by browsers; fetch the bytes, save via an object URL, and fall back to opening the file if the fetch is blocked.
