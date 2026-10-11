# cocoon-agent-sandbox

A sealed devcontainer for coding agents, Claude Code and Gemini CLI today: default-deny egress with an allowlist, no credential inside the container, every value hardcoded and changed by pull request, and a host that runs only what is on `main`. Split out of [cocoon-ai](https://github.com/theCocoonStudio/cocoon-ai) on 2026-10-11 after six weeks of daily use; the history of how each layer came to exist is in that repo and in a private records repo.

## What it is for

An agent with a shell, a toolchain and GitHub access can do a great deal of good and a great deal of harm. This container gives it the first and bounds the second: it sees one repository, reaches the hosts on a list and nothing else, acts on GitHub as its own bot user through a short-lived token, and cannot touch the machine it runs on. Review is the last layer and the only one that is not automated.

## The layers

Each is a precondition for the one after it. Each has its reason in the header of the file that implements it.

1. **The box.** A dedicated machine whose login user is not a sudoer (no sudo, and no group that elevates: wheel, admin, docker) and has no git. Why the first: under rootless podman with the user's id kept, the container's user IS that host user, so a namespace breakout lands as them and must find nothing to elevate with. Nothing of the owner's lives there except the GitHub App's private key and the launcher. Rootless podman, so there is no privileged daemon in the path and container root is an unprivileged subordinate uid on the host.
2. **The launcher** (`host/cocoon-launch.sh`). Installed once by hand outside any repo, with the configuration file beside the host's own dotfiles. It downloads this repo as a tarball over HTTPS at the ref the configuration pins, unpacks only `sandbox/` and `host/`, and runs that `run.sh` with that configuration; `run.sh` builds the image from its own directory. The agent's working tree is a container volume the host never reads, and no repository is ever on the host, not even for the configuration. Why: twice, a host that built from a tree the agent could write executed unreviewed sandbox scripts at a restart. A reviewed ref is now the only thing that runs.
3. **The identity** (`sandbox/run.sh`). The agent acts on GitHub as a bot user through a GitHub App. `run.sh` signs a short-lived JWT with the App's key on the host, exchanges it for a one-hour installation token, and passes only that token into the container. The key never enters the sandbox; the token lives in one process's environment and is written nowhere. One App per agent, so a review by one is never mistakable for the other's.
4. **The container** (`sandbox/Dockerfile`, `sandbox/entrypoint.sh`). Node on Debian, a non-root user, the agent CLIs pinned by version, npm lifecycle scripts off, the workspace and the agent's own state in named volumes. The entrypoint clones the repositories on first start, runs the firewall, and hands over to the agent. Its one sudo right is the firewall script.
5. **The wall** (`sandbox/init-firewall.sh`, `sandbox/configs/*.hosts`). Default-deny in every direction inside the container's own network namespace: outbound only to the resolvers the container was started with and to an allowlist built at start from GitHub's published ranges and the current addresses of the hosts on the lists; every private, link-local and multicast range rejected before the allowlist; IPv6 dropped; inbound only for replies. `base.hosts` is for every container, each agent gets only its own model and login hosts, and named lists such as `research.hosts` are off by default and turned on for one session from the host command line.
6. **The hooks** (`hooks/`). Session-start hooks for the agent: one reports which pinned CLI has a newer release on npm, so a bump is a pull request with the changelog read; one wakes the agent before the token expires.

## Install and run

On the host, once, by hand, as the user that will run the sessions, who must not be a sudoer (the box, above); nothing below needs sudo, and the launcher never asks for it: the configuration file, then one download of the launcher and one run of it.

```
mkdir -p ~/.config/cocoon && curl -fsSL https://raw.githubusercontent.com/theCocoonStudio/cocoon-agent-sandbox/main/examples/cocoon-ai.json -o ~/.config/cocoon/sandbox.json
curl -fsSL https://raw.githubusercontent.com/theCocoonStudio/cocoon-agent-sandbox/main/host/cocoon-launch.sh -o cocoon-launch.sh && bash cocoon-launch.sh --dry
```

Edit `~/.config/cocoon/sandbox.json` first: the account, the workspace repository, the App ids and key paths, the clones. The launcher refuses to start without it. With `command.install` true in the file (the example has it), that first run puts the launcher on your PATH as `cocoon`: on Linux in `~/.local/bin`, the XDG place, which Debian and Fedora put on the PATH when it exists; on macOS in Homebrew's prefix for the architecture, `/opt/homebrew/bin` on Apple silicon and `/usr/local/bin` on Intel, the one user-writable directory on a Mac's default PATH, and without a writable one the launcher refuses to guess and asks for `command.bin`, which names the directory on either platform. The launcher says so when the directory is not on your PATH. The installed `cocoon` never rewrites itself; a newer download run by hand replaces it, which is reinstalling, your decision after reading the diff the launcher reports.

Then `cocoon claude` or `cocoon gemini` starts a session as that agent's bot user; `cocoon claude -- --research` turns a named hosts list on for that session; `cocoon --dry` downloads and checks without starting anything; `cocoon --config=<path> claude` runs another configuration file (the `=` form only; `--config <name>` after `--` is a profile for the sandbox). The launcher compares its installed copy with the one at the pinned ref and says so when they differ.

An admin with git may run `sandbox/run.sh` from a checkout they have reviewed. The login user has no git and no sudo, on purpose.

## Configuration

One file on the host, `~/.config/cocoon/sandbox.json`, placed and edited by hand like the launcher itself and never inside a repository (the host has no git, so no repository belongs there, not even for one file); [`examples/cocoon-ai.json`](examples/cocoon-ai.json) is cocoon-ai's, the template to copy. It names the sandbox to run (this repository and a ref to pin), whether the launcher installs itself as the `cocoon` command and where (`command`), the image, the account the agents' Apps are installed on, the workspace repository, the repositories cloned beside it, the profiles the host user may turn on for a session, and one profile per agent: the App's id and the host path of its key, the bot user and its id, the container and volume names, an optional tokens file read one line at a time and never sourced, and the environment set for that agent, each line a reviewed decision.

The launcher reads the file, downloads this library at the ref the file pins, over HTTPS behind this repository's ruleset, and runs that `run.sh` with that file; the container gets the file mounted read-only at `/etc/cocoon/sandbox.json`, where the entrypoint reads the repositories to clone. Nothing is read from the environment. `sandbox/check-config.sh` validates the file with jq alone before anything runs: a wrong version, a missing key or a key nobody reads is refused with the problem named; [`schema/sandbox.schema.json`](schema/sandbox.schema.json) is the same contract for tools that speak JSON Schema. An absent `clones`, `profiles` or `env` means none: the strictest container is the one you get by saying nothing.

`run.sh --dry <config> [agent]` prints what would run, mints nothing and starts nothing; `tests/check-config.test.sh` runs the validator's cases and the dry runs.

The hosts lists stay files under `sandbox/configs/` for now, one per agent and per profile, baked into the image; moving them into the configuration is the next step, together with the gateway described under Next.

## What checks what

- **`check`** (`.github/workflows/check.yml`), on every pull request and on `main`: the lint (`tests/lint.sh`: ShellCheck with [`.shellcheckrc`](.shellcheckrc) over every script, each enabled check a class of mistake we made, plus the classes a linter cannot see as greps: a recursive delete on a variable path without `${var:?}`, `cherry-pick -q`, a script without `pipefail`), the configuration contract's tests and every script's syntax, and, as the second job `image`, the image built from `sandbox/` as `run.sh` builds it, then the entrypoint started in it with the firewall's two capabilities so the firewall's self-test decides: an ordinary public site unreachable, the gateway deaf on UDP 53, GitHub reachable. Made required statuses in the main ruleset, the check passes is a fact on the PR page.
- **`reviewer-policy`** (`.github/workflows/reviewer-policy.yml`): who may approve whose PR, as a status rather than a habit. The owner's PRs need the agent's approval; the agent's need the owner's; a second agent's approval satisfies nobody's. The file is code-owned, so a PR cannot rewrite the policy that judges it.
- **`dependency-check`** (`.github/workflows/dependency-check.yml`), weekly and on demand: each pinned CLI against GitHub's advisory database and the registry's newest release, red on an advisory against a pin. The owner's rule for every deployed repository; the hook does the same at session start for the agent.

## The protocol

The rules the files follow, each learned the hard way:

- **Nothing from the environment.** Every value is hardcoded and changed by pull request, so what runs is always what was reviewed.
- **Strictest first.** The image ships the strictest settings; an override is a pull request to the configuration, never a flag for convenience. A gate that blocks a run stops the run; it is not lowered.
- **Tools declared once.** Each shell script opens with the list of tools it needs and why, and checks them.
- **Pinned, with a watch.** The agent CLIs are pinned by version; the hook reports newer releases; a bump is a reviewed change with the changelog read and the advisories checked.
- **Every security line explained.** A line that cannot be explained does not ship. The headers of the scripts are the explanations.
- **Nothing unlinted.** Every script passes `tests/lint.sh` before it is committed, and CI refuses what does not; a new class of mistake becomes a rule there the day it is found (Izzy, 2026-10-11: "we never write unlinted code"). Scripts are bash, never zsh: ShellCheck does not read zsh, and bash is on every Linux and on macOS (3.2 there; the launcher stays within it, `run.sh` needs 4 or newer).

## Known limits

Stated because an allowlist that cannot name them is a false comfort.

- DNS to a recursive resolver is a covert channel: query names can carry data to whoever owns the queried domain. The wall cannot close this and still resolve names.
- The allowlist is by address. A host on a shared CDN edge admits every other site that edge serves for the life of the container; `research.hosts` states this beside the hosts it affects. Narrowing by name needs a TLS-terminating proxy, which is the gateway described under Next.
- The installation token lives one hour. A session that outlives it loses GitHub access until the next start.
- The agent's own account may bring tools of its own into the session that no file here declares; the owner accepts or refuses them at the account, not here.
- The launcher is written for Linux and macOS and has run on Linux; `run.sh` has run on Debian only. On macOS podman needs a machine, and two GNU forms in `run.sh` (`stat -c`, `readlink -f`) have BSD counterparts not yet written in.

## Next

- **The hosts lists into the configuration**, so the whole wall is one reviewed file; the image's self-check run on the runner against the sandbox's own network rules, not only the firewall's self-test.
- **A gateway.** One host in the wall instead of a list: the owner's own API gateway, one subdomain per upstream, the GitHub API wrapped with a policy table that refuses what the rules forbid, a client certificate to get in and a token for access, and no credential of any kind inside the container. The wall then shrinks to one address and the token's hour disappears. Its repository is [cocoon-gateway](https://github.com/theCocoonStudio/cocoon-gateway).

## License

MIT.
