#!/bin/bash
# Runs as `node` on every container start.
set -euo pipefail

# run.sh puts the chosen configs first, as `--config <name>` pairs the host user asked for
# (`cocoon claude -- --research`); they are stripped here and handed to the firewall, which
# reads the matching hosts lists. Nothing is read from the environment.
CONFIGS=()
while [ "${1:-}" = --config ]; do
  CONFIGS+=("$2")
  shift 2
done
# Nothing left after the profiles means they replaced the image's CMD (`cocoon -- --research`): the
# shell, the same command as no arguments at all.
[ $# -gt 0 ] || set -- bash

# The agent is the container's command (claude, gemini); the firewall allows only that
# agent's model host. A plain shell gets Claude's hosts.
AGENT=claude
[ "${1:-}" = gemini ] && AGENT=gemini
echo "configs: base, $AGENT${CONFIGS[*]:+, ${CONFIGS[*]}}"
sudo /usr/local/bin/init-firewall.sh "$AGENT" "${CONFIGS[@]}"

# The gateway shape (a `gateway` section in the mounted configuration): no token was minted and none is
# here. A CA and a wildcard leaf for *.<domain> are made now, for this container only, into a private
# directory (the CA's key is deleted once the leaf is signed, so nothing can mint another); the relay
# (gateway-relay.mjs, the one process holding the client certificate and the role's token) is started on
# 127.0.0.1:8443, where the firewall sends every connection to the gateway's port 443; then every tool is
# told to trust that CA alone and to reach GitHub, npm and the model through the subdomains:
#   SSL_CERT_FILE (gh, Python, OpenSSL tools), CURL_CA_BUNDLE (curl), NODE_EXTRA_CA_CERTS (Claude Code),
#   REQUESTS_CA_BUNDLE (Python requests); GH_HOST on the github subdomain with a placeholder enterprise
#   token (gh sends it as Authorization, which the gateway drops and replaces by the App's; it only has
#   to be non-empty); git rewrites github.com to the git subdomain and trusts the CA; npm's registry and
#   cafile; the agent's model base URL on its subdomain when its own agents.<agent>.gateway.model is true
#   (claude: ANTHROPIC_BASE_URL on anthropic; gemini: GOOGLE_GEMINI_BASE_URL on gemini, the variable its CLI
#   reads, unexercised until a gateway serves a gemini upstream). Per agent since 2026-10-14: one flag for
#   both agents routed Gemini to a gateway with no Gemini upstream, and its CLI hung at the prompt (2026-10-13).
CFG=/etc/cocoon/sandbox.json   # run.sh mounts the reviewed configuration read-only
GATEWAY=0
if [ -r "$CFG" ] && jq -e '.gateway' "$CFG" >/dev/null 2>&1; then
  GATEWAY=1
  GW_DOMAIN=$(jq -r '.gateway.domain' "$CFG")
  GW_ADDR=$(jq -r '.gateway.address' "$CFG")
  GW_MODEL=$(jq -r --arg a "$AGENT" '.agents[$a].gateway.model' "$CFG")   # this agent's; the firewall refused a non-boolean before this line
  GW_DIR=/etc/cocoon/gateway
  RELAY=/tmp/cocoon-relay
  rm -rf -- "${RELAY:?}" && mkdir -m 700 -- "$RELAY"
  openssl ecparam -name prime256v1 -genkey -noout -out "$RELAY/ca.key"
  openssl req -x509 -new -key "$RELAY/ca.key" -sha256 -days 2 -subj "/CN=cocoon relay CA (this container only)" \
    -config <(printf '[req]\ndistinguished_name=dn\n[dn]\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n') -extensions v3 -out "$RELAY/ca.crt" 2>/dev/null
  openssl ecparam -name prime256v1 -genkey -noout -out "$RELAY/leaf.key"
  openssl req -new -key "$RELAY/leaf.key" -subj "/CN=relay.$GW_DOMAIN" -out "$RELAY/leaf.csr" 2>/dev/null
  openssl x509 -req -in "$RELAY/leaf.csr" -CA "$RELAY/ca.crt" -CAkey "$RELAY/ca.key" -CAcreateserial -sha256 -days 2 \
    -extfile <(printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:*.%s\n' "$GW_DOMAIN") -out "$RELAY/leaf.crt" 2>/dev/null
  rm -f -- "$RELAY/ca.key" "$RELAY/leaf.csr" "$RELAY/ca.srl"
  node /usr/local/share/cocoon/gateway-relay.mjs "$RELAY" "$GW_DIR" "$GW_ADDR" "$GW_DOMAIN" > "$RELAY/relay.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8443' 2>/dev/null; then break; fi
    sleep 0.5
  done
  timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8443' 2>/dev/null || { echo "gateway: the relay did not start; $RELAY/relay.log:"; cat -- "$RELAY/relay.log"; exit 1; }
  export SSL_CERT_FILE="$RELAY/ca.crt" CURL_CA_BUNDLE="$RELAY/ca.crt" NODE_EXTRA_CA_CERTS="$RELAY/ca.crt" REQUESTS_CA_BUNDLE="$RELAY/ca.crt"
  export GH_HOST="github.$GW_DOMAIN" GH_ENTERPRISE_TOKEN=through-the-gateway
  git config --global "url.https://git.$GW_DOMAIN/.insteadOf" "https://github.com/"
  git config --global http.sslCAInfo "$RELAY/ca.crt"
  # The same two settings in the environment, which git reads before any file (GIT_CONFIG_COUNT, git 2.31+):
  # a process that hides the global file (the Gemini CLI runs its shell with GIT_CONFIG_GLOBAL=/dev/null, found
  # 2026-10-16 on the channel's first session: git fell back to github.com and the wall dropped it) still
  # rewrites github.com to the git subdomain and trusts the relay's CA. Both forms stay: the file for a child
  # that clears its environment, the environment for a child that hides the file.
  export GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0="url.https://git.$GW_DOMAIN/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/" \
    GIT_CONFIG_KEY_1=http.sslCAInfo GIT_CONFIG_VALUE_1="$RELAY/ca.crt"
  npm config set --location=user "registry=https://npm.$GW_DOMAIN/" "cafile=$RELAY/ca.crt"
  if [ "$GW_MODEL" = true ]; then
    case "$AGENT" in
      claude) export ANTHROPIC_BASE_URL="https://anthropic.$GW_DOMAIN" ;;
      gemini) export GOOGLE_GEMINI_BASE_URL="https://gemini.$GW_DOMAIN" ;;   # unexercised: no gateway serves a gemini upstream yet (the firewall refuses model true for gemini until gateway.upstreams lists it)
      *) echo "gateway: no model path known for agent '$AGENT'" >&2; exit 1 ;;
    esac
  fi
  echo "gateway: $GW_DOMAIN at $GW_ADDR through the relay; no token in this container; $AGENT's model through it: $GW_MODEL"
  echo "gh: through the gateway; repos: $(gh api installation/repositories -q '[.repositories[].full_name] | join(", ")' 2>/dev/null || echo '? (see the gateway log)')"
