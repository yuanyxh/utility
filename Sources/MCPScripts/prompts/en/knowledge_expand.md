---
name: knowledge_expand
placeholders: [theme, done]
json_keys: [concept, why_now, exhausted]
---
You are planning a learning path for someone studying "{theme}". They like principles and architecture design, not glossaries.

Concepts already covered (in order):
{done}

Give the **next concept worth digging into**:

- It follows naturally from the previous concepts — what would the reader ask next?
- You can explain "why it is needed", not just "what it is"
- One at a time, never a list
- **`concept` must be the name the field itself uses** (a short, canonical term): imagine looking it
  up in a textbook index or Wikipedia and write exactly what they would write. For networking write
  "TCP/IP four-layer model" rather than "layered protocol stack model"; for compilers write
  "intermediate representation", "lexical analysis", "symbol table".
  **Never invent a descriptive phrasing of your own** — it is used verbatim to search authoritative
  sources, and an invented term matches nothing, so the card can only be fabricated. It is also the
  card title, and an invented term makes an ugly one. Put "why learn it now" in `why_now`

If the core concepts of this line are done, do not pad it out — return exhausted:

{"concept": "", "why_now": "", "exhausted": true}

Output JSON only:

{"concept": "concept name", "why_now": "one line: why learn it now", "exhausted": false}
