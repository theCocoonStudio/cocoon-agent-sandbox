#!/bin/bash
# The host-side launcher. Install ONCE, by hand, outside any repo: the launcher, then the
# configuration file beside your own dotfiles, copied from the example and filled in:
#
#   curl -fsSL https://raw.githubusercontent.com/theCocoonStudio/cocoon-agent-sandbox/main/host/cocoon-launch.sh -o ~/bin/cocoon && chmod 755 ~/bin/cocoon
#   mkdir -p ~/.config/cocoon && curl -fsSL https://raw.githubusercontent.com/theCocoonStudio/cocoon-agent-sandbox/main/examples/cocoon-ai.json -o ~/.config/cocoon/sandbox.json
#
# then start sessions with `cocoon claude` or `cocoon gemini`; `cocoon --dry` downloads
# and checks without starting anything; `cocoon --config=<path> claude` runs another
# configuration file than the default one (a leading ~ is expanded here, for shells that
# do not expand it after =). The host keeps no clone of any repo and the
# login user has no git: there is nothing of the agent's on the host to execute, and
# nothing of any repository either, not even for the configuration (the owner,
# 2026-10-11: no git on the host, so no repository there, not even the first time).
#
# Why this file exists: run.sh builds the image from sandbox/ and runs on the host as
# your user. When the host built from a working tree the agent writes, a restart executed
# unreviewed scripts twice (2026-09-03 and 2026-10-02; the owner's private records). This
# launcher downloads ONE reviewed thing from GitHub as a tarball over HTTPS, behind a
# ruleset with a required review: this library at the ref the host's configuration pins;
# it unpacks only what it runs and runs THAT run.sh with the host's configuration. The
# agent's workspace is a container volume the host never reads.
#
# Nothing here is configurable from the environment, on purpose: a change to what runs
# goes through a PR to this library, or through the one file on the host that you edit
# by hand and the validator checks before anything runs; never through a variable the
# host happens to have set. The installed copy is what runs; the copy on main is its
# reviewed source. When the two differ the launcher says so, and you decide whether to
# reinstall.
set -euo pipefail

# --- Everything this script knows, in one place ---------------------------------------------
CONFIG=~/.config/cocoon/sandbox.json  # the host's configuration, placed by hand; the only input (--config=<path> overrides)
API=https://api.github.com/repos
# Tools, and what each is for. run.sh adds openssl (the App JWT) and podman; it checks its own.
TOOLS=(
  curl   # the commit lookups and the tarball downloads
  tar    # listing and unpacking the tarballs
  jq     # the commit shas and the sandbox ref out of JSON
)
# A run.sh from before the launcher bind-mounted the host's clone; refuse it rather than
# mount a temp dir as the workspace. The marker is the mount it must NOT contain.
OLD_RUN_MARKER='"$PWD":/workspace'

for tool in "${TOOLS[@]}"; do
  command -v "$tool" >/dev/null || { echo "launcher: '$tool' is required" >&2; exit 1; }
done

DRY=0
while [ $# -gt 0 ]; do   # the launcher's own options come first; the rest is the agent, its args and the profiles
  case "$1" in
    --dry) DRY=1; shift ;;
    --config=*) CONFIG=${1#--config=}; CONFIG=${CONFIG/#\~/$HOME}; shift ;;
    --config) echo "launcher: use --config=<path> (with the =); --config <name> after -- is a profile for the sandbox" >&2; exit 1 ;;
    *) break ;;
  esac
done

[ -r "$CONFIG" ] || { echo "launcher: no configuration at $CONFIG; copy examples/cocoon-ai.json from the sandbox repository there and fill it in" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One reviewed tarball: the commit a ref points at, for the record, then that commit's archive,
# unpacked only as far as $3. Public repos: no credential; the download follows GitHub's redirect.
fetch() { # fetch <owner/repo> <ref> <path within the repo> -> prints <dir of the unpacked path>
  local slug=$1 ref=$2 path=$3 sha top
  sha=$(curl -fsSL -H "Accept: application/vnd.github+json" "$API/$slug/commits/$ref" | jq -r .sha)
  curl -fsSL "$API/$slug/tarball/$sha" -o "$tmp/$sha.tgz"
  top=$(tar -tzf "$tmp/$sha.tgz" | awk -F/ 'NR == 1 { print $1 }')   # <owner>-<repo>-<sha7>; awk reads to the end, so pipefail stays quiet
  case "$sha" in "${top##*-}"*) ;; *) echo "launcher: archive $top does not match commit $sha" >&2; exit 1 ;; esac
  tar -xzf "$tmp/$sha.tgz" -C "$tmp" "$top/$path"
  echo "launcher: $slug@$ref is $sha" >&2
  printf '%s' "$tmp/$top/$path"
}

config=$CONFIG
sandbox_repo=$(jq -r '.sandbox.repo' "$config")
sandbox_ref=$(jq -r '.sandbox.ref' "$config")
[ -n "$sandbox_repo" ] && [ "$sandbox_repo" != null ] && [ -n "$sandbox_ref" ] && [ "$sandbox_ref" != null ] || { echo "launcher: $CONFIG names no sandbox.repo and sandbox.ref" >&2; exit 1; }
dc=$(fetch "$sandbox_repo" "$sandbox_ref" sandbox)
host=$(fetch "$sandbox_repo" "$sandbox_ref" host)

if grep -qF "$OLD_RUN_MARKER" "$dc/run.sh"; then
  echo "launcher: $sandbox_ref's run.sh predates the launcher (it mounts the host's clone); use a newer ref" >&2; exit 1
fi
if ! cmp -s "$host/cocoon-launch.sh" "$(readlink -f "$0")"; then
  echo "launcher: NOTE this installed launcher differs from $sandbox_ref's copy; reinstall it after reviewing the diff" >&2
fi

echo "launcher: running $sandbox_repo@$sandbox_ref's sandbox with $config"
if [ "$DRY" = 1 ]; then ls "$dc"; exec bash "$dc/run.sh" --dry "$config" "$@"; fi

exec bash "$dc/run.sh" "$config" "$@"
