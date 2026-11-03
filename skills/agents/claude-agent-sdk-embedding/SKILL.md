---
name: claude-agent-sdk-embedding
description: "Embed Claude Agent SDK in-process: sandbox, caps, verify."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [claude-agent-sdk, sandbox, llm-agent, remotion, temporal]
    related_skills: [delegate-task-tool, openstudio-development]
---

# Embedding the Claude Agent SDK as a sandboxed worker agent

## When to Use

- A service/worker runs `@anthropic-ai/claude-agent-sdk` `query()` unattended and lets the agent write files or run tools on a host it does not own.
- You are reviewing or hardening such an integration (permission gate, caps, env, generated-code execution).
- Not for interactive Claude Code use or for `delegate_task` subagents (see `delegate-task-tool`).

`@anthropic-ai/claude-agent-sdk` (TypeScript) runs a full Claude Code
agent loop in-process via `query()`, authenticated with `ANTHROPIC_API_KEY`
(no subscription). It spawns the `claude` CLI as a child and streams
`SDKMessage`s back. Use this skill whenever a service lets the agent write
files and run things on a host it does not own: the defaults are built for
an interactive developer, not for an unattended worker with a budget.

## Procedure

1. **Read `sdk.d.ts` before using any option.** The file ships with CRLF
   line endings: `tr -d '\r' < node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts | grep -n ...`
   or `$`-anchored greps and line-range extracts silently match nothing. Never
   invent an option name (there is no `allowFileModificationsOutsideCwd`);
   `tsc` only catches it if you did not cast the options object.
2. **Close the tool set with `tools: [...]`, not `disallowedTools`.** A
   deny list rots (tools get renamed: `Task` → `Agent`; `Skill`,
   `TodoWrite`, `ToolSearch` keep appearing). List exactly the built-ins
   you want; put ONLY your own `mcp__<server>__<tool>` names in
   `allowedTools`.
3. **Never put built-in file tools in `allowedTools`.** Anything in
   `allowedTools` is auto-allowed and `canUseTool` is never consulted for
   it — `canUseTool` is the *ask* path only. A policy that lives solely in
   `canUseTool` is decoration.
4. **Write the policy once as a pure function and install it twice:** as
   `canUseTool` (ask path) AND as a `hooks.PreToolUse` callback returning
   `hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason }`
   — the hook runs for every call regardless of allow rules and is the
   real enforcement. Default-deny any tool name the policy does not know.
5. **Path containment rules the policy must implement** (each one was a
   real hole):
   - Accept both the project path as given AND its `realpathSync.native`
     form — the CLI reports canonical paths (`/var/…` → `/private/var/…`
     on macOS), so a lexical `startsWith(root)` denies every legitimate
     read.
   - Case-fold on APFS/NTFS, or `src/ROOT.tsx` bypasses a `src/Root.tsx`
     lock.
   - For writes, realpath the deepest existing ancestor and re-check
     containment, or a pre-existing symlink inside the project writes
     outside it. Reads through symlinks (node_modules, skills) can stay
     allowed.
   - Glob/Grep: check `path`, and reject `pattern`/`glob` that are
     absolute or contain `..` — they enumerate the host otherwise.
   - Anything the agent must READ back (stills, logs, generated data)
     must live INSIDE the gate root; put it under `<project>/.<name>/`,
     not in a sibling `out/` dir, or the feedback loop is denied and the
     agent burns turns on refused reads.
6. **Give the agent typed tools instead of Bash.** `tool(name, desc,
   zodShape, handler)` + `createSdkMcpServer({ name, tools })` +
   `mcpServers: { name: server }`. Each handler is your code: add
   `timeout`/`killSignal` to every child process it spawns, because the
   wall-clock abort only kills the `claude` process, not your children.
   Make a rejected precondition (lint/source gate) NOT consume a limited
   iteration — return `isError: true` with the reason and let the agent
   fix it.
7. **Gate generated code before executing it** when the output runs
   anywhere (bundler, browser, eval). The system prompt's "no network, no
   other packages" is advisory; a user-controlled brief is a prompt
   injection surface. Run an AST allowlist over every generated file
   before each build (imports, forbidden globals incl. bare `fetch(...)`,
   `new WebSocket(...)`, `(0, fetch)(...)`, dynamic import, URL literals).
