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

# A PATH with no rewrite tool on it, whatever this git is. Trimming PATH to
# /usr/bin:/bin hides a filter-repo in ~/.local/bin, but not filter-branch:
# that is part of git itself, and a git older than 2.55 (CI runners) still has
# it. So the first git on this PATH refuses both and hands the rest to git.
REAL_GIT="$(command -v git)"
mkdir -p "$T/no-engine"
cat > "$T/no-engine/git" <<NOGIT
#!/bin/sh
case "\$1" in
    filter-branch|filter-repo) echo "git: '\$1' is not a git command. See 'git --help'." >&2; exit 1 ;;
esac
exec "$REAL_GIT" "\$@"
NOGIT
chmod +x "$T/no-engine/git"
NO_ENGINE_PATH="$T/no-engine:/usr/bin:/bin"

# The two engines rewrite differently (filter-repo deletes the remotes and
# turns origin's branches into local ones; filter-branch rewrites the
# tracking refs), so every case that rewrites runs once per engine this
# machine has. filter-repo is preferred where both exist; a git that refuses
# only filter-repo forces filter-branch.
mkdir -p "$T/only-fb"
cat > "$T/only-fb/git" <<FBGIT
#!/bin/sh
[ "\$1" = filter-repo ] && { echo "git: 'filter-repo' is not a git command. See 'git --help'." >&2; exit 1; }
exec "$REAL_GIT" "\$@"
FBGIT
chmod +x "$T/only-fb/git"
ENGINES=()
git filter-repo --version >/dev/null 2>&1 && ENGINES+=(filter-repo)
case "$(PATH="$T/only-fb:$PATH" git filter-branch -h 2>&1)" in
    *"is not a git command"*) ;;
    *) ENGINES+=(filter-branch) ;;
esac
for e in filter-repo filter-branch; do
    case " ${ENGINES[*]} " in *" $e "*) ;; *) echo "   skip - no $e here: its cases do not run" ;; esac
done
# mt ENGINE ARGS… — run the tool with that engine; output in $out, status in $rc.
mt() {
    local e="$1"; shift
    if [ "$e" = filter-branch ]; then out="$(PATH="$T/only-fb:$PATH" bash "$MT" "$@" 2>&1)"; rc=$?
    else out="$(bash "$MT" "$@" 2>&1)"; rc=$?; fi
}
has() { printf '%s' "$out" | grep -q -e "$1"; }

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

for E in "${ENGINES[@]}"; do
echo "## 2. [$E] --apply --push removes them, locally and on the remote"
fixture "$T/b-$E"
tree_before="$(git -C "$T/b-$E" rev-parse 'master^{tree}')"
count_before="$(git -C "$T/b-$E" rev-list --count master)"
mt "$E" --repo "$T/b-$E" --apply --push
check "it ran with $E"                     has "Rewrite engine: $E"
check "local trailers are gone"            [ "$(trailers "$T/b-$E")" = 0 ]
check "remote trailers are gone"           [ "$(trailers "$T/b-$E-origin.git")" = 0 ]
check "file content is untouched"          [ "$(git -C "$T/b-$E" rev-parse 'master^{tree}')" = "$tree_before" ]
check "no commits were lost"               [ "$(git -C "$T/b-$E" rev-list --count master)" = "$count_before" ]
check "the other trailer survived"         bash -c "git -C '$T/b-$E' log --format=%B | grep -q 'Reviewed-by: someone'"
check "the remote was restored"            bash -c "git -C '$T/b-$E' remote | grep -qx origin"
check "a backup bundle exists"             bash -c "ls '$T/cache/mind-trick'/b-$E-*.bundle >/dev/null 2>&1"
check "the backup still has the trailers"  bash -c '
    b=$(ls "$1"/cache/mind-trick/b-"$2"-*.bundle | head -1); d=$(mktemp -d)
    git clone -q "$b" "$d/r" && [ "$(git -C "$d/r" log --format="%(trailers:key=Co-Authored-By)" | grep -c .)" = 3 ]' _ "$T" "$E"

