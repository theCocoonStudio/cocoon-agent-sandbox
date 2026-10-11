# cocoon-agent-sandbox

A sealed devcontainer for coding agents, Claude Code and Gemini CLI today: default-deny egress with an allowlist, no credential inside the container, every value hardcoded and changed by pull request, and a host that runs only what is on `main`. Split out of [cocoon-ai](https://github.com/theCocoonStudio/cocoon-ai) on 2026-10-11 after six weeks of daily use; the history of how each layer came to exist is in that repo and in a private records repo.

## What it is for

An agent with a shell, a toolchain and GitHub access can do a great deal of good and a great deal of harm. This container gives it the first and bounds the second: it sees one repository, reaches the hosts on a list and nothing else, acts on GitHub as its own bot user through a short-lived token, and cannot touch the machine it runs on. Review is the last layer and the only one that is not automated.

## The layers

Each is a precondition for the one after it. Each has its reason in the header of the file that implements it.

1. **The box.** A dedicated machine whose login user cannot elevate and has no git. Nothing of the owner's lives there except the GitHub App's private key and the launcher. Rootless podman, so there is no privileged daemon in the path and container root is an unprivileged subordinate uid on the host.
2. **The launcher** (`host/cocoon-launch.sh`). Installed once by hand outside any repo. It downloads `main` of this repo as a tarball over HTTPS, unpacks only `sandbox/`, and runs that `run.sh`, which builds the image from its own directory. The agent's working tree is a container volume the host never reads. Why: twice, a host that built from a tree the agent could write executed unreviewed sandbox scripts at a restart. The reviewed `main` is now the only thing that runs.
3. **The identity** (`sandbox/run.sh`). The agent acts on GitHub as a bot user through a GitHub App. `run.sh` signs a short-lived JWT with the App's key on the host, exchanges it for a one-hour installation token, and passes only that token into the container. The key never enters the sandbox; the token lives in one process's environment and is written nowhere. One App per agent, so a review by one is never mistakable for the other's.
4. **The container** (`sandbox/Dockerfile`, `sandbox/entrypoint.sh`). Node on Debian, a non-root user, the agent CLIs pinned by version, npm lifecycle scripts off, the workspace and the agent's own state in named volumes. The entrypoint clones the repositories on first start, runs the firewall, and hands over to the agent. Its one sudo right is the firewall script.
5. **The wall** (`sandbox/init-firewall.sh`, `sandbox/configs/*.hosts`). Default-deny in every direction inside the container's own network namespace: outbound only to the resolvers the container was started with and to an allowlist built at start from GitHub's published ranges and the current addresses of the hosts on the lists; every private, link-local and multicast range rejected before the allowlist; IPv6 dropped; inbound only for replies. `base.hosts` is for every container, each agent gets only its own model and login hosts, and named lists such as `research.hosts` are off by default and turned on for one session from the host command line.
6. **The hooks** (`hooks/`). Session-start hooks for the agent: one reports which pinned CLI has a newer release on npm, so a bump is a pull request with the changelog read; one wakes the agent before the token expires.

## Install and run

On the box, once, by hand:

```
curl -fsSL https://raw.githubusercontent.com/theCocoonStudio/cocoon-agent-sandbox/main/host/cocoon-launch.sh -o ~/bin/cocoon && chmod 755 ~/bin/cocoon
```

Then `cocoon claude` or `cocoon gemini` starts a session as that agent's bot user; `cocoon claude -- --research` turns a named hosts list on for that session; `cocoon --dry` downloads and checks without starting anything. The launcher compares its installed copy with the one on `main` and says so when they differ; reinstalling is your decision.

An admin with git may run `sandbox/run.sh` from a checkout they have reviewed. The login user has no git, on purpose.

## Configuration

One file, `cocoon-sandbox.json`, held by the consuming repository and reviewed there by pull request; [`examples/cocoon-ai.json`](examples/cocoon-ai.json) is cocoon-ai's. It names the sandbox to run (this repository and a ref to pin), the image, the account the agents' Apps are installed on, the workspace repository, the repositories cloned beside it, the profiles the host user may turn on for a session, and one profile per agent: the App's id and the host path of its key, the bot user and its id, the container and volume names, an optional tokens file read one line at a time and never sourced, and the environment set for that agent, each line a reviewed decision.

The launcher downloads the consuming repository's `main` for the file and this library at the ref the file pins, both over HTTPS behind their rulesets, and runs that `run.sh` with that file; the container gets the file mounted read-only at `/etc/cocoon/sandbox.json`, where the entrypoint reads the repositories to clone. Nothing is read from the environment. `sandbox/check-config.sh` validates the file with jq alone before anything runs: a wrong version, a missing key or a key nobody reads is refused with the problem named; [`schema/sandbox.schema.json`](schema/sandbox.schema.json) is the same contract for tools that speak JSON Schema. An absent `clones`, `profiles` or `env` means none: the strictest container is the one you get by saying nothing.

`run.sh --dry <config> [agent]` prints what would run, mints nothing and starts nothing; `tests/check-config.test.sh` runs the validator's cases and the dry runs.

The hosts lists stay files under `sandbox/configs/` for now, one per agent and per profile, baked into the image; moving them into the configuration is the next step, together with the gateway described under Next.

## The protocol

The rules the files follow, each learned the hard way:

- **Nothing from the environment.** Every value is hardcoded and changed by pull request, so what runs is always what was reviewed.
- **Strictest first.** The image ships the strictest settings; an override is a pull request to the configuration, never a flag for convenience. A gate that blocks a run stops the run; it is not lowered.
- **Tools declared once.** Each shell script opens with the list of tools it needs and why, and checks them.
- **Pinned, with a watch.** The agent CLIs are pinned by version; the hook reports newer releases; a bump is a reviewed change with the changelog read and the advisories checked.
- **Every security line explained.** A line that cannot be explained does not ship. The headers of the scripts are the explanations.

## Known limits

Stated because an allowlist that cannot name them is a false comfort.

- DNS to a recursive resolver is a covert channel: query names can carry data to whoever owns the queried domain. The wall cannot close this and still resolve names.
- The allowlist is by address. A host on a shared CDN edge admits every other site that edge serves for the life of the container; `research.hosts` states this beside the hosts it affects. Narrowing by name needs a TLS-terminating proxy, which is the gateway described under Next.
- The installation token lives one hour. A session that outlives it loses GitHub access until the next start.
- The agent's own account may bring tools of its own into the session that no file here declares; the owner accepts or refuses them at the account, not here.

## Next

- **This repository's own CI** building the image and running the validator's tests and the firewall's self-checks, once Actions can be added; the hosts lists into the configuration.
- **A dependency check on a schedule** for every deployed repository: the lockfile against the advisory databases, by CVSS score, reported before anyone asks.
- **A gateway.** One host in the wall instead of a list: the owner's own API gateway, one subdomain per upstream, the GitHub API wrapped with a policy table that refuses what the rules forbid, a client certificate to get in and a token for access, and no credential of any kind inside the container. The wall then shrinks to one address and the token's hour disappears.

## License

MIT.