fi

# GH_TOKEN, if set, is a GitHub App installation token minted on the host by run.sh
# (1-hour lifetime) or a fine-grained PAT. It lives only in this process's env; nothing is
# written to disk. The App's private key is never mounted here.
if [ "$GATEWAY" = 1 ]; then
  :
elif [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null
  case "$GH_TOKEN" in
    ghs_*) # installation token: no /user endpoint, list what it can reach instead
      echo "gh: GitHub App installation token; repos: $(gh api installation/repositories -q '[.repositories[].full_name] | join(", ")' 2>/dev/null || echo '?')"
      echo "gh: token expires within 1 hour of container start; restart run.sh for a new one" ;;
    *)
      echo "gh: authenticated as $(gh api user -q .login 2>/dev/null || echo '?')" ;;
  esac
else
  echo "gh: no GH_TOKEN set; git push / gh pr will not work this session"
fi

# The Gemini agent authenticates to its API with GEMINI_API_KEY, passed in by run.sh the
# same way as GH_TOKEN: environment only, never on disk here.
if [ "$AGENT" = gemini ]; then
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    echo "gemini: GEMINI_API_KEY set for this session (env only)"
  else
    echo "gemini: no GEMINI_API_KEY set; the CLI cannot reach the model"
  fi
fi

# The workspace is a named volume, not a bind mount of anything on the host: the repo is
# cloned into it on the first start and kept across runs and image rebuilds. Branches and
# commits here reach the host only through GitHub, behind the ruleset's review.
WORKSPACE_REPO=$(jq -r '.workspace.repo' "$CFG" 2>/dev/null || true)
if [ ! -d /workspace/.git ]; then
  if [ -n "$WORKSPACE_REPO" ] && [ "$WORKSPACE_REPO" != null ]; then
    echo "cloning $WORKSPACE_REPO into the workspace volume (first start)..."
    git clone -q "https://github.com/$WORKSPACE_REPO.git" /workspace
  else
    echo "no configuration at $CFG: the workspace is not cloned (run through run.sh with a configuration)"
  fi
fi
cd /workspace

# Dependencies: npm ci whenever the lockfile differs from the one last installed, which
# also wipes node_modules, so a package pulled in by an old lockfile does not outlive it.
# Lifecycle scripts are refused by the image's npm config (ignore-scripts); the lockfile
# has no package that needs one (checked 2026-10-02, all 335 tests green without).
if [ -f package-lock.json ]; then
  want=$(sha256sum package-lock.json | cut -d' ' -f1)
  have=$(cat node_modules/.cocoon-lockfile-sha 2>/dev/null || true)
  if [ "$want" != "$have" ]; then
    echo "npm ci (lockfile changed or first start)..."
    npm ci --no-audit --no-fund
    echo "$want" > node_modules/.cocoon-lockfile-sha
  fi
fi

# The configuration's clones are cloned beside the workspace on the first start that has a token; a repo that does not exist yet, or
# that the App is not installed on, fails its clone and is retried next start. /home/node is not a volume: a fresh container
# re-clones, and local branches not pushed are lost (the records convention says so).
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  dir=/home/node/${slug##*/}
  if { [ -n "${GH_TOKEN:-}" ] || [ "$GATEWAY" = 1 ]; } && [ ! -d "$dir/.git" ]; then
    echo "cloning $slug (first start in this container)..."
    # git, not gh: in the gateway shape gh builds its clone URL on GH_HOST, the API subdomain, which the gateway
    # maps to api.github.com (403 for a git path; the first start with the gateway, 2026-10-13, cloned nothing);
    # git's insteadOf carries github.com to the git subdomain, and in the old shape gh's credential helper serves it.
    git clone -q "https://github.com/$slug.git" "$dir" || echo "clone of $slug failed; will retry next start"
  fi
done < <(jq -r '(.clones // [])[]' "$CFG" 2>/dev/null || true)

exec "$@"
