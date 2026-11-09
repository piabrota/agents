"""tyler-durden-bot's trigger: a Hermes webhook route script.

Hermes passes the GitHub pull_request event as JSON on stdin. This script drops it ("[SILENT]")
unless the pull request was just opened on a watched repository, by an author the config allows,
and its changed lines reach a threshold of config.toml. Otherwise it prints a new payload for the
route's prompt: the pull request's facts, the counts, the sections to write and the diff, cut to
the token budget. It reads GitHub only (the pull request's files); it never writes anywhere.
"""

from __future__ import annotations

import fnmatch
import json
import os
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

import tomllib

SILENT = "[SILENT]"
PER_PAGE = 100
MAX_PAGES = 30  # GitHub lists at most 3000 files of a pull request
CHARS_PER_TOKEN = 4
BUCKETS = ("code", "comment", "markdown")


@dataclass
class Counts:
    """Changed lines (additions plus deletions) in each bucket."""

    code: int = 0
    comment: int = 0
    markdown: int = 0

    def add(self, other: Counts) -> None:
        """Add another file's counts to these."""
        self.code += other.code
        self.comment += other.comment
        self.markdown += other.markdown

    @property
    def total(self) -> int:
        """All changed lines."""
        return self.code + self.comment + self.markdown


@dataclass
class Tally:
    """The pull request's counts, overall and by language."""

    overall: Counts = field(default_factory=Counts)
    by_language: dict[str, Counts] = field(default_factory=dict)


def load_config(path: Path) -> dict[str, Any]:
    """Read config.toml."""
    with path.open("rb") as f:
        return tomllib.load(f)


def skip_reason(event: dict[str, Any], cfg: dict[str, Any]) -> str | None:
    """Why this event is not summarized, or None when it may be."""
    pr = event.get("pull_request") or {}
    user = pr.get("user") or {}
    trigger = cfg.get("trigger", {})
    authors = trigger.get("authors", [])
    reasons = [
        (event.get("action") != "opened", "not opened"),
        ((event.get("repository") or {}).get("full_name") not in cfg.get("repos", []), "not watched"),
        (trigger.get("skip_bots", True) and user.get("type") == "Bot", "bot author"),
        (bool(authors) and user.get("login") not in authors, "author not listed"),
    ]
    return next((why for hit, why in reasons if hit), None)


def ignored(filename: str, cfg: dict[str, Any]) -> bool:
    """Whether a file never counts (lockfiles, images)."""
    name = PurePosixPath(filename).name
    return any(fnmatch.fnmatch(name, g) or fnmatch.fnmatch(filename, g) for g in cfg.get("ignore", []))


def language_of(filename: str, cfg: dict[str, Any]) -> tuple[str, dict[str, Any]] | None:
    """Return the language table whose extensions match the file, if any."""
    suffix = PurePosixPath(filename).suffix
    for name, spec in cfg.get("languages", {}).items():
        if suffix in spec.get("extensions", []):
            return name, spec
    return None


def is_markdown(filename: str, cfg: dict[str, Any]) -> bool:
    """Whether a file counts as markdown."""
    return PurePosixPath(filename).suffix in cfg.get("markdown", [])


class CommentState:
    """Tells comment lines from code, line by line, through block comments."""

    def __init__(self, spec: dict[str, Any]) -> None:
        """Take a language's comment markers."""
        self.line = tuple(spec.get("line_comment", []))
        self.blocks = [tuple(b) for b in spec.get("block_comment", [])]
        self.closer: str | None = None

    def is_comment(self, text: str) -> bool:
        """Whether this line is a comment; remembers an open block for the next lines."""
        s = text.strip()
        if self.closer is not None:
            if self.closer in s:
                self.closer = None
            return True
        if self.line and s.startswith(self.line):
            return True
        for opener, closer in self.blocks:
            if s.startswith(opener):
                if closer not in s[len(opener) :]:
                    self.closer = closer
                return True
        return False


def count_patch(patch: str, spec: dict[str, Any] | None) -> Counts:
    """Count a code file's changed lines as code or comment. Context lines only carry block state."""
    counts = Counts()
    state = CommentState(spec or {})
    for raw in patch.splitlines():
        if raw.startswith("@@"):
            state.closer = None
            continue
        if raw.startswith("\\"):  # "\ No newline at end of file"
            continue
        comment = state.is_comment(raw[1:])
        if raw[:1] in "+-":
            if comment:
                counts.comment += 1
            else:
                counts.code += 1
    return counts


def count_file(f: dict[str, Any], cfg: dict[str, Any]) -> tuple[str | None, Counts]:
    """Return a file's language (None when unknown) and its counts."""
    name = f["filename"]
    if is_markdown(name, cfg):
        return None, Counts(markdown=f.get("additions", 0) + f.get("deletions", 0))
    lang = language_of(name, cfg)
    patch = f.get("patch")
    if patch is None:  # binary, or too large for GitHub to show: all code
        counts = Counts(code=f.get("additions", 0) + f.get("deletions", 0))
    else:
        counts = count_patch(patch, lang[1] if lang else None)
    return (lang[0] if lang else None), counts


