Write today's health digest for piabrota's VPS, a small NixOS box (a Hostinger KVM 1: 1 vCPU,
4 GB of RAM, 50 GB of disk) that runs nginx with a static site, a Loco app (`loco-notes`), PGX (a
Postgres-compatible database) and KubeSolo (single-node Kubernetes) with rax-server.

What you are looking at, in the current directory:

- `snapshot.md`: the box's state, taken on the box today: the deployed system, uptime and load,
  memory and swap, disk, failed units, the units that matter, journal errors of the last day,
  Kubernetes pods and their restarts.
- `deploys.json`: the last deploys, newest first.
- `previous.md`: the previous digest, to compare with.

Answer with these fields (the schema fixes their form), each a sentence or two:

- `date`: the snapshot's date.
- `status`: "problem" is something down or failing now; "attention" is something that will become a
  problem (a disk filling up, memory near its limit, a unit restarting); "OK" otherwise.
- `reason`: the status's reason, in a few words.
- `services`: failed units, and any unit that matters that is not active; "All active" if so.
- `memory_and_disk`: used and available, and the change since the previous digest.
- `kubernetes`: pods not Running or Completed, and restarts since the previous digest.
- `deploys`: the last day's, and any failure.
- `errors`: the journal errors that matter, grouped, with counts; "None" if so.
- `watch`: what is getting worse over days; empty if nothing.
