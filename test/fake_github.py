"""A fake GitHub API for test/run.sh.

It serves the calls the agents make from state in memory and appends every request to a JSON-lines
file. Python's standard library only.

    python3 fake_github.py PORT STATE.json REQUESTS.jsonl
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import TYPE_CHECKING
from urllib.parse import parse_qs, unquote, urlparse

if TYPE_CHECKING:
    from collections.abc import Callable

PORT, STATE_FILE, LOG_FILE = int(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
state: dict = json.loads(STATE_FILE.read_text())
for key, empty in (("issues", []), ("comments", {}), ("labels", []), ("prs", []), ("reactions", {})):
    state.setdefault(key, empty)
REPO = state["repo"]
BOT = state.get("bot", "piabrota-ops[bot]")
TOKEN = "ghs_fake"  # noqa: S105 - the fake installation token the tests expect, not a secret
NOT_GRANTED = "The permissions requested are not granted to this installation."
counter = {"n": max([i["number"] for i in state["issues"]] + [p["number"] for p in state["prs"]] + [0])}

Reply = tuple[int, object, dict[str, str]]


def ok(body: object, status: int = 200) -> Reply:
    """Answer with a JSON body."""
    return status, body, {}


def next_number() -> int:
    """Issues and pull requests share their numbers, as on GitHub."""
    counter["n"] += 1
    return counter["n"]


def installation(_m: re.Match, _q: dict, _b: object) -> Reply:
    """GET the App's installation on the repository."""
    return ok({"id": 7})


def access_token(_m: re.Match, _q: dict, body: dict) -> Reply:
    """POST an installation token; pull_requests or contents:write can be refused."""
    perms = body["permissions"]
    if ("pull_requests" in perms and state.get("deny_pull_requests")) or (
        perms.get("contents") == "write" and state.get("deny_contents")
    ):
        return ok({"message": NOT_GRANTED}, 422)
    return ok({"token": TOKEN}, 201)