7b. **Skills (SKILL.md packs) the Remotion/agentskills.io way.** The CLI
   scans `<cwd>/.claude/skills/*/SKILL.md` only when `settingSources`
   includes `"project"` — so put ONLY that in `settingSources` (never
   `"user"`/`"local"`), make sure the scratch cwd has no `settings.json` /
   `CLAUDE.md`, and keep those paths non-writable in your gate. Add
   `"Skill"` to the closed `tools` list (NOT `allowedTools` — deprecated
   there and auto-allows); pass `skills: [names]` to filter the listing,
   but treat it as a context filter only (the d.ts says so): the CLI still
   lists its built-in skills (`deep-research`, `doctor`, `code-review`,
   `loop`…), so your gate must allow `Skill` only for `input.skill` ∈ your
   exact-name set (after `.trim()` and stripping ONE leading `/`, which
   the CLI does too). Verify from the `init` message (`m.skills`) that
   every expected skill was discovered before spending; also check
   `m.tools` has nothing outside your closed set and `m.cwd` is yours.
   Prompt with the pack's documented shape (`/skill-name <args>`) — but
   know that a leading `/` is SLASH-DISPATCHED: the skill body is injected
   with no `Skill` tool_use, so the gate never sees that first skill. Keep
   that prompt a constant; tenant text goes in a file the agent Reads.
   Pitfalls each found by a reviewer:
   - `managedSettings.disableSkillShellExecution` is silently DROPPED on a
     host with an admin managed-settings tier. Set it on `settings:` (flag
     layer, never dropped) as well. Add `strictMcpConfig: true`.
   - The CLI walks ANCESTOR dirs of cwd for `.claude/skills` and
     `CLAUDE.md`. A scratch project directly under a shared `/tmp` lets any
     local process plant either. Use a worker-private `0700` parent dir and
     write + lock an empty `CLAUDE.md` in the project.
   - It also discovers `.claude/skills` / `CLAUDE.md` NESTED under any dir
     it touches — deny dot-segments and `CLAUDE.md` inside the writable
     tree too.
   - Audit the vendored pack at boot: frontmatter keys ⊆ {name,
     description, version} (the CLI honours `hooks:`, `allowed-tools:`,
     `context: fork`, `agent:`, `model:`) and no inline `` !`cmd` `` /
     `^!cmd` lines. A future `skills update` must not be able to smuggle
     a shell hook.
   - Any error from reading the skills dir before `query()` must be
     classified non-retryable, or the workflow engine retries a
     deterministic failure. Validate dir names `/^[a-z0-9][a-z0-9_-]*$/`:
     the SDK turns them into `Skill(<name>)` rules and throws mid-query
     on odd characters.
   Probe cost: ~USD 0.005 on haiku for an init-only run.
7c. **Giving the agent web tools (fetch/download).** Lessons from a real
   adversarial review — each was a proven hole:
   - IPv6: WHATWG URL serialises `[::ffff:127.0.0.1]` as `[::ffff:7f00:1]`.
     A dotted-only v4-mapped regex is a full SSRF bypass. Expand every v6
     literal to 16 bytes; first 80 bits zero → judge the embedded v4;
     also handle 6to4 `2002::/16` (embedded v4), Teredo `2001::/32`,
     NAT64 `64:ff9b::/96`, `100::/64`. Test the URL-level forms.
   - Never accept SVG as an "image" asset. Entities, `<style>@import`,
     entity-encoded `href`, SMIL `<set attributeName=href>` all beat a
     regex denylist. It is a document format; refuse it.
   - If generated code is rendered in a browser, the static gate must
     refuse document-embedding JSX (`iframe`, `IFrame`, `object`, `embed`,
     `portal`…) and require `src`/`href`/`data` to be a literal or
     `staticFile(<literal>)` — `"ht"+"tp://…"` beats a whole-literal scan.
   - Never buffer a redirect body before following `Location`; cancel it.
     Release body + timer + dispatcher in a `finally` on EVERY exit path
     (non-text content-type, budget exhausted, !ok) — or sockets leak per
     call in the shared worker.
   - HTML→text with `[\s\S]*?` regexes is O(n²) on unclosed tags (10+ s
     stalls). Use a linear scanner for script/style/comment blocks, bound
     inner matches, cap input, cap calls per run.
   - An "untrusted data" frame needs a per-call nonce AND neutralised
     marker sequences in the content, or the page forges the close.
   - Block your own service hosts by resolved ADDRESS, not just name.
   - Log `origin + pathname` only; query strings carry presigned tokens
     and heartbeat details persist in workflow history.
   - A 2-byte mp3 sniff (`ff ex`) accepts anything; check version/layer/
     bitrate/samplerate bits of the frame header.
   - Refuse the test-only resolve seam under `NODE_ENV=production`.
