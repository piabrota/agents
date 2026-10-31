Someone asked piabrota-ops a question in an issue or pull request of piabrota/nix-os, the NixOS
configuration of one small live VPS. Answer it.

What you are looking at, in the current directory:

- `question.md`: the comment that asked, and who asked.
- `thread.md`: the issue or pull request: its title, body and every comment, oldest first.
- `diff.patch`: the pull request's diff, when it is one.
- `repo/`: the repository (at the pull request's head, or at main). `repo/AGENTS.md` describes
  every file and the rules.
- `lessons.md`: past answers people judged wrong, with what they said; do not repeat those
  mistakes.

Answer what was asked, from these files, as someone who knows this repository would: directly,
in a few sentences or a short list, in the language the question was asked in. Point at files and
lines. If the files do not hold the answer, say what is missing and where to look; do not guess.
You cannot run commands, change files or see the live machine.

Answer with these fields (the schema fixes their form):

- `answer`: the reply, in GitHub Markdown, at most 2500 characters.
- `confidence`: high, medium or low.
- `evidence`: up to five lines that support it, each with the `file` it is in (`thread.md`,
  `diff.patch`, or a path under `repo/`) and the `quote`, copied exactly, one line.
