#!/bin/bash
# The host-side launcher, run by a login user who is not a sudoer: with rootless podman and
# the user's id kept, the container's user IS this host user, so a breakout must find nothing
# to elevate with. Nothing here needs sudo and nothing asks for it. Install ONCE, by hand,
# outside any repo: the configuration file
# beside your own dotfiles, copied from the example and filled in, then one download of
# this script and one run of it:
#
#   mkdir -p ~/.config/cocoon && curl -fsSL https://raw.githubusercontent.com/theCocoonStudio/cocoon-agent-sandbox/main/examples/cocoon-ai.json -o ~/.config/cocoon/sandbox.json
#   curl -fsSL https://raw.githubusercontent.com/theCocoonStudio/cocoon-agent-sandbox/main/host/cocoon-launch.sh -o cocoon-launch.sh && bash cocoon-launch.sh --dry
#
# With `command.install` true in the file (the example has it) that run puts this script on
# your PATH as `cocoon`, in the directory the platform expects (below). Then start sessions
# with `cocoon claude` or `cocoon gemini`; `cocoon --dry` downloads
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
# shellcheck disable=SC2016  # the literal text of the old mount line, $PWD included; nothing to expand
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

# --- The command on this host, when the configuration asks for it ----------------------------
# `command.install: true` puts this launcher on the PATH as `cocoon`, so the install is one
# download and one run. Where, unless `command.bin` says: Linux ~/.local/bin (the XDG place,
# a Linux convention; Debian and Fedora put it on the PATH when it exists); macOS has no
# user-writable directory on its default PATH except Homebrew's prefix, which depends on the
# architecture, /opt/homebrew/bin on Apple silicon and /usr/local/bin on Intel; without a
# writable one the launcher refuses to guess and asks for `command.bin`. The installed copy
# never rewrites itself: only a launcher run from elsewhere (a fresh download) installs, so
# the running copy is the one you reviewed and reinstalling stays your decision. The script's
# own path is resolved with cd and pwd -P, not GNU readlink -f, which macOS lacked until 12.3.
self=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
if [ "$(jq -r '.command.install // false' "$CONFIG")" = true ]; then
  bin=$(jq -r '.command.bin // empty' "$CONFIG"); bin=${bin/#\~/$HOME}
  if [ -z "$bin" ]; then
    case "$(uname -s)/$(uname -m)" in
      Darwin/arm64) bin=/opt/homebrew/bin ;;
      Darwin/*)     bin=/usr/local/bin ;;
      *)            bin=$HOME/.local/bin ;;
    esac
    if [ "$(uname -s)" = Darwin ] && ! { [ -d "$bin" ] && [ -w "$bin" ]; }; then
      echo "launcher: $bin (Homebrew's prefix for this architecture) is not writable here; set command.bin in $CONFIG to a directory on your PATH" >&2; exit 1
    fi
  fi
  if [ "$self" != "$bin/cocoon" ]; then
    mkdir -p -- "$bin"
    if ! { [ -f "$bin/cocoon" ] && cmp -s -- "$self" "$bin/cocoon"; }; then
      cp -- "$self" "$bin/cocoon" && chmod 755 -- "$bin/cocoon"
      echo "launcher: installed as $bin/cocoon" >&2
    fi
    case ":$PATH:" in *":$bin:"*) ;; *) echo "launcher: NOTE $bin is not on your PATH; add it, or call $bin/cocoon" >&2 ;; esac
  fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

# One reviewed tarball: the commit a ref points at, for the record, then that commit's archive,
# unpacked only as far as $3. Public repos: no credential; the download follows GitHub's redirect.
fetch() { # fetch <owner/repo> <ref> <path within the repo> -> prints <dir of the unpacked path>
  local slug=$1 ref=$2 path=$3 sha top
  # A 200 is not trusted to carry a commit: the sha is taken only if it is a 40-digit hex string, and
  # checked again after the pipe (an empty answer would make the tarball URL the default branch's).
  sha=$(curl -fsSL -H "Accept: application/vnd.github+json" "$API/$slug/commits/$ref" \
        | jq -r 'if (.sha | type == "string" and test("^[0-9a-f]{40}$")) then .sha else error("no commit sha in the response") end')
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "launcher: $slug@$ref: the commit lookup did not return a commit sha" >&2; exit 1; }
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
if ! { [ -n "$sandbox_repo" ] && [ "$sandbox_repo" != null ] && [ -n "$sandbox_ref" ] && [ "$sandbox_ref" != null ]; }; then
  echo "launcher: $CONFIG names no sandbox.repo and sandbox.ref" >&2; exit 1
fi
dc=$(fetch "$sandbox_repo" "$sandbox_ref" sandbox)
host=$(fetch "$sandbox_repo" "$sandbox_ref" host)

if grep -qF "$OLD_RUN_MARKER" "$dc/run.sh"; then
  echo "launcher: $sandbox_ref's run.sh predates the launcher (it mounts the host's clone); use a newer ref" >&2; exit 1
fi
if ! cmp -s "$host/cocoon-launch.sh" "$self"; then
  echo "launcher: NOTE this installed launcher differs from $sandbox_ref's copy; reinstall it after reviewing the diff" >&2
fi

echo "launcher: running $sandbox_repo@$sandbox_ref's sandbox with $config"
if [ "$DRY" = 1 ]; then ls "$dc"; exec bash "$dc/run.sh" --dry "$config" "$@"; fi

exec bash "$dc/run.sh" "$config" "$@"
