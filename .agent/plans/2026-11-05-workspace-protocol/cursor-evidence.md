# 光标手型排查证据

结论：`NSTrackingArea` 的 `owner` 必须是视图自身，AppKit 才会投递 `cursorUpdate:`；用独立对象作 owner 时区域装上但回调为 0，随后 AppKit 在 `routeEnterExitEvent` 里把光标清回箭头。

## 失败与成功对照

| 写法 | 日志 | 结果 |
|---|---|---|
| owner 为独立 `PointerCursorOwner` 对象 | `area installed` 442 次，`cursorUpdate fired` 0 次 | 始终箭头，AppKit 持续 `_clearOverrideCursorAndSetArrow` |
| owner 为视图自身 | `cursorUpdate fired` 出现，栈顶为 `PointerRowView.cursorUpdate(with:)` | 截图确认显示手型 |
| 按钮叠在文本视图上（原布局） | 无本类回调，命中被 `NSTextView` 的 I-beam 抢走 | 显示 I-beam，非手型 |
| 按钮移到标题行（不覆盖滚动区域） | 命中按钮自身 | 截图确认手型 |
| 只处理 `cursorUpdate` | 鼠标进入行时短暂设置一次，继续移动后被重置 | 漂移测试通过、真实滑动失败 |
| 同时处理 `mouseMoved` | 每次移动都重新设置 | 滑动路径测试通过 |

## 验证必须模拟滑动

`CGWarpMouseCursorPosition` 直接跳到目标只触发一次进入事件，会掩盖「移动过程中被重置」的问题。复现时要沿路径逐步移动光标并逐点投递 `mouseMoved`。

## 验证方式

不依赖人工悬停：辅助功能权限已开，脚本移动光标并投递 `mouseMoved`，再用 `screencapture -C` 连光标一起截取局部区域。

```bash
CGWarpMouseCursorPosition(point)
CGEvent(mouseEventType: .mouseMoved, ...)?.post(tap: .cghidEventTap)
screencapture -C -x -R<x>,<y>,<w>,<h> /tmp/cursor-probe.png
```

日志开关：`UTILITY_CURSOR_TRACE=1`，日志在临时 home 的 `.cache/utility/debug.log`。

## 复现要点

- 工作区窗口必须是 key；隔离实例用 `CFFIXED_USER_HOME` 启动，不占用 9001。
- 文件树行位置按窗口右栏宽度与 44pt 活动栏推算，行高 26。
