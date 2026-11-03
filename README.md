# sleeperagentai/skills

A private, agent-agnostic library of every agent skill we use, organized by category, with
provenance and one-line install commands. Skills follow the open
[Agent Skills](https://agentskills.io/specification) format (`SKILL.md` with frontmatter), so they
work in Claude Code, Codex, Cursor, OpenCode, Gemini CLI, Hermes, Antigravity and any other agent
the [`skills` CLI](https://github.com/vercel-labs/skills) supports.

## Quick start

```bash
# 1. Install the finder once (global, all agents the CLI detects)
npx -y skills add sleeperagentai/skills --skill skill-finder -g -y

# 2. In any agent session
/skill-finder make my landing page look less AI-generated
```

`skill-finder` searches this repo's `catalog.json`, suggests the best matches, installs what you pick,
and if nothing fits it searches the wider ecosystem, vets the best candidate, opens a PR to add it here,
waits for you to merge, and installs it.

Install any single skill directly:

```bash
npx -y skills add sleeperagentai/skills --skill <name> -y        # project scope
npx -y skills add sleeperagentai/skills --skill <name> -g -y     # global scope
npx -y skills add sleeperagentai/skills --list                   # see everything installable
```

The repo is private: the CLI uses your existing git credentials, `gh auth`, or SSH key. See
[INSTALL.md](INSTALL.md) for per-agent details and manual installs.

## Layout

```
skills/<category>/<name>/   installable skills (SKILL.md + optional references/ scripts/ assets/ + metadata.json)
collections/<name>.json     large upstream collections we point to instead of vendoring
plugins/<name>.json         Claude Code plugins we use (marketplace install commands)
catalog.json                generated index used by skill-finder (do not edit by hand)
categories.json             allowed categories and their meaning
scripts/                    build-catalog.py, validate.sh, frontmatter.py
docs/                       metadata.json and catalog.json field reference
```

Each skill folder carries a `metadata.json` with its upstream repo, commit, license and install
commands. The skills CLI does not copy that file when installing, so installed skills stay identical
to upstream. See [CONTRIBUTING.md](CONTRIBUTING.md) to add a skill.

## Catalog

<!-- catalog:start -->

**143 skills** in 12 categories, **9 collections** and **2 plugins** referenced.

### agents — Agent runtimes, MCP, computer use, automation of other software

| Skill | What it does | Source | Install |
|---|---|---|---|
| [claude-agent-sdk-embedding](skills/agents/claude-agent-sdk-embedding) | Embed Claude Agent SDK in-process: sandbox, caps, verify. | local | `npx -y skills add sleeperagentai/skills --skill claude-agent-sdk-embedding -y` |
| [debugging-hermes-tui-commands](skills/agents/debugging-hermes-tui-commands) | Debug Hermes TUI slash commands: Python, gateway, Ink UI. | local | `npx -y skills add sleeperagentai/skills --skill debugging-hermes-tui-commands -y` |
| [delegate-task-tool](skills/agents/delegate-task-tool) | Rules for using Hermes's delegate_task tool safely. | local | `npx -y skills add sleeperagentai/skills --skill delegate-task-tool -y` |
| [godmode](skills/agents/godmode) | Jailbreak LLMs: Parseltongue, GODMODE, ULTRAPLINIAN. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill godmode -y` |
| [inspecting-hermes-desktop-dom](skills/agents/inspecting-hermes-desktop-dom) | Read the live Hermes desktop DOM/CSS over CDP. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill inspecting-hermes-desktop-dom -y` |
| [jupyter-live-kernel](skills/agents/jupyter-live-kernel) | Iterative Python via live Jupyter kernel (hamelnb). | local | `npx -y skills add sleeperagentai/skills --skill jupyter-live-kernel -y` |
| [macos-computer-use](skills/agents/macos-computer-use) | Drive the macOS desktop in the background — screenshots, mouse, keyboard, scroll, drag — without stealing the… | local | `npx -y skills add sleeperagentai/skills --skill macos-computer-use -y` |
| [minecraft-modpack-server](skills/agents/minecraft-modpack-server) | Host modded Minecraft servers (CurseForge, Modrinth). | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill minecraft-modpack-server -y` |
| [native-mcp](skills/agents/native-mcp) | MCP client: connect servers, register tools (stdio/HTTP). | local | `npx -y skills add sleeperagentai/skills --skill native-mcp -y` |
| [opencode](skills/agents/opencode) | Delegate coding to OpenCode CLI (features, PR review). | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill opencode -y` |
| [openhue](skills/agents/openhue) | Control Philips Hue lights, scenes, rooms via OpenHue CLI. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill openhue -y` |
| [pokemon-player](skills/agents/pokemon-player) | Play Pokemon via headless emulator + RAM reads. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill pokemon-player -y` |
| [yuanbao](skills/agents/yuanbao) | Yuanbao (元宝) groups: @mention users, query info/members. | local | `npx -y skills add sleeperagentai/skills --skill yuanbao -y` |

### creative — Art, music, image and audio generation, visual experiments

| Skill | What it does | Source | Install |
|---|---|---|---|
| [ascii-art](skills/creative/ascii-art) | ASCII art: pyfiglet, cowsay, boxes, image-to-ascii. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill ascii-art -y` |
| [baoyu-comic](skills/creative/baoyu-comic) | Knowledge comics (知识漫画): educational, biography, tutorial. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill baoyu-comic -y` |
| [comfyui](skills/creative/comfyui) | Generate images, video, and audio with ComfyUI — install, launch, manage nodes/models, run workflows with par… | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill comfyui -y` |
| [gif-search](skills/creative/gif-search) | Search/download GIFs from Tenor via curl + jq. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill gif-search -y` |
| [heartmula](skills/creative/heartmula) | HeartMuLa: Suno-like song generation from lyrics + tags. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill heartmula -y` |
| [ideation](skills/creative/ideation) | Generate project ideas via creative constraints. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill ideation -y` |
| [pixel-art](skills/creative/pixel-art) | Pixel art w/ era palettes (NES, Game Boy, PICO-8). | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill pixel-art -y` |
| [pretext](skills/creative/pretext) | Use when building creative browser demos with @chenglou/pretext — DOM-free text layout for ASCII art, typogra… | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill pretext -y` |
| [sketch](skills/creative/sketch) | Throwaway HTML mockups: 2-3 design variants to compare. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill sketch -y` |
| [songsee](skills/creative/songsee) | Audio spectrograms/features (mel, chroma, MFCC) via CLI. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill songsee -y` |
| [spotify](skills/creative/spotify) | Spotify: play, search, queue, manage playlists and devices. | local | `npx -y skills add sleeperagentai/skills --skill spotify -y` |
| [touchdesigner-mcp](skills/creative/touchdesigner-mcp) | Control a running TouchDesigner instance via twozero MCP — create operators, set parameters, wire connections… | third-party | `npx -y skills add sleeperagentai/skills --skill touchdesigner-mcp -y` |

### design — UI, UX, visual design systems, styling and anti-slop frontend taste

| Skill | What it does | Source | Install |
|---|---|---|---|
| [design-md](skills/design/design-md) | Author/validate/export Google's DESIGN.md token spec files. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill design-md -y` |
| [design-taste-frontend](skills/design/design-taste-frontend) | tasteskill v2, the anti-slop frontend skill. Art direction for websites, distilled from a study of 247 curate… | [Leonxlnx/taste-skill](https://github.com/Leonxlnx/taste-skill/tree/12af471f627f866411b4bd785b19646d3672784c/skills/taste-skill) | `npx -y skills add sleeperagentai/skills --skill design-taste-frontend -y` |
| [emil-design-eng](skills/design/emil-design-eng) | This skill encodes Emil Kowalski's philosophy on UI polish, component design, animation decisions, and the in… | [emilkowalski/skills](https://github.com/emilkowalski/skills/tree/f1090bec277140d02ed202440185ad9d02ac1490/skills/emil-design-eng) | `npx -y skills add sleeperagentai/skills --skill emil-design-eng -y` |
| [frontend-design](skills/design/frontend-design) | Guidance for distinctive, intentional visual design when building new UI or reshaping an existing one. Helps… | [anthropics/skills](https://github.com/anthropics/skills/tree/ca45fc496a3436251f191354091d557da31c15b5/skills/frontend-design) | `npx -y skills add sleeperagentai/skills --skill frontend-design -y` |
| [frontend-ui-engineering](skills/design/frontend-ui-engineering) | Builds production-quality, accessible, responsive user-facing UIs. Use when building or modifying interfaces… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill frontend-ui-engineering -y` |
| [hallmark](skills/design/hallmark) | Design skill for websites and new pages that look designed, not generated. Use when the user asks to build or… | [Nutlope/hallmark](https://github.com/Nutlope/hallmark/tree/4f6a46c6dc325d40ab268c93e25c7b96676ebccd/skills/hallmark) | `npx -y skills add sleeperagentai/skills --skill hallmark -y` |
| [huashu-design](skills/design/huashu-design) | 花叔Design——用HTML做高保真原型、幻灯片、动画、可视化与专家评审。任何新设计100%先出三个方向初稿给用户选（指定风格/品牌也不豁免），选定后才执行。触发词：做原型、PPT、幻灯片、动画、设计风格、评审、做个… | [alchaincyf/huashu-design](https://github.com/alchaincyf/huashu-design/tree/9b01ee8751679724dd43d855a532944aaa2c2b59) | `npx -y skills add sleeperagentai/skills --skill huashu-design -y` |
| [impeccable](skills/design/impeccable) | Use when the user wants to design, redesign, shape, critique, audit, polish, simplify, harden, animate, or ot… | [pbakaus/impeccable](https://github.com/pbakaus/impeccable/tree/9fadc41729c38fd47d7ae622b501558653f9d2e9/.agents/skills/impeccable) | `npx -y skills add sleeperagentai/skills --skill impeccable -y` |
| [make-interfaces-feel-better](skills/design/make-interfaces-feel-better) | Design engineering principles for making interfaces feel polished. Use when building UI components, reviewing… | [jakubkrehel/make-interfaces-feel-better](https://github.com/jakubkrehel/make-interfaces-feel-better/tree/35545ea1512ad59fa463e6b1f95ca9c052981fe6/skills/make-interfaces-feel-better) | `npx -y skills add sleeperagentai/skills --skill make-interfaces-feel-better -y` |
| [material-3](skills/design/material-3) | Implement Google's Material Design 3 (Material You) UI system. Primary: Jetpack Compose Material3 (MaterialTh… | [hamen/material-3-skill](https://github.com/hamen/material-3-skill/tree/14385f2bf3804d8779f8b4db2604211f1e70b4c1/skills/material-3) | `npx -y skills add sleeperagentai/skills --skill material-3 -y` |
| [nextjs-app-router-production](skills/design/nextjs-app-router-production) | Ship Next.js App Router apps end-to-end. | local | `npx -y skills add sleeperagentai/skills --skill nextjs-app-router-production -y` |
| [nothing-design](skills/design/nothing-design) | This skill should be used when the user explicitly says "Nothing style", "Nothing design", "/nothing-design",… | [dominikmartn/nothing-design-skill](https://github.com/dominikmartn/nothing-design-skill/tree/74affbb786af098b18503467b205c10a7df30126/nothing-design) | `npx -y skills add sleeperagentai/skills --skill nothing-design -y` |
| [refactoring-ui](skills/design/refactoring-ui) | Design and improve user interfaces using the concrete rules from Refactoring UI (Wathan & Schoger) — constrai… | local | `npx -y skills add sleeperagentai/skills --skill refactoring-ui -y` |
| [scandinavian-design](skills/design/scandinavian-design) | Apply a refined Scandinavian visual system with a neutral black-and-white foundation, restrained sans-serif t… | [ericzakariasson/scandinavian-design](https://github.com/ericzakariasson/scandinavian-design/tree/295742307b97fa0fb848f9be2d6e229ca517c736/skills/scandinavian-design) | `npx -y skills add sleeperagentai/skills --skill scandinavian-design -y` |
| [shadcn](skills/design/shadcn) | Manages shadcn components and projects — adding, searching, fixing, debugging, styling, and composing UI, inc… | [shadcn-ui/ui](https://github.com/shadcn-ui/ui) | `npx -y skills add sleeperagentai/skills --skill shadcn -y` |
| [storybook-component-library](skills/design/storybook-component-library) | Add or upgrade Storybook for React+Vite apps. | local | `npx -y skills add sleeperagentai/skills --skill storybook-component-library -y` |
| [swiss-design](skills/design/swiss-design) | Apply a Swiss International Style design system using Tailwind CSS. Use when asked to style a webpage, clean… | [zeke/swiss-design-skill](https://github.com/zeke/swiss-design-skill/tree/285009f3dc4ba311f59bb757973274de2c9446c3/swiss-design) | `npx -y skills add sleeperagentai/skills --skill swiss-design -y` |
| [tailwind-4](skills/design/tailwind-4) | Tailwind CSS 4 patterns and best practices. Trigger: When styling with Tailwind (className, variants, cn()),… | [prowler-cloud/prowler](https://github.com/prowler-cloud/prowler) | `npx -y skills add sleeperagentai/skills --skill tailwind-4 -y` |
| [ui-ux-pro-max](skills/design/ui-ux-pro-max) | UI/UX design intelligence for web, mobile, and desktop. This skill should be used when designing, building, r… | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/tree/713eef51b04efc98d6fa565323b495f7c9c89fd4/.claude/skills/ui-ux-pro-max) | `npx -y skills add sleeperagentai/skills --skill ui-ux-pro-max -y` |
| [unslop](skills/design/unslop) | Cut AI tells from any writing. | [cursor/plugins](https://github.com/cursor/plugins/tree/ae5650febf4320793844c12c4adaa937f417f8da/pstack/skills/unslop) | `npx -y skills add sleeperagentai/skills --skill unslop -y` |
| [userinterface-wiki](skills/design/userinterface-wiki) | UI/UX best practices for web interfaces. Use when reviewing animations, CSS, audio, typography, UX patterns,… | [raphaelsalaja/userinterface-wiki](https://github.com/raphaelsalaja/userinterface-wiki/tree/256a954080c8bcf1b1ceb1e2a4079d1f24cf593a/skills) | `npx -y skills add sleeperagentai/skills --skill userinterface-wiki -y` |
| [web-design-guidelines](skills/design/web-design-guidelines) | Review UI code for Web Interface Guidelines compliance. Use when asked to "review my UI", "check accessibilit… | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills/tree/1a2c79d4e6c4a2283dc2c614b6538cbe1ed5ca62/skills/web-design-guidelines) | `npx -y skills add sleeperagentai/skills --skill web-design-guidelines -y` |
| [yc-web-design-strategy](skills/design/yc-web-design-strategy) | Strategic web design consultant for building, reviewing, or auditing websites and landing pages. Trigger when… | local | `npx -y skills add sleeperagentai/skills --skill yc-web-design-strategy -y` |

### devops — CI, infrastructure, databases, observability, environment setup

| Skill | What it does | Source | Install |
|---|---|---|---|
| [ci-pipeline-remediation](skills/devops/ci-pipeline-remediation) | Make red CI green on an existing repo without a huge PR. | local | `npx -y skills add sleeperagentai/skills --skill ci-pipeline-remediation -y` |
| [kanban-orchestrator](skills/devops/kanban-orchestrator) | Decomposition playbook + anti-temptation rules for an orchestrator profile routing work through Kanban. The "… | local | `npx -y skills add sleeperagentai/skills --skill kanban-orchestrator -y` |
| [kanban-worker](skills/devops/kanban-worker) | Pitfalls, examples, and edge cases for Hermes Kanban workers. The lifecycle itself is auto-injected into ever… | local | `npx -y skills add sleeperagentai/skills --skill kanban-worker -y` |
| [postgres-row-level-security](skills/devops/postgres-row-level-security) | Postgres RLS: policies, ownership bypass, migrations. | local | `npx -y skills add sleeperagentai/skills --skill postgres-row-level-security -y` |
| [self-hosted-grafana-stack](skills/devops/self-hosted-grafana-stack) | Boot Grafana+Tempo+Loki+Prom+Pyroscope+otelcol natively. | local | `npx -y skills add sleeperagentai/skills --skill self-hosted-grafana-stack -y` |
| [tailscale-service-access](skills/devops/tailscale-service-access) | Access local services via Tailscale MagicDNS | local | `npx -y skills add sleeperagentai/skills --skill tailscale-service-access -y` |
| [technical-environment-setup](skills/devops/technical-environment-setup) | Comprehensive setup for technical work environments including shell configuration, knowledge vault organizati… | local | `npx -y skills add sleeperagentai/skills --skill technical-environment-setup -y` |
| [webhook-subscriptions](skills/devops/webhook-subscriptions) | Webhook subscriptions: event-driven agent runs. | local | `npx -y skills add sleeperagentai/skills --skill webhook-subscriptions -y` |

### engineering — Software engineering practice: planning, TDD, review, debugging, APIs, shipping

| Skill | What it does | Source | Install |
|---|---|---|---|
| [api-and-interface-design](skills/engineering/api-and-interface-design) | Guides stable API and interface design. Use when designing APIs, module boundaries, or any public interface.… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill api-and-interface-design -y` |
| [async-jobs-and-sse-go](skills/engineering/async-jobs-and-sse-go) | Go async 202 job APIs + SSE progress streams. | local | `npx -y skills add sleeperagentai/skills --skill async-jobs-and-sse-go -y` |
| [browser-testing-with-devtools](skills/engineering/browser-testing-with-devtools) | Tests in real browsers via Chrome DevTools MCP. Use when building or debugging anything that runs in a browse… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill browser-testing-with-devtools -y` |
| [ci-cd-and-automation](skills/engineering/ci-cd-and-automation) | Automates CI/CD pipeline setup. Use when setting up or modifying build and deployment pipelines. Use when you… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill ci-cd-and-automation -y` |
| [code-review-and-quality](skills/engineering/code-review-and-quality) | Conducts multi-axis code review. Use before merging any change. Use when reviewing code written by yourself,… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill code-review-and-quality -y` |
| [code-simplification](skills/engineering/code-simplification) | Simplifies code for clarity. Use when refactoring code for clarity without changing behavior. Use when code w… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill code-simplification -y` |
| [constraint-driven-development](skills/engineering/constraint-driven-development) | Establishes a project's quality bar as a written contract and stops agents quietly lowering it. Interviews th… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill constraint-driven-development -y` |
| [context-engineering](skills/engineering/context-engineering) | Optimizes agent context setup. Use when starting a new session, when agent output quality degrades, when swit… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill context-engineering -y` |
| [debugging-and-error-recovery](skills/engineering/debugging-and-error-recovery) | Guides systematic root-cause debugging. Use when tests fail, builds break, something that worked yesterday br… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill debugging-and-error-recovery -y` |
| [deprecation-and-migration](skills/engineering/deprecation-and-migration) | Manages deprecation and migration. Use when removing old systems, APIs, or features. Use when migrating users… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill deprecation-and-migration -y` |
| [documentation-and-adrs](skills/engineering/documentation-and-adrs) | Records decisions and documentation. Use when you need to document an architecture decision (ADR) or the reas… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill documentation-and-adrs -y` |
| [doubt-driven-development](skills/engineering/doubt-driven-development) | Subjects every non-trivial decision to a fresh-context adversarial review before it stands. Use when you want… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill doubt-driven-development -y` |
| [git-workflow-and-versioning](skills/engineering/git-workflow-and-versioning) | Structures git workflow practices. Use when making any code change. Use when committing, branching, resolving… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill git-workflow-and-versioning -y` |
| [go-workspace-monorepo](skills/engineering/go-workspace-monorepo) | Use when adding intra-repo imports in a Go monorepo. | local | `npx -y skills add sleeperagentai/skills --skill go-workspace-monorepo -y` |
| [idea-refine](skills/engineering/idea-refine) | Refines raw ideas into sharp, actionable concepts through structured divergent and convergent thinking. Use w… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill idea-refine -y` |
| [incremental-implementation](skills/engineering/incremental-implementation) | Delivers changes incrementally in thin, verifiable slices. Use when implementing any feature or change that t… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill incremental-implementation -y` |
| [interview-me](skills/engineering/interview-me) | Extracts what the user actually wants instead of what they think they should want. Achieves this through one-… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill interview-me -y` |
| [node-inspect-debugger](skills/engineering/node-inspect-debugger) | Debug Node.js via --inspect + Chrome DevTools Protocol CLI. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill node-inspect-debugger -y` |
| [observability-and-instrumentation](skills/engineering/observability-and-instrumentation) | Instruments code so production behavior is visible and diagnosable. Use when adding logging, metrics, tracing… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill observability-and-instrumentation -y` |
| [openapi-spec-authoring](skills/engineering/openapi-spec-authoring) | Edit OpenAPI 3.1 specs; split via $ref; redocly validate. | local | `npx -y skills add sleeperagentai/skills --skill openapi-spec-authoring -y` |
| [payment-provider-integration](skills/engineering/payment-provider-integration) | Wire Stripe/Paddle. Adapter, replay-safe webhooks. | local | `npx -y skills add sleeperagentai/skills --skill payment-provider-integration -y` |
| [performance-optimization](skills/engineering/performance-optimization) | Optimizes application performance across frontend, backend, queries, and databases. Use when performance requ… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill performance-optimization -y` |
| [plan](skills/engineering/plan) | Plan mode: write markdown plan to .hermes/plans/, no exec. | local | `npx -y skills add sleeperagentai/skills --skill plan -y` |
| [planning-and-task-breakdown](skills/engineering/planning-and-task-breakdown) | Breaks work into ordered tasks. Use when you have a spec or clear requirements and need to break work into im… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill planning-and-task-breakdown -y` |
| [python-debugpy](skills/engineering/python-debugpy) | Debug Python: pdb REPL + debugpy remote (DAP). | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill python-debugpy -y` |
| [rate-limiting-go](skills/engineering/rate-limiting-go) | Rate limit Go HTTP APIs | local | `npx -y skills add sleeperagentai/skills --skill rate-limiting-go -y` |
| [security-and-hardening](skills/engineering/security-and-hardening) | Hardens code against vulnerabilities. Use when auditing an input handler for vulnerabilities, when handling u… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill security-and-hardening -y` |
| [shipping-and-launch](skills/engineering/shipping-and-launch) | Prepares production launches. Use when preparing to deploy to production, or when asking what needs to be in… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill shipping-and-launch -y` |
| [source-driven-development](skills/engineering/source-driven-development) | Grounds every implementation decision in official documentation. Use when you want to verify an approach agai… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill source-driven-development -y` |
| [spec-driven-development](skills/engineering/spec-driven-development) | Creates specs before coding. Use when starting a new project, feature, or significant change and no specifica… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill spec-driven-development -y` |
| [subagent-driven-development](skills/engineering/subagent-driven-development) | Execute plans via delegate_task subagents (2-stage review). | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill subagent-driven-development -y` |
| [test-driven-development](skills/engineering/test-driven-development) | Drives development with tests using the red-green-refactor loop. Use when implementing any logic, fixing any… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill test-driven-development -y` |
| [using-agent-skills](skills/engineering/using-agent-skills) | Discovers and invokes agent skills. Use when starting a session, or when you need to decide which skill or wo… | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | `npx -y skills add sleeperagentai/skills --skill using-agent-skills -y` |
| [writing-plans](skills/engineering/writing-plans) | Write implementation plans: bite-sized tasks, paths, code. | local | `npx -y skills add sleeperagentai/skills --skill writing-plans -y` |

### github — GitHub auth, pull requests, issues, code review and repo management

| Skill | What it does | Source | Install |
|---|---|---|---|
| [github-auth](skills/github/github-auth) | GitHub auth setup: HTTPS tokens, SSH keys, gh CLI login. | local | `npx -y skills add sleeperagentai/skills --skill github-auth -y` |
| [github-code-review](skills/github/github-code-review) | Review PRs: diffs, inline comments via gh or REST. | local | `npx -y skills add sleeperagentai/skills --skill github-code-review -y` |
| [github-issues](skills/github/github-issues) | Create, triage, label, assign GitHub issues via gh or REST. | local | `npx -y skills add sleeperagentai/skills --skill github-issues -y` |
| [github-pr-workflow](skills/github/github-pr-workflow) | GitHub PR lifecycle: branch, commit, open, CI, merge. | local | `npx -y skills add sleeperagentai/skills --skill github-pr-workflow -y` |
| [github-repo-management](skills/github/github-repo-management) | Clone/create/fork repos; manage remotes, releases. | local | `npx -y skills add sleeperagentai/skills --skill github-repo-management -y` |

### knowledge — Knowledge graphs, diagrams, research, wikis and documentation tooling

| Skill | What it does | Source | Install |
|---|---|---|---|
| [architecture-diagram](skills/knowledge/architecture-diagram) | Create polished dark-themed architecture diagrams as self-contained HTML+SVG files. Use when the user asks fo… | [cocoon-ai/architecture-diagram-generator](https://github.com/cocoon-ai/architecture-diagram-generator) | `npx -y skills add sleeperagentai/skills --skill architecture-diagram -y` |
| [blogwatcher](skills/knowledge/blogwatcher) | Monitor blogs and RSS/Atom feeds via blogwatcher-cli tool. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill blogwatcher -y` |
| [excalidraw](skills/knowledge/excalidraw) | Hand-drawn Excalidraw JSON diagrams (arch, flow, seq). | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill excalidraw -y` |
| [graphify](skills/knowledge/graphify) | Use for any question about a codebase, its architecture, file relationships, or project content — especially… | [safishamsi/graphify](https://github.com/safishamsi/graphify) | `npx -y skills add sleeperagentai/skills --skill graphify -y` |
| [llm-wiki](skills/knowledge/llm-wiki) | Karpathy's LLM Wiki: build/query interlinked markdown KB. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill llm-wiki -y` |
| [polymarket](skills/knowledge/polymarket) | Query Polymarket: markets, prices, orderbooks, history. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill polymarket -y` |
| [research-paper-writing](skills/knowledge/research-paper-writing) | Write ML papers for NeurIPS/ICML/ICLR: design→submit. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill research-paper-writing -y` |

### meta — Skills about finding, installing and authoring skills

| Skill | What it does | Source | Install |
|---|---|---|---|
| [claude-code-skill-management](skills/meta/claude-code-skill-management) | Manage skills for Claude Code CLI: install, update, remove, and organize third-party skills. | local | `npx -y skills add sleeperagentai/skills --skill claude-code-skill-management -y` |
| [find-skills](skills/meta/find-skills) | Helps users discover and install agent skills when they ask questions like "how do I do X", "find a skill for… | [vercel-labs/skills](https://github.com/vercel-labs/skills) | `npx -y skills add sleeperagentai/skills --skill find-skills -y` |
| [hermes-agent-skill-authoring](skills/meta/hermes-agent-skill-authoring) | Author in-repo SKILL.md files: frontmatter and structure. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill hermes-agent-skill-authoring -y` |
| [skill-finder](skills/meta/skill-finder) | Master finder: searches the sleeperagentai/skills catalog, suggests and installs skills; falls back to skills… | local | `npx -y skills add sleeperagentai/skills --skill skill-finder -y` |

### mlops — Model training, inference serving, evaluation and ML tooling

| Skill | What it does | Source | Install |
|---|---|---|---|
| [audiocraft-audio-generation](skills/mlops/audiocraft-audio-generation) | AudioCraft: MusicGen text-to-music, AudioGen text-to-sound. | third-party | `npx -y skills add sleeperagentai/skills --skill audiocraft-audio-generation -y` |
| [dspy](skills/mlops/dspy) | DSPy: declarative LM programs, auto-optimize prompts, RAG. | third-party | `npx -y skills add sleeperagentai/skills --skill dspy -y` |
| [evaluating-llms-harness](skills/mlops/evaluating-llms-harness) | lm-eval-harness: benchmark LLMs (MMLU, GSM8K, etc.). | third-party | `npx -y skills add sleeperagentai/skills --skill evaluating-llms-harness -y` |
| [huggingface-hub](skills/mlops/huggingface-hub) | HuggingFace hf CLI: search/download/upload models, datasets. | third-party | `npx -y skills add sleeperagentai/skills --skill huggingface-hub -y` |
| [llama-cpp](skills/mlops/llama-cpp) | llama.cpp local GGUF inference + HF Hub model discovery. | third-party | `npx -y skills add sleeperagentai/skills --skill llama-cpp -y` |
| [obliteratus](skills/mlops/obliteratus) | OBLITERATUS: abliterate LLM refusals (diff-in-means). | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill obliteratus -y` |
| [segment-anything-model](skills/mlops/segment-anything-model) | SAM: zero-shot image segmentation via points, boxes, masks. | third-party | `npx -y skills add sleeperagentai/skills --skill segment-anything-model -y` |
| [serving-llms-vllm](skills/mlops/serving-llms-vllm) | vLLM: high-throughput LLM serving, OpenAI API, quantization. | third-party | `npx -y skills add sleeperagentai/skills --skill serving-llms-vllm -y` |
| [weights-and-biases](skills/mlops/weights-and-biases) | W&B: log ML experiments, sweeps, model registry, dashboards. | third-party | `npx -y skills add sleeperagentai/skills --skill weights-and-biases -y` |

### productivity — Documents, spreadsheets, PDFs, task trackers and everyday tools

| Skill | What it does | Source | Install |
|---|---|---|---|
| [airtable](skills/productivity/airtable) | Airtable REST API via curl. Records CRUD, filters, upserts. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill airtable -y` |
| [box](skills/productivity/box) | Box manages cloud files, sharing, search, and metadata. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill box -y` |
| [docx](skills/productivity/docx) | Create, read, edit, template, and review Word .docx files. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill docx -y` |
| [flight-search](skills/productivity/flight-search) | Find cheap flights while dealing with anti-bot measures. | local | `npx -y skills add sleeperagentai/skills --skill flight-search -y` |
| [linear](skills/productivity/linear) | Linear: manage issues, projects, teams via GraphQL + curl. | local | `npx -y skills add sleeperagentai/skills --skill linear -y` |
| [nano-pdf](skills/productivity/nano-pdf) | Edit PDF text/typos/titles via nano-pdf CLI (NL prompts). | third-party | `npx -y skills add sleeperagentai/skills --skill nano-pdf -y` |
| [notion](skills/productivity/notion) | Notion API + ntn CLI: pages, databases, markdown, Workers. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill notion -y` |
| [ocr-and-documents](skills/productivity/ocr-and-documents) | Extract text from PDFs/scans (pymupdf, marker-pdf). | local | `npx -y skills add sleeperagentai/skills --skill ocr-and-documents -y` |
| [powerpoint](skills/productivity/powerpoint) | Create, read, edit .pptx decks with python-pptx. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill powerpoint -y` |
| [xlsx](skills/productivity/xlsx) | Create, read, edit Excel .xlsx workbooks and CSVs. | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `npx -y skills add sleeperagentai/skills --skill xlsx -y` |

### project — Skills written for the user's own projects (private context)

| Skill | What it does | Source | Install |
|---|---|---|---|
| [openstudio-development](skills/project/openstudio-development) | Use when working in the agentclip/openstudio monorepo. | local | `npx -y skills add sleeperagentai/skills --skill openstudio-development -y` |
| [openstudio-riso-rebuild](skills/project/openstudio-riso-rebuild) | OpenStudio Riso pixel-perfect UI rebuild (feat/riso-design). | local | `npx -y skills add sleeperagentai/skills --skill openstudio-riso-rebuild -y` |

### video — Remotion and programmatic video, motion graphics, media pipelines

| Skill | What it does | Source | Install |
|---|---|---|---|
| [ai-agentic-media-workflow](skills/video/ai-agentic-media-workflow) | Orchestrating multi-step AI generation pipelines for media creation (video, audio, images) with human approva… | local | `npx -y skills add sleeperagentai/skills --skill ai-agentic-media-workflow -y` |
| [ai-agentic-multimedia-workflow](skills/video/ai-agentic-multimedia-workflow) | Use this skill when building AI-powered multimedia generation platforms that require orchestration of multipl… | local | `npx -y skills add sleeperagentai/skills --skill ai-agentic-multimedia-workflow -y` |
| [full-stack-video-platform](skills/video/full-stack-video-platform) | Build a full-stack video processing platform with FastAPI backend, Next.js/Remotion frontend, Prefect orchest… | local | `npx -y skills add sleeperagentai/skills --skill full-stack-video-platform -y` |
| [remotion-agent-setup](skills/video/remotion-agent-setup) | Set up a Remotion project with agent skills for autonomous development. | local | `npx -y skills add sleeperagentai/skills --skill remotion-agent-setup -y` |
| [remotion-best-practices](skills/video/remotion-best-practices) | Router for all Remotion skills | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-best-practices -y` |
| [remotion-captions](skills/video/remotion-captions) | Transcribing, displaying and animating captions | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-captions -y` |
| [remotion-create](skills/video/remotion-create) | Create a new Remotion video | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-create -y` |
| [remotion-docs](skills/video/remotion-docs) | Search Remotion documentation | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-docs -y` |
| [remotion-interactivity](skills/video/remotion-interactivity) | Structure Remotion markup for interactivity | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-interactivity -y` |
| [remotion-maps](skills/video/remotion-maps) | Remotion Map animation knowledge | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-maps -y` |
| [remotion-markup](skills/video/remotion-markup) | Content, animation and effects best practices | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-markup -y` |
| [remotion-multimedia](skills/video/remotion-multimedia) | Interacting with Mediabunny | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-multimedia -y` |
| [remotion-render](skills/video/remotion-render) | Export a Remotion video | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-render -y` |
| [remotion-saas](skills/video/remotion-saas) | Build an app with Remotion | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-saas -y` |
| [remotion-studio](skills/video/remotion-studio) | Preview a Remotion video | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-studio -y` |
| [remotion-upgrade](skills/video/remotion-upgrade) | Upgrade Remotion, and related packages | [remotion-dev/skills](https://github.com/remotion-dev/skills) | `npx -y skills add sleeperagentai/skills --skill remotion-upgrade -y` |

### Collections (not vendored, install from upstream)

| Collection | What it is | Install |
|---|---|---|
| [anthropic-skills](collections/anthropic-skills.json) ([anthropics/skills](https://github.com/anthropics/skills)) | Anthropic's public Agent Skills: docx, pdf, pptx, xlsx, skill-creator, frontend-design, mcp-builder, webapp-testing, ca… | `npx -y skills add anthropics/skills --skill pdf -y` |
| [awesome-design-md](collections/awesome-design-md.json) ([VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md)) | Library of DESIGN.md files reverse-engineered from popular brand design systems (color, type, components, layout). Drop… | `Copy the wanted <site>/DESIGN.md into your project root and reference it from your agent instructions (AGENTS.md / CLAUDE.md).` |
| [bencium-design-skills](collections/bencium-design-skills.json) ([bencium/bencium-claude-code-design-skill](https://github.com/bencium/bencium-claude-code-design-skill)) | Bencium's design and development skills: controlled and innovative UX designer, impact designer, design audit, code con… | `npx -y skills add bencium/bencium-claude-code-design-skill --skill bencium-innovative-ux-designer -y` |
| [claude-code-workflows](collections/claude-code-workflows.json) ([OneRedOak/claude-code-workflows](https://github.com/OneRedOak/claude-code-workflows)) | OneRedOak's Claude Code workflows: design-review (Playwright-driven front-end review agent and /design-review command),… | `Clone the repo and copy design-review/ files (slash command, agent, design-principles example) into your agent's commands/agents directories as described in its README.` |
| [designer-skills](collections/designer-skills.json) ([Owl-Listener/designer-skills](https://github.com/Owl-Listener/designer-skills)) | Designer Skills Collection by Marie Claire Dean: 63 design skills and 27 commands in 8 plugins covering research, UX, v… | `npx -y skills add Owl-Listener/designer-skills --skill design-critique -y` |
| [emil-kowalski-skills](collections/emil-kowalski-skills.json) ([emilkowalski/skills](https://github.com/emilkowalski/skills)) | Emil Kowalski's skills for design engineers: emil-design-eng (animation and UI polish), review-animations, improve-anim… | `npx -y skills add emilkowalski/skills --skill emil-design-eng -y` |
| [styleseed](collections/styleseed.json) ([bitjaru/styleseed](https://github.com/bitjaru/styleseed)) | StyleSeed design-method engine: ss-setup wizard scaffolds a DESIGN-LANGUAGE.md and golden rules for a project; ss-updat… | `npx -y skills add bitjaru/styleseed --skill ss-setup -y` |
| [threejs-skills](collections/threejs-skills.json) ([CloudAI-X/threejs-skills](https://github.com/CloudAI-X/threejs-skills)) | Curated Three.js skill files (fundamentals, geometry, materials, lighting, animation, shaders, post-processing) for bui… | `npx -y skills add CloudAI-X/threejs-skills --all -y` |
| [vercel-agent-skills](collections/vercel-agent-skills.json) ([vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills)) | Vercel's official agent skills: react-best-practices, web-design-guidelines, composition-patterns, react-view-transitio… | `npx -y skills add vercel-labs/agent-skills --skill vercel-react-best-practices -y` |

### Plugins

| Plugin | What it does | Install |
|---|---|---|
| [ponytail](plugins/ponytail.json) ([DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)) | Lazy senior dev mode: forces the simplest, shortest solution that works (YAGNI, stdlib first, no unrequested abstractio… | `/plugin marketplace add DietrichGebert/ponytail, then /plugin install ponytail@ponytail` |
| [superwhisper](plugins/superwhisper.json) ([superultrainc/superwhisper-claude-code](https://github.com/superultrainc/superwhisper-claude-code)) | Superwhisper voice integration: speaks a notification when the agent finishes a task so you can dictate the next comman… | `/plugin marketplace add superultrainc/superwhisper-claude-code, then /plugin install superwhisper@superwhisper` |

<!-- catalog:end -->

## Licenses

Vendored skills keep their upstream license files. Where upstream publishes no license, the
`metadata.json` says so; those skills are kept here for personal use only.
