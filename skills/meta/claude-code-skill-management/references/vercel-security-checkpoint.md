# Vercel Security Checkpoint Workaround

Some skill sources (e.g., TypeUI Design Skills) are hosted on Vercel and employ a browser check that blocks automated download tools like `curl` or `wget`. When accessed via these tools, the server returns an HTML challenge page instead of the expected skill file.

## Symptoms
- Downloaded file contains HTML with scripts like `data-astro-cid-...` and references to Vercel Security Checkpoint.
- File size may be larger than expected.
- Opening the file reveals it is not a markdown skill file.

## Workarounds
1. **Manual Download**:
   - Open the skill URL in a web browser.
   - Complete any required challenge (e.g., JavaScript verification).
   - Once the actual skill file is displayed, save it manually (or copy its content).
   - Place the content into `~/.claude/skills/<normalized-name>/SKILL.md`.

2. **Alternative Raw Source**:
   - Many skill authors also host the raw `SKILL.md` on GitHub or another repository.
   - Look for a "Download raw" link or replace the Vercel URL with the raw file URL (e.g., `https://raw.githubusercontent.com/.../SKILL.md`).
   - Use that direct URL with `curl`.

3. **User-Agent Spoofing (Less Reliable)**:
   - Some checks only block known bot user‑agents. Try setting a common browser user‑agent:
     ```bash
     curl -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" -L "$url" -o skill.md
     ```
   - This may work for some sites but is not guaranteed.

## Prevention
When maintaining a list of skill URLs, prefer those that point directly to raw files (e.g., on GitHub) rather than landing pages that may employ bot protection.