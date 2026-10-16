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
if ! { grep -q 'agent claude as example-claude\[bot\] <200001+example-claude\[bot\]@users.noreply.github.com>, App 100001' <<< "$out" && grep -q 'chosen: --config research' <<< "$out"; }; then echo "FAIL: run.sh --dry claude: $out"; fail=1; fi
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json gemini 2>&1)
if ! { grep -q 'agent gemini as example-gemini\[bot\]' <<< "$out" && grep -q 'example-gemini-config:/home/node/.gemini' <<< "$out"; }; then echo "FAIL: run.sh --dry gemini: $out"; fail=1; fi
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json claude -- --nope 2>&1); grep -q "unknown profile '--nope'" <<< "$out" || { echo "FAIL: run.sh --dry unknown profile: $out"; fail=1; }
# the container's command is the typed words once, after the profiles; the agent's name is not added again (2026-10-11:
# run.sh passed it twice and Claude Code took the second copy as the session's first prompt); no words means the image alone
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json claude --continue -- --research 2>&1); grep -q 'container command: example-sandbox --config research claude --continue$' <<< "$out" || { echo "FAIL: run.sh --dry container command: $out"; fail=1; }
out=$(bash sandbox/run.sh --dry examples/cocoon-ai.json 2>&1); grep -q 'container command: example-sandbox$' <<< "$out" || { echo "FAIL: run.sh --dry container command without an agent: $out"; fail=1; }
# the gateway section: the gateway example passes; each half is refused without the other; a non-address, a bad hostname and an
# unknown key in either section are refused with the problem named
G=examples/cocoon-ai-gateway.json
expect pass "$G" ""
jq 'del(.agents.claude.gateway)' "$G" > "$T/gw1.json"; expect fail "$T/gw1.json" "agents.claude.gateway is required when gateway is configured"
jq '.agents.claude.gateway = {cert: "c", key: "k", token: "t"}' examples/cocoon-ai.json > "$T/gw2.json"; expect fail "$T/gw2.json" "agents.claude.gateway is set but no gateway is configured"
jq '.gateway.address = "gw.example"' "$G" > "$T/gw3.json"; expect fail "$T/gw3.json" "gateway.address must be an IPv4 address"
jq '.gateway.domain = "GW"' "$G" > "$T/gw4.json"; expect fail "$T/gw4.json" "gateway.domain must be a hostname"
jq '.gateway.port = 8443' "$G" > "$T/gw5.json"; expect fail "$T/gw5.json" "unknown key in gateway: port"
jq '.agents.claude.gateway.extra = "x"' "$G" > "$T/gw6.json"; expect fail "$T/gw6.json" "unknown key in agents.claude.gateway: extra"
# the model path is per agent (2026-10-14: one flag for both agents sent Gemini to a gateway with no Gemini upstream): the
# top-level key is refused, each agent's is required and boolean, and true needs the agent's model upstream in upstreams
jq '.gateway.model = false' "$G" > "$T/gw7.json"; expect fail "$T/gw7.json" "unknown key in gateway: model"
jq 'del(.agents.claude.gateway.model)' "$G" > "$T/gw8.json"; expect fail "$T/gw8.json" "missing in agents.claude.gateway: model"
jq '.agents.claude.gateway.model = "yes"' "$G" > "$T/gw9.json"; expect fail "$T/gw9.json" "agents.claude.gateway.model must be true or false"
jq '.agents.gemini.gateway.model = true' "$G" > "$T/gw10.json"; expect fail "$T/gw10.json" "agents.gemini.gateway.model is true but gateway.upstreams has no gemini"
jq '.gateway.upstreams -= ["anthropic"]' "$G" > "$T/gw11.json"; expect fail "$T/gw11.json" "agents.claude.gateway.model is true but gateway.upstreams has no anthropic"
jq '.gateway.upstreams += ["gemini"] | .agents.gemini.gateway.model = true' "$G" > "$T/gw12.json"; expect pass "$T/gw12.json" ""
out=$(bash sandbox/check-config.sh "$G" 2>&1); grep -q 'model through it: claude)$' <<< "$out" || { echo "FAIL: check-config names the agents whose model goes through the gateway: $out"; fail=1; }
# the dry run with a gateway: the four host files present, it names the gateway and its mounts, mints nothing, and the
# container's command is unchanged; a key at a mode other than 600 or 400 is warned about; a missing file is refused by path
mkdir -p -- "$T/gw"; for f in root.crt claude.crt claude.key claude.token gemini.crt gemini.key gemini.token; do echo x > "$T/gw/$f"; done; chmod -- 600 "$T/gw/claude.key" "$T/gw/claude.token" "$T/gw/gemini.key" "$T/gw/gemini.token"
jq --arg d "$T/gw" '.gateway.ca = $d + "/root.crt" | .agents.claude.gateway = {cert: ($d + "/claude.crt"), key: ($d + "/claude.key"), token: ($d + "/claude.token"), model: true} | .agents.gemini.gateway = {cert: ($d + "/gemini.crt"), key: ($d + "/gemini.key"), token: ($d + "/gemini.token"), model: false}' "$G" > "$T/gwdry.json"
out=$(bash sandbox/run.sh --dry "$T/gwdry.json" claude 2>&1)
if ! { grep -q "gateway gw.example.com at $(jq -r .gateway.address "$G"); no token minted; model through it: true; mounts: root.crt, client.crt, client.key, client.token" <<< "$out" && grep -q 'container command: example-sandbox claude$' <<< "$out"; }; then echo "FAIL: run.sh --dry with a gateway: $out"; fail=1; fi
grep -q 'WARNING' <<< "$out" && { echo "FAIL: run.sh --dry with a gateway warned at mode 600: $out"; fail=1; }
out=$(bash sandbox/run.sh --dry "$T/gwdry.json" gemini 2>&1); grep -q "no token minted; model through it: false; mounts:" <<< "$out" || { echo "FAIL: run.sh --dry gemini names its own model path: $out"; fail=1; }
chmod -- 644 "$T/gw/claude.key"; out=$(bash sandbox/run.sh --dry "$T/gwdry.json" claude 2>&1); grep -q "WARNING $T/gw/claude.key has mode 644" <<< "$out" || { echo "FAIL: run.sh --dry gateway key mode: $out"; fail=1; }
rm -f -- "${T:?}/gw/claude.token"; out=$(bash sandbox/run.sh --dry "$T/gwdry.json" claude 2>&1); grep -q "gateway file not readable: $T/gw/claude.token" <<< "$out" || { echo "FAIL: run.sh --dry gateway missing file: $out"; fail=1; }
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
if ! { grep -q "installed as $T/bin/cocoon" <<< "$out" && cmp -s -- "$T/downloaded.sh" "$T/bin/cocoon" && [ -x "$T/bin/cocoon" ] && grep -q "not on your PATH" <<< "$out"; }; then echo "FAIL: launcher install: $out"; fail=1; fi
out=$(bash "$T/bin/cocoon" --dry "--config=$T/install.json" 2>&1 || true); grep -q "installed as" <<< "$out" && { echo "FAIL: the installed copy reinstalled itself: $out"; fail=1; }
jq '.command.install = false' "$T/install.json" > "$T/noinstall.json"; rm -f -- "${T:?}/bin/cocoon"
out=$(bash "$T/downloaded.sh" --dry "--config=$T/noinstall.json" 2>&1 || true); [ ! -e "$T/bin/cocoon" ] || { echo "FAIL: installed with command.install false: $out"; fail=1; }
# the gateway shape's git settings reach a process that hides the global file (GIT_CONFIG_GLOBAL=/dev/null, the Gemini CLI's
# shell, 2026-10-16): the entrypoint exports them as GIT_CONFIG_COUNT entries too, and git reads those before any file
if ! { grep -q 'GIT_CONFIG_COUNT=2' sandbox/entrypoint.sh && grep -qF "GIT_CONFIG_KEY_0=\"url.https://git.\$GW_DOMAIN/.insteadOf\"" sandbox/entrypoint.sh && grep -q 'GIT_CONFIG_KEY_1=http.sslCAInfo' sandbox/entrypoint.sh; }; then echo "FAIL: entrypoint.sh does not export the git settings as GIT_CONFIG_COUNT entries"; fail=1; fi
out=$(cd "$T" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="url.https://git.gw.example.com/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/" GIT_CONFIG_KEY_1=http.sslCAInfo GIT_CONFIG_VALUE_1=/tmp/ca.crt git config --get-urlmatch http.sslCAInfo https://x 2>&1; cd "$T" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.https://git.gw.example.com/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/" git config --get url.https://git.gw.example.com/.insteadof 2>&1)
[ "$out" = "/tmp/ca.crt
https://github.com/" ] || { echo "FAIL: git under GIT_CONFIG_GLOBAL=/dev/null did not read the environment settings: $out"; fail=1; }
for f in sandbox/*.sh host/*.sh hooks/*.sh tests/*.sh; do bash -n "$f" || { echo "FAIL: syntax: $f"; fail=1; }; done
[ $fail -eq 0 ] && echo "check-config tests: all pass"; exit $fail
