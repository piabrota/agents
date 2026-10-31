A pull request updates piabrota/nix-os' flake inputs (flake.lock), most often nixpkgs on the
nixos-26.05 branch. It is the NixOS configuration of one small live VPS, and a merge deploys it.
Say how risky the update is and what to watch after it deploys.

What you are looking at, in the current directory:

- `pr.json`: the pull request; its body has the closure difference (`dix`: packages added, removed
  and changed in version, and the size change) and the inputs' old and new revisions.
- `lock.diff`: the change to flake.lock.
- `repo/`: the repository at the pull request's head. `repo/AGENTS.md` describes the machine: what
  must not break (SSH, cloud-init, the guest agent, GRUB), what runs on it (nginx, the Loco app,
  PGX, KubeSolo), and the resource budget.
- `lessons.md`: past annotations people judged wrong.

You cannot see changelogs or the internet: judge from the versions that change and from what
matters on this machine. A major version of the kernel, systemd, OpenSSH, nginx, glibc or of a
package a unit here runs is worth a line; patch releases of libraries are not. Say so when the
closure grows by more than a few MiB.

Answer with these fields (the schema fixes their form):

- `risk`: low, medium or high.
- `summary`: two to four sentences: what changes and why the risk is what it is.
- `watch`: up to six things to check after the deploy, each one line (for example a unit to look
  at with `systemctl status`); empty when nothing stands out.
