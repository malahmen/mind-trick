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
# Dependency: git. Run --help for the flags.
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
ORIGIN_REFS=""                     # pre-rewrite '<sha> refs/remotes/origin/<b>' lines, for --force-with-lease
ENGINE=""                          # which rewriting tool _preflight found

usage() {
    cat >&2 <<'EOF'
mind-trick — scrub commit-message trailers from git history

USAGE
  mind-trick.sh [--repo DIR] [--pattern REGEX] [--apply] [--push]

FLAGS
  --repo DIR       repository to operate on (default: current directory)
  --pattern REGEX  message lines to remove, grep -iE (default '^Co-Authored-By: Claude')
  --apply          actually rewrite history (default: dry-run only)
  --push           force-push the rewritten branches and tags after --apply
  -h, --help

Safe by default: without --apply it only reports. --apply always writes a git
bundle backup first. It cannot remove commits GitHub keeps in refs/pull/*
(merged-PR pages) — only branch history + the Contributors graph clear.

Rewrites every local ref (branches, tags, origin/* tracking refs). --push sends
the local branches that exist on origin, plus tags; other remotes and remote-only
branches are untouched. Signatures on rewritten commits are dropped. Refuses a
dirty tree (untracked files count) and shallow clones.
EOF
}

_git() { git -C "$REPO" "$@"; }
_matching_commits() { _git log --all -i -E --grep="$PATTERN" --format='%H'; }

_report() {
    local n; n=$(_matching_commits | wc -l | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then success "No commits match /$PATTERN/ — nothing to do."; return 1; fi
    warn "${n} commit(s) contain a line matching /$PATTERN/:"
    _git log --all -n 20 -i -E --grep="$PATTERN" --format='  %h %an | %s' >&2   # -n, not | head: no SIGPIPE under pipefail
    (( n > 20 )) && info "  … and $((n - 20)) more"
    info "Affected branches:"
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        [[ -n "$(_git log "$b" -n 1 -i -E --grep="$PATTERN" --format='%H')" ]] && printf '    %s\n' "$b" >&2
    done < <(_git for-each-ref --format='%(refname:short)' refs/heads)
    return 0
}

_backup() {
    mkdir -p "$BACKUP_DIR"
    local name ts bundle
    name=$(basename "$(cd "$REPO" && pwd)")
    ts=$(date +%Y%m%d-%H%M%S)
    bundle="${BACKUP_DIR}/${name}-${ts}.bundle"
    _git bundle create "$bundle" --all >&2 && success "Backup: $bundle (restore: git clone $bundle)"
}

_rewrite() {
    # filter-branch rewrites refs/remotes/origin/* too, so snapshot what origin really has first.
    ORIGIN_REFS=$(_git for-each-ref --format='%(objectname) %(refname)' refs/remotes/origin)
    local helper esc; helper=$(mktemp)
    esc=$(printf '%s' "$PATTERN" | sed "s/'/'\\\\''/g")   # single-quote-safe
    cat > "$helper" <<EOF
#!/usr/bin/env bash
export PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin
msg="\$(cat)"
msg="\$(printf '%s\n' "\$msg" | grep -v -iE '${esc}' || true)"
printf '%s\n' "\$msg"
EOF
    case "$ENGINE" in
        filter-branch)
            FILTER_BRANCH_SQUELCH_WARNING=1 _git filter-branch -f --msg-filter "bash '$helper'" --tag-name-filter cat -- --all >&2
            ;;
        filter-repo)
            # Deliberately not implemented yet rather than quietly falling
            # back: filter-repo's message rewriting is a --message-callback in
            # Python, not a --msg-filter shell command, so it is a different
            # code path and not one to write untested against published
            # history. See the TODO in kamino (R9).
            rm -f "$helper"
            error_exit "filter-repo is installed but this tool has not been ported to it yet. Nothing was changed."
            ;;
        *)  rm -f "$helper"
            error_exit "No rewrite engine selected — _preflight should have caught this."
            ;;
    esac
    rm -f "$helper"
    _git for-each-ref --format='%(refname)' refs/original/ 2>/dev/null | while read -r r; do _git update-ref -d "$r"; done
    _git reflog expire --expire=now --all 2>/dev/null || true
    _git gc --prune=now --quiet 2>/dev/null || true
}

_force_push() {
    local b lease
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        lease=$(printf '%s\n' "$ORIGIN_REFS" | awk -v r="refs/remotes/origin/$b" '$2 == r { print $1 }')
        [[ -n "$lease" ]] || { info "skip $b (no origin branch)"; continue; }
        if _git push --force-with-lease="refs/heads/$b:$lease" origin "$b" >&2; then success "force-pushed $b"; else warn "push failed: $b (remote moved? fetch, re-run)"; fi
    done < <(_git for-each-ref --format='%(refname:short)' refs/heads)
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

    # Checked HERE, before the backup and before anything is announced: the
    # run cannot succeed without an engine, and discovering that after writing
    # a bundle and reporting it is how a failure gets mistaken for a success.
    ENGINE="$(_rewrite_engine)" || {
        warn "No history-rewriting tool available."
        warn "  'git filter-branch' was removed in git 2.55 (this host has $(git --version | awk '{print $3}'))"
        warn "  and 'git filter-repo' is not installed."
        warn ""
        warn "  Install filter-repo, which is one Python file and needs no root:"
        warn "    pip install --user git-filter-repo"
        warn "  or drop it in by hand:"
        warn "    curl -fsSL https://raw.githubusercontent.com/newren/git-filter-repo/main/git-filter-repo \\"
        warn "      -o ~/.local/bin/git-filter-repo && chmod +x ~/.local/bin/git-filter-repo"
        error_exit "Nothing was changed."
    }
    info "Rewrite engine: ${ENGINE}"
}

main() {
    while [[ $# -gt 0 ]]; do case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --pattern) PATTERN="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --push) PUSH=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; error_exit "unknown flag: $1" ;;
    esac; done
    REPO="${REPO/#\~/$HOME}"

    _preflight
    _report || exit 0
    if [[ "$APPLY" != true ]]; then
        info "Dry run — re-run with --apply to rewrite (and --push to force-push)."
        exit 0
    fi
    _backup
    _rewrite
    success "History cleaned locally."
    if [[ "$PUSH" == true ]]; then _force_push
    else info "Not pushed. Use --push, or: cd $REPO && git push --force origin <branch> --tags"; fi
}

main "$@"
