"""A fake GitHub API for test/run.sh.

It serves the calls the agents make from state in memory and appends every request to a JSON-lines
file. Python's standard library only.

    python3 fake_github.py PORT STATE.json REQUESTS.jsonl
"""

from __future__ import annotations

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import TYPE_CHECKING
from urllib.parse import parse_qs, urlparse

if TYPE_CHECKING:
    from collections.abc import Callable

PORT, STATE_FILE, LOG_FILE = int(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
state: dict = json.loads(STATE_FILE.read_text())
state.setdefault("issues", [])
state.setdefault("comments", {})
state.setdefault("labels", [])
REPO = state["repo"]
TOKEN = "ghs_fake"  # noqa: S105 - the fake installation token the tests expect, not a secret
NOT_GRANTED = "The permissions requested are not granted to this installation."

Reply = tuple[int, object, dict[str, str]]


def ok(body: object, status: int = 200) -> Reply:
    """Answer with a JSON body."""
    return status, body, {}


def installation(_m: re.Match, _q: dict, _b: object) -> Reply:
    """GET the App's installation on the repository."""
    return ok({"id": 7})


def access_token(_m: re.Match, _q: dict, body: dict) -> Reply:
    """POST an installation token; pull_requests can be refused."""
    if "pull_requests" in body["permissions"] and state.get("deny_pull_requests"):
        return ok({"message": NOT_GRANTED}, 422)
    return ok({"token": TOKEN}, 201)


def blob(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a job log where the logs endpoint redirects."""
    return 200, state["logs"][m.group(1)].encode(), {}


def runs(_m: re.Match, query: dict, _b: object) -> Reply:
    """GET the deploy workflow's runs, optionally only the failed ones."""
    found = state["runs"]
    if query.get("status") == ["failure"]:
        found = [r for r in found if r["conclusion"] == "failure"]
    return ok({"workflow_runs": found})


def jobs(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a run's jobs."""
    return ok({"jobs": state["jobs"].get(m.group(1), [])})


def job_log(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a job's log: a redirect to storage, as GitHub does."""
    return 302, b"", {"Location": f"http://127.0.0.1:{PORT}/blob/{m.group(1)}"}


def commit_pulls(_m: re.Match, _q: dict, _b: object) -> Reply:
    """GET the pull requests a commit belongs to."""
    return ok(state.get("pulls", []))


def label(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET a label, 404 until it is created."""
    if m.group(1) in state["labels"]:
        return ok({"name": m.group(1)})
    return ok({"message": "Not Found"}, 404)


def new_label(_m: re.Match, _q: dict, body: dict) -> Reply:
    """POST a label."""
    state["labels"].append(body["name"])
    return ok(body, 201)


def issues(_m: re.Match, query: dict, _b: object) -> Reply:
    """GET issues by label and state."""
    wanted = query.get("labels", [""])[0]
    which = query.get("state", ["open"])[0]
    found = [i for i in state["issues"] if wanted in i.get("labels", []) and which in ("all", i["state"])]
    return ok(found)


def new_issue(_m: re.Match, _q: dict, body: dict) -> Reply:
    """POST an issue."""
    number = len(state["issues"]) + 1
    issue = {**body, "number": number, "state": "open", "html_url": f"https://github.com/{REPO}/issues/{number}"}
    state["issues"].append(issue)
    return ok(issue, 201)


def comments(m: re.Match, _q: dict, _b: object) -> Reply:
    """GET an issue's comments."""
    return ok(state["comments"].setdefault(m.group(1), []))


def new_comment(m: re.Match, _q: dict, body: dict) -> Reply:
    """POST a comment on an issue or pull request."""
    thread = state["comments"].setdefault(m.group(1), [])
    comment = {"body": body["body"], "html_url": f"https://github.com/{REPO}/issues/{m.group(1)}#c{len(thread) + 1}"}
    thread.append(comment)
    return ok(comment, 201)


# The App's own calls (with its JWT) and storage come first: they need no installation token.
OPEN_ROUTES: list[tuple[str, str, Callable[[re.Match, dict, dict], Reply]]] = [
    ("GET", rf"/repos/{REPO}/installation", installation),
    ("POST", r"/app/installations/7/access_tokens", access_token),
    ("GET", r"/blob/(\d+)", blob),
]
ROUTES: list[tuple[str, str, Callable[[re.Match, dict, dict], Reply]]] = [
    ("GET", rf"/repos/{REPO}/actions/workflows/deploy\.yml/runs", runs),
    ("GET", rf"/repos/{REPO}/actions/runs/(\d+)/jobs", jobs),
    ("GET", rf"/repos/{REPO}/actions/jobs/(\d+)/logs", job_log),
    ("GET", rf"/repos/{REPO}/commits/([0-9a-f]+)/pulls", commit_pulls),
    ("GET", rf"/repos/{REPO}/labels/(.+)", label),
    ("POST", rf"/repos/{REPO}/labels", new_label),
    ("GET", rf"/repos/{REPO}/issues", issues),
    ("POST", rf"/repos/{REPO}/issues", new_issue),
    ("GET", rf"/repos/{REPO}/issues/(\d+)/comments", comments),
    ("POST", rf"/repos/{REPO}/issues/(\d+)/comments", new_comment),
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
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None
        auth = self.headers.get("Authorization", "")
        with LOG_FILE.open("a") as f:
            record = {"method": method, "path": url.path, "query": url.query, "auth": auth, "body": body}
            f.write(json.dumps(record) + "\n")
        status, payload, headers = route(
            method, url.path, parse_qs(url.query), body, authorized=auth == f"Bearer {TOKEN}"
        )
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


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