echo "## 3. [$E] a remote that moved after the fetch is refused, not overwritten"
# The teammate pushes between mind-trick's own fetch and its push: the git
# below fires once, on the first push, so only the lease can stop it.
fixture "$T/c-$E"
git clone -q "$T/c-$E-origin.git" "$T/c-$E-other"
git -C "$T/c-$E-other" commit -q --allow-empty -m "a teammate pushed this"
mkdir -p "$T/c-$E-race"
cat > "$T/c-$E-race/git" <<RACE
#!/bin/sh
[ "\$1" = filter-repo ] && [ "$E" = filter-branch ] && { echo "git: 'filter-repo' is not a git command." >&2; exit 1; }
if [ "\$3" = push ] && [ ! -e "$T/c-$E-race/done" ]; then
    : > "$T/c-$E-race/done"; "$REAL_GIT" -C "$T/c-$E-other" push -q origin master
fi
exec "$REAL_GIT" "\$@"
RACE
chmod +x "$T/c-$E-race/git"
out="$(PATH="$T/c-$E-race:$PATH" bash "$MT" --repo "$T/c-$E" --apply --push 2>&1)"
check "it ran with $E"                     has "Rewrite engine: $E"
check "the race fired"                     [ -e "$T/c-$E-race/done" ]
check "the teammate's commit survived"     bash -c "git -C '$T/c-$E-origin.git' log -1 --format=%s master | grep -q 'a teammate pushed this'"
check "the remote still has its trailers"  [ "$(trailers "$T/c-$E-origin.git")" = 3 ]

echo "## 9. [$E] a branch behind origin: refused before anything changes (Kamino 165)"
# A teammate pushed B; this clone has only A on main. Fetched-not-pulled, and
# not fetched at all: both used to end with origin's main replaced by A'.
for how in fetched unfetched; do
    w="$T/i-$E-$how"; git init -q --bare -b master "$w-origin.git"
    git clone -q "$w-origin.git" "$w-mate" 2>/dev/null
    echo A > "$w-mate/f"; git -C "$w-mate" add f
    git -C "$w-mate" commit -q -m A -m "Co-Authored-By: Claude <noreply@anthropic.com>"
    git -C "$w-mate" push -q origin master
    git clone -q "$w-origin.git" "$w"
    echo B >> "$w-mate/f"; git -C "$w-mate" commit -q -am B -m "Co-Authored-By: Claude <noreply@anthropic.com>"
    git -C "$w-mate" push -q origin master
    [ "$how" = fetched ] && git -C "$w" fetch -q origin
    remote_before="$(git -C "$w-origin.git" rev-parse master)"; local_before="$(git -C "$w" rev-parse master)"
    mt "$E" --repo "$w" --apply --push
    check "[$how] it is refused"                 [ "$rc" -ne 0 ]
    check "[$how] it says to pull first"         has "Pull first"
    check "[$how] it names the branch"           has "master: origin/master has commits"
    check "[$how] origin's master is untouched"  [ "$(git -C "$w-origin.git" rev-parse master)" = "$remote_before" ]
    check "[$how] the local branch is untouched" [ "$(git -C "$w" rev-parse master)" = "$local_before" ]
    check "[$how] no backup: nothing started"    bash -c "! ls '$T/cache/mind-trick'/i-$E-$how-*.bundle >/dev/null 2>&1"
done
done

echo "## 4. no engine: refuse before the backup"
fixture "$T/d"
sha="$(git -C "$T/d" rev-parse master)"
out="$(PATH="$NO_ENGINE_PATH" bash "$MT" --repo "$T/d" --apply --push 2>&1)"
check "it says there is no tool"           bash -c "printf '%s' \"\$1\" | grep -q 'No history-rewriting tool'" _ "$out"
check "it says nothing was changed"        bash -c "printf '%s' \"\$1\" | grep -q 'Nothing was changed'" _ "$out"
check "master is untouched"                [ "$(git -C "$T/d" rev-parse master)" = "$sha" ]
check "and no backup was written for it"   bash -c "! ls '$T/cache/mind-trick'/*-d-*.bundle >/dev/null 2>&1"

