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

usage() {
    cat >&2 <<'EOF'
mind-trick — scrub commit-message trailers from git history

USAGE
  mind-trick.sh [--repo DIR] [--pattern REGEX] [--apply] [--push]

FLAGS
  --repo DIR       repository to operate on (default: current directory)
  --pattern REGEX  message lines to remove, grep -iE (default '^Co-Authored-By: Claude')
  --apply          actually rewrite history (default: dry-run only)
  --push           force-push the rewritten branches after --apply
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
    _git log --all -i -E --grep="$PATTERN" --format='  %h %an | %s' | head -20 >&2
    info "Affected branches:"
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        [[ -n "$(_git log "$b" -i -E --grep="$PATTERN" --format='%H' | head -1)" ]] && printf '    %s\n' "$b" >&2
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
    local helper esc; helper=$(mktemp)
    esc=$(printf '%s' "$PATTERN" | sed "s/'/'\\\\''/g")   # single-quote-safe
    cat > "$helper" <<EOF
#!/usr/bin/env bash
export PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin
msg="\$(cat)"
msg="\$(printf '%s\n' "\$msg" | grep -v -iE '${esc}' || true)"
printf '%s\n' "\$msg"
EOF
    FILTER_BRANCH_SQUELCH_WARNING=1 _git filter-branch -f --msg-filter "bash '$helper'" -- --all >&2
    rm -f "$helper"
    _git for-each-ref --format='%(refname)' refs/original/ 2>/dev/null | while read -r r; do _git update-ref -d "$r"; done
    _git reflog expire --expire=now --all 2>/dev/null || true
    _git gc --prune=now --quiet 2>/dev/null || true
}

_force_push() {
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        _git show-ref --verify --quiet "refs/remotes/origin/$b" || { info "skip $b (no origin branch)"; continue; }
        if _git push --force origin "$b" >&2; then success "force-pushed $b"; else warn "push failed: $b"; fi
    done < <(_git for-each-ref --format='%(refname:short)' refs/heads)
    warn "GitHub keeps merged-PR commits via refs/pull/* — those pages still show old commits; the Contributors graph clears on recompute."
}

_preflight() {
    _git rev-parse --is-inside-work-tree &>/dev/null || error_exit "Not a git repository: $REPO"
    [[ -z "$(_git status --porcelain)" ]] || error_exit "Working tree not clean in $REPO — commit/stash first."
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
    else info "Not pushed. Use --push, or: cd $REPO && git push --force origin <branch>"; fi
}

main "$@"
