---
name: technical-environment-setup
description: Comprehensive setup for technical work environments including shell configuration, knowledge vault organization, and structured learning systems with automated task delivery.
category: productivity
---

# Technical Environment Setup

Comprehensive setup for technical work environments including shell configuration, knowledge vault organization, and structured learning systems with automated task delivery.

## When to Use

- Setting up a new development machine or user account
- Creating a structured environment for learning technical subjects
- Establishing a productive workspace with automated knowledge organization
- Onboarding developers or learners to a standardized technical environment

## Overview

This skill combines environment setup, knowledge organization, and learning system automation to create a cohesive technical workspace. It covers:

1. **Shell Environment** - Configure Oh My Zsh with essential plugins and optimizations
2. **Knowledge Vault** - Set up an Obsidian-based knowledge organization system  
3. **Learning System** - Implement structured curriculum with automated task delivery and progress tracking

## 1. Shell Environment Setup

### Install Oh My Zsh
```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

### Add Useful Plugins
Clone popular plugins into the custom plugins directory.

```sh
# Autosuggestions
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

# Enhanced completions
git clone https://github.com/zsh-users/zsh-completions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-completions
```

### Update .zshrc
Enable the installed plugins and add performance/comfort tweaks.

```sh
# Ensure plugins line includes git, zsh-autosuggestions, zsh-completions
# Example:
# plugins=(git zsh-autosuggestions zsh-completions)

# Fast completions and caching
zstyle ':completion::complete:*' use-cache on
zstyle ':completion::complete:*' cache-path ~/.zsh/cache

# Autosuggestions styling
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#9e9e9e'
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
```

> **Tip:** Use `patch` or `sed` to modify the plugins line if you prefer not to edit the file manually.

### Verify Shell Installation
Start a new terminal session and confirm:
- Oh My Zsh theme loads
- Autosuggestions appear as you type
- Tab completion shows enhanced completions

## 2. Knowledge Vault Organization

Set up a structured knowledge vault using Obsidian (or similar tools like Notion, Logseq) for learning, notes, and project tracking.

### Knowledge Organization Structure

Create a hierarchical knowledge vault with:

```
[Your Technical Vault]/
├── README.md                    # Vault overview and purpose
├── learning-plan.md             # Detailed curriculum with phases/weeks
├── TEMPLATES/                   # Reusable templates
│   └── Daily-Log-Template.md    # Template for daily progress notes
├── LEARNING/                    # All learning materials organized by phase
│   ├── Phase0-Foundations/
│   │   ├── daily-task-log.md    # Log of automated tasks sent
│   │   └── [topic-specific notes]/
│   ├── Phase1-[TopicName]/
│   ├── Phase2-[TopicName]/
│   └── ...                      # Continue through all phases
└── RESOURCES/                   # Curated external resources
    ├── books.md
    ├── courses.md
    ├── tools.md
    └── datasources.md
```

### Vault Root Files
- `README.md` – Overview of the vault.
- `learning-plan.md` – Detailed curriculum or project roadmap.
- `daily-log-template.md` – Template for daily progress notes (see templates/).

### Phase Folders (under LEARNING/)
Create folders for each learning phase or project module:

```
LEARNING/
├── Phase0-Foundations/
├── Phase1-MarketMechanics/
├── Phase2-Statistics/
├── Phase3-Algos/
├── Phase4-Risk/
├── Phase5-Architecture/
├── Phase6-Prototype/
└── Phase7-Testing/
```

### Example Files
See `templates/` directory for starter files like `daily-log-template.md` and `learning-plan.md`.

## 3. Structured Learning System

Implement a structured approach to self-directed technical learning with automated delivery, knowledge organization, and practical application.

### Curriculum Design Principles

1. **Phase-Based Learning**: Break the subject into 4-7 logical phases, each 2-6 weeks
2. **Weekly Objectives**: Clear, measurable goals for each week
3. **Daily Breakdown**: 2-hour daily sessions divided into:
   - 30% Conceptual learning (reading, videos)
   - 30% Practical application (coding, exercises)
   - 20% Review/reflection
   - 20% Hands-on projects/builds
4. **Deliverables**: Tangible output at end of each phase/week
5. **Ongoing Practices**:
   - Daily reflection (10 min): What learned, questions, next steps
   - Weekly review (30 min): Demo work, note blockers, adjust plan
   - Community engagement: Forums, discussion groups

### Detailed Daily Learning Task Format

Automated daily learning tasks should be RICH and ACTIONABLE, not brief reminders. Each task must include:

- **Clear date and phase/week/day identification** (e.g., "Phase 0 – Foundations - Week 1, Day 2")
- **Specific time-blocked activities** with exact durations (e.g., "30 min Python Review")
- **Direct links to recommended resources** (videos, articles, documentation) to reduce search time
- **Hands-on exercises** with code snippets, commands, or practical steps
- **Clear deliverable** for the session (what to produce/save)
- **Well-formatted output** using markdown tables, bold headers, and visual cues (emojis, icons)
- **Resource links section** for quick reference
- **After-session guidance** for logging progress and reflection

### Automated Task Delivery System

#### Components

1. **Start Date**: Set fixed start date (Day 1 of Phase 0, Week 1)
2. **Task Generator**: Script that calculates:
   - Current week and day based on start date
   - Current phase (based on week number)
   - Appropriate learning activity for that day/week
3. **Delivery Mechanism**: Scheduled job that:
   - Runs the task generator at set time (e.g., 6:00 AM daily)
   - Sends formatted task via preferred channel (Telegram, email, etc.)
   - Logs sent tasks for review/audit
4. **Progress Tracking**:
   - Daily notes created from template
   - Phase-specific logs of automated tasks
   - Weekly review notes

#### Implementation Example (Python + Telegram + Cron)

```python
# daily_learning_task.py
import datetime
import subprocess
import os

