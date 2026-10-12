#!/bin/bash
# Build (if needed) and drop into the sandbox. Rootless podman. Usage:
#   run.sh <config.json> [agent] [agent args] [-- --<profile> ...]
#   run.sh --dry <config.json> [agent]     # print what would run, mint nothing, start nothing
#
# Through the installed launcher (host/cocoon-launch.sh) this is `cocoon claude`, `cocoon gemini`,
# `cocoon claude -- --research`: flags before `--` go to the agent, after it name the profiles
# (hosts lists) turned on for this one session.
#
# The configuration file lives on the host, ~/.config/cocoon/sandbox.json, placed and edited by
# hand like the launcher, never inside a repository; the launcher reads it and hands it here. Everything this script
# knows comes from that file; nothing is read from the environment. check-config.sh refuses a
# file with a key nobody reads.
#
# GitHub access: a GitHub App installation token, minted HERE on the host from the App's
# private key (a host path in the configuration), and passed into the container as GH_TOKEN.
# The key never enters the sandbox. The token is valid for 1 hour; a session that outlives it
# loses push/PR access until run.sh is started again. Everything the agent does on GitHub is
# attributed to the bot user.
set -euo pipefail
SANDBOX="$(dirname "$0")"

DRY=0
if [ "${1:-}" = --dry ]; then DRY=1; shift; fi
CONFIG=${1:?run.sh: the configuration file is the first argument}; shift
bash "$SANDBOX/check-config.sh" "$CONFIG" >/dev/null || exit 1
cfg() { jq -r "$1" "$CONFIG"; }          # a string, or "null"
expand() { printf '%s' "${1/#\~/$HOME}"; } # a leading ~ in a host path

IMAGE=$(cfg .image)
APP_ACCOUNT=$(cfg .account)
API=https://api.github.com
mapfile -t KNOWN_PROFILES < <(cfg '(.profiles // [])[]')
AGENT=claude
if jq -e --arg a "${1:-}" '.agents | has($a)' "$CONFIG" >/dev/null 2>&1; then AGENT=$1; fi
jq -e --arg a "$AGENT" '.agents | has($a)' "$CONFIG" >/dev/null || { echo "run.sh: the configuration has no agent '$AGENT' (agents: $(cfg '.agents | keys | join(", ")'))" >&2; exit 1; }

