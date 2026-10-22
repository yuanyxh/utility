import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Sources" / "MCPScripts"))

from utility.services.knowledge import knowledge_pool as pool


class KnowledgePoolRotationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(
            os.environ,
            {"UTILITY_DATA_DIR": self.tmp.name},
            clear=False,
        )
        self.env.start()
        pool.init_db()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def _card(self, title: str) -> int:
        return pool.insert_card(kind=pool.KIND_TOPIC, title=title, body="body")

    def test_unseen_cards_are_served_before_reviewed(self):
        self._card("first")
        self._card("second")
        self.assertEqual(pool.unseen_count(pool.KIND_TOPIC), 2)

        first = pool.next_card(pool.KIND_TOPIC)
        second = pool.next_card(pool.KIND_TOPIC)
        self.assertEqual([first["title"], second["title"]], ["first", "second"])
        self.assertEqual(pool.unseen_count(pool.KIND_TOPIC), 0)
        self.assertIsNone(pool.next_card(pool.KIND_TOPIC))

    def test_reviewed_cards_are_opt_in(self):
        self._card("first")
        pool.next_card(pool.KIND_TOPIC)
        self.assertIsNone(pool.next_card(pool.KIND_TOPIC))

        reviewed = pool.next_card(pool.KIND_TOPIC, show_reviewed=True, max_shown=2)
        self.assertEqual(reviewed["title"], "first")
        self.assertIsNone(
            pool.next_card(pool.KIND_TOPIC, show_reviewed=True, max_shown=2)
        )

    def test_seed_only_loads_topics(self):
        topics = '[{"name":"TCP/IP","kind":"principle"}]'
        with patch.dict(os.environ, {"KNOWLEDGE_TOPICS": topics}, clear=False):
            self.assertEqual(pool.seed_from_config(), 1)
            self.assertEqual(pool.seed_from_config(), 0)


if __name__ == "__main__":
    unittest.main()
