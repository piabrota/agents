# tyler-durden-bot

Summarizes a large pull request on `h0ffmann/proof` in one comment, as the GitHub App
**tyler-durden-bot** (owned by h0ffmann). Unlike the other agents here it is not a task of `agent
tick`: it runs inside Hermes on piabrota2, from a webhook, when a pull request is opened. nix-os'
`tyler-durden-bot.nix` installs these files at a pinned commit.

| File | Is |
|---|---|
| `config.toml` | The watchlist and the three parts of the config: `[trigger]` (thresholds of code, comment and markdown lines, and per language by extension), `[sections]` (TLDR, ELI5, summary, risk: on or off) and `[quality]` (the diff's token budget, the risk's minimum confidence, the summary's length) |
| `filter.py` | The Hermes route script: drops the event (`[SILENT]`) unless the pull request was opened on a watched repository by an allowed author and a threshold is reached; otherwise reads its files from GitHub and gives the route's prompt the counts, the sections and the diff, cut to the budget. Python's standard library only |
| `skill/SKILL.md` | The Hermes skill that writes the comment: the sections, the five risk levels (very low, low, medium, high, critical) and the confidence, the rules (no `@`, no secrets, no verdict on merging), the footer |
| `test_filter.py` | Its tests, offline: `python3 -m unittest discover -s tyler-durden-bot` (also in `test/run.sh`) |
| `../apps/tyler-durden-bot.json` | The App's manifest: Pull requests read and write, Metadata read, the `pull_request` event, the webhook URL |

## How a pull request becomes a comment

1. GitHub sends `pull_request` to `https://tyler.piabrota.art/p/tyler-durden/webhooks/tyler-durden`,
   signed with the App's webhook secret. nginx passes only that path to Hermes's webhook port, on
   127.0.0.1.
2. Hermes checks the signature and the event, and runs `filter.py` with the payload on stdin.
3. The filter counts each file's changed lines: markdown by extension; code and comment lines by
   the language's comment markers (`line_comment`, `block_comment`), line by line through the patch.
   It is a heuristic: a block opened outside the patch's lines, or `//` inside a string, is
   miscounted. An extension that no language lists counts as code; a file with no patch (binary,
   too large) counts its additions and deletions as code.
4. When any threshold is reached, the route's prompt, the skill and Claude (Hermes's model) write the
   comment, and Hermes posts it with the `tyler-durden` profile's token: `tyler-durden-bot[bot]`.

A push to an open pull request, a reopen and a draft made ready do not run it again.

## The App

Create it on h0ffmann's account from `apps/tyler-durden-bot.json` (Settings, Developer settings,
GitHub Apps): Pull requests read and write, Metadata read, the Pull request event, a webhook secret
of 32 random bytes. Install it on `h0ffmann/proof` only. The App ID, its private key and the
webhook secret go to the box, never here (nix-os' `docs/TYLER-DURDEN.md`).
