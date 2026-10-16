#!/usr/bin/env bash
# mind-trick: the scrub itself, end to end, against a synthetic repo and a
# file:// origin. No network, and nothing here touches a real repository.
#
# This tool rewrites published history and force-pushes it, so the properties
# asserted are the ones that make that acceptable: the trailers go, nothing
# else changes, no commits are lost, a moved remote is refused rather than
# overwritten, and a missing engine stops the run before the backup.
# shellcheck disable=SC2016
# One check below passes $T to `bash -c` as a positional argument and reads it
# as $1 inside single quotes, which is the safe way round: a captured path
# interpolated into a command line is not. A directive covers only the next
# COMMAND, so this is file-scoped and sits above the first one.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MT="${MIND_TRICK:-${TEST_DIR}/../mind-trick.sh}"
[ -f "$MT" ] || { echo "mind-trick.sh not found at $MT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# Keep the tool's backups out of the real cache.
export XDG_CACHE_HOME="$T/cache"
# And --setup's install dir out of ~/.local/bin, which the engine searches: a
# filter-repo the user installed there would defeat the "no engine" cases.
export MIND_TRICK_BIN_DIR="$T/bin"

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

echo "## 5. no engine: a dry run still reports, a clean repo still passes"
out="$(PATH=/usr/bin:/bin bash "$MT" --repo "$T/d" 2>&1)"; rc=$?
check "the matches are still listed"       bash -c "printf '%s' \"\$1\" | grep -q '3 commit(s) contain'" _ "$out"
check "then it says there is no tool"      bash -c "printf '%s' \"\$1\" | grep -q 'No history-rewriting tool'" _ "$out"
check "and exits 3, so a caller can offer --setup" [ "$rc" -eq 3 ]
git init -q -b master "$T/e"
git -C "$T/e" commit -q --allow-empty -m "nothing to scrub"
out="$(PATH=/usr/bin:/bin bash "$MT" --repo "$T/e" 2>&1)"; rc=$?
check "a clean repo says nothing to do"    bash -c "printf '%s' \"\$1\" | grep -q 'nothing to do'" _ "$out"
check "without asking for a tool"          bash -c "! printf '%s' \"\$1\" | grep -q 'No history-rewriting tool'" _ "$out"
check "and succeeds"                       [ "$rc" -eq 0 ]

echo "## 6. --setup refuses a download that fails the checksum"
printf '#!/usr/bin/env python3\nprint("not filter-repo")\n' > "$T/evil"
out="$(PATH=/usr/bin:/bin MIND_TRICK_FILTER_REPO_URL="file://$T/evil" bash "$MT" --setup 2>&1)"; rc=$?
check "it fails"                           [ "$rc" -ne 0 ]
check "it names the checksum"              bash -c "printf '%s' \"\$1\" | grep -q 'Checksum mismatch'" _ "$out"
check "nothing was installed"              bash -c "[ -z \"\$(ls -A '$T/bin' 2>/dev/null)\" ]"

echo "## 7. --setup leaves an installed filter-repo alone"
mkdir -p "$T/have"
printf '#!/bin/sh\necho a40bce548d2c\n' > "$T/have/git-filter-repo"; chmod +x "$T/have/git-filter-repo"
out="$(PATH="$T/have:/usr/bin:/bin" MIND_TRICK_FILTER_REPO_URL="file://$T/evil" bash "$MT" --setup 2>&1)"; rc=$?
check "it succeeds without downloading"    [ "$rc" -eq 0 ]
check "it says it is already installed"    bash -c "printf '%s' \"\$1\" | grep -q 'already installed'" _ "$out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