def blob(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a job log where the logs endpoint redirects."""
    return 200, state["logs"][m.group(1)].encode(), {}


def bot_user(_m: re.Match, _q: dict, _b: object) -> Reply:
    """GET the App's bot user."""
    return ok({"login": BOT, "id": 4242})


def runs(_m: re.Match, query: dict, _b: object) -> Reply:
    """GET the deploy workflow's runs, optionally only the failed ones."""
    found = state["runs"]
    if query.get("status") == ["failure"]:
        found = [r for r in found if r["conclusion"] == "failure"]
    return ok({"workflow_runs": found})


def run(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET one run."""
    return ok(next(r for r in state["runs"] if str(r["id"]) == m.group(1)))


def jobs(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a run's jobs."""
    return ok({"jobs": state["jobs"].get(m.group(1), [])})


def job_log(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a job's log: a redirect to storage, as GitHub does."""
    return 302, b"", {"Location": f"http://127.0.0.1:{PORT}/blob/{m.group(1)}"}


def commit_pulls(_m: re.Match, _q: dict, _b: object) -> Reply:
    """GET the pull requests a commit belongs to."""
    return ok(state.get("commit_pulls", []))


def label(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a label, 404 until it is created."""
    if m.group(1) in state["labels"]:
        return ok({"name": m.group(1)})
    return ok({"message": "Not Found"}, 404)


def new_label(_m: re.Match, _q: dict, body: dict) -> Reply:
    """POST a label."""
    state["labels"].append(body["name"])
    return ok(body, 201)


def label_names(item: dict) -> list[str]:
    """Return the names of an issue's labels, kept as text in the state or as objects."""
    return [n["name"] if isinstance(n, dict) else n for n in item.get("labels", [])]


def issues(_m: re.Match, query: dict, _b: object) -> Reply:
    """GET issues (and pull requests, which are issues too) by label and state."""
    wanted = query.get("labels", [""])[0]
    which = query.get("state", ["open"])[0]
    every = state["issues"] + [{**p, "pull_request": {}} for p in state["prs"]]
    found = [i for i in every if wanted in label_names(i) and which in ("all", i.get("state", "open"))]
    return ok([{**i, "labels": [{"name": n} for n in label_names(i)]} for i in found])


def issue(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET one issue or pull request, as the issues API shows it."""
    number = int(m.group(1))
    for i in state["issues"]:
        if i["number"] == number:
            return ok({**i, "labels": [{"name": n} for n in i.get("labels", [])]})
    for p in state["prs"]:
        if p["number"] == number:
            return ok({**p, "pull_request": {}, "labels": [{"name": n} for n in p.get("labels", [])]})
    return ok({"message": "Not Found"}, 404)


def new_issue(_m: re.Match, _q: dict, body: dict) -> Reply:
    """POST an issue, opened by the App."""
    number = next_number()
    created = {
        **body,
        "number": number,
        "state": "open",
        "user": {"login": BOT, "type": "Bot"},
        "html_url": f"https://github.com/{REPO}/issues/{number}",
    }
    state["issues"].append(created)
    return ok(created, 201)


def comments(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET an issue's comments."""
    return ok(state["comments"].setdefault(m.group(1), []))


def all_comments(_m: re.Match, _q: dict, _b: object) -> Reply:
    """GET every issue comment in the repository."""
    return ok([c for thread in state["comments"].values() for c in thread])


def issue_events(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET an issue's events."""
    return ok(state.get("events", {}).get(m.group(1), []))


def add_labels(m: re.Match, _q: dict, body: dict) -> Reply:
    """POST labels on an issue or pull request."""
    number = int(m.group(1))
    item = next((i for i in state["issues"] + state["prs"] if i["number"] == number), None)
    if item is None:
        return ok({"message": "Not Found"}, 404)
    item["labels"] = label_names(item) + body["labels"]
    return ok([{"name": n} for n in item["labels"]])


def repo_runs(_m: re.Match, query: dict, _b: object) -> Reply:
    """GET the repository's runs at one commit."""
    sha = query.get("head_sha", [""])[0]
    return ok({"workflow_runs": [r for r in state["runs"] if r["head_sha"] == sha]})


def new_comment(m: re.Match, _q: dict, body: dict) -> Reply:
    """POST a comment on an issue or pull request, as the App."""
    thread = state["comments"].setdefault(m.group(1), [])
    cid = 9000 + sum(len(t) for t in state["comments"].values())
    comment = {
        "id": cid,
        "body": body["body"],
        "user": {"login": BOT, "type": "Bot"},
        "author_association": "NONE",
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "issue_url": f"https://api.github.com/repos/{REPO}/issues/{m.group(1)}",
        "html_url": f"https://github.com/{REPO}/issues/{m.group(1)}#issuecomment-{cid}",
        "reactions": {},
    }
    thread.append(comment)
    return ok(comment, 201)


def edit_comment(m: re.Match, _q: dict, body: dict) -> Reply:
    """PATCH a comment's body."""
    for thread in state["comments"].values():
        for c in thread:
            if str(c["id"]) == m.group(1):
                c["body"] = body["body"]
                return ok(c)
    return ok({"message": "Not Found"}, 404)


def reactions(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a comment's reactions."""
    return ok(state["reactions"].get(m.group(1), []))


def pulls(_m: re.Match, query: dict, _b: object) -> Reply:
    """GET pull requests by state, optionally by head (owner:branch)."""
    head = query.get("head", [""])[0].split(":")[-1]
    which = query.get("state", ["open"])[0]
    found = [p for p in state["prs"] if p.get("state", "open") == which and head in ("", p["head"]["ref"])]
    return ok(found)


def pull(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET one pull request."""
    return ok(next(p for p in state["prs"] if p["number"] == int(m.group(1))))


def pull_files(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a pull request's files."""
    return ok(next(p for p in state["prs"] if p["number"] == int(m.group(1))).get("files", []))


def pull_commits(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a pull request's commits."""
    return ok(next(p for p in state["prs"] if p["number"] == int(m.group(1))).get("commits", []))


def new_pull(_m: re.Match, _q: dict, body: dict) -> Reply:
    """POST a pull request, opened by the App."""
    number = next_number()
    created = {
        **body,
        "number": number,
        "state": "open",
        "user": {"login": BOT},
        "head": {"ref": body["head"], "sha": "", "repo": {"full_name": REPO}},
        "base": {"ref": body["base"]},
        "html_url": f"https://github.com/{REPO}/pull/{number}",
    }
    state["prs"].append(created)
    return ok(created, 201)


Route = tuple[str, str, "Callable[[re.Match, dict, dict], Reply]"]
# The App's own calls (with its JWT) and storage come first: they need no installation token.
OPEN_ROUTES: list[Route] = [
    ("GET", rf"/repos/{REPO}/installation", installation),
    ("POST", r"/app/installations/7/access_tokens", access_token),
    ("GET", r"/blob/(\d+)", blob),
]
ROUTES: list[Route] = [
    ("GET", r"/users/[a-z0-9-]+\[bot\]", bot_user),
    ("GET", rf"/repos/{REPO}/actions/workflows/deploy\.yml/runs", runs),
    ("GET", rf"/repos/{REPO}/actions/runs", repo_runs),
    ("GET", rf"/repos/{REPO}/actions/runs/(\d+)", run),
    ("GET", rf"/repos/{REPO}/actions/runs/(\d+)/jobs", jobs),
    ("GET", rf"/repos/{REPO}/actions/jobs/(\d+)/logs", job_log),
    ("GET", rf"/repos/{REPO}/commits/([0-9a-f]+)/pulls", commit_pulls),
    ("GET", rf"/repos/{REPO}/labels/(.+)", label),
    ("POST", rf"/repos/{REPO}/labels", new_label),
    ("GET", rf"/repos/{REPO}/issues", issues),
    ("POST", rf"/repos/{REPO}/issues", new_issue),
    ("GET", rf"/repos/{REPO}/issues/comments", all_comments),
    ("PATCH", rf"/repos/{REPO}/issues/comments/(\d+)", edit_comment),
    ("GET", rf"/repos/{REPO}/issues/comments/(\d+)/reactions", reactions),
    ("GET", rf"/repos/{REPO}/issues/(\d+)", issue),
    ("GET", rf"/repos/{REPO}/issues/(\d+)/comments", comments),
    ("GET", rf"/repos/{REPO}/issues/(\d+)/events", issue_events),
    ("POST", rf"/repos/{REPO}/issues/(\d+)/labels", add_labels),
    ("POST", rf"/repos/{REPO}/issues/(\d+)/comments", new_comment),
    ("GET", rf"/repos/{REPO}/pulls", pulls),
    ("POST", rf"/repos/{REPO}/pulls", new_pull),
    ("GET", rf"/repos/{REPO}/pulls/(\d+)", pull),
    ("GET", rf"/repos/{REPO}/pulls/(\d+)/files", pull_files),
    ("GET", rf"/repos/{REPO}/pulls/(\d+)/commits", pull_commits),
]


def route(method: str, path: str, query: dict, body: dict, *, authorized: bool) -> Reply:
    """Find the handler for a request and run it."""
    for table, needs_token in ((OPEN_ROUTES, False), (ROUTES, True)):
        for want, pattern, handler in table:
            m = re.fullmatch(pattern, path)
            if want == method and m:
                if needs_token and not authorized:
                    return ok({"message": "Bad credentials"}, 401)
                return handler(m, query, body)
    return ok({"message": f"no fake for {method} {path}"}, 404)


class Handler(BaseHTTPRequestHandler):
    """Records each request, then answers it from the route tables."""

    def log_message(self, *_args: object) -> None:
        """Keep the test's output quiet."""

    def handle_any(self, method: str) -> None:
        """Record the request and send the routed reply."""
        url = urlparse(self.path)
        path = unquote(url.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None
        auth = self.headers.get("Authorization", "")
        with LOG_FILE.open("a") as f:
            record = {"method": method, "path": path, "query": url.query, "auth": auth, "body": body}
            f.write(json.dumps(record) + "\n")
        status, payload, headers = route(method, path, parse_qs(url.query), body, authorized=auth == f"Bearer {TOKEN}")
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        """Serve a GET."""
        self.handle_any("GET")

    def do_POST(self) -> None:
        """Serve a POST."""
        self.handle_any("POST")

    def do_PATCH(self) -> None:
        """Serve a PATCH."""
        self.handle_any("PATCH")


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
