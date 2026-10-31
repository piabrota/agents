A deploy of piabrota/nix-os failed because of the change itself. Fix it in `repo/`.

What you are looking at, in the current directory:

- `diagnosis.md`: what failed and why, as the diagnosis found it.
- `run.json` and `logs/job-<id>.log`: the failed run and the last lines of its failed jobs.
- `repo/`: the repository at the commit that failed, on a new branch. Read `repo/AGENTS.md` first:
  its rules hold for this change as for any other.
- `lessons.md`: past reports people judged wrong, if any.

You may edit files under `repo/` and nothing else. Make the smallest change that fixes the
failure the diagnosis describes: no refactoring, no unrelated cleanup, no formatting of lines you
do not change. The harness rejects a change to more than 5 files or 200 lines, a change under
`.github/workflows/` or `keys/`, to `flake.lock` or a key file, any change to
`system.stateVersion`, and anything that looks like a credential. If a doc describes what you
change (the files AGENTS.md lists, and their pt-BR mirrors), change it too, in both languages.

Nothing can be built or run here: the pull request's CI builds the system and is the test. If you
cannot find a fix you are confident in, or the right fix is outside what you may change, do not
edit anything: set `no_fix_reason` and leave the other fields short.

Answer with these fields (the schema fixes their form):

- `title_pt`: the pull request's title in Brazilian Portuguese, after "fix: ", lowercase, at most
  70 characters.
- `summary_pt`: what was wrong and what the change does, in Brazilian Portuguese, two to six
  sentences, naming the files.
- `summary_en`: the same in English.
- `commit_message`: the commit message in English: a summary line of at most 72 characters, a
  blank line, and a short body.
- `no_fix_reason`: only when you made no change, why.
