#!/usr/bin/env python3
"""通过飞书 Open API 把 Feishu/Lark 文档抓取为 Markdown。

特别感谢 joeseesun 出色的 qiaomu-markdown-proxy 项目，这里的飞书 API 集成
与文档解析思路受其启发。
https://github.com/joeseesun/qiaomu-markdown-proxy

默认路径：
    pip install requests

配置：
    export FEISHU_APP_ID=your_app_id
    export FEISHU_APP_SECRET=your_app_secret
    应用需要：docx:document:readonly, wiki:wiki:readonly

备选的用户登录路径：
    npm install -g @larksuite/cli
    lark-cli auth login
    lark-cli docs +fetch --doc <feishu_url>

用法：
    python3 fetch_feishu.py <feishu_url>
    python3 fetch_feishu.py <feishu_url> --json
"""

import sys
import json
import os
import re
import urllib.parse

try:
    import requests
except ImportError:
    requests = None

API = "https://open.feishu.cn/open-apis"
TIMEOUT = 20
LARK_CLI_HINT = (
    "若想改用用户登录而非应用凭据，请安装/配置 lark-cli "
    "(npm install -g @larksuite/cli && lark-cli auth login)，然后运行 "
    "lark-cli docs +fetch --doc <feishu_url>。"
)


def yaml_string(value):
    return json.dumps("" if value is None else str(value), ensure_ascii=False)


def get_token():
    app_id = os.environ.get("FEISHU_APP_ID")
    app_secret = os.environ.get("FEISHU_APP_SECRET")
    missing = []
    if requests is None:
        missing.append("未安装 Python 包 requests；请运行：pip install requests")
    if not app_id or not app_secret:
        missing.append("未设置 FEISHU_APP_ID 或 FEISHU_APP_SECRET")
    if missing:
        return None, "; ".join(missing) + f". {LARK_CLI_HINT}"
    resp = requests.post(
        f"{API}/auth/v3/tenant_access_token/internal",
        json={"app_id": app_id, "app_secret": app_secret},
        timeout=TIMEOUT,
    )
    d = resp.json()
    if d.get("code") != 0:
        return None, f"鉴权失败：{d.get('msg', resp.text)}"
    return d["tenant_access_token"], None


def parse_url(url):
    patterns = [
        (r"feishu\.cn/docx/([A-Za-z0-9]+)", "docx"),
        (r"feishu\.cn/docs/([A-Za-z0-9]+)", "legacy_doc"),
        (r"feishu\.cn/wiki/([A-Za-z0-9]+)", "wiki"),
        (r"larksuite\.com/docx/([A-Za-z0-9]+)", "docx"),
        (r"larksuite\.com/docs/([A-Za-z0-9]+)", "legacy_doc"),
        (r"larksuite\.com/wiki/([A-Za-z0-9]+)", "wiki"),
    ]
    for pattern, doc_type in patterns:
        m = re.search(pattern, url)
        if m:
            return m.group(1), doc_type
    return url, "docx"


def resolve_wiki(token, wiki_token):
    resp = requests.get(
        f"{API}/wiki/v2/spaces/get_node",
        headers={"Authorization": f"Bearer {token}"},
        params={"token": wiki_token},
        timeout=TIMEOUT,
    )
    d = resp.json()
    if d.get("code") == 0:
        node = d["data"]["node"]
        return node.get("obj_token"), node.get("obj_type")
    return None, None


def get_blocks(token, doc_id):
    blocks, page_token = [], None
    while True:
        params = {"page_size": 500}
        if page_token:
            params["page_token"] = page_token
        resp = requests.get(
            f"{API}/docx/v1/documents/{doc_id}/blocks",
            headers={"Authorization": f"Bearer {token}"},
            params=params,
            timeout=TIMEOUT,
        )
        d = resp.json()
        if d.get("code") != 0:
            return None, f"拉取 blocks 失败：{d.get('msg', resp.text)}"
        blocks.extend(d["data"].get("items", []))
        if not d["data"].get("has_more"):
            break
        page_token = d["data"].get("page_token")
    return blocks, None


def extract_text(elements):
    if not elements:
        return ""
    parts = []
    for el in elements:
        if "text_run" in el:
            tr = el["text_run"]
            text = tr.get("content", "")
            s = tr.get("text_element_style", {})
            if s.get("bold"):
                text = f"**{text}**"
            if s.get("italic"):
                text = f"*{text}*"
            if s.get("inline_code"):
                text = f"`{text}`"
            if s.get("link", {}).get("url"):
                text = f"[{text}]({urllib.parse.unquote(s['link']['url'])})"
            parts.append(text)
        elif "mention_user" in el:
            parts.append(f"@{el['mention_user'].get('user_id', 'user')}")
        elif "equation" in el:
            parts.append(f"${el['equation'].get('content', '')}$")
    return "".join(parts)