8. **Env allowlist for the subprocess.** `env: { ...process.env }` hands
   the agent every secret the worker holds. Pass `PATH`, `HOME`,
   `TMPDIR`, `LANG`, `ANTHROPIC_API_KEY` (+ `ANTHROPIC_BASE_URL`/
   `ANTHROPIC_AUTH_TOKEN` if used), and set `CLAUDE_CONFIG_DIR` to a
   scratch dir, `DISABLE_TELEMETRY=1`, `DISABLE_AUTOUPDATER=1`,
   `settingSources: []` so host `~/.claude` settings never leak in.
9. **Caps, and what each one actually does:**
   - `maxBudgetUsd` / `maxTurns` → SDK ends the run with a `result`
     message, `subtype: "error_max_budget_usd"` / `"error_max_turns"`.
   - Wall clock → your own `AbortController` + `setTimeout`. On abort the
     message iterator THROWS ("Claude Code process aborted by user");
     catch around the `for await`, check `abort.signal.aborted`, and
     classify as non-retryable. Distinguish your abort from the host's
     cancellation signal (propagate the latter as cancellation).
   - `subtype: "success"` can still carry `is_error: true` — treat as
     failure. Enforce your own completion marker (e.g. the agent must
     emit `DONE`) rather than trusting a graceful end.
   - Cost: read `total_cost_usd` from the LAST `result` message (running
     total); it is an estimate, not billing.
10. **If the host is a durable workflow engine (Temporal etc.):** run the
    activity with ONE attempt — a retry re-runs the whole loop and doubles
    every cap; heartbeat on a fixed interval (`setInterval`, ~20 s)
    independent of agent chatter, or a silent model call trips the
    heartbeat timeout and starts a concurrent, double-spending attempt;
    honour the cancellation signal in the post-agent render/build steps
    too.
11. **Verify in three layers before calling it sandboxed:**
    - unit: the pure policy against a REAL temp project with a symlink
      out, a case-variant locked file, the realpath form of the root,
      absolute/`..` globs, and the hook adapter;
    - dry run: the whole pipeline with the LLM stubbed (no spend);
    - live probe: one real run with a hostile brief appended
      ("edit the locked file, write outside src, add fetch") — expect
      deny/reject log lines and a clean artifact. A sandbox that has
      never been attacked is unverified.

## Pitfalls

- `tsx` runs specs that use TS parameter properties; node's
  `--experimental-strip-types` rejects them (`ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`).
- `execFile` has no `input` option — stdin for a sidecar goes through
  `spawn` + `child.stdin.end(src)`; otherwise the sidecar sees an empty
  source and "rejects" everything with a misleading rule name.
- Each `@remotion/bundler` `bundle()` call leaks a `remotion-webpack-bundle-*`
  dir in `$TMPDIR` unless you pass `outDir` inside your cleanup root; skip
  a final re-bundle when a digest of the source tree is unchanged.
- Tell the agent exactly where in-project data lives and that imports
  must stay inside the gated source dir (e.g. generate `src/words.ts`, not
  `public/words.json`) — otherwise its first bundle fails the source gate
  and it spends turns relocating data.
- Zod: the SDK accepts zod 3 or 4; pick the major the rest of the tree
  needs (`@remotion/*` wants 4 for `zod/mini`). Pinning a second major
  breaks the bundler, not the SDK.