echo "## 5. no engine: a dry run still reports, a clean repo still passes"
out="$(PATH="$NO_ENGINE_PATH" bash "$MT" --repo "$T/d" 2>&1)"; rc=$?
check "the matches are still listed"       bash -c "printf '%s' \"\$1\" | grep -q '3 commit(s) contain'" _ "$out"
check "then it says there is no tool"      bash -c "printf '%s' \"\$1\" | grep -q 'No history-rewriting tool'" _ "$out"
check "and exits 3, so a caller can offer --setup" [ "$rc" -eq 3 ]
git init -q -b master "$T/e"
git -C "$T/e" commit -q --allow-empty -m "nothing to scrub"
out="$(PATH="$NO_ENGINE_PATH" bash "$MT" --repo "$T/e" 2>&1)"; rc=$?
check "a clean repo says nothing to do"    bash -c "printf '%s' \"\$1\" | grep -q 'nothing to do'" _ "$out"
check "without asking for a tool"          bash -c "! printf '%s' \"\$1\" | grep -q 'No history-rewriting tool'" _ "$out"
check "and succeeds"                       [ "$rc" -eq 0 ]

echo "## 6. --setup refuses a download that fails the checksum"
printf '#!/usr/bin/env python3\nprint("not filter-repo")\n' > "$T/evil"
out="$(PATH="$NO_ENGINE_PATH" MIND_TRICK_FILTER_REPO_URL="file://$T/evil" bash "$MT" --setup 2>&1)"; rc=$?
check "it fails"                           [ "$rc" -ne 0 ]
check "it names the checksum"              bash -c "printf '%s' \"\$1\" | grep -q 'Checksum mismatch'" _ "$out"
check "nothing was installed"              bash -c "[ -z \"\$(ls -A '$T/bin' 2>/dev/null)\" ]"

echo "## 7. --setup leaves an installed filter-repo alone"
mkdir -p "$T/have"
printf '#!/bin/sh\necho a40bce548d2c\n' > "$T/have/git-filter-repo"; chmod +x "$T/have/git-filter-repo"
out="$(PATH="$T/have:/usr/bin:/bin" MIND_TRICK_FILTER_REPO_URL="file://$T/evil" bash "$MT" --setup 2>&1)"; rc=$?
check "it succeeds without downloading"    [ "$rc" -eq 0 ]
check "it says it is already installed"    bash -c "printf '%s' \"\$1\" | grep -q 'already installed'" _ "$out"

echo "## 8. its bin dir is searched last: the user's git runs, filter-repo is still found"
# A git in the bin dir (a wrapper, a shim) must not outrank the user's: that
# git rewrites history and force-pushes.
rm -rf "${T:?}/bin"; mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" >> "%s/shim-git.log"\nexec "%s" "$@"\n' "$T" "$REAL_GIT" > "$T/bin/git"; chmod +x "$T/bin/git"
fixture "$T/f"
out="$(PATH="$(dirname "$REAL_GIT"):/usr/bin:/bin" bash "$MT" --repo "$T/f" 2>&1)"
check "the bin dir's git was never called"  [ ! -e "$T/shim-git.log" ]
rm -f "$T/bin/git"
# What the bin dir is for: a filter-repo there is found without being on PATH.
printf '#!/bin/sh\necho a40bce548d2c\n' > "$T/bin/git-filter-repo"; chmod +x "$T/bin/git-filter-repo"
out="$(PATH="/usr/bin:/bin" MIND_TRICK_FILTER_REPO_URL="file://$T/evil" bash "$MT" --setup 2>&1)"; rc=$?
check "a filter-repo only in the bin dir is still found" bash -c "[ $rc -eq 0 ] && printf '%s' \"\$1\" | grep -q 'already installed'" _ "$out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
