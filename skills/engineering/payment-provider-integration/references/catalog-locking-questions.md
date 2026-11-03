# Catalog locking — questions to resolve BEFORE writing migrations

These numbers hard-code into migration CHECK constraints, env vars, UI copy, and the Postgres schema. Changing them later means a migration, a UI redeploy, and reconciling in-flight subscriptions. Lock them with the user in one pass and record the answers in the PR1 plan doc.

## Plans

1. How many paid tiers? (Three — Lite / Creator / Pro — works well; two feels thin, four crowds the UI.)
2. Monthly price per tier, in whole dollars? Rendering `$X/mo` is cleaner than cents.
3. Yearly discount per tier (as a %)? Common pattern: cheapest tier no discount, middle ~8%, highest ~17%.
4. Rounding rule for yearly? Round UP to the nearest whole dollar is the safe default — never round down (looks like a bug when the display math doesn't tie out).
5. Credits-per-period per tier? Monthly amount; yearly = ×12 on the single annual invoice.
6. Trial? None by default — a trial period adds a `trialing` status branch everywhere and complicates signup accounting.

## Signup bonus

1. Credits on first signup? Keep it modest — enough for ~5–10 one-minute videos, not a free month's allocation. The paid-tier monthly grant should be clearly larger.
2. Keyed on what? Normalised email in a `signup_bonus_grants` table, so delete-and-rejoin does not re-roll.
3. UI copy where? `/pricing` Free row AND `/settings/plan` under the balance card. Match the exact credit number across both surfaces.

## Top-up packs

1. How many pack SKUs? Three (small/medium/large) is the sweet spot — one is stingy, five is paralysis.
2. Credits and prices per pack? Simple whole-dollar prices and credit counts that look proportional (e.g. 500/$9, 2500/$39, 7500/$99).
3. Expiry? Packs that NEVER expire are the right default — users treat purchased credits as owned goods, and a surprise expiry is the single loudest support complaint pattern in credit systems.

## Free-daily credits

If the codebase has a pre-existing scheduler job that grants credits daily on the free tier: DISABLE it by default when wiring billing. The mix of "free users get N/day + paid users get M/period" is almost always wrong. One or the other, and "paid monthly + one-time signup bonus" is the simpler model.

## Provider price-id mapping

One env var per plan+cadence and per pack (`STRIPE_PRICE_<PLAN>_<CADENCE>`, `STRIPE_PRICE_PACK_<SIZE>`). The catalog read endpoint should return an `available` flag reflecting whether the env is set, so the UI can render a disabled or hidden button when a SKU isn't configured — never render a button that will 400 on click.

## Red flags to resolve in this pass, not later

- "We'll figure out the yearly discount after launch." → No. UI copy and provider price IDs need the number now.
- "Credits refresh daily on paid plans too." → Monthly grant lots that expire at `current_period_end` is the simpler model; daily refresh on paid plans conflates subscription accounting with free-tier accounting.
- "Packs expire in 90 days to encourage usage." → User-hostile and generates a steady stream of "where did my credits go" tickets. Treat packs as goods.
- "We'll add a trial once we have users." → Fine as a deferred item; just confirm it's deferred and not implicit on the signup grant.
