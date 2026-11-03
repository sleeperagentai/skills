# Next.js production build failures — field guide

One symptom per section; each contains the mechanism (why Next says this) and the fix (what changes to make it go green). Focused on the misleading errors that come up repeatedly.

## `<Html> should not be imported outside of pages/_document`

Appears during `next build`, on `Error occurred prerendering page "/404"` or `/500` or `/_error`. The stack trace points into `next/dist/compiled/next-server/pages.runtime.prod.js` and one of your `.next/server/chunks/*.js`.

This error is **misleading**. You almost never actually import `<Html>` — the pages runtime is trying to render the built-in `/404` static page and something in the shared server graph made that render die.

### Trigger A: `NODE_ENV=development` in the build shell

1. `env | grep NODE_ENV`. If it says `development`, that is the bug.
2. Fix: `NODE_ENV=production pnpm build`. If you want it permanent, `unset NODE_ENV` before `pnpm build` in whatever runs your CI.
3. Confirm: the `⚠ You are using a non-standard NODE_ENV value` warning at the top of the build output goes away.

The warning is the actual signal; the `<Html>` error is downstream noise. Watch for the warning line even when the build succeeds — it changes hydration in surprising ways.

### Trigger B: a dep pulls Next’s pages runtime into the server bundle

Suspects observed in the wild: `@scalar/api-reference-react`, other heavy client-only doc / diagram viewers that transitively touch `next/document`.

Diagnosis: `grep -l "Html" apps/<web>/.next/server/chunks/*.js` after a failed build — chunks that contain the shim are the ones being pulled in transitively.

Fix hierarchy (weakest to strongest — use the strongest that works):

1. `dynamic(() => import('...'), { ssr: false })` around the offending component. Often insufficient — the module still resolves.
2. Move the component behind a client-only mount via `useEffect(() => setMounted(true), [])`. Also often insufficient.
3. **Remove the npm dep entirely.** Mount the third-party viewer from a CDN inside an `<iframe srcDoc={html}>`. Redoc’s `https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js` is a working substitute for Scalar; a similar approach works for any client-only viewer.

### Confirm the failure is pre-existing before touching anything

```bash
git stash -u && rm -rf .next && NODE_ENV=production pnpm build
```

Same error = it’s not your diff. Pop the stash and go fix the env or the dep as above.

## `Cannot find module '../../../../../app/<route>/page.js'` during `pnpm typecheck`

Mechanism: `next dev` populated `.next/types/app/<route>/page.ts` while the route existed. You deleted the route file. TypeScript still walks the type shim and errors.

Fix: `rm -rf apps/<web>/.next && pnpm --filter <web> typecheck`. Not a code bug.

## Dev server bound to a stuck port

`⨯ Failed to start server: EADDRINUSE :::3001` after a previous background `next dev` was orphaned.

```bash
lsof -i :3001 -t | xargs -I{} kill {}   # SIGTERM first
lsof -i :3001 -t | xargs -I{} kill -9 {}  # then SIGKILL if needed
sleep 1 && lsof -i :3001                  # confirm empty
```

Then restart. Do this before every `pnpm dev` when running under a background-process tool that doesn’t reliably reap children.
