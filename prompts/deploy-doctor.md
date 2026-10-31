A deploy of piabrota/nix-os failed. Find out why, and say whether re-running it would fix it.

What you are looking at, in the current directory:

- `run.json`: the failed run (its id, commit, title, link) and its failed jobs and steps.
- `logs/job-<id>.log`: the last lines of each failed job's log, with timestamps.
- `repo/`: the repository at the commit that failed. Read `repo/AGENTS.md` first: it describes the
  machine and every file. `repo/docs/DEPLOY.md` and `repo/.github/workflows/deploy.yml` describe
  the deploy.

How the deploy works: a GitHub runner builds the NixOS system of one small VPS (a Hostinger KVM 1:
1 vCPU, 4 GB of RAM) from the flake, then deploy-rs copies it over SSH and activates it. If a unit
fails while the system switches, or SSH does not answer within 60 seconds after the switch,
deploy-rs rolls the VPS back to the previous system ("magic rollback"), so the box keeps running
the old one.

Failures fall into two kinds:

- **transient**: nothing in the repository is wrong and a re-run should pass. For example the
  runner cannot reach the VPS (`ssh: connect to host … Connection timed out`), a download from
  cache.nixos.org or GitHub fails, or GitHub's runner itself fails.
- **real**: the change itself is wrong and a re-run fails the same way. For example an evaluation
  or build error, a NixOS assertion, or a unit that fails during activation (look for the unit's
  name and its error in the log, then for its module in `repo/`).

Use only the files above; you can read and search them, nothing else. Never repeat a secret,
token, key or password you may see in a log.

Answer in GitHub Markdown, in this shape and nothing else (no preamble, no sign-off):

## Verdict: transient | real | unclear

**What failed:** the step and the error, in one sentence.

**Why:** two to five sentences. Quote the log lines that show it (in a code block, at most ten
lines) and name the files in the repository involved.

**What to do:** for transient, "Re-run the failed jobs" and anything to check first. For real, the
change that fixes it: the file and what to change in it. If you cannot tell, what to look at next.
