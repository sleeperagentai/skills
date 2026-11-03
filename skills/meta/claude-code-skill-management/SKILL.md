---
name: claude-code-skill-management
description: "Manage skills for Claude Code CLI: install, update, remove, and organize third-party skills."
trigger: "/claude-code-skill-management"
---
# Claude Code Skill Management

Manage skills for Claude Code CLI: install, update, remove, and organize third-party skills (e.g., from awesome-ai-tools-for-ui) as slash-commands.

## When to Use
- You want to install a batch of skills from a curated list (e.g., awesome-ai-tools-for-ui).
- You need to handle sites that block automated downloads (e.g., Vercel Security Checkpoint).
- You want to ensure skills are available as slash-commands in Claude Code.

## Steps

### 1. Extract Skill List from Source
If you have a README or webpage listing skills with names and URLs:
```bash
# Example for awesome-ai-tools-for-ui
curl -s https://raw.githubusercontent.com/maxbogo/awesome-ai-tools-for-ui/main/README.md |
  sed -n '38,67p' |   # Adjust lines based on actual "Skills" section
  grep '^- ' |
  sed 's/^- ⭐️ //;s/^- //' |
  sed -n 's/.*\[\([^]]*\)\].*/\1/p' > skill_names.txt
# Also extract URLs if needed (see notes below).
```

### 2. Prepare Installation Directory
Ensure Claude Code skills directory exists:
```bash
mkdir -p ~/.claude/skills
```

### 3. Download Skill Files
For each skill, create a directory and download its SKILL.md (or equivalent):
```bash
while IFS='|' read -r name url; do
  # Normalize name: lowercase, spaces to hyphens, remove punctuation
  norm=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//')
  echo "Installing $name -> $norm"
  mkdir -p "~/.claude/skills/$norm"
  # Try direct download; if blocked, fall back to manual
  curl -sfL "$url" -o "~/.claude/skills/$norm/SKILL.md" ||
    echo "Failed to download $url; manual install may be needed (see pitfalls)."
done < skill_list.txt
```

### 4. Verify Installation
List installed skills:
```bash
ls -la ~/.claude/skills/
```
Each skill directory should contain a `SKILL.md` file. The skill will be available in Claude Code as a slash-command using the normalized name (e.g., `/impeccable`).

## Pitfalls
- **Vercel Security Checkpoint**: Some sites (e.g., TypeUI Design Skills at https://www.typeui.sh) employ bot protection that returns an HTML challenge page instead of the skill file. Automated `curl` will save the challenge page, resulting in an invalid skill.  
  **Workaround**: Visit the URL in a browser, complete the challenge, then manually copy the skill content into `~/.claude/skills/<norm>/SKILL.md`. Alternatively, look for a raw skill file repository (often on GitHub) and use that URL directly.
- **Skill Format Variability**: Not all sources provide a raw `SKILL.md`; some link to a GitHub page or a web preview. In such cases:
  - Replace `github.com/.../blob/` with `raw.githubusercontent.com/` to get the raw file.
  - If the page is a web preview, look for a "Download" or "Raw" button, or inspect the network tab for the actual skill file.
- **Name Collisions**: Different sources may use the same skill name. Check existing directories before installing; consider prefixing with source (e.g., `awesome-impeccable`).

## Verification
After installation, start Claude Code and run:
```
/<skill-name> --help
```
or simply invoke the skill to see its output.

## Maintenance
- To update a skill, repeat the download step.
- To remove a skill, delete its directory under `~/.claude/skills/`.
- Periodically check the source list for new skills or updates.

## References
- See `references/vercel-security-checkpoint.md` for detailed notes on handling bot-protected sites.