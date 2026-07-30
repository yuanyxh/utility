---
date: 2026-07-30
tags: [token-proxy, openai, api-format, architecture]
---

# Token Proxy OpenAI 格式适配

## 背景
用户使用 DeepSeek API（OpenAI 兼容格式）时，token_proxy.py 原先仅支持 Anthropic 格式的 SSE 解析和系统提示词注入。

## 改动
1. **格式检测**：`_detect_api_format()` 三步判断
   - 顶层 `system` 数组 → Anthropic
   - `messages[0].role == "system"` → OpenAI
   - tools 定义 `inputSchema` → Anthropic，`type: "function"` → OpenAI

2. **SSE 解析**：3 个提取函数新增 `api_format` 参数
   - `_extract_usage_from_sse()`：OpenAI 读 `choices[0].finish_reason`，映射为统一 stop_reason；usage 字段归一化（prompt_tokens→input_tokens, completion_tokens→output_tokens）
   - `_extract_output_from_sse()`：OpenAI 读 `choices[0].delta.content`
   - `_extract_tool_name_from_sse()`：OpenAI 读 `choices[0].delta.tool_calls[0].function.name`

3. **记录**：`record_usage()` 新增 `api_format` 参数写入数据库

## 缓存控制策略
- **Anthropic 格式**：系统提示词注入到 `system` 数组末尾，不设 `cache_control`，自然不在缓存前缀中
- **OpenAI 格式**：追加到已有 system message 的 content 数组，原始最后一块设 `prompt_cache_breakpoint: {mode: "explicit"}`，注入内容在断点后
  - `prompt_cache_breakpoint` 是 per-content-block 级别，标记缓存前缀的精确终点（包含该块）
  - `prompt_cache_options: {mode: "explicit"}` 是请求级全局设置，会禁用整个请求的缓存
  - 仅在 content 为数组格式时可用，GPT-5.6+ 模型支持

## 关键文件
- `Sources/MCPScripts/token_proxy.py`：`_detect_api_format()`, `_extract_usage_from_sse()`, `_extract_output_from_sse()`, `_extract_tool_name_from_sse()`, `_inject_system_prompt()`, `record_usage()`
- `Sources/MCP/TokenProxyManager.swift`：buildEnv() 传递 NOTES_DIR 给 token_proxy.py
