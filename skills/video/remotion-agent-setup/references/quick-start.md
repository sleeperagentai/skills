# Quick‑Start Cheat Sheet

## 1. Install Remotion Skills globally
```bash
npx -y skills@latest add remotion-dev/skills -g -y
```

## 2. Scaffold a new Remotion project (interactive)
```bash
npx create-video@latest
```
- Template: `Blank`
- Add TailwindCSS?: `No`
- Add agent skills?: `Yes`
- Select skills: `Space` on “Select All”, then `Enter`

## 3. Enter project folder
```bash
cd <project-folder>
```

## 4. Install dependencies
```bash
npm i
```

## 5. Add agent skills to project
```bash
npx remotion skills add
```
- Choose **Select All** → `Enter`

## 6. Start dev server
```bash
npm run dev
```
→ Remotion Studio at `http://localhost:3000`