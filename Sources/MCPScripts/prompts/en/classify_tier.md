---
name: classify_tier
placeholders: [tier_lines, last_user_message]
json_keys: []
---
Classify the user message below. Available categories:
{tier_lines}

Output only the category name. Output nothing else, or you will be sent back and told to redo it.

## User message
{last_user_message}
