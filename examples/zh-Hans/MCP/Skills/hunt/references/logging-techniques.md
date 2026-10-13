# 调试用的日志技巧

每一条日志都在回答一个关于某个假设的是/否问题：「如果它在 Y 之前打印 X，假设 A 成立；否则 A 就死了。」无法判定某个假设成立与否的日志都是噪音。

## 有区分度的内容

记录能在假设之间做出区分的东西：顺序（序号或时间戳）、输入的身份键、走的分支、旧状态到新状态的转换，以及错误码加上下文。把日志放在行为本应可预测的边界上（handler 入口/出口、缓存命中或未命中并带 key、状态 setter 带旧值与调用方、异步回调入口、外部 API 结果），而不是放在紧循环内部。绝不记录凭据、PII 或完整的请求/响应体。

对竞态条件、闪烁或间歇性失败，还要捕获事件身份、单调顺序、起点与终点（而不只是「它跑过了」），以及线程/任务/队列身份。如果加一条日志改变了行为，那就是时序、生命周期或并发问题的证据，而不是可以一笑置之的「日志副作用」。

## 只在特定 runner 下失败

当某个脚本只在特定的 runner 下失败（make 目标、CI job、测试框架、cron），单独跑却能通过时，不要用那些你可能忘记删掉的调试小动作去改脚本。改从外部注入追踪，走 runner 本来就传递的环境：

```bash
# xtrace-env.sh: sourced by every non-interactive bash via BASH_ENV
exec 19>>/path/to/persistent/xtrace.log
export BASH_XTRACEFD=19
export PS4='+ [$0:$LINENO] '
set -x
```

把失败的流水线跑成 `BASH_ENV=/path/to/xtrace-env.sh make test`（或该 runner 的等价写法）。runner 派生的每个 bash 都会把带 `file:line` 标记的追踪追加到同一个持久文件里，从而扛过 runner 的临时目录清理，这样即便该失败需要整条流水线才能复现，出事的确切那一行也会被记录在案。如果嵌套 shell 会重复 source，就用一个 sentinel 变量把这次注入保护好，收尾时删掉这个 env 文件。