LANG_MAP = {
    7: "bash",
    8: "c",
    9: "csharp",
    10: "cpp",
    14: "css",
    19: "dockerfile",
    25: "go",
    29: "html",
    31: "java",
    32: "javascript",
    33: "json",
    35: "kotlin",
    40: "markdown",
    46: "php",
    50: "python",
    52: "ruby",
    53: "rust",
    58: "sql",
    59: "swift",
    62: "typescript",
    68: "xml",
    69: "yaml",
}


def blocks_to_md(blocks):
    lines = []
    counters = {}
    for block in blocks:
        bt = block.get("block_type")
        pid = block.get("parent_id", "")

        if bt == 2:
            text = extract_text(block.get("text", {}).get("elements", []))
            lines.append(text if text.strip() else "")
        elif bt in range(3, 10):
            level = bt - 2
            key = f"heading{level}"
            data = block.get(key) or block.get("heading", {})
            text = extract_text(data.get("elements", []))
            lines.append(f"{'#' * min(level, 6)} {text}")
        elif bt == 10:
            text = extract_text(block.get("bullet", {}).get("elements", []))
            lines.append(f"- {text}")
        elif bt == 11:
            text = extract_text(block.get("ordered", {}).get("elements", []))
            n = counters.get(pid, 0) + 1
            counters[pid] = n
            lines.append(f"{n}. {text}")
        elif bt == 12:
            code_data = block.get("code", {})
            text = extract_text(code_data.get("elements", []))
            lang = LANG_MAP.get(code_data.get("style", {}).get("language", 0), "")
            lines.extend([f"```{lang}", text, "```"])
        elif bt == 13:
            text = extract_text(block.get("quote", {}).get("elements", []))
            lines.append(f"> {text}")
        elif bt == 15:
            todo_data = block.get("todo", {})
            text = extract_text(todo_data.get("elements", []))
            done = todo_data.get("style", {}).get("done", False)
            lines.append(f"- {'[x]' if done else '[ ]'} {text}")
        elif bt == 16:
            lines.append("---")
        elif bt == 17:
            tok = block.get("image", {}).get("token", "")
            lines.append(f"![image](feishu-image://{tok})")
        elif bt == 1:
            pass
        else:
            for key, val in block.items():
                if isinstance(val, dict) and "elements" in val:
                    text = extract_text(val["elements"])
                    if text.strip():
                        lines.append(text)
                    break

    return "\n\n".join(lines)


def fetch_feishu(url):
    doc_id, doc_type = parse_url(url)

    if doc_type == "legacy_doc":
        return {
            "error": (
                "本脚本不支持旧式飞书 /docs/ 页面。"
                "请先把文档转成 docx；若该页面无需 API 即可访问，也可改用公开页面兜底方案。"
            )
        }

    token, err = get_token()
    if err:
        return {"error": err}

    if doc_type == "wiki":
        real_id, real_type = resolve_wiki(token, doc_id)
        if not real_id:
            return {"error": f"无法解析 wiki 节点：{doc_id}"}
        doc_id, doc_type = real_id, real_type or "docx"

    info_resp = requests.get(
        f"{API}/docx/v1/documents/{doc_id}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=TIMEOUT,
    )
    doc_info = (info_resp.json().get("data") or {}).get("document") or {}
    title = doc_info.get("title", "")

    blocks, err = get_blocks(token, doc_id)
    if err:
        return {"error": err}

    return {
        "title": title,
        "document_id": doc_id,
        "url": url,
        "content": blocks_to_md(blocks),
    }


def to_markdown(r):
    if "error" in r:
        return f"错误：{r['error']}"
    parts = [
        "---",
        f"title: {yaml_string(r.get('title', ''))}",
        f"document_id: {yaml_string(r.get('document_id', ''))}",
        f"url: {yaml_string(r.get('url', ''))}",
        "---",
        "",
        f"# {r['title']}" if r.get("title") else "",
        "",
        r.get("content", ""),
    ]
    return "\n".join(parts)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法：fetch_feishu.py <feishu_url> [--json]", file=sys.stderr)
        print(
            "  默认需 pip install requests，并设置 FEISHU_APP_ID 与 FEISHU_APP_SECRET",
            file=sys.stderr,
        )
        print(f"  备选方案：{LARK_CLI_HINT}", file=sys.stderr)
        sys.exit(1)

    result = fetch_feishu(sys.argv[1])
    if "--json" in sys.argv:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(to_markdown(result))
    if "error" in result:
        sys.exit(1)