def tally(files: list[dict[str, Any]], cfg: dict[str, Any]) -> Tally:
    """Count every file that is not ignored."""
    t = Tally()
    for f in files:
        if ignored(f["filename"], cfg):
            continue
        lang, counts = count_file(f, cfg)
        t.overall.add(counts)
        if lang is not None:
            t.by_language.setdefault(lang, Counts()).add(counts)
    return t


def hits(counts: Counts, limits: dict[str, Any], label: str) -> list[str]:
    """Return the thresholds these counts reach, as readable lines."""
    found = []
    for bucket in (*BUCKETS, "total"):
        limit = limits.get(bucket, 0)
        value = counts.total if bucket == "total" else getattr(counts, bucket)
        if isinstance(limit, int) and limit > 0 and value >= limit:
            found.append(f"{label}{bucket} {value} >= {limit}")
    return found


def reached(t: Tally, cfg: dict[str, Any]) -> list[str]:
    """Every threshold reached, global first, then each language's own."""
    found = hits(t.overall, cfg.get("trigger", {}), "")
    for lang, counts in sorted(t.by_language.items()):
        found += hits(counts, cfg.get("languages", {}).get(lang, {}), f"{lang} ")
    return found


def build_diff(files: list[dict[str, Any]], cfg: dict[str, Any]) -> tuple[str, list[str]]:
    """Return the patches that fit the token budget, and the files left out."""
    budget = int(cfg.get("quality", {}).get("max_input_tokens", 80000)) * CHARS_PER_TOKEN
    parts: list[str] = []
    omitted: list[str] = []
    used = 0
    for f in files:
        name = f["filename"]
        patch = f.get("patch")
        if ignored(name, cfg) or patch is None:
            omitted.append(name)
            continue
        part = f"--- {name} ({f.get('status', 'modified')})\n{patch}\n"
        if used + len(part) > budget:
            omitted.append(name)
            continue
        parts.append(part)
        used += len(part)
    return "".join(parts), omitted


def describe(t: Tally) -> str:
    """Return the counts in one line."""
    o = t.overall
    langs = ", ".join(f"{k} {v.total}" for k, v in sorted(t.by_language.items()))
    return f"code {o.code}, comment {o.comment}, markdown {o.markdown}, total {o.total}" + (
        f" (by language: {langs})" if langs else ""
    )


def summary_payload(event: dict[str, Any], files: list[dict[str, Any]], cfg: dict[str, Any]) -> dict[str, Any] | None:
    """Return the payload for the route's prompt, or None when no threshold is reached."""
    t = tally(files, cfg)
    why = reached(t, cfg)
    if not why:
        return None
    diff, omitted = build_diff(files, cfg)
    pr = event["pull_request"]
    sections = [s for s, on in cfg.get("sections", {}).items() if on]
    quality = cfg.get("quality", {})
    return {
        "repository": {"full_name": event["repository"]["full_name"]},
        "number": pr["number"],
        "pull_request": {
            "number": pr["number"],
            "title": pr.get("title", ""),
            "body": (pr.get("body") or "")[:4000],
            "html_url": pr.get("html_url", ""),
            "user": {"login": (pr.get("user") or {}).get("login", "")},
            "head": {"sha": (pr.get("head") or {}).get("sha", "")},
        },
        "tyler": {
            "trigger": "; ".join(why),
            "counts": describe(t),
            "sections": ", ".join(sections),
            "min_confidence": str(quality.get("min_confidence", 0.6)),
            "summary_max_items": str(quality.get("summary_max_items", 7)),
            "files": str(len(files)),
            "omitted": ", ".join(omitted) or "none",
            "diff": diff,
        },
    }


def fetch_files(repo: str, number: int, token: str, api: str) -> list[dict[str, Any]]:
    """Return the pull request's files, every page."""
    files: list[dict[str, Any]] = []
    for page in range(1, MAX_PAGES + 1):
        url = f"{api}/repos/{repo}/pulls/{number}/files?per_page={PER_PAGE}&page={page}"
        req = urllib.request.Request(  # noqa: S310 - the API's https URL, from the config
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "User-Agent": "tyler-durden-bot",
            },
        )
        with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310
            batch = json.load(resp)
        files += batch
        if len(batch) < PER_PAGE:
            break
    return files


def read_token() -> str:
    """Return the App's installation token: TYLER_DURDEN_TOKEN_FILE, else GH_TOKEN."""
    path = os.environ.get("TYLER_DURDEN_TOKEN_FILE", "/run/tyler-durden-bot/token")
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return os.environ.get("GH_TOKEN", "")


def main() -> int:
    """Read the event on stdin; print the payload, or [SILENT]."""
    here = Path(__file__).parent  # not resolved: Hermes may link the script from elsewhere
    cfg = load_config(Path(os.environ.get("TYLER_DURDEN_CONFIG", here / "tyler-durden-bot.toml")))
    event = json.load(sys.stdin)
    if skip_reason(event, cfg) is not None:
        sys.stdout.write(SILENT + "\n")
        return 0
    api = os.environ.get("GITHUB_API", "https://api.github.com")
    files = fetch_files(event["repository"]["full_name"], event["pull_request"]["number"], read_token(), api)
    payload = summary_payload(event, files, cfg)
    sys.stdout.write((json.dumps(payload) if payload else SILENT) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
