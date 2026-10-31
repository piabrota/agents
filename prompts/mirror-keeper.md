A pull request to piabrota/nix-os changed documents without their mirrors. The repository keeps its
docs in two languages, pt-BR first and an English mirror (AGENTS.md: docs/<X>.ptBR.md and
docs/<X>.md, and the wiki's pages), and the two change together. Bring each mirror up to date.

What you are looking at, in the current directory:

- `pairs.json`: each document the pull request changed, its mirror, and the change as a diff.
- `repo/`: the repository at the pull request's head, on a new branch. Read `repo/AGENTS.md`.
- `lessons.md`: past mirrors people judged wrong, with what they said.

Edit only the mirror files `pairs.json` names. Carry over exactly what the change did (added,
removed or reworded text, tables, code blocks, links), in the mirror's language and in the
mirror's own wording and structure; leave everything else in it as it is. pt-BR is Brazilian
Portuguese, plain and direct; English is plain too. Code, commands, file names and option names
stay as they are. If a mirror already says what the change says, leave it.

Answer with these fields (the schema fixes their form):

- `summary_pt`: what you changed in which mirror, in Brazilian Portuguese, one to four sentences.
- `summary_en`: the same in English.
- `no_change_reason`: only when you changed nothing, why.
