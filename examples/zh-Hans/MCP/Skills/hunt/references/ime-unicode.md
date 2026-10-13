# IME / Unicode 调试参考

Tauri 与原生 macOS app 中反复出现的模式。在形成假设之前，先检查这些。

## IME 状态不同步

**症状**：拉丁字符显示正常，但 CJK 输入被丢弃、重复，或在错误的时机被提交。

**可能的成因**：
- 组字中途切换输入法：IME 用陈旧的目标提交了 preedit，随后新模式又处理了同一批按键。
- `keydown` 处理器在组字进行中吞掉了事件：在响应 `keydown`/`keyup` 之前先检查 `event.isComposing`。如果 `isComposing` 为 true，就把该动作推迟到 `compositionend`。
- Webview + 原生 frame 焦点分裂：在 Tauri 中，webview 与原生窗口标题栏可以同时持有焦点。IME 组字期间点击某个原生控件会触发 focus-out，提交尚未完成的 preedit 文本。

**探针**：
- 记录 `compositionstart`、`compositionupdate`、`compositionend` 序列；确认它们按序触发且无空隙。
- 记录每个 `compositionupdate` 的 `data` 字段；突然出现的空字符串意味着一次强制提交。

## IME 提交后的光标位置漂移

**症状**：确认一个 CJK 词之后，光标跳到错误的位置，或选区塌陷。

**可能的成因**：
- 组字期间的 DOM 变更：当 `isComposing` 为 true 时 React/Svelte/Vue 重新渲染会重置选区。批量处理状态更新，只在 `compositionend` 时才 flush。
- 位置计算里数的是字节而不是码点：CJK 字符在 UTF-8 里是多字节。位置中的字符级偏移要用 `Array.from(str).length` 或 `[...str].length`，而不是 `str.length`。

## Emoji ZWJ 序列拆分

**症状**：多人或职业类 emoji（例如 `👩‍🚒`）渲染成两三个独立的 emoji，或 ZWJ（`U+200D`）作为一个可见字符出现。

**可能的成因**：
- 在字节偏移处切字符串：如果 `n` 落在某个 ZWJ 序列内部，`str.slice(0, n)` 就会把它切开。用带 `granularity: 'grapheme'` 的 `Intl.Segmenter` 在字素簇边界处切分。
- 字体不支持该序列：字体逐个渲染每个码点。用 `canvas.measureText` 核实，或通过 `document.fonts` 检查实际使用的是哪个字体。
- 序列化剥掉了 ZWJ：某些 JSON 编码器会规范化或转义 `U+200D`。核实所存字符串的原始字节。

**测试**：`[...'👩‍🚒'].length` 应当是 1（一个字素簇）。如果返回 3，说明运行时在按码点迭代，而不是按字素簇。

## `compositionend` / `keydown` 事件顺序

**症状**：绑定到 Enter 或 Tab 的动作在 IME 确认期间触发，提交了不完整的输入。

**成因**：在 macOS + 某些 IME 上，顺序是 `compositionend` → `keydown(Enter)`。在 Windows + 另一些 IME 上则可能是 `keydown(Enter)` → `compositionend`。只在 `isComposing` 为 true 时阻止 Enter 的代码，会在 macOS 的顺序下失效，因为 `keydown` 触发时 `isComposing` 已经是 false。

**修复**：用一个布尔标志追踪组字状态——`compositionstart` 时置位，`compositionend` 时清除。用这个标志，而不是 `event.isComposing`，来守卫 Enter 处理器。

## macOS 文本系统与 Webview 的冲突

**症状**：撤销（`Cmd+Z`）回退的是一个个 IME preedit 字符，而不是已提交的词；或系统文本快捷键（用 Cmd+Shift+Left 选词）在 webview 内外表现不同。

**成因**：WKWebView 有自己的文本系统，与 NSTextView 的约定部分重叠。Tauri 的 `preventDefaultFor` 配置会压制系统快捷键；检查 `tauri.conf.json`（v1）或 `app.json`（v2）里是否有过于宽泛的 `preventDefault` 规则。

## 快速清单

- [ ] 在响应键盘事件之前检查了 `isComposing` 吗？
- [ ] `isComposing` 为 true 时没有发生 DOM 变更吗？
- [ ] 字符串位置计算用的是字素簇，而不是字节或码点吗？
- [ ] 用 `Intl.Segmenter` 核实过 ZWJ 序列吗？
- [ ] Enter/Tab 守卫用的是 `compositionstart` 置位的标志，而不是 `event.isComposing` 吗？
- [ ] `tauri.conf.json` 的 `preventDefaultFor` 是否过于宽泛？
