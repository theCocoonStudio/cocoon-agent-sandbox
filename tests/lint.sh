#!/bin/bash
# The lint: every shell script here through ShellCheck with .shellcheckrc, plus the classes a
# linter cannot see, as greps. Exit 1 on anything. Run before every commit; CI runs it on every PR.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
TOOLS=(
  shellcheck   # the linter; Debian's package in the image, preinstalled on GitHub's runner
  grep
)
for tool in "${TOOLS[@]}"; do
  command -v "$tool" >/dev/null || { echo "lint: '$tool' is required" >&2; exit 1; }
done
echo "lint: shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
scripts=(sandbox/*.sh host/*.sh hooks/*.sh tests/*.sh)
fail=0
shellcheck "${scripts[@]}" || fail=1
# Our own classes, each with the date it was learned. This file is skipped: its patterns would match themselves.
for f in "${scripts[@]}"; do
  [ "$f" = tests/lint.sh ] && continue
  # 2026-10-11: a recursive delete on a variable path that can collapse to / (the guardrail's catch)
  if grep -nE 'rm -r[f]? +"?\$[A-Za-z_{][^:?}]*[/"]' "$f" | grep -vE '\$\{[A-Za-z_]+:\?' ; then echo "lint: $f: rm -r on a variable path without \${var:?}"; fail=1; fi
  # 2026-09-16, 2026-10-05: git cherry-pick has no -q; the chain ran on past the failed pick
  if grep -nE 'cherry-pick +-q' "$f"; then echo "lint: $f: git cherry-pick -q does not exist"; fail=1; fi
  # 2026-10-02, 2026-10-08: a pipeline's status is its last command's, so a failure before the last
  # pipe is invisible; every script turns pipefail on in its first set line (-e is the script's own
  # call: the collectors and the hooks run every check and decide at the end)
  grep -qE '^set -[a-z]*o pipefail' "$f" || { echo "lint: $f: no 'set -...o pipefail' at the top"; fail=1; }
done
[ $fail -eq 0 ] && echo "lint: clean"
exit $fail
