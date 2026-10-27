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
check "it lists those 3 and no other"     bash -c "[ \"\$(printf '%s\n' \"\$1\" | grep -cE '^  [0-9a-f]{7,} t \| ')\" = 3 ] && ! printf '%s' \"\$1\" | grep -q '| change 2\$'" _ "$out"
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

echo "## 10. [$E] a branch only on origin is neither pushed nor left behind (Kamino 171)"
# filter-repo turned origin/feat into a local feat, which --push then scrubbed
# and force-pushed; README and --help promise remote-only branches untouched.
w="$T/j-$E"; fixture "$w"
git clone -q "$w-origin.git" "$w-mate"
git -C "$w-mate" checkout -q -b feat
git -C "$w-mate" commit -q --allow-empty -m "feat work" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git -C "$w-mate" push -q origin feat
git -C "$w" fetch -q origin
feat_before="$(git -C "$w-origin.git" rev-parse feat)"
mt "$E" --repo "$w" --apply --push
check "it succeeds"                          [ "$rc" -eq 0 ]
check "origin's master was scrubbed"         [ "$(trailers "$w-origin.git")" = 0 ]
check "origin's feat is untouched"           [ "$(git -C "$w-origin.git" rev-parse feat)" = "$feat_before" ]
check "no local feat was left behind"        bash -c "! git -C '$w' rev-parse -q --verify refs/heads/feat >/dev/null"

echo "## 11. [$E] what the report shows is what is rewritten (Kamino 171)"
# The report used git's regex, filter-repo Python's re. Whatever this grep
# makes of a pattern, a run either removes exactly what it reported or
# refuses with nothing changed.
w="$T/k-$E"; fixture "$w"
m_before="$(git -C "$w" rev-parse master)"; r_before="$(git -C "$w-origin.git" rev-parse master)"
mt "$E" --repo "$w" --pattern '^Co-Authored-By:[[:space:]]+Claude' --apply --push
if [ "$rc" -eq 0 ]; then
    check "[[:space:]] reported 3 and removed them, locally"  bash -c "printf '%s' \"\$1\" | grep -q '3 commit(s) contain' && [ \"\$(git -C \"\$2\" log --format='%(trailers:key=Co-Authored-By)' master | grep -c .)\" = 0 ]" _ "$out" "$w"
    check "[[:space:]] and on origin"        [ "$(trailers "$w-origin.git")" = 0 ]
else
    check "[[:space:]] refused: says nothing changed" has "nothing changed"
    check "[[:space:]] refused: master untouched"     [ "$(git -C "$w" rev-parse master)" = "$m_before" ]
    check "[[:space:]] refused: origin untouched"     [ "$(git -C "$w-origin.git" rev-parse master)" = "$r_before" ]
fi
check "[[:space:]] never 'cleaned' with matches left" bash -c "! { printf '%s' \"\$1\" | grep -q 'History cleaned' && [ \"\$(git -C \"\$2\" log --format='%(trailers:key=Co-Authored-By)' master | grep -c .)\" != 0 ]; }" _ "$out" "$w"
[ "$E" = filter-repo ] && check "[[:space:]] filter-repo: refused, not half-done" [ "$rc" -ne 0 ]

w="$T/l-$E"; fixture "$w"
git -C "$w" commit -q --allow-empty -m "ref forty-two" -m "Ref: 42"
git -C "$w" commit -q --allow-empty -m "ref dee" -m "Ref: d"
git -C "$w" push -q origin master
m_before="$(git -C "$w" rev-parse master)"
mt "$E" --repo "$w" --pattern '^Ref: \d' --apply --push
for x in "42:forty-two" "d:dee"; do
    v="${x%%:*}"; subj="ref ${x#*:}"
    check "\\d: 'Ref: $v' is kept, or it was reported" bash -c "git -C \"\$2\" log --format=%B master | grep -qx 'Ref: $v' || printf '%s' \"\$1\" | grep -q '| $subj\$'" _ "$out" "$w"
done
[ "$rc" -eq 0 ] || check "\\d refused: master untouched" [ "$(git -C "$w" rev-parse master)" = "$m_before" ]

