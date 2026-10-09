#!/usr/bin/env bash
# mind-trick: the scrub itself, end to end, against a synthetic repo and a
# file:// origin. No network, and nothing here touches a real repository.
#
# This tool rewrites published history and force-pushes it, so the properties
# asserted are the ones that make that acceptable: the trailers go, nothing
# else changes, no commits are lost, a moved remote is refused rather than
# overwritten, and a missing engine stops the run before the backup.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MT="${MIND_TRICK:-${TEST_DIR}/../mind-trick.sh}"
[ -f "$MT" ] || { echo "mind-trick.sh not found at $MT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# Keep the tool's backups out of the real cache.
export XDG_CACHE_HOME="$T/cache"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
trailers() { git -C "$1" log "${2:-master}" --format='%(trailers:key=Co-Authored-By)' | grep -c . || true; }

# fixture <dir> — a repo with three trailer commits and three without, plus a
# file:// origin it has already been pushed to.
fixture() {
    local w="$1"
    git init -q -b master "$w"
    for i in 1 2 3; do
        echo "line $i" >> "$w/file.txt"
        git -C "$w" add file.txt
        if [ $((i % 2)) -eq 1 ]; then
            git -C "$w" commit -q -m "change $i" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
        else
            git -C "$w" commit -q -m "change $i" -m "Reviewed-by: someone"
        fi
    done
    echo more >> "$w/file.txt"; git -C "$w" add file.txt
    git -C "$w" commit -q -m "last change" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
    git init -q --bare "${w}-origin.git"
    git -C "$w" remote add origin "${w}-origin.git"
    git -C "$w" push -q --all origin
    git -C "$w" fetch -q origin
}

echo "## 1. a dry run reports and changes nothing"
fixture "$T/a"
before_sha="$(git -C "$T/a" rev-parse master)"
out="$(bash "$MT" --repo "$T/a" 2>&1)"
check "it reports the matching commits"   bash -c "printf '%s' \"\$1\" | grep -q '3 commit(s) contain'" _ "$out"
check "it names the engine"               bash -c "printf '%s' \"\$1\" | grep -q 'Rewrite engine:'" _ "$out"
check "nothing was rewritten"             [ "$(git -C "$T/a" rev-parse master)" = "$before_sha" ]
check "no backup was written"             bash -c "[ ! -d '$T/cache/mind-trick' ] || [ -z \"\$(ls -A '$T/cache/mind-trick')\" ]"

echo "## 2. --apply --push removes them, locally and on the remote"
fixture "$T/b"
tree_before="$(git -C "$T/b" rev-parse 'master^{tree}')"
count_before="$(git -C "$T/b" rev-list --count master)"
bash "$MT" --repo "$T/b" --apply --push >/dev/null 2>&1
check "local trailers are gone"            [ "$(trailers "$T/b")" = 0 ]
check "remote trailers are gone"           [ "$(trailers "$T/b-origin.git")" = 0 ]
check "file content is untouched"          [ "$(git -C "$T/b" rev-parse 'master^{tree}')" = "$tree_before" ]
check "no commits were lost"               [ "$(git -C "$T/b" rev-list --count master)" = "$count_before" ]
check "the other trailer survived"         bash -c "git -C '$T/b' log --format=%B | grep -q 'Reviewed-by: someone'"
check "the remote was restored"            bash -c "git -C '$T/b' remote | grep -qx origin"
check "a backup bundle exists"             bash -c "ls '$T/cache/mind-trick'/*.bundle >/dev/null 2>&1"
check "the backup still has the trailers"  bash -c '
    b=$(ls "$1"/cache/mind-trick/*.bundle | head -1); d=$(mktemp -d)
    git clone -q "$b" "$d/r" && [ "$(git -C "$d/r" log --format="%(trailers:key=Co-Authored-By)" | grep -c .)" = 3 ]' _ "$T"

echo "## 3. a remote that moved is refused, not overwritten"
fixture "$T/c"
git clone -q "$T/c-origin.git" "$T/c-other"
git -C "$T/c-other" commit -q --allow-empty -m "a teammate pushed this"
git -C "$T/c-other" push -q origin master
bash "$MT" --repo "$T/c" --apply --push >/dev/null 2>&1
check "the teammate's commit survived"     bash -c "git -C '$T/c-origin.git' log -1 --format=%s master | grep -q 'a teammate pushed this'"
check "the remote still has its trailers"  [ "$(trailers "$T/c-origin.git")" = 3 ]

echo "## 4. no engine: refuse before the backup"
fixture "$T/d"
sha="$(git -C "$T/d" rev-parse master)"
out="$(PATH=/usr/bin:/bin bash "$MT" --repo "$T/d" --apply --push 2>&1)"
check "it says there is no tool"           bash -c "printf '%s' \"\$1\" | grep -q 'No history-rewriting tool'" _ "$out"
check "it says nothing was changed"        bash -c "printf '%s' \"\$1\" | grep -q 'Nothing was changed'" _ "$out"
check "master is untouched"                [ "$(git -C "$T/d" rev-parse master)" = "$sha" ]
check "and no backup was written for it"   bash -c "! ls '$T/cache/mind-trick'/*-d-*.bundle >/dev/null 2>&1"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
