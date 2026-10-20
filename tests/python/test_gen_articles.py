import ast
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Sources" / "MCPScripts"))

from gen_articles import runtime
from gen_articles.config import ConfigError, load, validate
from gen_articles.language_pack import LanguagePack, PackError
from gen_articles.generate import _material_count
from gen_articles.production import _scan_latest, _write_latest
from gen_articles.material import filter_items, render_markdown
from gen_articles.lint import lint_text
from gen_articles.sources import _extract_items, _sections
from gen_articles.topics import (
    _valid_topic,
    load_existing_topics,
    record_topics,
)


FIXTURE_PACK = Path(__file__).parent / "fixtures/zh-Hans"
FIXTURE_EN_TEXTS = Path(__file__).parent / "fixtures/en/texts.json"


def _project(root: Path, language: str = "zh-Hans") -> None:
    pack = root / "packs" / language
    shutil.copytree(FIXTURE_PACK, pack)
    if language != "zh-Hans":
        data = json.loads((pack / "pack.json").read_text(encoding="utf-8"))
        data["id"] = language
        (pack / "pack.json").write_text(json.dumps(data), encoding="utf-8")
        shutil.copy(FIXTURE_EN_TEXTS, pack / "texts.json")
    (root / "extracts").mkdir()
    (root / "config.json").write_text(json.dumps({
        "version": 1,
        "language": language,
        "pack": f"packs/{language}",
        "outputDir": "runs",
        "extractsDir": "extracts",
        "material": {"minItems": 2, "minRelevance": 0.5},
    }), encoding="utf-8")


