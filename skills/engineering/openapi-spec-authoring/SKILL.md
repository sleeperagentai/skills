---
name: openapi-spec-authoring
description: Edit OpenAPI 3.1 specs; split via $ref; redocly validate.
---

# OpenAPI 3.1 spec authoring

Procedure for extending an OpenAPI spec with new routes/schemas, including splitting across files via `$ref`, and validating with Redocly before shipping.

## Procedure

1. **Decide inline vs split by scale.** <20 new routes: inline in the main file. ≥20 or a logically-separate surface (auth, admin, webhooks): split into `docs/openapi/<topic>.yaml` + `docs/openapi/<topic>-schemas.yaml` and `$ref` them from `paths:` in the main spec. Splitting keeps the diff reviewable; inlining avoids a second validator pass.

2. **For split files, write paths in the sub-file as a normal OpenAPI 3.1 document** (its own `openapi: 3.1.0` header, its own `paths:`). Schemas live in a separate `*-schemas.yaml`. Both files are consumed by `$ref` only — redocly bundles them into one spec at build time.

3. **Cross-file `$ref` syntax**: in the main spec's `paths:`, each entry is a path-level `$ref`:
   ```yaml
   /auth/otp/verify:  { $ref: './auth.yaml#/paths/~1auth~1otp~1verify' }
   ```
   The JSON-Pointer `~1` is the escape for `/` — do not write `/paths//auth/otp/verify`, it won't resolve.

4. **Refs OUT of the sub-file back to the main spec** must be relative-filename-prefixed:
   ```yaml
   '400': { $ref: './openstudio.yaml#/components/responses/BadRequest' }
   ```
   A bare `#/components/responses/BadRequest` inside the sub-file points at the sub-file's own (empty) components block and fails `no-unresolved-refs`.

5. **Add new `tags:` entries in the main spec** for every tag the sub-file uses. Tags are name-only references; redocly warns on undeclared tags but does not fail.

6. **Validate — two commands, in order:**
   ```bash
   npx -y @redocly/cli@latest bundle docs/openapi/<main>.yaml -o /tmp/bundled.yaml
   npx -y @redocly/cli@latest lint docs/openapi/<main>.yaml --max-problems 500
   ```
   Bundle first (fast, catches ref-resolution problems); lint second (slow, catches schema shape). `--max-problems 500` is important — the default truncates and hides what's yours.

7. **Separate NEW errors from PRE-EXISTING errors** before claiming green. Run `redocly lint` once BEFORE your edits (`git stash` first), save the error count, then compare after. A spec that was already failing (common with legacy `nullable: true` on OpenAPI 3.1 schemas) will keep failing; your bar is "zero new errors in files I touched", not "zero errors overall".

## Pitfalls

- **YAML flow-mapping values with commas or parens get silently split.** `'400': { description: Bad request (member not found, etc.) }` parses the commas as separator tokens — redocly reports an invalid property on the response object. Quote the value: `'400': { description: 'Bad request (member not found, etc.)' }`. Or use block style. Any time a description includes `,`, `(`, `)`, `:`, or `#` and you're in `{ ... }` flow syntax, quote it.

- **OpenAPI 3.1 forbids `nullable: true`.** It's a 3.0 property. Use `type: [string, "null"]` instead. If the main spec is already littered with the 3.0-style field, don't bulk-fix in the same PR — pre-existing lint errors will drown the review. Fix the ones you add and leave the rest to a separate migration PR.

- **`operation-summary` and `operation-operationId` are warnings, not errors** in default redocly rulesets. Don't block on them — but DO add operationIds for anything a client generator will consume. A short consistent naming convention (`<method><PathCamelCase>` → `postInternalMe2faEnroll`) is cheap to generate programmatically if you have many to backfill.

- **Security scheme references are name-only in `security:` blocks**, not `$ref`. `security: [{ sessionCookie: [] }]` works across files because redocly resolves the name against the final bundled spec's `components.securitySchemes`. The sub-file does NOT need its own `components.securitySchemes` — it would fail to validate as a standalone document, but that's fine, it's never consumed standalone.

- **Legacy routes that no longer exist in code should be deleted, not deprecated-with-404-stubs.** A `deprecated: true` entry documenting a route that returns 404 is noise that confuses client-generator users ("should I handle 404 as business logic?"). If an upstream migration moved the route, remove the old entry; if clients still call the old URL, keep it as a real redirect at the API, not a doc fossil.

## When to split

Add a new split file when the new surface is >~15 routes AND conceptually separate (auth vs public API, admin vs user, inbound webhooks vs outbound). Extend inline when it's a few routes under an existing tag. Never split by HTTP method or by individual feature — that creates many tiny files and ref-maze headaches.
