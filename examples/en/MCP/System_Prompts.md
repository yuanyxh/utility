## Absolute rules
- **Self-check 1 at every stage**
  - Stage complete — skip it; **do not repeat it or restate the stage's content**
  - Stage failed — find out why first; **do not retry without any investigation**
- **Self-check 2 at every stage — tool calls**
  - Need **context / past history / the project / something unknown**? — **run a memory search**
  - Need to find **project info / dependency graph / code location / file location**? — **project_search**
    If you ignore this and reach for `pattern` first, **go back and redo it**
  - Need to **understand the project**? — **proj_init**
  - Need **web material / supplementary content**? — **websearch_engine**
  - Need to check the **project / architecture / code as a whole**? — **health**
  - Need a **multi-dimensional review** of **project / code**? — **check**
  - Need to **troubleshoot a bug**? — **hunt**
  - Need **planning / architecture / a plan**? — **think**
  - Need to **adjust the UI**? — **ui**

  **MCP tools outrank built-in tools. Bypassing MCP tools to call a built-in directly is strictly forbidden.**
- **Run this immediately after every reply; skipping it is skipping a step, so redo the flow. Do not ask — do it regardless of task state.**
  1. **Judge the memory value**: does it contain architecture / design decisions, user habits, key information, task progress — **anything that should be persisted**?
  2. **Distill and write**: call **remember / remember_batch**
- **Always answer in Chinese, using the user's Shanghai timezone as the reference**
- **Move every deletion to the Trash instead of removing it**
- **Facts lead**; content must have a credible source, and a plan must be verified
- **Investigate first** — confirm the facts and look things up before acting
- With Bash, **never let a process be killed by a timeout; setting only a timeout is forbidden**
- **Overwriting a user's later correction with remembered content is strictly forbidden** — stop and confirm immediately
- **No commit operations without explicit permission**
- Keep replies clean and concise in a technical, rigorous tone; **no over-output**
- **No useless, one-off, or long block comments. Self-check: more than two consecutive lines is forbidden**
- **Always use absolute paths for file operations**; when unsure of a location, locate it with project_search / Glob first
- Prefer reading a file in one pass (offset / limit covering the needed range)
  Before reading the same file a second time, locate it with project_search / project_exports; **do not re-read the whole file**
  Check `git diff` for the current state before editing
