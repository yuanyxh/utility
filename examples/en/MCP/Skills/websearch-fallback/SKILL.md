---
name: websearch-fallback
description: Triggered when the user says: web search, online search, look something up, search the web, search for the latest information, look it up; this kind of online-search request, or when you need to find web resources. Prefer the built-in WebSearch; on empty results, immediately fall back to Bash+curl to scrape a search engine and parse the results.
---

> **Mandatory resource retrieval protocol**: When this document asks you to load resources under the `scripts/` directory (instructions such as `scripts/search.sh`, `scripts/bing_search.sh`, etc.), you must follow these steps:
>
> 1. Call the `tool_resource` tool with `parentName: websearch-fallback` and `path: <subdir>/<filename>`;
> 2. Treat the content returned by `tool_resource` as authoritative; never substitute memory or guesswork for it;
> 3. After fetching the script, run it in a local shell (Bash); do not obtain script content through other channels such as local file reads or curl — `tool_resource` is the only permitted retrieval method.

# Web Search

## Execution Flow (in order, no skipping steps)
1. **Prefer the built-in WebSearch tool** to locate keywords and obtain a structured result list.
   
   - An empty template returned (`Web search results for query: X` + no Links) or 0 results → immediately switch to step 2.
   
2. **Core path: cascade multiple search engines**:
   
   - Use the unified entry script `scripts/search.sh` to scrape several search engines
   - Supported engines: Bing, Google, DuckDuckGo, Brave
   - Default cascade mode: Bing → Google → DuckDuckGo → Brave, until enough results are obtained (≥5)
   
   ```bash
   # fetch the script content via tool_resource (parentName: websearch-fallback)
   bash <this-skill-dir>/scripts/search.sh "keyword1 keyword2"
   ```
   
   - You can also specify a single engine:
     ```bash
     bash <this-skill-dir>/scripts/search.sh --engine=google "keyword"
     ```
   
   - Or merge the results of all engines:
     ```bash
     bash <this-skill-dir>/scripts/search.sh --all "keyword"
     ```
   
3. **Dig into the full text**: use the `read` tool on the matched URLs to obtain the detailed content
   
4. **Unpromising search results**: too many keywords → reduce; too few → add; no results in Chinese → immediately switch to English, and vice versa.

## Search Quality (mandatory)
- **Result count**: obtain at least 10 complete, non-duplicate results; if short, switch keywords to make up the difference.
- **Precise keywords**: `core terms + qualifiers` (year / type / platform / language); never search a single broad word directly.
- **Use syntax well**: `"exact phrase"` (quoted match), `site:domain` (restrict to a site), `-excluded-term` (filter out noise).
- **Strong-relevance filter**: discard anything unrelated to the keywords; judge relevance solely by "title + URL".
- **Traceable sources**: every conclusion must cite a real URL; if there are no results, say so honestly; never fabricate content or invent sources.

## Search Speed (mandatory)
- **Single-pass coverage**: prefer covering multiple keyword sets in one round to reduce round trips.
- **Bounded attempts**: at most ≤3 searches per question; if several attempts still fall short → stop immediately and say so honestly; never spin in place.
- **Cut losses immediately**: when a keyword / engine clearly returns nothing, switch immediately; never retry the same spot more than once.

## Search Engine Selection

| Engine | Characteristics | Best for |
|------|------|----------|
| Bing | Good Chinese support, rich results | Chinese content, Chinese sites |
| Google | Global coverage, high result quality | English content, international sites |
| DuckDuckGo | Privacy-focused, no tracking | Privacy-sensitive scenarios |
| Brave | Newer engine, novel results | Technical content, news |

## Privacy Notes

- By default, use the local search-engine scraping script; the URL never leaves this machine
- When fetching page details, use the `read` tool by default
- To fetch a JS-rendered page through proxy mode, explicit user consent is required (`--use-proxy`)
- Never use proxy mode for authenticated, internal, or sensitive URLs

## Error Handling

| Scenario | Handling |
|------|----------|
| A single engine fails | Continue with the next engine |
| All engines fail | Stop and tell the user; never fabricate results |
| `read` fails | Tell the user the specific failure reason and suggest an alternative |
| Insufficient results | Switch keywords and retry, at most 3 times |
| CAPTCHA/403 | Switch to another engine; never retry the same engine |