echo "## 12. [$E] a rewrite that is not what was reported is never pushed (Kamino 171)"
# The last check before a force-push: an engine that also drops a line the
# pattern does not match (Reviewed-by) must stop the run, origin untouched.
w="$T/m-$E"; fixture "$w"; mkdir -p "$w-bad"
cat > "$w-bad/git" <<BAD
#!/bin/sh
[ "\$1" = filter-repo ] && [ "$E" = filter-branch ] && { echo "git: 'filter-repo' is not a git command." >&2; exit 1; }
case "\$3" in
    filter-repo) exec "$REAL_GIT" -C "\$2" filter-repo --force --message-callback '
return b"\\n".join(l for l in message.split(b"\\n") if not l.lower().startswith((b"co-authored-by", b"reviewed-by")))' ;;
    filter-branch) FILTER_BRANCH_SQUELCH_WARNING=1 exec "$REAL_GIT" -C "\$2" filter-branch -f --msg-filter "sed -e '/^Reviewed-by/d' -e '/^Co-Authored-By/d'" --tag-name-filter cat -- --all ;;
esac
exec "$REAL_GIT" "\$@"
BAD
chmod +x "$w-bad/git"
r_before="$(git -C "$w-origin.git" rev-parse master)"
out="$(PATH="$w-bad:$PATH" bash "$MT" --repo "$w" --apply --push 2>&1)"; rc=$?
check "it ran with $E"                       has "Rewrite engine: $E"
check "it fails"                             [ "$rc" -ne 0 ]
check "it names what went wrong"             has "lines that do not match"
check "it says nothing was pushed"           has "NOTHING was pushed"
check "it says how to restore"               has "git clone .*\\.bundle"
check "origin is untouched"                  [ "$(git -C "$w-origin.git" rev-parse master)" = "$r_before" ]

echo "## 13. [$E] matching is case-insensitive, as grep -iE (Kamino 194)"
w="$T/n-$E"; fixture "$w"
git -C "$w" commit -q --allow-empty -m "lower" -m "co-authored-by: CLAUDE <noreply@anthropic.com>"
git -C "$w" push -q origin master
mt "$E" --repo "$w" --apply --push
check "the report counts it"                 has "4 commit(s) contain"
check "it is gone locally"                   bash -c "! git -C '$w' log --format=%B master | grep -qi 'co-authored-by: claude'"
check "and on origin"                        bash -c "! git -C '$w-origin.git' log --format=%B master | grep -qi 'co-authored-by: claude'"

echo "## 14. [$E] a branch origin does not have is scrubbed here, not pushed (Kamino 194)"
w="$T/o-$E"; fixture "$w"
git -C "$w" checkout -q -b wip
git -C "$w" commit -q --allow-empty -m "local work" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git -C "$w" checkout -q master
mt "$E" --repo "$w" --apply --push
check "it says it skips wip"                 has "skip wip (no origin branch)"
check "origin has no wip"                    bash -c "! git -C '$w-origin.git' rev-parse -q --verify refs/heads/wip >/dev/null"
check "the local wip was scrubbed"           [ "$(trailers "$w" wip)" = 0 ]

echo "## 15. [$E] tags: rewritten ones pushed with a lease, no others (Kamino 194)"
# v1 (annotated) and v0 are on origin as here: pushed. mine is local-only:
# not published. theirs is a different tag on origin: not overwritten.
w="$T/q-$E"; fixture "$w"
git -C "$w" tag -a v1 -m "release 1" master~1
git -C "$w" tag v0 master~3
git -C "$w" tag theirs master~2
git -C "$w" push -q origin v1 v0
git clone -q "$w-origin.git" "$w-mate"
git -C "$w-mate" checkout -q --detach
git -C "$w-mate" commit -q --allow-empty -m "their tagged commit"
git -C "$w-mate" tag theirs
git -C "$w-mate" push -q origin theirs
git -C "$w" tag mine master
theirs_before="$(git -C "$w-origin.git" rev-parse refs/tags/theirs)"
v1_before="$(git -C "$w-origin.git" rev-parse refs/tags/v1)"
mt "$E" --repo "$w" --apply --push
check "it succeeds"                          [ "$rc" -eq 0 ]
check "origin's v1 moved"                    [ "$(git -C "$w-origin.git" rev-parse refs/tags/v1)" != "$v1_before" ]
check "origin's v1 is still annotated"       [ "$(git -C "$w-origin.git" cat-file -t refs/tags/v1)" = tag ]
check "origin's v1 and v0 point at scrubbed history" bash -c "[ \"\$(git -C \"\$1\" log --format='%(trailers:key=Co-Authored-By)' v1 v0 | grep -c .)\" = 0 ]" _ "$w-origin.git"
check "origin's v1 is what is here"          [ "$(git -C "$w-origin.git" rev-parse 'v1^{commit}')" = "$(git -C "$w" rev-parse 'v1^{commit}')" ]
check "the local-only tag was not published" bash -c "! git -C '$w-origin.git' rev-parse -q --verify refs/tags/mine >/dev/null"
check "origin's own theirs is untouched"     [ "$(git -C "$w-origin.git" rev-parse refs/tags/theirs)" = "$theirs_before" ]
check "it says so"                           has "skip tag theirs (origin's is a different one"
check "and why mine was not pushed"          has "skip tag mine (not on origin)"

