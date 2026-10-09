#!/usr/bin/env bash
# Run every tests/test-*.sh against the engine (or $MIND_TRICK) and exit
# non-zero if any fails. No network: file:// remotes and synthetic repos only.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
for t in "$TEST_DIR"/test-*.sh; do
    name=$(basename "$t")
    if out=$(bash "$t" </dev/null 2>&1); then printf 'PASS  %s\n' "$name"
    else printf 'FAIL  %s\n' "$name"; grep -E '^ *FAIL' <<<"$out" | sed 's/^/        /'; failed+=("$name"); fi
done
echo
if (( ${#failed[@]} )); then echo "${#failed[@]} test file(s) failed: ${failed[*]}"; exit 1; fi
echo "all test files passed"
