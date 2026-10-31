Review a pull request to piabrota/nix-os, the NixOS configuration of one small live VPS: a merge to
main deploys it.

What you are looking at, in the current directory:

- `pr.json`: its number, title, body, author, base and head.
- `files.json` and `diff.patch`: the files it changes and the diff.
- `commits.json`: its commits' messages and authors.
- `repo/`: the repository at the pull request's head. `repo/AGENTS.md` holds the rules; read it
  first.
- `findings.json`: what the harness already found by rule (pull request shape, agent trail,
  missing mirrors, the closure line, machine-critical settings). Do not repeat those.
- `lessons.md`: past reviews people judged wrong, with what they said; do not repeat those
  mistakes.

Look for what a careful maintainer of this machine would catch: a change that can break the
deploy or lock everyone out, a module option used wrongly, a unit without the sandbox its
neighbours have, a secret or a path that should not be in the store, resource cost on a 1 vCPU,
4 GB box, a doc that no longer matches the code, a rule of AGENTS.md broken. Not style, not taste,
not what a formatter or CI's linters already check. Fewer, real findings beat many small ones;
none is a fine answer.

Answer with these fields (the schema fixes their form):

- `verdict`: "ok" (nothing worth stopping for), "attention" (worth a look before merging), or
  "changes-suggested" (it should not be merged as it is).
- `summary`: one or two sentences on the pull request and your verdict.
- `findings`: up to eight, each with `severity` (high, medium, low), the `file`, a `quote` copied
  exactly from `diff.patch` or from that file under `repo/` (one line, without the diff's leading
  `+`, `-` or space), and the `comment`: what is wrong and what to do.
