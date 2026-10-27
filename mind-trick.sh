#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mind-trick.sh — scrub commit-message trailers from git history.
# "These aren't the commits you're looking for."
#
# Removes matching trailer lines (default 'Co-Authored-By: Claude …') from every
# commit across ALL branches of a repo, then optionally force-pushes. gum-free
# and flag-driven — the CLI engine; an interactive front-end (scomp-link) drives
# it. Safe by default: dry-run unless --apply, always backs up first.
#
# WARNING: --apply rewrites history and --push force-pushes it. It CANNOT touch
# GitHub's refs/pull/* — merged-PR pages keep their old commits; only branch
# history (and the Contributors graph, on recompute) is cleaned.
#
# Dependency: git, plus a rewrite tool: git filter-repo (--setup installs it)
# or git filter-branch (gone from git 2.55). Run --help for the flags.
# -----------------------------------------------------------------------------

set -euo pipefail

# gum-free status output (stderr; stdout stays clean).
if [[ -t 2 ]]; then C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
else C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""; fi
info()       { printf '%s[info]%s  %s\n' "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s[ok]%s    %s\n' "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s[warn]%s  %s\n' "$C_Y" "$C_N" "$*" >&2; }
error_exit() { printf '%s[error]%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }

command -v git &>/dev/null || error_exit "git is required."

REPO="."
PATTERN='^Co-Authored-By: Claude'   # grep -iE, matched per message line
APPLY=false
PUSH=false
BACKUP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mind-trick"
ORIGIN_REFS=""                     # '<sha> refs/remotes/origin/<b>' lines as _check_push_safe checked them: the leases
HEADS_BEFORE=""                    # '<sha> refs/heads/<b>' lines before the rewrite: the only branches ever pushed
ENGINE=""                          # which rewriting tool _need_engine found
WORK=""                            # scratch dir for the message dumps, removed on exit
BUNDLE=""                          # the backup _backup wrote

# What --setup installs: one pinned filter-repo release, checked against the
# sha256 of the file in its release tarball, into a user dir (no root, no pip).
FILTER_REPO_VERSION="2.47.0"
FILTER_REPO_SHA256="67447413e273fc76809289111748870b6f6072f08b17efe94863a92d810b7d94"
FILTER_REPO_URL="${MIND_TRICK_FILTER_REPO_URL:-https://raw.githubusercontent.com/newren/git-filter-repo/v${FILTER_REPO_VERSION}/git-filter-repo}"
BIN_DIR="${MIND_TRICK_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
# Searched even when it is not on the user's PATH, so a --setup install works
# at once (and from a launcher whose PATH never had ~/.local/bin) - but LAST:
# it is only there to find git-filter-repo, and first it would let a `git`
# wrapper or shim in that folder outrank the user's own git, which is the git
# that rewrites history and force-pushes (Kamino item 111).
USER_PATH="$PATH"
case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) PATH="${PATH}:${BIN_DIR}" ;;
esac

EXIT_NO_ENGINE=3                   # matches exist but nothing here can rewrite them

# The grep that defines what --pattern means: the report, the post-rewrite
# check and filter-branch's message filter all run THIS binary, by absolute
# path (the filter runs under a fixed PATH, where another grep could differ).
GREP="$(command -v grep)"

usage() {
    cat >&2 <<'EOF'
mind-trick — scrub commit-message trailers from git history

USAGE
  mind-trick.sh [--repo DIR] [--pattern REGEX] [--apply] [--push]
  mind-trick.sh --setup

FLAGS
  --repo DIR       repository to operate on (default: current directory)
  --pattern REGEX  message lines to remove, grep -iE (default '^Co-Authored-By: Claude').
                   filter-repo rewrites with Python's re: a pattern the two
                   read differently on this history is refused.
  --apply          actually rewrite history (default: dry-run only)
  --push           force-push the rewritten branches and tags after --apply
  --setup          install git filter-repo (pinned, checksum-verified) into
                   ~/.local/bin; no root, no pip. Needs python3 and curl.
  -h, --help

EXIT STATUS
  0 done, or nothing matched   1 error   3 matches, but no rewrite tool (run --setup)

Safe by default: without --apply it only reports. --apply always writes a git
bundle backup first. It cannot remove commits GitHub keeps in refs/pull/*
(merged-PR pages) — only branch history + the Contributors graph clear.

Rewrites every local ref (branches, tags, origin/* tracking refs). --push first
fetches origin and refuses the whole run (nothing rewritten, nothing pushed) if a
local branch lacks commits its origin/<branch> has: pull first. It then sends
the local branches that existed before the rewrite and exist on origin, plus
tags; other remotes and remote-only branches are untouched. Nothing is pushed
unless the rewritten history has no matching line left and lost only matching
lines. Signatures on rewritten commits are dropped. Refuses a
dirty tree (untracked files count) and shallow clones.
EOF
}

_git() { git -C "$REPO" "$@"; }

# _messages OUT REV… — every message line of every commit reachable from REV…,
# one per line, into OUT, and the commit each line belongs to, line for line,
# into OUT.c. The report, the dialect check and the post-rewrite check all
# read these files, so they judge the same lines with the same grep.
_messages() {
    local out="$1"; shift
    : > "$out"; : > "${out}.c"
    _git log --format='%x01%H%n%B' "$@" | awk -v l="$out" -v c="${out}.c" '
        substr($0, 1, 1) == "\001" { h = substr($0, 2); next }
        { print $0 > l; print h > c }'
}

# _grep_lines FILE — the numbers of FILE's lines that --pattern matches.
_grep_lines() {
    local rc=0
    "$GREP" -n -i -E -e "$PATTERN" "$1" > "${1}.m" || rc=$?
    (( rc <= 1 )) || error_exit "grep cannot use --pattern '$PATTERN' — nothing changed."
    cut -d: -f1 "${1}.m"
}

_report() {
    _messages "$WORK/all" --all
    _grep_lines "$WORK/all" > "$WORK/all.lines"
    # The matching commits: the commit of each matching line, once.
    awk 'NR == FNR { m[$1]; next } FNR in m' "$WORK/all.lines" "$WORK/all.c" | sort -u > "$WORK/all.commits"
    local n; n=$(wc -l < "$WORK/all.commits" | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then success "No commits match /$PATTERN/ — nothing to do."; return 1; fi
    warn "${n} commit(s) contain a line matching /$PATTERN/:"
    # Not -n 20: with it, git (2.39 and 2.43 at least) walks despite
    # --no-walk, and the list showed the matching commits' ancestors too.
    # awk, not head: it reads to the end, so no SIGPIPE under pipefail.
    _git log --no-walk --stdin --format='  %h %an | %s' < "$WORK/all.commits" | awk 'NR <= 20' >&2
    (( n > 20 )) && info "  … and $((n - 20)) more"
    info "Affected branches:"
    local b hits
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        # Counted, not grep -q: an early exit would SIGPIPE rev-list under pipefail.
        hits=$(_git rev-list "$b" | "$GREP" -c -F -x -f "$WORK/all.commits" || true)
        [[ "${hits:-0}" -gt 0 ]] && printf '    %s\n' "$b" >&2
    done < <(_git for-each-ref --format='%(refname:short)' refs/heads)
    return 0
}

# _check_dialects — refuse a pattern that grep -E (the report) and Python's re
# (filter-repo's rewrite) read differently on THIS history (Kamino item 171).
# '^Co-Authored-By:[[:space:]]+Claude' is a POSIX class to grep and a set to
# Python: the report listed matches the rewrite kept, then said "History
# cleaned". '^Ref: \d' is a digit to Python and a 'd' to grep: the rewrite
# removed lines the report never showed. Every message line is tested with
# both, so the check is exact for the history about to be rewritten.
_check_dialects() {
    [[ "$ENGINE" == filter-repo ]] || return 0   # filter-branch filters with the report's own grep
    MT_PATTERN="$PATTERN" python3 -c '
import os, re, sys
rx = re.compile(os.environ["MT_PATTERN"].encode(), re.IGNORECASE)
with open(sys.argv[1], "rb") as f:
    for i, l in enumerate(f.read().split(b"\n")[:-1], 1):
        if rx.search(l): print(i)
' "$WORK/all" > "$WORK/all.py" 2>/dev/null \
        || error_exit "Python's re cannot compile --pattern '$PATTERN' (filter-repo's rewrite uses it) — nothing changed."
    cmp -s "$WORK/all.lines" "$WORK/all.py" && return 0
    warn "--pattern '$PATTERN' means different things to grep -E (the report)"
    warn "and to Python's re (filter-repo's rewrite) on these message lines:"
    local n
    while IFS= read -r n; do printf '    grep only:   %s\n' "$(sed -n "${n}p" "$WORK/all")" >&2
    done < <(comm -23 <(sort "$WORK/all.lines") <(sort "$WORK/all.py") | sort -n | head -n 5)
    while IFS= read -r n; do printf '    Python only: %s\n' "$(sed -n "${n}p" "$WORK/all")" >&2
    done < <(comm -13 <(sort "$WORK/all.lines") <(sort "$WORK/all.py") | sort -n | head -n 5)
    error_exit "Refusing: what is shown must be what is rewritten. Write it so both read it alike ('[ ]' or ' ', not [[:space:]] or \\s; [0-9], not \\d) — nothing changed."
}

# _fetch_origin — what origin has NOW, before anything is decided about it.
# Branches only (--no-tags): a fetched tag must not clobber a local one.
_fetch_origin() {
    _git remote get-url origin &>/dev/null || error_exit "--push needs a remote named 'origin' — nothing changed."
    info "Fetching origin…"
    _git fetch --no-tags --quiet origin >&2 || error_exit "Cannot fetch origin, so cannot check what --push would overwrite — nothing changed."
}

# _check_push_safe — refuse unless every branch --push would send contains
# everything origin has on it (Kamino item 165). The lease alone stops only a
# push made AFTER the last fetch: a branch fetched but not pulled
# (origin/main=B, main=A) was leased on B, and the remote's "B A" became
# "A'" - B surviving only in the backup bundle.
#
# The whole run is refused rather than the branch skipped: the rewrite covers
# every local branch, so a skipped one would be rewritten here anyway, and
# pulling origin into it afterwards would bring every scrubbed commit back
# beside its rewritten twin. Refused before the backup, so nothing changes.
#
# The shas checked here are the leases _force_push uses: if origin moves
# after this, the push is rejected.
_check_push_safe() {
    ORIGIN_REFS=$(_git for-each-ref --format='%(objectname) %(refname)' refs/remotes/origin)
    local b o behind=()
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        o=$(printf '%s\n' "$ORIGIN_REFS" | awk -v r="refs/remotes/origin/$b" '$2 == r { print $1 }')
        [[ -n "$o" ]] || continue
        _git merge-base --is-ancestor "$o" "refs/heads/$b" || behind+=("$b")
    done < <(_git for-each-ref --format='%(refname:short)' refs/heads)
    (( ${#behind[@]} )) || return 0
    local x
    for x in "${behind[@]}"; do warn "  ${x}: origin/${x} has commits ${x} does not"; done
    error_exit "Refusing --push: it would erase those commits from origin. Pull first (each branch above), then re-run — nothing changed."
}

_backup() {
    mkdir -p "$BACKUP_DIR"
    local name ts bundle
    name=$(basename "$(cd "$REPO" && pwd)")
    ts=$(date +%Y%m%d-%H%M%S)
    bundle="${BACKUP_DIR}/${name}-${ts}.bundle"
    _git bundle create "$bundle" --all >&2 || error_exit "Backup failed — nothing changed."
    BUNDLE="$bundle"
    success "Backup: $bundle (restore: git clone $bundle)"
}

_rewrite() {
    # origin's shas (the leases) were taken by _check_push_safe, before this:
    # both engines destroy them - filter-branch rewrites refs/remotes/origin/*
    # too, and filter-repo deletes the remotes outright.
    #
    # Snapshotted here, before the rewrite: the branches that exist now are
    # the only ones ever pushed, and the messages are what the result is
    # checked against.
    HEADS_BEFORE=$(_git for-each-ref --format='%(objectname) %(refname)' refs/heads)
    _messages "$WORK/before" --branches --tags
    local commits_before; commits_before=$(_git rev-list --count --branches --tags)

    case "$ENGINE" in
        filter-branch) _rewrite_filter_branch ;;
        filter-repo)   _rewrite_filter_repo ;;
        *)             error_exit "No rewrite engine selected — _need_engine should have caught this." ;;
    esac

    # filter-repo turns refs/remotes/origin/<b> into refs/heads/<b> where no
    # local <b> exists. Those are remote-only branches, which this tool leaves
    # alone and filter-branch never creates: dropped, so neither engine leaves
    # one behind (Kamino item 171). origin and the backup have the originals.
    local r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        printf '%s\n' "$HEADS_BEFORE" | awk -v r="$r" '$2 == r { f = 1 } END { exit !f }' && continue
        _git update-ref -d "$r"
        info "dropped ${r#refs/heads/}: filter-repo made it from origin's branch; remote-only branches are left alone"
    done < <(_git for-each-ref --format='%(refname)' refs/heads)

    _git for-each-ref --format='%(refname)' refs/original/ 2>/dev/null | while read -r r; do _git update-ref -d "$r"; done
    _git reflog expire --expire=now --all 2>/dev/null || true
    _git gc --prune=now --quiet 2>/dev/null || true

    _verify_rewrite "$commits_before"
}

# _verify_rewrite N — the rewritten branches and tags hold N commits, no line
# that matches, no line that was not there, and every line that is gone
# matched (blank lines aside: the engines differ on trailing ones). The same
# grep and files as the report, so what was shown is what was rewritten; if
# not, stop before any push.
_verify_rewrite() {
    local commits_after problem=""
    commits_after=$(_git rev-list --count --branches --tags)
    _messages "$WORK/after" --branches --tags
    if [[ "$commits_after" != "$1" ]]; then
        problem="the branches and tags held $1 commits and now hold ${commits_after}"
    elif [[ -n "$(_grep_lines "$WORK/after")" ]]; then
        problem="lines matching /$PATTERN/ are still there"
    else
        { "$GREP" -v -x -E -e '[[:space:]]*' "$WORK/before" || true; } | LC_ALL=C sort > "$WORK/before.s"
        { "$GREP" -v -x -E -e '[[:space:]]*' "$WORK/after"  || true; } | LC_ALL=C sort > "$WORK/after.s"
        LC_ALL=C comm -23 "$WORK/before.s" "$WORK/after.s" > "$WORK/removed"
        if [[ -n "$(LC_ALL=C comm -13 "$WORK/before.s" "$WORK/after.s")" ]]; then
            problem="lines that were never there appeared"
        elif [[ -n "$("$GREP" -v -i -E -e "$PATTERN" "$WORK/removed" || true)" ]]; then
            problem="lines that do not match /$PATTERN/ were removed"
        fi
    fi
    [[ -n "$problem" ]] || return 0
    error_exit "The rewrite does not match the report: ${problem}. NOTHING was pushed. Restore this repository from the backup: git clone ${BUNDLE}"
}

_rewrite_filter_branch() {
    local helper esc; helper=$(mktemp)
    # The report's own grep, by path (single-quote-safe); the pattern comes
    # through the environment, not the filter's source.
    esc=$(printf '%s' "$GREP" | sed "s/'/'\\\\''/g")
    cat > "$helper" <<EOF
#!/usr/bin/env bash
export PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin
msg="\$(cat)"
msg="\$(printf '%s\n' "\$msg" | '${esc}' -v -i -E -e "\$MT_PATTERN" || true)"
printf '%s\n' "\$msg"
EOF
    MT_PATTERN="$PATTERN" FILTER_BRANCH_SQUELCH_WARNING=1 _git filter-branch -f --msg-filter "bash '$helper'" --tag-name-filter cat -- --all >&2
    local rc=$?
    rm -f "$helper"
    [[ $rc -eq 0 ]] || error_exit "filter-branch failed — nothing pushed."
}

_rewrite_filter_repo() {
    # filter-repo DELETES THE REMOTES. Measured on a clone of the backup
    # bundle: afterwards `git remote` is empty and refs/remotes holds nothing.
    # That is deliberate upstream — it expects to run in a fresh clone you
    # then push from on purpose — but this tool pushes back to the remote it
    # just rewrote, so the URLs are snapshotted and put back.
    local remotes_snapshot
    remotes_snapshot="$(_git remote -v | awk '$3=="(push)" {print $1"\t"$2}')"

    # --force because the repository is not a fresh clone, and because
    # filter-repo leaves .git/filter-repo/already_ran behind, which blocks a
    # second run without it.
    #
    # The pattern reaches Python through the ENVIRONMENT rather than being
    # interpolated into the callback source: it is user-supplied, and a
    # --pattern containing a quote would otherwise be executable code.
    #
    # grep -iE (the report) and Python's re are not the same dialect:
    # _check_dialects refused a pattern they read differently on this
    # history, and _verify_rewrite checks the result before any push.
    MT_PATTERN="$PATTERN" _git filter-repo --force --message-callback '
import os, re
_rx = re.compile(os.environ["MT_PATTERN"].encode(), re.IGNORECASE)
return b"\n".join(l for l in message.split(b"\n") if not _rx.search(l))
' >&2 || error_exit "filter-repo failed — nothing pushed."

    local name url
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" ]] || continue
        _git remote get-url "$name" &>/dev/null || {
            _git remote add "$name" "$url"
            info "restored remote '${name}' (filter-repo removes them)"
        }
    done <<< "$remotes_snapshot"
}

_force_push() {
    # Only the branches that existed before the rewrite (Kamino item 171).
    local ref b lease
    while read -r _ ref; do
        [[ -z "$ref" ]] && continue
        b="${ref#refs/heads/}"
        lease=$(printf '%s\n' "$ORIGIN_REFS" | awk -v r="refs/remotes/origin/$b" '$2 == r { print $1 }')
        [[ -n "$lease" ]] || { info "skip $b (no origin branch)"; continue; }
        if _git push --force-with-lease="$ref:$lease" origin "$ref:$ref" >&2; then success "force-pushed $b"; else warn "push failed: $b (remote moved? fetch, re-run)"; fi
    done <<< "$HEADS_BEFORE"
    if _git push --force origin --tags >&2; then success "force-pushed tags"; else warn "push failed: tags"; fi
    warn "GitHub keeps merged-PR commits via refs/pull/* — those pages still show old commits; the Contributors graph clears on recompute."
}

# _rewrite_engine — which history-rewriting tool this machine actually has.
#
# 'git filter-branch' was deprecated for years and is GONE from git 2.55: not
# in the exec-path, not a subcommand. This tool called it anyway, so on a
# current git it enumerated the commits, wrote a backup bundle, and then
# printed git's own "'filter-branch' is not a git command" — after announcing
# success at the backup, which reads like the rewrite happened.
#
# filter-repo is the upstream replacement and is preferred where both exist.
_rewrite_engine() {
    if git filter-repo --version &>/dev/null; then
        printf 'filter-repo'; return 0
    fi
    # Captured, then matched — NOT piped into grep. `git filter-branch -h`
    # exits non-zero even where the builtin exists, and under 'set -o pipefail'
    # (which this script sets) the pipeline then reports failure however grep
    # answered. So `! git ... | grep -q` was true in both cases and this
    # function claimed filter-branch on a git that has none — which is how the
    # missing-engine guard ended up selecting the missing engine.
    local out
    out="$(git filter-branch -h 2>&1 || true)"
    case "$out" in
        *"is not a git command"*) return 1 ;;
        *) printf 'filter-branch'; return 0 ;;
    esac
}

_preflight() {
    _git rev-parse --is-inside-work-tree &>/dev/null || error_exit "Not a git repository: $REPO"
    [[ "$(_git rev-parse --is-shallow-repository)" != true ]] || error_exit "Shallow clone in $REPO — rewriting would produce broken history. Run: git fetch --unshallow (or re-clone without --depth)."
    [[ -z "$(_git status --porcelain)" ]] || error_exit "Working tree not clean in $REPO — commit/stash first."
}

# _need_engine — stop here if this machine cannot rewrite history.
#
# Called after _report and before the backup: the run cannot succeed without
# an engine, and discovering that after writing a bundle and reporting it is
# how a failure gets mistaken for a success. Not part of _preflight, because a
# dry run must still list what matches, and a repo with nothing to scrub has
# no use for an engine at all.
_need_engine() {
    ENGINE="$(_rewrite_engine)" || {
        warn "No history-rewriting tool available."
        warn "  'git filter-branch' was removed in git 2.55 (this host has $(git --version | awk '{print $3}'))"
        warn "  and 'git filter-repo' is not installed."
        warn ""
        warn "  Install it (one Python file, into ${BIN_DIR}, no root):"
        warn "    $(basename "$0") --setup"
        printf '%s[error]%s %s\n' "$C_R" "$C_N" "Nothing was changed." >&2
        exit "$EXIT_NO_ENGINE"
    }
    info "Rewrite engine: ${ENGINE}"
}

_sha256() {
    if command -v sha256sum &>/dev/null; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# _setup — install the pinned git-filter-repo into $BIN_DIR.
_setup() {
    if git filter-repo --version &>/dev/null; then
        success "git filter-repo is already installed: $(command -v git-filter-repo)"
        return 0
    fi
    command -v python3 &>/dev/null || error_exit "git filter-repo needs python3, which is not installed."
    command -v curl &>/dev/null    || error_exit "curl is needed to download git filter-repo."
    mkdir -p "$BIN_DIR" || error_exit "Cannot create ${BIN_DIR}."
    local tmp; tmp="$(mktemp "${BIN_DIR}/.git-filter-repo.XXXXXX")"
    info "Downloading git filter-repo ${FILTER_REPO_VERSION}…"
    curl -fsSL "$FILTER_REPO_URL" -o "$tmp" || { rm -f "$tmp"; error_exit "Download failed: ${FILTER_REPO_URL}"; }
    local got; got="$(_sha256 "$tmp")"
    if [[ "$got" != "$FILTER_REPO_SHA256" ]]; then
        rm -f "$tmp"
        error_exit "Checksum mismatch for git filter-repo (got ${got}) — not installed."
    fi
    chmod 755 "$tmp" && mv -f "$tmp" "${BIN_DIR}/git-filter-repo"
    git filter-repo --version &>/dev/null || error_exit "git filter-repo was installed to ${BIN_DIR} but does not run (python3 too old?)."
    success "git filter-repo ${FILTER_REPO_VERSION} installed to ${BIN_DIR}/git-filter-repo"
    case ":${USER_PATH}:" in
        *":${BIN_DIR}:"*) ;;
        *) info "mind-trick finds it there on its own; to run 'git filter-repo' yourself, add ${BIN_DIR} to your PATH." ;;
    esac
}

main() {
    while [[ $# -gt 0 ]]; do case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --pattern) PATTERN="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --push) PUSH=true; shift ;;
        --setup) _setup; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; error_exit "unknown flag: $1" ;;
    esac; done
    REPO="${REPO/#\~/$HOME}"

    _preflight
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    [[ "$PUSH" != true ]] || _fetch_origin
    _report || exit 0
    _need_engine
    _check_dialects
    [[ "$PUSH" != true ]] || _check_push_safe
    if [[ "$APPLY" != true ]]; then
        info "Dry run — re-run with --apply to rewrite (and --push to force-push)."
        exit 0
    fi
    _backup
    _rewrite
    success "History cleaned locally."
    if [[ "$PUSH" == true ]]; then _force_push
    else info "Not pushed. --apply --push together first checks that origin has nothing you lack; by hand, only if you pulled before --apply: cd $REPO && git push --force-with-lease origin <branch>"; fi
}

main "$@"
