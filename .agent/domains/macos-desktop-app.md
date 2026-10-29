# 领域：macOS 桌面应用

## summary

以 AppKit 构建的常驻菜单栏工具，需要处理窗口层级、焦点、全局热键、系统权限与本地持久化。

## applies_when

`project.type = desktop` 且目标平台为 macOS。

## core_concerns

1. **窗口与焦点**：区分 `isVisible` / `isKeyWindow` / `NSApp.isActive` / 前台应用，不能混用。
2. **全局热键生命周期**：热键只在启动注册，配置变更需重启；组合键冲突要有日志证据。
3. **系统权限**：辅助功能、屏幕录制、通知授权缺失时功能降级可感知，不静默失败。
4. **本地存储**：SQLite 需 WAL 与 busy timeout；持久化结构变更必须双向兼容。
5. **资源本地化**：文案走 `Resources/<lang>.json`，生成访问器，禁止手改生成文件。
6. **打包完整性**：资源 bundle 缺失必须硬失败，不做条件跳过。

## questions

- 是否需要开机自启、自动更新通道？
- 权限被拒时的降级路径是什么？
- 数据目录如何派生，是否存在个人路径回退？

## research

- LSUIElement 应用的激活与菜单栏行为（本机实测：accessory app 激活时菜单栏仍属上一个 app）。
- 通知授权状态查询与降级（`NSUserNotification` 已弃用，待迁移 UserNotifications）。

## generates

窗口/焦点规则、权限降级清单、持久化兼容检查、打包校验脚本。

## verify

- 失焦、权限拒绝、结构变更三类场景各有一条可复现验证。
- 打包产物中资源与二进制符号可核对。

## pitfalls

- 把「窗口被其他 app 盖住」误判为「窗口隐藏」。
- 用 `isKeyWindow` 判断用户是否在看（输入法候选窗会抢 key）。
- 删除持久化字段时只验证新读旧，忽略旧读新。
- 资源缺失被 `if [ -d ]` 静默跳过，产出一个启动即崩的包。
