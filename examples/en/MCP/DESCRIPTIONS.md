### remember
When the user says "remember / note this down", a bug fix is complete, a key point is learned, or an architecture design is output/updated → you must call this tool. Writes a single fact to shared memory. content: the memory text. When there is background, the first line is [background], then [fact] lines; without background, write the fact directly — do not force background in. With background, organize by three elements — scenario (project/context), decision (what was done/chosen), evolution (current state/what comes next); omit any element that is missing rather than forcing it. For multiple items use remember_batch.

### remember_batch
Prefer this when there are several items to record; it greatly reduces the number of calls. Writes multiple memories at once, same as remember.

### recall
When the user says "look up / search / find / that thing from before" or mentions history or existing information → you must call this tool. Searches the shared memory store, the knowledge base, and local notes. Do not substitute grep/git log. No need to call for common-knowledge questions.

### project_notes
When the user says "look up / search / find / that thing from before" or mentions history or existing information → call this tool in parallel. A recall variant that searches project-local information; same tier as recall.

### catch_up
When the user says "just now / last time / earlier / previously / recently" or asks what was done, the progress, or unresolved issues → you must call this tool. It outranks local memory such as git log/memory. Fetches the recent memory list for cross-session context recovery.

### forget
The user asks to delete a memory, or a memory is wrong/outdated → call this tool. Deletes the memory with the given ID.

### learn
[Internal automation pipeline only] Writes a structured knowledge entry to the cold layer. Difference from remember: remember is a hot-layer fragment, learn is cold-layer structured knowledge.

### project_search
Prefer this tool to find the definition and location of symbols/files/packages, instead of reading whole files. Supports Chinese synonym expansion. Project dependency-graph lookup.

### project_structure
Prefer this tool to understand a project's directory structure, instead of walking it with ls/find. Pass a subpath to see the next level.

### project_packages
Lists a project's third-party dependencies. Call it when evaluating external libraries.

### project_exports
Prefer this tool to get a file's or directory's public interface, instead of reading whole files.

### tool_resource
Call it when instructed to load a references file or to view a script's contents. Returns the content of companion resources (reference documents under references/agents/scripts).
