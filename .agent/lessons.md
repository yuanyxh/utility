# 教训记录

## 代理指标不是验证结论（2026-10-29）

构建成功、产物含符号、日志出现关键字只证明代码存在。真实交互未跑过时，不得说「验证通过」，
必须标注证据级别并列出待验项。

## 报告措辞要与证据对齐（2026-10-29）

「部署验证通过」实际只验了产物与进程，标题却给了通过印象。结论先行写清验证范围，
未验部分单独列节，不埋在末尾。

## 无法驱动 UI 时要先造入口（2026-10-29）

app 没有 CLI/URL scheme 等可脚本化入口时，自动化验证从第一轮就不可能。应在基座阶段声明
驱动方式；缺失时先补入口，再谈修复。

## 持久化字段删除要双向验证（2026-10-29）

删 `StoredTerminalSession.backend` 只验证了「新读旧」（忽略多余键），没验证「旧读新」：
旧版把它当必填，缺键会让整数组解码失败、静默丢会话。删除持久化字段前先查旧代码如何解码。

## 单实现抽象应收缩而非保留（2026-10-29）

三个后端时协议合理；只剩一个时协议、枚举、工厂都是负债，应在同一次改动里删除。

## 副作用不要藏在解析函数里（2026-10-29）

`resolvedBackend()` 内弹通知，最后只能靠布尔标记去重。解析返回结果，提示由调用方决定。

## 机制先分清再开药方（2026-10-29）

「滚不动」对应三种不同机制（alternate buffer、WheelReportBudget、allowMouseReporting），
一刀切修法会修好一个、弄坏两个。

## 验证环境要可恢复（2026-10-29）

移走 tmux 做缺失测试前，先确认 tmux server 不依赖二进制，测完立即还原并核对版本；
并行会话可能同时改动环境，双开时不要做破坏性实验。

## 调试日志字段要前置布置（2026-10-29）

`became/resigned key`、`frontmost`、`newKey` 等字段应在改代码前就布好，
否则每轮都要改日志 → 打包 → 重新部署。

## 选中态是状态，不是视图属性（2026-11-06）

列表选中来自快照时，视图层不能再让 AppKit 自行清空：`allowsEmptySelection = true` 下点空白会 deselect，
回调里 `row == -1` 提前 return，界面与状态就此分叉。空白点击一律在视图层拦住（`PersistentSelectionTableView`），
旧侧栏用 `allowsEmptySelection = false` 修过同一问题，新列表重写时又退回去了。

## 焦点转移会改选中底色（2026-11-06）

选行后把 first responder 交给编辑器/终端，AppKit 默认按「非强调」画选中，蓝色立刻变灰。
列表选中要稳定就得在行视图里自己画（`PointerRowView.drawSelection`），只在窗口失焦时才降级。

## GUI app 看不到 launchctl setenv 的变量（2026-11-09）

`launchctl setenv HTTPS_PROXY …` 之后启动的 utility.app，`ps eww` 里仍然没有任何代理变量。
给 GUI 子进程配网络代理不能靠 shell/launchd 环境，必须在代码里显式注入，或读 `SCDynamicStoreCopyProxies`。

## 向导只在 config.yaml 不存在时出现（2026-11-09）

`AppDelegate` 用「配置文件缺失」判定首启。移走模型目录后普通重启不会弹向导，
想复验安装步骤必须同时移走 `config.yaml`，且要在 app 退出状态下移——运行中的 app 会立刻把模板写回去。

## 默认配置不要用空模型编码（2026-11-09）

`YAMLEncoder().encode(AppConfig())` 会把 `mcp`（Optional，默认 nil）整段省略，
新机器拿到的 config 没有 MCP 段，功能默认关闭。默认值应复用仓库里的 `default-config.yaml` 模板。
