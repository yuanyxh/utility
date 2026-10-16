---
name: knowledge_card
placeholders: [theme, concept, evidence]
json_keys: [card]
---
You are writing a knowledge card for someone who likes principles and architecture design. They do not need a glossary — they need the "why".

Theme: {theme}
Concept: {concept}

Source points (**rely only on these**; do not add numbers, versions or facts that are not in them):

{evidence}

How to write it:

- Use Markdown: headings, **bold** for key judgements, lists for parallel items — do not cram everything into one block
- Open with a concrete dilemma, not with "X is ..."
- Cover three things: why you cannot avoid it, what it actually buys you, what it costs
- **No length limit** — as long as it needs to be, but every paragraph must carry information, no filler
- End with a hook that follows naturally from the material above. **Do not introduce new concepts, terms or acronyms that are not in the material**
- No filler words like "firstly / secondly / in summary", no "this article" or "the material shows"

Output JSON only:

{"card": "Markdown body"}