echo "## 15b. [$E] a tag that moved on origin after the listing is refused, not overwritten (Kamino 194)"
# The teammate re-tags v1 between mind-trick's ls-remote and its tag push:
# only the lease can stop it.
w="$T/q2-$E"; fixture "$w"
git -C "$w" tag v1 master~1
git -C "$w" push -q origin v1
git clone -q "$w-origin.git" "$w-mate"
git -C "$w-mate" commit -q --allow-empty -m "their v1"
mkdir -p "$w-race"
cat > "$w-race/git" <<RACE
#!/bin/sh
[ "\$1" = filter-repo ] && [ "$E" = filter-branch ] && { echo "git: 'filter-repo' is not a git command." >&2; exit 1; }
if [ "\$3" = push ] && [ ! -e "$w-race/done" ]; then
    case "\$*" in *refs/tags/v1*)
        : > "$w-race/done"; "$REAL_GIT" -C "$w-mate" tag -f v1 >/dev/null; "$REAL_GIT" -C "$w-mate" push -q -f origin v1 ;;
    esac
fi
exec "$REAL_GIT" "\$@"
RACE
chmod +x "$w-race/git"
out="$(PATH="$w-race:$PATH" bash "$MT" --repo "$w" --apply --push 2>&1)"; rc=$?
check "it ran with $E"                       has "Rewrite engine: $E"
check "the race fired"                       [ -e "$w-race/done" ]
check "origin's v1 is the teammate's"        [ "$(git -C "$w-origin.git" rev-parse v1)" = "$(git -C "$w-mate" rev-parse v1)" ]
check "it says the tag push failed"          has "push failed: tag v1"

echo "## 16. [$E] the old commits are gone from the repository, reflogs too (Kamino 194)"
w="$T/r-$E"; fixture "$w"
old="$(git -C "$w" rev-parse master)"
mt "$E" --repo "$w" --apply
check "it succeeds"                          [ "$rc" -eq 0 ]
check "the pre-rewrite tip is not in the object store" bash -c "! git -C '$w' cat-file -e '$old' 2>/dev/null"
check "no reflog still names it"             bash -c "! git -C '$w' reflog --all --format=%H 2>/dev/null | grep -q '$old'"

if [ "$E" = filter-branch ]; then
echo "## 17. [$E] filter-branch fails: helper removed, 'nothing pushed', origin untouched (Kamino 194)"
# Under set -e the failure ended the script before its own check.
w="$T/s-$E"; fixture "$w"; mkdir -p "$w-fail" "$w-tmp"
cat > "$w-fail/git" <<FAIL
#!/bin/sh
[ "\$1" = filter-repo ] && { echo "git: 'filter-repo' is not a git command." >&2; exit 1; }
[ "\$3" = filter-branch ] && { echo "fatal: simulated filter-branch failure" >&2; exit 1; }
exec "$REAL_GIT" "\$@"
FAIL
chmod +x "$w-fail/git"
m_before="$(git -C "$w" rev-parse master)"; r_before="$(git -C "$w-origin.git" rev-parse master)"
out="$(PATH="$w-fail:$PATH" TMPDIR="$w-tmp" bash "$MT" --repo "$w" --apply --push 2>&1)"; rc=$?
check "it fails"                             [ "$rc" -ne 0 ]
check "it says nothing was pushed"           has "filter-branch failed — nothing pushed"
check "its helper file is gone"              bash -c "[ -z \"\$(ls -A '$w-tmp')\" ]"
check "master is untouched"                  [ "$(git -C "$w" rev-parse master)" = "$m_before" ]
check "origin is untouched"                  [ "$(git -C "$w-origin.git" rev-parse master)" = "$r_before" ]
fi
done

