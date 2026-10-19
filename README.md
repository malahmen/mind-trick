# mind-trick

[![ci](https://github.com/malahmen/mind-trick/actions/workflows/ci.yml/badge.svg)](https://github.com/malahmen/mind-trick/actions/workflows/ci.yml)

**`mind-trick.sh` — scrub commit-message trailers from git history.**

> "These aren't the commits you're looking for."

Removes matching **trailer lines** (default `Co-Authored-By: Claude …`) from every
commit across **all branches and tags** of a repository, then optionally force-pushes.
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
- **Refuses a dirty working tree** (untracked files count as dirty) and non-git
  directories.
- **Refuses shallow clones** (`--depth`) — neither rewrite engine can produce
  sound history from a truncated one. Run `git fetch --unshallow` first, or
  re-clone in full.
- **Force-push is opt-in** (`--push`) — never automatic. Branches are pushed with
  `--force-with-lease` against the sha `origin` had before the rewrite, so a
  concurrent push is rejected instead of clobbered; tags are pushed with `--force`.
- Content is untouched — only commit *messages* change (trees stay identical).

## What gets rewritten and pushed

- **Rewritten locally:** every ref in the repository — all local branches, all
  tags (annotated tags are re-created pointing at the rewritten commits) and the
  `origin/*` remote-tracking refs.
- **Pushed with `--push`:** every local branch that has an `origin/<branch>`
  counterpart (branches without one are skipped with a note), then all tags.
- **Untouched:** other remotes, and branches that exist only on the remote (no
  local branch) — check them out first if they need scrubbing.
- **Signatures are stripped:** a rewritten commit is a new object, so GPG/SSH
  signatures on rewritten commits (and on signed tags) do not survive. Re-sign
  afterwards if you need them.

## What it can't do

It cannot remove commits GitHub keeps in **`refs/pull/*`** — a merged PR's page
still shows its original commits. Only **branch history** and, once GitHub
recomputes, the **Contributors graph** are cleaned. The tool prints this reminder
after pushing.

## Requirements

- **git**
- **a history-rewriting engine**, either of:
  - [`git filter-repo`](https://github.com/newren/git-filter-repo) — preferred,
    and the only option on current git;
  - `git filter-branch` — used where it still exists.

`filter-branch` was deprecated for years and is **gone from git 2.55**: not a
subcommand, not in the exec-path. If you are on 2.55 or later, filter-repo is
not optional. It is a single Python script and needs no root, and mind-trick
installs it for you:

```sh
./mind-trick.sh --setup
```

That downloads filter-repo 2.47.0 (pinned), checks it against the sha256 of the
file in that release's tarball, and puts it in `~/.local/bin` (or
`$XDG_BIN_HOME`, or `$MIND_TRICK_BIN_DIR`). It needs `python3` and `curl`. A
download that fails the checksum is deleted, not installed. mind-trick looks in
that directory even when it is not on your `PATH` - after your own `PATH`,
never before it, so a `git` wrapper or shim kept there cannot stand in for the
git that rewrites your history and force-pushes it.

It is checked for after the report and before anything is done. A dry run
still lists what matches; a repo with nothing to scrub never needs it. A run
that would rewrite, with no engine, stops before the backup is written, says
to run `--setup`, and exits with status **3**, so a front-end can offer the
install and retry.

One behaviour worth knowing, because it is surprising: **filter-repo deletes
the repository's remotes.** That is deliberate upstream — it expects to run in
a fresh clone you then push from on purpose — but this tool pushes back to the
remote it just rewrote, so the URLs are snapshotted beforehand and restored
afterwards.

## Testing

```sh
tests/run-all.sh
MIND_TRICK=/path/to/mind-trick.sh tests/run-all.sh
```

**31 checks.** No network: synthetic repositories and `file://` remotes. Because this tool
rewrites published history and force-pushes it, the suite asserts the
properties that make that acceptable rather than only that it runs:

- the matching trailers are gone, locally **and** on the remote;
- **file content is byte-identical** — the tree sha is compared before and
  after, so only messages changed;
- **no commits are lost** — the count is compared;
- a trailer that was not asked for (`Reviewed-by:`) survives;
- the backup bundle exists and still contains the trailers, so it is a real
  restore point;
- a remote that moved under you is **refused, not overwritten** — the
  teammate's commit and their trailers both survive;
- the remotes filter-repo removed are back;
- with no engine on PATH the run stops before the backup and leaves the
  branch untouched;
- with no engine, a dry run still lists the matches and exits 3, and a repo
  with nothing to scrub still exits 0;
- `--setup` refuses (and deletes) a download that fails the checksum, and
  leaves an installed filter-repo alone.

Checked against deliberate regressions: stopping the stripping, and dropping
`--force-with-lease`, each fail the suite.

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to
`main`, every pull request, and on demand: versions, then `git-filter-repo`
installed with `./mind-trick.sh --setup` (so the pinned download and its
checksum are tested too), then `shellcheck`, then the suite.

The install step is not incidental. `test-rewrite.sh`'s control case needs a
working rewrite engine, and the runner's git may have no `filter-branch` at
all — so without it the suite's own baseline fails and every real assertion
after it becomes meaningless.

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
| `--push` | force-push the rewritten branches and tags after `--apply` |
| `--setup` | install `git filter-repo` (pinned, checksum-verified) into `~/.local/bin` |
| `-h`, `--help` | show help |

Exit status: `0` done or nothing matched, `1` error, `3` matches but no rewrite
tool (run `--setup`).

## Notes

- Status goes to **stderr**; nothing pollutes stdout, so it composes in scripts.
- Never elevates privileges.

## License

[MIT](LICENSE) © 2026 malahmen.
