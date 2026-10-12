#!/bin/bash
# The configuration contract, tested with jq alone: the example passes; an unknown key, a missing
# key, a wrong version and a bad profile name are refused, each naming the problem.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
C=sandbox/check-config.sh; T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT; fail=0
expect() { # expect <pass|fail> <file> <needle>
  out=$(bash "$C" "$2" 2>&1); status=$?
  if [ "$1" = pass ] && [ $status -ne 0 ]; then echo "FAIL: expected pass: $2: $out"; fail=1; fi
  if [ "$1" = fail ] && { [ $status -eq 0 ] || ! grep -q -- "$3" <<< "$out"; }; then echo "FAIL: expected '$3' for $2: $out"; fail=1; fi
}
expect pass examples/cocoon-ai.json ""
jq '. + {"extra": 1}' examples/cocoon-ai.json > "$T/unknown.json"; expect fail "$T/unknown.json" "unknown top-level key: extra"
jq 'del(.image)' examples/cocoon-ai.json > "$T/missing.json"; expect fail "$T/missing.json" "missing: image"
jq '.version = 2' examples/cocoon-ai.json > "$T/version.json"; expect fail "$T/version.json" "version must be 1"
jq '.profiles = ["Research Hosts"]' examples/cocoon-ai.json > "$T/profile.json"; expect fail "$T/profile.json" "profiles must be"
jq '.agents.claude.secret = "x"' examples/cocoon-ai.json > "$T/agentkey.json"; expect fail "$T/agentkey.json" "unknown key in agents.claude: secret"
jq '.agents.other = .agents.claude' examples/cocoon-ai.json > "$T/agent.json"; expect fail "$T/agent.json" "unknown agent: other"
jq '.command.install = "yes"' examples/cocoon-ai.json > "$T/cmd1.json"; expect fail "$T/cmd1.json" "command.install must be true or false"
jq '.command.path = "/x"' examples/cocoon-ai.json > "$T/cmd2.json"; expect fail "$T/cmd2.json" "unknown key in command: path"
jq 'del(.command)' examples/cocoon-ai.json > "$T/cmd3.json"; expect pass "$T/cmd3.json" ""
echo "not json" > "$T/bad.json"; expect fail "$T/bad.json" "not valid JSON"
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json claude -- --research 2>&1)
if ! { grep -q 'agent claude as cocoon-claude\[bot\] <324573615+cocoon-claude\[bot\]@users.noreply.github.com>, App 4819921' <<< "$out" && grep -q 'chosen: --config research' <<< "$out"; }; then echo "FAIL: run.sh --dry claude: $out"; fail=1; fi
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json gemini 2>&1)
if ! { grep -q 'agent gemini as cocoon-gemini\[bot\]' <<< "$out" && grep -q 'cocoon-ai-gemini-config:/home/node/.gemini' <<< "$out"; }; then echo "FAIL: run.sh --dry gemini: $out"; fail=1; fi
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json claude -- --nope 2>&1); grep -q "unknown profile '--nope'" <<< "$out" || { echo "FAIL: run.sh --dry unknown profile: $out"; fail=1; }
# the container's command is the typed words once, after the profiles; the agent's name is not added again (2026-10-11:
# run.sh passed it twice and Claude Code took the second copy as the session's first prompt); no words means the image alone
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json claude --continue -- --research 2>&1); grep -q 'container command: cocoon-ai-sandbox --config research claude --continue$' <<< "$out" || { echo "FAIL: run.sh --dry container command: $out"; fail=1; }
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json 2>&1); grep -q 'container command: cocoon-ai-sandbox$' <<< "$out" || { echo "FAIL: run.sh --dry container command without an agent: $out"; fail=1; }
out=$(HOME="$T" bash host/cocoon-launch.sh --dry 2>&1); grep -q "no configuration at $T/.config/cocoon/sandbox.json" <<< "$out" || { echo "FAIL: launcher without a configuration: $out"; fail=1; }
out=$(bash host/cocoon-launch.sh --dry "--config=$T/elsewhere.json" 2>&1); grep -q "no configuration at $T/elsewhere.json" <<< "$out" || { echo "FAIL: launcher --config=<path>: $out"; fail=1; }
out=$(HOME="$T" bash host/cocoon-launch.sh '--config=~/tilde.json' --dry 2>&1); grep -q "no configuration at $T/tilde.json" <<< "$out" || { echo "FAIL: launcher --config=~ expansion: $out"; fail=1; }
out=$(bash host/cocoon-launch.sh --config "$T/x.json" 2>&1); grep -q "use --config=<path>" <<< "$out" || { echo "FAIL: launcher --config without =: $out"; fail=1; }
# the command on the host: a launcher run from elsewhere installs itself where the file says, once, and says when that
# directory is off the PATH; the installed copy never rewrites itself; command.install false installs nothing. The sandbox
# repo is a name that does not exist, so the run stops at the first download, after the install. The platform's default
# directory (Linux ~/.local/bin, macOS Homebrew's prefix) is read, not run, here.
jq --arg bin "${T:?}/bin" '.command = {install: true, bin: $bin} | .sandbox.repo = "theCocoonStudio/no-such-repo-for-this-test"' examples/cocoon-ai.json > "$T/install.json"
cp host/cocoon-launch.sh "$T/downloaded.sh"
out=$(PATH=/usr/bin:/bin bash "$T/downloaded.sh" --dry "--config=$T/install.json" 2>&1 || true)
if ! { grep -q "installed as $T/bin/cocoon" <<< "$out" && cmp -s "$T/downloaded.sh" "$T/bin/cocoon" && [ -x "$T/bin/cocoon" ] && grep -q "not on your PATH" <<< "$out"; }; then echo "FAIL: launcher install: $out"; fail=1; fi
out=$(bash "$T/bin/cocoon" --dry "--config=$T/install.json" 2>&1 || true); grep -q "installed as" <<< "$out" && { echo "FAIL: the installed copy reinstalled itself: $out"; fail=1; }
jq '.command.install = false' "$T/install.json" > "$T/noinstall.json"; rm -f "${T:?}/bin/cocoon"
out=$(bash "$T/downloaded.sh" --dry "--config=$T/noinstall.json" 2>&1 || true); [ ! -e "$T/bin/cocoon" ] || { echo "FAIL: installed with command.install false: $out"; fail=1; }
for f in sandbox/*.sh host/*.sh hooks/*.sh tests/*.sh; do bash -n "$f" || { echo "FAIL: syntax: $f"; fail=1; }; done
[ $fail -eq 0 ] && echo "check-config tests: all pass"; exit $fail
