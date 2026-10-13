# Read 方法参考

## 代理级联

按顺序尝试。成功 = 输出非空且内容可读。若某个代理返回空、错误页，或少于 5 行，视为失败并尝试下一个：

### 1. defuddle.md

```bash
curl -sL "https://defuddle.md/{url}"
```

输出更干净，带 YAML front-matter。优先尝试这个。

### 2. r.jina.ai

```bash
curl -sL "https://r.jina.ai/{url}"
```

覆盖面广，会保留图片链接。若 defuddle.md 返回空或报错，用它。

### 3. Web search 插件 reader（如有）

若安装了 web search 插件（如 PipeLLM），级联会在本地兜底之前尝试它的 reader 工具。对 JavaScript 渲染的页面，它比免费代理处理得更好。

### 4. 本地工具

```bash
npx agent-fetch "{url}" --json
# or
defuddle parse "{url}" -m
```

两个代理都失败时的最后手段。`agent-fetch --json` 返回的是 JSON，所以在返回或保存结果前要先取出其中承载 Markdown 的字段。`defuddle parse -m` 直接输出 Markdown。原始 JSON 不是 `/read` 的合法最终输出。

## GitHub URL

GitHub 文件 URL（`github.com/user/repo/blob/...`）会渲染出很重的 HTML。代理级联常常返回残缺或满是导航的内容。优先用：

```bash
# Raw file content (fastest)
curl -sL "https://raw.githubusercontent.com/{user}/{repo}/{branch}/{path}"

# Via gh CLI (works with private repos)
gh api repos/{user}/{repo}/contents/{path} --jq '.content' | base64 -d
```

仅对不是原始文件视图的 GitHub 页面（如 issue 讨论串、README 渲染页）才把代理级联当作兜底。

## PDF 转 Markdown

### 远程 PDF URL

r.jina.ai 能直接处理 PDF URL：

```bash
curl -sL "https://r.jina.ai/{pdf_url}"
```

若不行，就下载到本地再提取：

```bash
curl -sL "{pdf_url}" -o /tmp/input.pdf
pdftotext -layout /tmp/input.pdf -
```

### 本地 PDF 文件

```bash
# Best quality (requires: pip install marker-pdf)
marker_single /path/to/file.pdf --output_dir "${READ_OUTPUT_DIR:-/tmp/waza-read}"

# Fast, text-heavy PDFs (requires: brew install poppler)
pdftotext -layout /path/to/file.pdf - | sed 's/\f/\n---\n/g'

# No-dependency fallback
python3 -c "
import pypdf, sys
r = pypdf.PdfReader(sys.argv[1])
print('\n\n'.join(p.extract_text() for p in r.pages))
" /path/to/file.pdf
```

当版式重要时（论文、表格）用 `marker`。追求速度时用 `pdftotext`。

## 飞书 / Lark 文档

先解析一次内置辅助脚本目录。无论是单 skill 安装、打包后的分发器，还是源码仓库根目录，都可这样处理：

```bash
READ_SCRIPT_DIR=""
for candidate in \
  "<skill-base-dir>/scripts" \
  "<skill-base-dir>/skills/read/scripts"; do
  if [ -f "$candidate/fetch_feishu.py" ]; then
    READ_SCRIPT_DIR="$candidate"
    break
  fi
done
if [ -z "$READ_SCRIPT_DIR" ]; then
  echo "read helper scripts not found under the installed skill base; reinstall Waza" >&2
  exit 1
fi
```

把 `<skill-base-dir>` 替换为已安装的 Read skill 或 Waza 分发器目录。

需要 `requests` 以及飞书应用凭据：

```bash
pip install requests  # one-time setup
export FEISHU_APP_ID=your_app_id
export FEISHU_APP_SECRET=your_app_secret
python3 "$READ_SCRIPT_DIR/fetch_feishu.py" "{url}"
```

支持：docx 与 wiki 页面。旧式 `/docs/` 页面不受本脚本支持；请先把它们转成 docx，或在文档无需 API 即可访问时改用公开页面兜底方案。应用需要 `docx:document:readonly` 与 `wiki:wiki:readonly` 权限。
输出：YAML front-matter（title、document_id、url）+ Markdown 正文。

不要一上来就让每个用户都去装 `lark-cli`。当 API 辅助脚本因缺少应用凭据而失败，或用户明确偏好用 OAuth 登录而非 `FEISHU_APP_ID` / `FEISHU_APP_SECRET` 时，把它当作「用户登录」的兜底方案：

```bash
npm install -g @larksuite/cli  # one-time setup if lark-cli is absent
lark-cli auth login            # one-time login
lark-cli docs +fetch --doc "{url}" --format json
```

`lark-cli docs +fetch` 返回的是结构化文档 JSON，而非最终 Markdown。回答前先提取并转换出有用的内容；不要返回原始 JSON。

## 微信公众号

使用代理级联（r.jina.ai / defuddle.md）。对大多数文章无需任何额外工具即可奏效。

若代理被拦截，作为最后手段使用内置的 Playwright 脚本（需一次性安装约 300 MB）：

```bash
pip install playwright beautifulsoup4 lxml && playwright install chromium
python3 "$READ_SCRIPT_DIR/fetch_weixin.py" "{url}"
```
