---
name: remotion-agent-setup
description: Set up a Remotion project with agent skills for autonomous development.
category: media
version: 1.0.0
---

# Remotion Agent Setup

## Description
Set up a Remotion project pre‑configured with agent skills so that autonomous agents can continue development, rendering, and automation without manual intervention.

## When to Use
- Starting a new Remotion‑based video generation project (e.g., brainrotshorts.com).
- You want agents to handle subsequent feature work, rendering, or publishing.

## Steps

### 1. Verify Node.js
Ensure you have Node.js ≥16 (or Bun ≥1.0.3).  
```bash
node --version
```

### 2. Install Remotion Skills globally
This makes the `remotion skills` command available and pulls in the official agent skill packs.
```bash
npx -y skills@latest add remotion-dev/skills -g -y
```

### 3. Scaffold a new Remotion project
Run the interactive wizard and answer as follows:
```bash
npx create-video@latest
```
- **Template:** `Blank`
- **Add TailwindCSS?** `No`
- **Add agent skills?** `Yes`
- **Select skills to install:** Press `Space` on “Select All” to check all 12, then `Enter`.

The wizard will create a folder (e.g., `brainrotshorts/`).

### 4. Enter the project folder
```bash
cd <project-folder>
```

### 5. Install npm dependencies
```bash
npm i
```

### 6. Add agent skills to the project
Copies/links the skill packs into the project’s `.agents/skills/` folder.
```bash
npx remotion skills add
```
Again, choose **Select All** → `Enter`.

### 7. Start the development server
```bash
npm run dev
```
Remotion Studio will be available at `http://localhost:3000`.

## Agent‑First Workflow
Once the dev server is running, you can delegate tasks to agents using Hermes’ delegation or cronjob system, for example:
- Generate video scripts via LLM agents.
- Add AI‑generated voiceovers (TTS) with the `remotion-multimedia` skill.
- Automate captioning with `remotion-captions`.
- Set up a nightly cron job that renders a new batch of shorts and saves them to `~/<project>/output/`.

## Pitfalls & Troubleshooting
- **Missing `@remotion/tailwind-v4` error:** If you see `Cannot find module '@remotion/tailwind-v4'` when running `npx remotion skills add`, ensure you are inside the project folder and have run `npm i` first.
- **Interactive prompts hanging:** Use the `--yes`/`-y` flags where possible, or drive the wizard via `printf` and `pty` as shown in the session.
- **Global skill installation failures:** Some skills may refuse global install due to agent restrictions; installing locally inside the project (as shown) works reliably.

## References
- See `references/quick-start.md` for a condensed cheat‑sheet of the exact commands used in this session.