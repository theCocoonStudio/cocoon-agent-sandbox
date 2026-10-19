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
scripts=(sandbox/*.sh sandbox/claude-code/hooks/*.sh host/*.sh hooks/*.sh tests/*.sh)
fail=0
shellcheck "${scripts[@]}" || fail=1
# Our own classes, each with the date it was learned. This file is skipped: its patterns would match themselves.
for f in "${scripts[@]}"; do
  [ "$f" = tests/lint.sh ] && continue
  # 2026-10-11: a recursive delete on a variable path that can collapse to / (the guardrail's catch)
  if grep -nE 'rm -r[f]? +"?\$[A-Za-z_{][^:?}]*[/"]' "$f" | grep -vE '\$\{[A-Za-z_]+:\?' ; then echo "lint: $f: rm -r on a variable path without \${var:?}"; fail=1; fi
  # 2026-10-11: a file command whose first operand is a variable path with no -- before it, so a value
  # beginning with a dash would be read as an option (Izzy: mkdir -p -- "$dir"); the grep covers the
  # plain forms (options, a mode or an owner, then the quoted variable); an option that takes a value
  # (stat -c, tar -C) is outside it and is read by hand
  if grep -nE '(^|&&[[:space:]]*|;[[:space:]]*|\{[[:space:]]*|\|\|[[:space:]]*)[[:space:]]*(mkdir|rm|rmdir|chmod|chown|cp|mv|ln|touch|cat|cmp)( -[A-Za-z0-9]+| [0-7]{3,4}| [0-9]+:[0-9]+)* "\$' "$f"; then echo "lint: $f: a variable path as the first operand without -- before it"; fail=1; fi
  # 2026-09-16, 2026-10-05: git cherry-pick has no -q; the chain ran on past the failed pick
  # 2026-10-11: an API response read through jq with no check of its shape. A 200 can carry an unexpected
  # payload, and `jq -r .field` prints "null" for a missing field, which then travels on as a value. The
  # grep sees the direct form only, curl piped into jq on one line with no `if (`, `select(` or `-e`; a
  # response held in a variable and read later is checked by hand (the owner, 2026-10-11).
  if grep -nE 'curl .*\|[[:space:]]*jq ' "$f" | grep -vE 'jq +-[a-zA-Z]*e|if \(|select\('; then echo "lint: $f: an API response read through jq with no check of its shape"; fail=1; fi
  # 2026-10-13: chmod or chown with the -- after the mode or the owner. GNU accepts it; macOS's BSD chmod ends its
  # options at the mode and reads the -- as a file name ("chmod: --: No such file or directory", the owner's Mac,
  # running the gateway's certs.sh). The -- goes before the mode: chmod -- 700 "$dir". The launcher runs on macOS.
  if grep -nE '(chmod|chown)( -[A-Za-z]+)* +([0-7]{3,4}|[0-9]+:[0-9]+|[ugoa]*[-+=][rwxXst]+) +-- ' "$f"; then echo "lint: $f: -- after the mode; macOS reads it as a file (put it before the mode)"; fail=1; fi
  if grep -nE 'cherry-pick +-q' "$f"; then echo "lint: $f: git cherry-pick -q does not exist"; fail=1; fi
  # 2026-10-02, 2026-10-08: a pipeline's status is its last command's, so a failure before the last
  # pipe is invisible; every script turns pipefail on in its first set line (-e is the script's own
  # call: the collectors and the hooks run every check and decide at the end)
  grep -qE '^set -[a-z]*o pipefail' "$f" || { echo "lint: $f: no 'set -...o pipefail' at the top"; fail=1; }
done
[ $fail -eq 0 ] && echo "lint: clean"
exit $fail