START_DATE = datetime.date(YYYY, MM, DD)  # Your fixed start date
TELEGRAM_TARGET = "your-telegram-target"   # From `hermes send_message --list`

def get_task_for_date(today: datetime.date):
    # Calculate week/day, determine phase, return formatted task string
    # (See full implementation in references/daily_task_generator.md)
    pass

def main():
    today = datetime.date.today()
    task = get_task_for_date(today)
    # Send via Hermes CLI: hermes send_message --target X --message Y
    # Log sent task to appropriate phase folder
    pass

if __name__ == '__main__':
    main()
```

Schedule with cron: `0 6 * * * /path/to/daily_learning_task.py`

### Daily Learning Routine

1. **Receive automated task** via your preferred channel at set time
2. **Create daily log** from template:
   - Copy TEMPLATES/Daily-Log-Template.md to YYYY-MM-DD.md
   - Fill in sections: What I Learned, Hands-On, Questions, Next Steps, Time Spent
3. **Execute learning activities** (~2 hours total)
4. **Update log** with results, code snippets, insights
5. **Save note** in appropriate location (vault root or phase folder)
6. **Optional**: Mark completion in Telegram/chat if desired

### Weekly Review Process

At end of each week:
1. Review all daily notes from the week
2. Create weekly summary note:
   - Accomplishments/deliverables completed
   - Concepts mastered vs. still unclear
   - Code/projects built
   - Questions that arose
   - Adjustments needed for upcoming weeks
3. Update learning plan if pacing needs adjustment
4. Identify next week's focus areas

### Knowledge Capture Guidelines

When learning, capture:
- **Concepts**: Definitions, explanations, diagrams (in your own words)
- **Commands**: Exact terminal/code commands that worked
- **Configurations**: Working config files with explanations
- **Code snippets**: Small, focused examples that illustrate concepts
- **Resources**: Links to articles, videos, docs with brief annotations
- **Blockers**: What didn't work, error messages, how you resolved
- **Ideas**: Applications, extensions, project ideas that arise

### Common Pitfalls and Solutions

| Pitfall | Solution |
|---------|----------|
| **Consuming without creating** | Enforce 50/50 rule: for every 30 min of input, spend 30 min on output (notes, code, exercises) |
| **Falling behind schedule** | Build in buffer weeks; adjust pacing based on weekly review, don't skip fundamentals |
| **Getting stuck in tutorial hell** | After each tutorial, immediately build something original using the concepts |
| **Losing motivation** | Weekly demos of working code/projects; share progress with community |
| **Disorganized notes** | Strict adherence to vault structure; weekly organization session (15 min) |
| **Ignoring fundamentals** | Spend extra time on Phase 0-2; these compound throughout the curriculum |

### Progress Indicators

You're making good progress when you can:
- Complete weekly deliverables without excessive struggle
- Explain concepts to others (or rubber duck) clearly
- Build small original projects using learned concepts
- Identify and correct your own misconceptions
- Feel excited to start each day's learning session
- See connections between different topics/modules

### Adaptation for Different Subjects

While designed for technical learning, this system adapts to:
- **Languages**: Replace coding exercises with conversation/writing practice
- **Hardware/Electronics**: Substitute breadboard projects and instrumentation labs
- **Theoretical subjects**: Increase time for problem-solving and derivation practice
- **Creative technical**: Balance theory with creative projects (generative art, game dev, etc.)

### Maintenance and Evolution

- **Quarterly**: Review overall progress; adjust long-term goals
- **After each phase**: Conduct retrospective; refine upcoming phases based on what worked
- **When blocked**: Seek specific help; don't let single topics derail entire plan
- **Completion**: After finishing, consider: teaching others, building portfolio projects, or starting advanced specialization

## Pitfalls & Troubleshooting

- **Plugin not loading:** Ensure the plugin directory exists under `$ZSH_CUSTOM/plugins` and the plugin name is correctly spelled in the `plugins=(...)` line.
- **Slow startup:** Disable unnecessary plugins; keep only those you use daily.
- **Completion cache issues:** Delete `~/.zsh/cache/*` if completions stale, then restart shell.
- **Permission errors:** If using `sudo` with Oh My Zsh install script, avoid it; the script expects to write to your home directory.
- **Service binding:** Ensure services are listening on all interfaces (0.0.0.0) or the appropriate interface, not just localhost (127.0.0.1).
- **Firewall:** Local firewalls may block incoming connections; configure appropriately for your setup.
- **DNS propagation:** MagicDNS changes may take a moment to propagate; wait a few seconds if a new hostname doesn't resolve immediately.

## Verification

After setup, verify by:
- Starting a new terminal session and confirming Oh My Zsh loads with plugins
- Checking that the Obsidian vault opens and shows the expected folder structure
- Verifying automated learning tasks are generated and delivered (if configured)
- Testing service access via constructed URLs (if applicable)

## References

- Oh My Zsh official repo: https://github.com/ohmyzsh/ohmyzsh
- zsh-autosuggestions: https://github.com/zsh-users/zsh-autosuggestions
- zsh-completions: https://github.com/zsh-users/zsh-completions
- Obsidian help: https://help.obsidian.md/
- Trading vault specialization: references/trading-vault-specialization.md
- Session example: references/session-summary.md
- Daily task generator: references/daily_task_generator.md

## Templates

- `templates/daily-log-template.md` – Ready‑to‑use daily note format.
- `templates/learning-plan.md` – Example curriculum outline.

## Scripts

- `scripts/setup_env.sh` – Automates shell environment and basic vault setup (optional).
- `scripts/daily_learning_task.py` – Automated learning task generation and delivery (optional).