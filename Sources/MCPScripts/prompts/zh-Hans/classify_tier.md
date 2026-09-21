---
name: classify_tier
placeholders: [tier_lines, last_user_message]
json_keys: []
---
根据以下用户消息归类。可选类别：
{tier_lines}

只输出类别名，禁止输出其他任何内容，否则退回重走。

## 用户消息
{last_user_message}
