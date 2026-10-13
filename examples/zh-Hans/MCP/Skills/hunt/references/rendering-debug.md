# 渲染 Bug 调试参考

## 渲染 Bug 模式

启用条件：「PDF looks wrong」「page break issue」「font not rendering」、PDF 输出损坏、打印版式不对。

先做静态分析（审阅 CSS），必要时再复现。

### WeasyPrint

- `rgba()` 会导致双矩形 bug：改用纯色 hex 颜色
- `page-break-inside: avoid` 常被忽略：改用显式分页
- 基于 float 的布局常在分页边界处断开：优先用 flexbox 或 block
- 外部字体的 URL 在渲染时被拦截：把字体以 base64 内嵌，或本地托管

### 字体加载

- 检查 `@font-face` 的 src 路径（相对 vs 绝对）
- 对外部字体，CORS 头必须允许渲染源
- 格式支持：WeasyPrint 偏好 WOFF/TTF；WOFF2 的支持取决于版本
- 字体缺失时的兜底 = 不可见文本或系统回退字形

### 页面溢出

- 在逐行调试之前，先算内容高度 vs 页面高度
- 减小 `line-height`、`padding` 或 `margin` 来夺回空间
- 孤行/寡行控制：在 `@page` 的 body 规则里写 `orphans: 3; widows: 3`

### 浏览器打印 CSS

- 确认 `@media print` 规则存在且未被覆盖
- `@page` 的 margin 必须把打印机的不可打印区域（最少约 6mm）算进去
- 在分节分隔处用 `break-before: page` / `break-after: page`
- 在浏览器 DevTools 里用 `window.print()` 测试，而不只是看视觉预览
