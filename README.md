# mind-trick

**`mind-trick.sh` — scrub commit-message trailers from git history.**

> "These aren't the commits you're looking for."

Removes matching **trailer lines** (default `Co-Authored-By: Claude …`) from every
commit across **all branches** of a repository, then optionally force-pushes.
Handy for stripping AI co-author attribution — or any unwanted trailer — from
history. It's a gum-free, flag-driven CLI (the engine); an interactive front-end
(scomp-link) drives it, the same split as
[holo-convert](https://github.com/malahmen/holo-convert) and
[navicomputer](https://github.com/malahmen/navicomputer).

## Safety

History rewriting is destructive, so mind-trick is conservative:

- **Dry-run by default** — without `--apply` it only reports which commits/branches
  match; nothing changes.
- **Backup first** — `--apply` always writes a `git bundle` of the whole repo to
  `~/.cache/mind-trick/` before rewriting (restore: `git clone <bundle>`).
- **Refuses a dirty working tree** and non-git directories.
- **Force-push is opt-in** (`--push`) — never automatic.
- Content is untouched — only commit *messages* change (trees stay identical).

## What it can't do

It cannot remove commits GitHub keeps in **`refs/pull/*`** — a merged PR's page
still shows its original commits. Only **branch history** and, once GitHub
recomputes, the **Contributors graph** are cleaned. The tool prints this reminder
after pushing.

## Requirements

- **git** (uses `git filter-branch`, built in). No other dependencies.

## Install

```sh
git clone git@github.com:malahmen/mind-trick.git
cd mind-trick
chmod +x mind-trick.sh
./mind-trick.sh --help
```

## Usage

```sh
# Dry run in the current repo (default pattern: Co-Authored-By: Claude)
./mind-trick.sh

# Rewrite a specific repo and force-push
./mind-trick.sh --repo ~/code/myrepo --apply --push

# Strip a different trailer
./mind-trick.sh --repo . --pattern '^Signed-off-by:' --apply
```

## Flags

| Flag | Meaning |
| ---- | ------- |
| `--repo DIR` | repository to operate on (default: current directory) |
| `--pattern REGEX` | message lines to remove, `grep -iE` (default `^Co-Authored-By: Claude`) |
| `--apply` | actually rewrite history (default: dry-run) |
| `--push` | force-push the rewritten branches after `--apply` |
| `-h`, `--help` | show help |

## Notes

- Status goes to **stderr**; nothing pollutes stdout, so it composes in scripts.
- Never elevates privileges.

## License

Released under the [Unlicense](LICENSE).