# Profiles after `--`: each must be one the configuration names; an unknown one is an error,
# not a silent default. They reach the entrypoint as `--config <name>` pairs.
COMMAND=()
CONFIG_ARGS=()
while [ $# -gt 0 ] && [ "$1" != -- ]; do COMMAND+=("$1"); shift; done
if [ "${1:-}" = -- ]; then
  shift
  for flag in "$@"; do
    name="${flag#--}"
    known=0
    for c in "${KNOWN_PROFILES[@]}"; do [ "$c" = "$name" ] && known=1; done
    [ "$known" = 1 ] || { echo "run.sh: unknown profile '$flag' (known: ${KNOWN_PROFILES[*]:-none})" >&2; exit 1; }
    CONFIG_ARGS+=(--config "$name")
  done
fi
set -- "${COMMAND[@]}"

a() { cfg ".agents[\"$AGENT\"].$1"; }
APP_ID=$(a app_id)
APP_KEY=$(expand "$(a key)")
BOT_NAME=$(a bot)
BOT_EMAIL="$(a bot_id)+$(a bot)@users.noreply.github.com"
CONTAINER=$(a container)
WORKSPACE_VOLUME=$(a workspace_volume)
CONFIG_VOLUME=$(a config_volume)
TOKENS_FILE=$(a tokens_file); [ "$TOKENS_FILE" = null ] && TOKENS_FILE="" || TOKENS_FILE=$(expand "$TOKENS_FILE")
AGENT_ENV=()
while IFS= read -r kv; do [ -n "$kv" ] && AGENT_ENV+=(-e "$kv"); done < <(cfg ".agents[\"$AGENT\"].env // {} | to_entries[] | \"\\(.key)=\\(.value)\"")

if [ "$DRY" = 1 ]; then
  echo "run.sh --dry: agent $AGENT as $BOT_NAME <$BOT_EMAIL>, App $APP_ID, key $APP_KEY"
  echo "run.sh --dry: image $IMAGE from $SANDBOX; container $CONTAINER; volumes $WORKSPACE_VOLUME:/workspace, $CONFIG_VOLUME"
  echo "run.sh --dry: profiles known: ${KNOWN_PROFILES[*]:-none}; chosen: ${CONFIG_ARGS[*]:-none}; agent env: ${AGENT_ENV[*]:-none}"
  printf 'run.sh --dry: container command:'; printf ' %s' "$IMAGE" "${CONFIG_ARGS[@]}" "$@"; echo   # the image, then exactly what the entrypoint receives
  exit 0   # a dry run shows what would run; the tools are the host's to have
fi

TOOLS=(
  podman    # builds the image and runs the container
  openssl   # signs the App JWT
  curl      # the GitHub API, for the installation token
  jq        # reads the configuration and the API's JSON
)
for tool in "${TOOLS[@]}"; do
  command -v "$tool" >/dev/null || { echo "run.sh: '$tool' is required on the host" >&2; exit 1; }
done

# Always show the build log. Cached runs print one short line per step; a real rebuild shows everything.
podman build -t "$IMAGE" "$SANDBOX"

# --- Mint a 1-hour installation token for the App (host side, key stays here) ---------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
gh_api() { curl -fsS -H "Authorization: Bearer $1" -H "Accept: application/vnd.github+json" \
                 -H "X-GitHub-Api-Version: 2022-11-28" "${@:2}"; }

GH_TOKEN=""
if [ -z "$APP_ID" ] || [ "$APP_ID" = null ]; then
  echo "github: no App id for $BOT_NAME (set it in the configuration by PR); starting without a credential" >&2
elif [ ! -r "$APP_KEY" ]; then
  echo "github: App key not readable at $APP_KEY; starting without a credential" >&2
else
  perms=$(stat -c %a "$APP_KEY")
  [ "$perms" = "600" ] || [ "$perms" = "400" ] || echo "github: WARNING $APP_KEY has mode $perms; chmod 600 it" >&2

  # JWT signed with the App key, valid 9 minutes (iat backdated 60s for clock skew).
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$APP_KEY" -binary | b64url)
  jwt="$header.$payload.$sig"

  # The installation of this App on the configured account, then a token for it.
  inst=$(gh_api "$jwt" "$API/app/installations" \
         | jq -r --arg a "$APP_ACCOUNT" '.[] | select(.account.login == $a) | .id' | head -1)
  [ -n "$inst" ] || { echo "github: App $APP_ID has no installation on $APP_ACCOUNT" >&2; exit 1; }
  resp=$(gh_api "$jwt" -X POST "$API/app/installations/$inst/access_tokens")
  GH_TOKEN=$(printf '%s' "$resp" | jq -r .token)
  echo "github: installation token minted for $APP_ACCOUNT as $BOT_NAME, expires $(printf '%s' "$resp" | jq -r .expires_at)"
  echo "github: repos: $(printf '%s' "$resp" | jq -r '.repository_selection')"
  unset jwt sig payload header resp
fi
export GH_TOKEN   # read by podman via `-e GH_TOKEN` below; the value is never on a command line

# --- The agent's own token file, same discipline: one KEY=value line read (never sourced) --------
# --- into the container's environment only. Today the Gemini API key. ---------------------------
if [ -n "$TOKENS_FILE" ]; then
  if [ -r "$TOKENS_FILE" ]; then
    perms=$(stat -c %a "$TOKENS_FILE")
    [ "$perms" = "600" ] || [ "$perms" = "400" ] || echo "$AGENT: WARNING $TOKENS_FILE has mode $perms; chmod 600 it" >&2
    line=$(grep -m1 -E '^[A-Z_]+=' "$TOKENS_FILE" || true)
    if [ -n "$line" ]; then
      key_name=${line%%=*}
      export "$key_name"="${line#*=}"
      AGENT_ENV+=(-e "$key_name")
      echo "$AGENT: $key_name set for this session (env only)"
    else
      echo "$AGENT: no KEY=value line in $TOKENS_FILE; starting without one" >&2
    fi
  else
    echo "$AGENT: tokens file $TOKENS_FILE not readable; starting without one" >&2
  fi
fi

exec podman run -it --rm \
  --name "$CONTAINER" \
  --userns=keep-id:uid=1000,gid=1000 \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "$WORKSPACE_VOLUME:/workspace" \
  -v "$CONFIG_VOLUME" \
  -v "$(readlink -f "$CONFIG"):/etc/cocoon/sandbox.json:ro" \
  -e GIT_AUTHOR_NAME="$BOT_NAME" -e GIT_COMMITTER_NAME="$BOT_NAME" \
  -e GIT_AUTHOR_EMAIL="$BOT_EMAIL" -e GIT_COMMITTER_EMAIL="$BOT_EMAIL" \
  -e GH_TOKEN \
  "${AGENT_ENV[@]}" \
  "$IMAGE" "${CONFIG_ARGS[@]}" "$@"
# The container's command is what was typed after `cocoon`, as typed: `claude`, `claude --continue`,
# `gemini`, or nothing (the image's CMD, a shell). The agent's name is already the first of those
# words when one was named, so it is not added again: from the split (2026-10-11, PR 1) to PR 5 this
# line passed "$AGENT" ahead of "$@", the entrypoint ran `claude claude`, and Claude Code took the
# second word as the session's first prompt, typed by nobody.
