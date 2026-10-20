---
name: skill_creator
description: Triggered when the user says: create a skill, create a new skill, fetch a skill, install a skill, find a skill, adapt a skill, skill-creator, create skill, fetch skill, install skill, recommend a skill, what skills are there. Find/fetch/create/adapt a Skill: run prerequisite checks first (duplicate detection, naming, source), then adapt and land it.
---

> **Mandatory Resource Retrieval Protocol**: When loading resources under `references/`, `scripts/`, or `agents/`, you must:
> 1. Call `tool_resource` with `parentName: skill_creator` and `path: <subdir>/<filename>`;
> 2. Treat its returned content as authoritative; never substitute memory or guesswork for it;
> 3. For scripts, fetch their content first, then execute them locally. `tool_resource` is the only retrieval channel.

# Skill Creator: Find → Fetch/Create → Adapt → Land

## Goal

Turn an external or self-authored skill into one that is **registrable in this project**, so that once landed it can be invoked as an MCP tool.

## Landing Location (single criterion)

- **No affiliated resources** → `[notes]/MCP/Skills/autonomous/<name>.md` (a single .md)
- **Has affiliated resources** → `[notes]/MCP/Skills/<skill-dir>/SKILL.md`, with affiliated files placed under `references/`, `scripts/`, `agents/`
- `[notes]` = config `mcp.knowledgeBasePath`
- The registered name is taken from the `name` field of the SKILL.md frontmatter, and is **independent of the directory name**

## Steps

### 1. Prerequisite Checks

- Scan the existing skills under `Skills/` (including `autonomous/`) and list each one's `name`
- If the target name already exists → report the conflict and ask the user whether to overwrite or rename; **never overwrite silently**

### 2. Source Decision

- The user provides a GitHub / URL → fetch: call `scripts/fetch_skill.sh <url>`
- No external source → create new: write from scratch following `references/skill-spec.md`

### 3. Adapt to This Project

- The frontmatter must contain `name` (snake_case) and `description` (Chinese trigger phrases, clearly stating "what the user says to trigger it")
- Localize the body to Chinese; keep code and commands as-is
- Remove external proprietary dependencies; rewrite paths into a form usable by this project
- If affiliated resources are referenced → add a "Mandatory Resource Retrieval Protocol" block to the body (see the template in `references/skill-spec.md`)

### 4. Land

Write it according to "Landing Location"

### 5. Validate

Call `scripts/validate_skill.py <path>`; if it reports errors, fix until it passes

### 6. Confirm Registration

The skill should appear in the MCP tool list; if not, restart the MCP service and check `~/.cache/utility/server.log`
