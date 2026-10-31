"""A fake GitHub API for test/run.sh: the calls the agents make, state in memory, and every request
appended to a JSON-lines file. Python's standard library only.

    python3 fake_github.py PORT STATE.json REQUESTS.jsonl
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT, STATE_FILE, LOG_FILE = int(sys.argv[1]), sys.argv[2], sys.argv[3]
with open(STATE_FILE) as f:
    state = json.load(f)
state.setdefault("issues", [])
state.setdefault("comments", {})
state.setdefault("labels", [])
TOKEN = "ghs_fake"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=None, headers=None):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps({"method": method, "path": path, "query": url.query,
                                "auth": self.headers.get("Authorization", ""), "body": body}) + "\n")

        repo = state["repo"]
        # The App's own calls, with its JWT.
        if path == f"/repos/{repo}/installation":
            return self.reply(200, {"id": 7})
        if method == "POST" and path == "/app/installations/7/access_tokens":
            return self.reply(201, {"token": TOKEN})
        if path.startswith("/blob/"):
            return self.reply(200, state["logs"][path.split("/")[-1]].encode())
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.reply(401, {"message": "Bad credentials"})

        if path == f"/repos/{repo}/actions/workflows/deploy.yml/runs":
            runs = state["runs"]
            if query.get("status") == ["failure"]:
                runs = [r for r in runs if r["conclusion"] == "failure"]
            return self.reply(200, {"workflow_runs": runs})
        m = re.fullmatch(rf"/repos/{repo}/actions/runs/(\d+)/jobs", path)
        if m:
            return self.reply(200, {"jobs": state["jobs"].get(m.group(1), [])})
        m = re.fullmatch(rf"/repos/{repo}/actions/jobs/(\d+)/logs", path)
        if m:
            return self.reply(302, headers={"Location": f"http://127.0.0.1:{PORT}/blob/{m.group(1)}"})
        m = re.fullmatch(rf"/repos/{repo}/labels/(.+)", path)
        if m:
            found = m.group(1) in state["labels"]
            return self.reply(200 if found else 404, {"name": m.group(1)} if found else {"message": "Not Found"})
        if method == "POST" and path == f"/repos/{repo}/labels":
            state["labels"].append(body["name"])
            return self.reply(201, body)
        if path == f"/repos/{repo}/issues":
            if method == "POST":
                number = len(state["issues"]) + 1
                issue = {**body, "number": number, "state": "open",
                         "html_url": f"https://github.com/{repo}/issues/{number}"}
                state["issues"].append(issue)
                return self.reply(201, issue)
            label = query.get("labels", [""])[0]
            want = query.get("state", ["open"])[0]
            issues = [i for i in state["issues"] if label in i.get("labels", [])
                      and (want == "all" or i["state"] == want)]
            return self.reply(200, issues)
        m = re.fullmatch(rf"/repos/{repo}/issues/(\d+)/comments", path)
        if m:
            comments = state["comments"].setdefault(m.group(1), [])
            if method == "POST":
                comment = {"body": body["body"], "html_url": f"https://github.com/{repo}/issues/{m.group(1)}#c{len(comments) + 1}"}
                comments.append(comment)
                return self.reply(201, comment)
            return self.reply(200, comments)
        return self.reply(404, {"message": f"no fake for {method} {path}"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
