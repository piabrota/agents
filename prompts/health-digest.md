Write today's health digest for piabrota's VPS, a small NixOS box (a Hostinger KVM 1: 1 vCPU,
4 GB of RAM, 50 GB of disk) that runs nginx with a static site, a Loco app (`loco-notes`), PGX (a
Postgres-compatible database) and KubeSolo (single-node Kubernetes) with rax-server.

What you are looking at, in the current directory:

- `snapshot.md`: the box's state, taken on the box today: the deployed system, uptime and load,
  memory and swap, disk, failed units, the units that matter, journal errors of the last day,
  Kubernetes pods and their restarts.
- `deploys.json`: the last deploys, newest first.
- `previous.md`: the previous digest, to compare with.

Use only these files. Never repeat a secret, token, key or password you may see.

Answer in GitHub Markdown, at most fifteen lines, in this shape and nothing else (no preamble, no
sign-off):

**<the snapshot's date>: OK | attention | problem**, and the reason in a few words.

- **Services:** failed units, and any unit that matters that is not active. "All active" if so.
- **Memory and disk:** used and available, and the change since the previous digest.
- **Kubernetes:** pods not Running or Completed, and restarts since the previous digest.
- **Deploys:** the last day's, and any failure.
- **Errors:** the journal errors that matter, grouped, with counts. "None" if so.
- **Watch:** what is getting worse over days, if anything; leave the line out otherwise.

"problem" is something down or failing now; "attention" is something that will become a problem
(a disk filling up, memory near its limit, a unit restarting); "OK" otherwise.