class ConfigTest(unittest.TestCase):
    def test_load_resolves_relative_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            cfg = load(root)
            self.assertEqual(cfg.output_dir, (root / "runs").resolve())
            self.assertEqual(cfg.extracts_dir, (root / "extracts").resolve())
            self.assertEqual(validate(cfg), [])
            runtime.configure(cfg)
            self.assertEqual(runtime.anchors(), [])



    def test_diagnostics_use_stable_codes(self):
        result = lint_text("# 记录一次测试\n\n前一阵子做了个测试，结果没成功。")
        self.assertTrue(result["hard_issues"])
        self.assertTrue(all("code" in i and "message" in i
                            for i in result["hard_issues"]))
        codes = {i["code"] for i in result["hard_issues"]}
        self.assertIn("hardcore_density", codes)

    def test_artifacts_follow_language(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root, "en")
            runtime.configure(load(root))
            text = render_markdown({
                "topic": "T", "fetched_at": "now", "endpoint": "x",
                "items": [], "dropped_count": 0,
            })
            self.assertTrue(text.startswith("# Material: T"))

    def test_review_and_report_follow_language(self):
        from gen_articles.review import _review
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root, "en")
            runtime.configure(load(root))
            text, clean, codes = _review({"results": []})
            self.assertTrue(clean)
            self.assertEqual(codes, [])
            self.assertTrue(text.startswith("# Manual Review"))
            self.assertIn("No manual review needed.", text)

    def test_language_without_pack_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            data = json.loads((root / "config.json").read_text())
            data["language"] = "en"
            data["pack"] = "packs/en"
            (root / "config.json").write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(ConfigError):
                load(root)

    def test_latest_points_to_selected_article(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            runtime.configure(load(root))
            _write_latest(root, "batch-1", {
                "status": "ok",
                "results": [{
                    "id": "auto_x", "status": "ok",
                    "selected": {"title": "T", "path": "/tmp/a.md"},
                    "run_dir": "/tmp/run", "review": "/tmp/review.md",
                }],
            })
            data = json.loads(
                (root / "latest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(data["batch_id"], "batch-1")
            self.assertEqual(data["results"][0]["path"], "/tmp/a.md")
            self.assertTrue((root / "latest.md").exists())

    def test_scan_latest_resolves_selected_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run = root / "runs" / "batch-1" / "run-a"
            (run / "candidates").mkdir(parents=True)
            article = run / "candidates" / "candidate_1.md"
            article.write_text("# T", encoding="utf-8")
            (run / "meta.json").write_text(json.dumps({
                "candidates": [{"index": 1, "path": str(article)}],
            }), encoding="utf-8")
            (run / "batch_item.json").write_text(json.dumps({
                "id": "run-a", "status": "ok",
                "selected": {"index": 1, "title": "T"},
                "run_dir": str(run), "review": "",
            }), encoding="utf-8")
            data = _scan_latest(root / "runs")
            self.assertEqual(data["results"][0]["path"], str(article))

    def test_missing_config_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ConfigError):
                load(Path(tmp))

    def test_validate_reports_missing_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            (root / "packs/zh-Hans/SOUL.md").rename(
                root / "packs/zh-Hans/SOUL.md.bak"
            )
            cfg = load(root)
            self.assertTrue(any("SOUL" in e for e in validate(cfg)))


class LanguagePackTest(unittest.TestCase):
    def test_pack_contract_rejects_incomplete_pack(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            pack_json = root / "packs/zh-Hans/pack.json"
            data = json.loads(pack_json.read_text(encoding="utf-8"))
            data.pop("question_marks")
            pack_json.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(PackError):
                LanguagePack(root / "packs/zh-Hans")

    def test_pack_texts_cover_engine_keys(self):
        engine = Path(__file__).parents[2] / "Sources/MCPScripts/gen_articles"
        used = set()
        for path in sorted(engine.glob("*.py")):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if (isinstance(node, ast.Call)
                        and isinstance(node.func, ast.Name)
                        and node.func.id == "tr"
                        and node.args
                        and isinstance(node.args[0], ast.Constant)
                        and isinstance(node.args[0].value, str)):
                    used.add(node.args[0].value)
        from gen_articles.review import REVIEW_ACTIONS
        used.update(REVIEW_ACTIONS.values())
        texts = json.loads(
            (FIXTURE_PACK / "texts.json").read_text(encoding="utf-8")
        )
        self.assertEqual(sorted(used - set(texts)), [])

    def test_engine_has_no_cjk_string_literals(self):
        engine = Path(__file__).parents[2] / "Sources/MCPScripts/gen_articles"
        offenders = []
        for path in sorted(engine.glob("*.py")):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            docstrings = set()
            for node in ast.walk(tree):
                if isinstance(node, (ast.Module, ast.FunctionDef,
                                     ast.AsyncFunctionDef, ast.ClassDef)):
                    body = node.body
                    if (body and isinstance(body[0], ast.Expr)
                            and isinstance(body[0].value, ast.Constant)
                            and isinstance(body[0].value.value, str)):
                        docstrings.add(id(body[0].value))
            for node in ast.walk(tree):
                if (isinstance(node, ast.Constant)
                        and isinstance(node.value, str)
                        and id(node) not in docstrings
                        and any("\u4e00" <= ch <= "\u9fff"
                                for ch in node.value)):
                    offenders.append(f"{path.name}:{node.lineno}")
        self.assertEqual(offenders, [])


class TopicHistoryTest(unittest.TestCase):
    def test_history_survives_runs_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            runtime.configure(load(root))
            record_topics([{"topic": "SQLite WAL 写入并发边界", "genre": "排查调试"}])
            runs = root / "runs"
            self.assertEqual(
                load_existing_topics(runs), ["SQLite WAL 写入并发边界"]
            )
            record_topics([{"topic": "SQLite WAL 写入并发边界", "genre": "排查调试"}])
            self.assertEqual(
                load_existing_topics(runs), ["SQLite WAL 写入并发边界"]
            )
            history = json.loads(
                (root / "topic_history.json").read_text(encoding="utf-8")
            )
            self.assertEqual(history["topics"][0]["count"], 2)

    def test_topic_revisit_requires_new_source_or_cooldown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            cfg = load(root)
            cfg.raw["topics"]["cooldownDays"] = 30
            runtime.configure(cfg)
            record_topics([{
                "topic": "SQLite WAL 写入并发边界",
                "genre": "排查调试",
                "sources": ["memory:a"],
                "sourceHashes": {"memory:a": "hash-a"},
            }])
            self.assertFalse(_valid_topic(
                "SQLite WAL 写入并发边界", ["SQLite WAL 写入并发边界"], [],
                ["memory:a"], {"memory:a": "hash-a"},
            ))
            self.assertTrue(_valid_topic(
                "SQLite WAL 写入并发边界", ["SQLite WAL 写入并发边界"], [],
                ["memory:b"], {"memory:b": "hash-b"},
            ))
            self.assertTrue(_valid_topic(
                "SQLite WAL 写入并发边界", ["SQLite WAL 写入并发边界"], [],
                ["memory:a"], {"memory:a": "hash-changed"},
            ))


class SourceTest(unittest.TestCase):
    def test_sections_split_by_heading(self):
        text = ("# 标题\n\n开头。\n\n## 小节一\n\n" + "甲" * 200 +
                "\n\n## 小节二\n\n" + "乙" * 200)
        sections = _sections(text)
        self.assertEqual(len(sections), 2)
        self.assertTrue(sections[0][1].startswith("## 小节一"))

    def test_extracts_only_scan_configured_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _project(root)
            (root / "extracts/keep.md").write_text(
                "# 记\n\n## 真\n\n" + "SQLite WAL 写事务与忙等。" * 20,
                encoding="utf-8",
            )
            (root / "outside.md").write_text(
                "## 假\n\n" + "SQLite WAL 写事务与忙等。" * 20,
                encoding="utf-8",
            )
            cfg = load(root)
            items = _extract_items(cfg, 10)
            self.assertTrue(items)
            self.assertTrue(all(not i["path"].startswith("..") for i in items))
            self.assertTrue(all("outside" not in i["path"] for i in items))

    def test_custom_material_counts_plain_markdown(self):
        self.assertEqual(
            _material_count({"error": None}, "# Custom\n\nplain material"),
            1,
        )
        self.assertEqual(_material_count({"error": None}, "  \n"), 0)

    def test_relevance_drops_off_topic(self):
        topic = "SQLite WAL 模式下的读写并发与忙等"
        items = [
            {"kind": "memory", "id": "a", "content":
             "uniapp 页面生命周期与路由守卫。" * 8, "score": 0.9},
            {"kind": "memory", "id": "b", "content":
             "SQLite WAL 下写事务串行化，忙等超过 timeout。" * 8,
             "score": 0.8},
        ]
        kept, dropped = filter_items(items, topic, 0.35, 0.25)
        self.assertEqual([i["id"] for i in kept], ["b"])
        self.assertEqual(len(dropped), 1)


if __name__ == "__main__":
    unittest.main()
