# App Router — talking to a separate-origin API

When the Next app runs on one origin (say `http://localhost:3001`) and calls a JSON API on another (say `http://localhost:4000`), the following pieces have to line up on both sides. Missing any one turns into an opaque “network error” in devtools.

## Backend CORS contract (must all be present)

- `Access-Control-Allow-Origin` — echo the request’s `Origin` header verbatim. `*` is refused by browsers when credentials are on.
- `Vary: Origin` — stops caches from serving one client’s ACAO to another.
- `Access-Control-Allow-Credentials: true` — needed if you send cookies OR if you sometimes rely on auth cookies alongside the Bearer token.
- `Access-Control-Allow-Headers` — must enumerate every custom header the browser will send. Typical set: `authorization, content-type, idempotency-key`. Wildcards are ignored by many browsers.
- `Access-Control-Allow-Methods` — enumerate `GET, POST, PUT, DELETE, OPTIONS`.
- `Access-Control-Max-Age: 600` — optional, keeps preflight churn down in dev.
- On `OPTIONS`, return `204 No Content` with the above headers and no body.

Make the allow-list configurable via env (e.g. `CORS_ALLOW_ORIGINS=http://localhost:3001,http://localhost:3000`), split on comma, trim, honour `*` only when explicitly asked. Never hardcode dev origins into production builds.

## Frontend API client contract

One shared `lib/api.ts`:

1. Injects `Authorization: Bearer <key>` from `localStorage.getItem('<product>.apiKey')` on every request.
2. Mints `Idempotency-Key: crypto.randomUUID()` on POST/PUT/DELETE.
3. On `401`, wipes the storage entry and `router.push('/dashboard/setup')` — keeps a rotated key from leaving the UI in a permanently broken state.
4. Parses `{error:{code,message,retryable}}` envelopes on non-2xx and throws a typed API error class.
5. Never logs the key, never sends it as a query parameter, never puts it in an analytics event.

## Route gating

`app/dashboard/layout.tsx` wraps children in a client component that reads `localStorage['<product>.apiKey']`, redirects to `/dashboard/setup` when missing, and re-verifies via `GET /api/v1/me` on mount so a stale key surfaces immediately.

## Verifying the whole stack works

```bash
# 1. Preflight succeeds with the right headers
curl -sI -X OPTIONS -H 'Origin: http://localhost:3001' \
     -H 'Access-Control-Request-Method: GET' \
     http://localhost:4000/api/v1/stats | head -10

# 2. Every dashboard route serves 200 in dev
for path in / /dashboard/setup /dashboard /dashboard/projects \
             /dashboard/create /dashboard/create/<kind> \
             /dashboard/renders /dashboard/webhooks /dashboard/api /api-docs; do
  echo "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001$path)  $path"
done
```

All 200 = ready. Anything less on a route you touched is a regression.
