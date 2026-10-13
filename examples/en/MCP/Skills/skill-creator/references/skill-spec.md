# Skill Specification (This Project)

## File Layout

- **Flat**: `Skills/autonomous/<name>.md` — no affiliated resources
- **Directory**: `Skills/<skill-dir>/SKILL.md` + `references/`, `scripts/`, `agents/` — has affiliated resources

## frontmatter

```yaml
---
name: snake_case_name
description: Triggered when the user says: <Chinese trigger phrases, comma-separated>… . <one sentence explaining what it does>
---
```

- `name`: must start with a lowercase letter, only `[a-z0-9_]` allowed; **the registered name is based on it**, independent of the directory name
- `description`: determines when the model invokes the skill; must clearly state "what the user says to trigger it"

## Affiliated Resource Retrieval Protocol (required when affiliated resources are referenced)

> **Mandatory Resource Retrieval Protocol**: When loading resources under `references/`, `scripts/`, or `agents/`:
> 1. Call `tool_resource` with `parentName: <this skill's name>` and `path: <subdir>/<filename>`;
> 2. Treat its returned content as authoritative; never substitute memory or guesswork for it;
> 3. For scripts, fetch their content first, then execute them locally. `tool_resource` is the only retrieval channel.

## Registration Behavior (server `_scan_skills`)

- A directory containing `SKILL.md` → only SKILL.md itself is registered; `references/scripts/agents` are skipped
- An ordinary directory without SKILL.md → every `.md` inside it is registered as its own skill (`autonomous/` follows this pattern)
