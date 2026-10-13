# 项目审计模式（项目级评分卡）

当请求是项目级质量评分卡时，从 `check` 的模式选择加载。它区别于默认评审（以 diff 为范围）与分流（issue 批量处理）。

单遍项目级质量评估。

**流程**

1. 在目标仓库中运行 `python3 <skill-base-dir>/scripts/audit_signals.py --root <project>`，其中 `<skill-base-dir>` 替换为本 skill 的基础目录。脚本会输出带标签的块（`=== FILE SIZE HOTSPOTS ===` …… `=== DENYLIST IN BUILD ===`），每块以 `status: PASS|WARN|FAIL|N/A` 结束。
2. 浏览由 `FILE SIZE HOTSPOTS` 呈现的最大的源文件（通常 3-5 个；若架构已经清晰，可更早停止）。
3. 在依据通用惯例评判之前，先阅读 `CLAUDE.md` / `AGENTS.md` / `README.md` 了解项目自己声明的惯例。仓库的 agent 指引本身就是被审计面的一部分：核实它的命令与路径是否仍然存在，并把过时、自相矛盾或可删除的规则作为发现上报。
4. 套用下方的四轴评分准则。每个轴独立打 0-10 分。总分 = 算术平均。
5. 上报每一条会影响轴得分的发现，尽量附上 file:line 引用、严重程度（CRIT/STRUCT/INCR）与一行修复建议。某个轴上零发现是有效结果；不要为凑数而灌水。
6. 只输出到 **terminal**。不要在目标仓库中创建文件。如果用户随后说「保存它」，那时再提供 `./docs/<project>-audit.md`；默认是临时的。

**评分准则**

| 轴 | 覆盖内容 |
|---|---|
| 架构 | 模块边界、耦合、抽象层 vs 扁平重复、单一事实源 |
| 代码质量 | 文件大小纪律、去重、可读性、对非显然行为的注释 |
| 工程 | 测试、CI 闸门、版本协调、安装 URL 固定、打包姿态 |
| 性能与风险 | 隐患、范围蔓延、分发风险、隐私姿态、第三方影响半径 |

**评分锚点**

- 9-10：出色的纪律，仅有打磨项
- 7-8.5：扎实，有明确的有针对性的改进点
- 5-7：能用，但存在结构性债务
- 低于 5：建议大幅返工

一个已被项目显式给出理由（在其自己的文档或某条注释中）的 WARN 不算发现；引用该理由并跳过。不要机械地把 WARN 转成 CRIT。`status: N/A` 的块表示该面不存在（例如没有打包脚本）；把它当作静默，而非积极信号。

**输出模板（terminal）**

```
Project: <name>
Overall: X.X / 10

Architecture: X / 10 -- one-line summary
Code Quality: X / 10 -- one-line summary
Engineering:  X / 10 -- one-line summary
Perf & Risk:  X / 10 -- one-line summary

Findings
[CRIT] <file:line> -- <issue>
       why: <reason grounded in signal or read>
       fix: <concrete action>
[STRUCT] ...
[INCR] ...

Top 3 highest-leverage moves
1. ...
2. ...
3. ...
```

报告之后即停止，除非用户要求后续实现。审计模式不修改目标仓库中的文件。
