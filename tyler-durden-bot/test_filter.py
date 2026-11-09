"""Tests of filter.py: the trigger, the counts, the cut diff, the payload. No network."""

from __future__ import annotations

import io
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import filter as tyler

CONFIG = Path(__file__).with_name("config.toml")
PR_NUMBER = 7


def event(action: str = "opened", repo: str = "h0ffmann/proof", login: str = "h0ffmann", kind: str = "User") -> dict:
    """Return a pull_request event as GitHub sends it, trimmed."""
    return {
        "action": action,
        "repository": {"full_name": repo},
        "pull_request": {
            "number": PR_NUMBER,
            "title": "Prove the lemma",
            "body": "Closes #3",
            "html_url": "https://github.com/h0ffmann/proof/pull/7",
            "user": {"login": login, "type": kind},
            "head": {"sha": "abc123"},
        },
    }


def patch(code: int = 0, comment: int = 0, prefix: str = "//") -> str:
    """Return a patch with that many added code and comment lines."""
    lines = ["@@ -0,0 +1 @@"]
    lines += [f"+let x{i} = {i};" for i in range(code)]
    lines += [f"+{prefix} note {i}" for i in range(comment)]
    return "\n".join(lines)


class TriggerTest(unittest.TestCase):
    """Which events may be summarized at all."""

    def setUp(self) -> None:
        """Load the shipped config."""
        self.cfg = tyler.load_config(CONFIG)

    def test_only_opened(self) -> None:
        """A push to an open pull request is not summarized again."""
        assert tyler.skip_reason(event("synchronize"), self.cfg) == "not opened"
        assert tyler.skip_reason(event(), self.cfg) is None

    def test_only_watched_repos(self) -> None:
        """Only h0ffmann/proof is on the watchlist."""
        assert tyler.skip_reason(event(repo="piabrota/nix-os"), self.cfg) == "not watched"

    def test_bots_skipped(self) -> None:
        """Bots' pull requests are skipped."""
        assert tyler.skip_reason(event(login="dependabot[bot]", kind="Bot"), self.cfg) == "bot author"

    def test_authors_list(self) -> None:
        """A non-empty authors list admits only those authors."""
        self.cfg["trigger"]["authors"] = ["h0ffmann"]
        assert tyler.skip_reason(event(login="someone"), self.cfg) == "author not listed"


class CountTest(unittest.TestCase):
    """How changed lines are counted and compared with the thresholds."""

    def setUp(self) -> None:
        """Load the shipped config."""
        self.cfg = tyler.load_config(CONFIG)

    def test_code_and_comments(self) -> None:
        """Line comments, block comments and code are told apart; context lines are not counted."""
        p = "@@ -1,2 +1,6 @@\n fn a() {}\n+/* opened\n+ still comment\n+*/\n+fn b() {}\n-// gone\n"
        c = tyler.count_patch(p, tyler.language_of("x.rs", self.cfg)[1])
        assert (c.code, c.comment) == (1, 4)

    def test_python_docstring(self) -> None:
        """A one-line docstring opens and closes on the same line."""
        p = '@@ -0,0 +1,2 @@\n+"""One line."""\n+x = 1\n'
        c = tyler.count_patch(p, tyler.language_of("a.py", self.cfg)[1])
        assert (c.code, c.comment) == (1, 1)

    def test_markdown_and_ignored(self) -> None:
        """Markdown is its own bucket; lockfiles never count."""
        files = [
            {"filename": "README.md", "additions": 10, "deletions": 2, "patch": "+x"},
            {"filename": "flake.lock", "additions": 5000, "deletions": 0, "patch": "+x"},
        ]
        t = tyler.tally(files, self.cfg)
        assert (t.overall.markdown, t.overall.code) == (12, 0)

    def test_thresholds(self) -> None:
        """999 code lines do not trigger, 1000 do; comments and markdown have their own."""
        below = [{"filename": "a.rs", "patch": patch(code=999, comment=999)}]
        assert tyler.reached(tyler.tally(below, self.cfg), self.cfg) == []
        at = [{"filename": "a.rs", "patch": patch(code=1000)}]
        assert tyler.reached(tyler.tally(at, self.cfg), self.cfg) == ["code 1000 >= 1000"]
        md = [{"filename": "a.md", "additions": 1000, "deletions": 0}]
        assert tyler.reached(tyler.tally(md, self.cfg), self.cfg) == ["markdown 1000 >= 1000"]

    def test_language_threshold(self) -> None:
        """A language's own threshold counts only that language's lines."""
        self.cfg["languages"]["rust"]["code"] = 300
        files = [{"filename": "a.rs", "patch": patch(code=300)}, {"filename": "b.nix", "patch": patch(code=10)}]
        assert tyler.reached(tyler.tally(files, self.cfg), self.cfg) == ["rust code 300 >= 300"]

    def test_unknown_extension_is_code(self) -> None:
        """A file no language lists counts as code, even its lines that look like comments."""
        c = tyler.tally([{"filename": "a.zig", "patch": patch(comment=3)}], self.cfg).overall
        assert (c.code, c.comment) == (3, 0)


class PayloadTest(unittest.TestCase):
    """What the route's prompt receives."""

    def setUp(self) -> None:
        """Load the shipped config."""
        self.cfg = tyler.load_config(CONFIG)

    def test_diff_cut_to_budget(self) -> None:
        """Patches past the budget are left out and named."""
        self.cfg["quality"]["max_input_tokens"] = 10
        files = [{"filename": "a.rs", "patch": "+x"}, {"filename": "b.rs", "patch": "+" + "y" * 100}]
        diff, omitted = tyler.build_diff(files, self.cfg)
        assert "a.rs" in diff
        assert omitted == ["b.rs"]

    def test_payload(self) -> None:
        """The payload names the sections, the counts and the trigger."""
        files = [{"filename": "a.rs", "patch": patch(code=1200)}]
        p = tyler.summary_payload(event(), files, self.cfg)
        assert p is not None
        assert p["tyler"]["sections"] == "tldr, eli5, summary, risk"
        assert p["tyler"]["trigger"] == "code 1200 >= 1000"
        assert p["pull_request"]["number"] == PR_NUMBER

    def test_main_silent_for_push(self) -> None:
        """Print [SILENT] from main for an event it does not take, without calling GitHub."""
        out = io.StringIO()
        stdin = io.StringIO(json.dumps(event("synchronize")))
        with (
            mock.patch.dict(os.environ, {"TYLER_DURDEN_CONFIG": str(CONFIG)}),
            mock.patch.object(sys, "stdin", stdin),
            mock.patch.object(sys, "stdout", out),
            mock.patch.object(tyler, "fetch_files", side_effect=AssertionError("called GitHub")),
        ):
            assert tyler.main() == 0
        assert out.getvalue().strip() == "[SILENT]"

    def test_main_payload(self) -> None:
        """Print the payload from main when a threshold is reached."""
        out = io.StringIO()
        stdin = io.StringIO(json.dumps(event()))
        files = [{"filename": "a.rs", "patch": patch(code=1000)}]
        with (
            mock.patch.dict(os.environ, {"TYLER_DURDEN_CONFIG": str(CONFIG)}),
            mock.patch.object(sys, "stdin", stdin),
            mock.patch.object(sys, "stdout", out),
            mock.patch.object(tyler, "fetch_files", return_value=files),
            mock.patch.object(tyler, "read_token", return_value="t"),
        ):
            assert tyler.main() == 0
        assert json.loads(out.getvalue())["tyler"]["counts"].startswith("code 1000")


if __name__ == "__main__":
    unittest.main()