E="${ENGINES[0]:-}"
if [ -n "$E" ]; then
echo "## 18. refusals before anything is written: shallow, dirty, an operation in progress (Kamino 194)"
fixture "$T/u"
git clone -q --depth 1 "file://$T/u-origin.git" "$T/u-shallow"
sha="$(git -C "$T/u-shallow" rev-parse HEAD)"
mt "$E" --repo "$T/u-shallow" --apply
check "a shallow clone is refused"           bash -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'Shallow clone'" _ "$out"
check "and left as it was"                   [ "$(git -C "$T/u-shallow" rev-parse HEAD)" = "$sha" ]
sha="$(git -C "$T/u" rev-parse master)"
echo scratch > "$T/u/untracked.txt"
mt "$E" --repo "$T/u" --apply
check "an untracked file is refused"         bash -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'not clean'" _ "$out"
check "and master left as it was"            [ "$(git -C "$T/u" rev-parse master)" = "$sha" ]
rm -f "$T/u/untracked.txt"
GIT_SEQUENCE_EDITOR="sed -i.bak -e 's/^pick/edit/'" git -C "$T/u" rebase -q -i master~2 >/dev/null 2>&1
check "(a rebase is stopped, tree clean)"    bash -c "[ -d '$T/u/.git/rebase-merge' ] && [ -z \"\$(git -C '$T/u' status --porcelain)\" ]"
head_before="$(git -C "$T/u" rev-parse HEAD)"
mt "$E" --repo "$T/u" --apply
check "a rebase in progress is refused"      bash -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'in progress'" _ "$out"
check "and nothing was rewritten"            bash -c "[ \"\$(git -C '$T/u' rev-parse master)\" = '$sha' ] && [ \"\$(git -C '$T/u' rev-parse HEAD)\" = '$head_before' ]"
git -C "$T/u" rebase --abort
git -C "$T/u" bisect start >/dev/null 2>&1
mt "$E" --repo "$T/u" --apply
check "a bisect in progress is refused"      bash -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'in progress'" _ "$out"
check "and master left as it was"            [ "$(git -C "$T/u" rev-parse master)" = "$sha" ]
git -C "$T/u" bisect reset >/dev/null 2>&1
# A range cherry-pick stopped on a conflict, resolved and committed: the tree
# is clean and only .git/sequencer says the pick is not finished.
git -C "$T/u" checkout -q -b pick master~1
echo "their line" >> "$T/u/file.txt"; git -C "$T/u" commit -q -am "pick one"
echo x > "$T/u/other.txt"; git -C "$T/u" add other.txt; git -C "$T/u" commit -q -m "pick two"
git -C "$T/u" checkout -q master
git -C "$T/u" cherry-pick master..pick >/dev/null 2>&1
git -C "$T/u" checkout -q --theirs file.txt; git -C "$T/u" add file.txt
git -C "$T/u" -c core.editor=true commit -q --no-edit >/dev/null 2>&1
check "(only a stopped cherry-pick, tree clean)" bash -c "[ -d '$T/u/.git/sequencer' ] && [ -z \"\$(cd '$T/u/.git' && ls -d rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_START BISECT_LOG 2>/dev/null)\" ] && [ -z \"\$(git -C '$T/u' status --porcelain)\" ]"
head_before="$(git -C "$T/u" rev-parse HEAD)"
mt "$E" --repo "$T/u" --apply
check "a cherry-pick in progress is refused" bash -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q 'in progress'" _ "$out"
check "and nothing was rewritten"            [ "$(git -C "$T/u" rev-parse HEAD)" = "$head_before" ]
git -C "$T/u" cherry-pick --abort >/dev/null 2>&1
fi

echo "## 19. a flag missing its value is a usage error (Kamino 194)"
for f in --repo --pattern; do
    out="$(bash "$MT" "$f" 2>&1)"; rc=$?
    check "$f alone: exit 1"                 [ "$rc" -eq 1 ]
    check "$f alone: says it needs a value"  has "$f needs a value"
    check "$f alone: no 'unbound variable'"  bash -c "! printf '%s' \"\$1\" | grep -q unbound" _ "$out"
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
