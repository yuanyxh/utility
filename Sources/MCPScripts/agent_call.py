"""agent CLI 调用共享实现：命令模板 + 占位符替换，零参数假设。

不同 agent CLI 的启动标志千差万别（claude 用 `-p`，其他 agent 未必），
因此脚本不追加任何固定参数——只做「写临时文件 + 替换占位符」，
最终命令完全由调用方传入的模板决定。

模板占位符：
- {system_prompt_file}：system 文本写入的临时文件路径（必用）
- {prompt_file}：user 文本写入的临时文件路径（模板含它则走文件；
  否则 user 通过 stdin 传入，兼容 `claude -p` 从 stdin 读 prompt 的用法）

示例模板（claude -p）：
    claude -p --output-format text --append-system-prompt-file {system_prompt_file}
"""

from __future__ import annotations

import os
import shlex
import subprocess
import tempfile

from log_utils import setup_logging

logger = setup_logging("agent_call")

# 单次 agent 调用超时（秒）。不限制 MCP 检索轮次（保质量优先），
# 深挖记忆库 + 写长文整体可能较久。25 分钟上限防「无限挂起」，
# 超时杀进程并报错，避免任务挂起数小时。
# 通过环境变量 AGENT_TIMEOUT 可覆盖（Swift 层从 GeneralConfig.aiTimeout 读取）
AGENT_TIMEOUT = int(os.environ.get("AGENT_TIMEOUT", "1500"))


def call_agent(
    agent_template: str, system: str, user: str, cwd: str | None = None
) -> str:
    """按命令模板调用 agent CLI，返回其 stdout 文本。

    system 总是写入临时文件；user 若模板含 {prompt_file} 则写文件，
    否则经 stdin 传入。命令完全由模板决定，脚本不追加任何参数。

    注意：agent CLI 应限制工具权限，只允许读取和 MCP 工具，禁止写文件。
    """
    # 输出调试文件目录
    debug_dir = os.path.expanduser("~/.cache/utility/agent_debug")
    os.makedirs(debug_dir, exist_ok=True)

    with tempfile.NamedTemporaryFile(
        "w", suffix=".txt", delete=False, encoding="utf-8"
    ) as f:
        f.write(system)
        sys_prompt_path = f.name

    user_file = None
    try:
        kwargs = {"system_prompt_file": sys_prompt_path}
        if "{prompt_file}" in agent_template:
            with tempfile.NamedTemporaryFile(
                "w", suffix=".txt", delete=False, encoding="utf-8"
            ) as f:
                f.write(user)
                user_file = f.name
            kwargs["prompt_file"] = user_file
            stdin = None
        else:
            stdin = user.encode("utf-8")

        # 构建完整命令：模板
        base_cmd = agent_template.format(**kwargs)
        cmd = shlex.split(base_cmd)
        try:
            logger.info("调用 agent CLI: cmd=%s", " ".join(cmd))
            proc = subprocess.run(
                cmd,
                input=stdin,
                capture_output=True,
                cwd=cwd,
                timeout=AGENT_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            logger.error("agent CLI 超时(%ds): cmd=%s", AGENT_TIMEOUT, " ".join(cmd))
            raise SystemExit(
                f"[agent 错误] 超时({AGENT_TIMEOUT}s) 已终止 cmd={' '.join(cmd)}"
            )
        if proc.returncode != 0:
            stderr = proc.stderr.decode("utf-8", errors="replace")
            logger.error(
                "agent CLI 失败: exit=%d, stderr=%s", proc.returncode, stderr[:500]
            )
            raise SystemExit(
                f"[agent 错误] exit={proc.returncode} cmd={' '.join(cmd)}\n" + stderr
            )
        text = proc.stdout.decode("utf-8", errors="replace").strip()
        if not text:
            logger.error("agent CLI 输出为空: cmd=%s", " ".join(cmd))
            raise SystemExit("[agent 错误] 输出为空")

        # 保存调试文件
        import time

        timestamp = int(time.time())
        debug_file = os.path.join(debug_dir, f"agent_output_{timestamp}.txt")
        with open(debug_file, "w", encoding="utf-8") as f:
            f.write(
                f"[System Prompt]\n{system}\n\n[User Prompt]\n{user}\n\n[Output]\n{text}"
            )
        logger.info("agent CLI 输出: %d字符, 调试文件: %s", len(text), debug_file)

        return text
    finally:
        try:
            os.unlink(sys_prompt_path)
        except OSError:
            pass
        if user_file:
            try:
                os.unlink(user_file)
            except OSError:
                pass
