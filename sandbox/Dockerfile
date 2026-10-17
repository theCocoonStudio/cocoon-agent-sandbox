# Sandbox for running Claude Code against this repo.
# Based on anthropics/claude-code/.devcontainer, trimmed to what we need.
FROM node:22

ARG TZ=America/New_York
ENV TZ="$TZ"
# Pinned; bump on purpose, with the changelog read. 2.1.287 was the image's version on 2026-10-02; 2.1.288 on 2026-10-03; 2.1.289 on 2026-10-05, changelog read;
# 2.1.296 on 2026-10-11 (the bump cocoon-ai took on 2026-10-10 in its PR #73, changelog 2.1.290 to 2.1.296 read there; the split of
# 2026-10-11 copied the older pin; GitHub's advisory database lists 28 advisories for @anthropic-ai/claude-code, every one patched at or
# before 2.1.163, none affecting 2.1.296; npm's latest tag is 2.1.296, published 2026-10-10).
ARG CLAUDE_CODE_VERSION=2.1.296
# Pinned the same way; 0.62.0 audited 2026-10-02 (clean, Apache-2.0, one bundle, no runtime dependencies);
# 0.63.0 on 2026-10-11 (cocoon-ai's PR #73 of 2026-10-10: release notes read there, fixes only; the one advisory in GitHub's database,
# GHSA-wpqr-6v78-jr5g, affects versions below 0.39.1; npm's latest tag is 0.63.0, published 2026-10-06, 5 days old).
ARG GEMINI_CLI_VERSION=0.63.0

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git gh jq less nano procps sudo \
  iptables ipset iproute2 dnsutils aggregate \
  chromium \
  python3-numpy \
  shellcheck python3-pyflakes \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
# chromium: the headless browser `npm run export:logo-group` screenshots its
# WebGL render with (SwiftShader, no GPU), driven by puppeteer-core from npm.
# Nothing else in the sandbox uses it.
# shellcheck: the shell linter, so the agent lints every script before it is committed
# (tests/lint.sh) and every Bash command before it runs; from Debian, no third-party check.
# python3-pyflakes: the Python linter for cocoon-ml (undefined names, unused imports: the
# errors Python raises only when the path runs, hours into a cell); Debian's 2.5.0, the
# version cocoon-ml's CI pins, so the agent and the runner agree.
# python3-numpy: Debian's numpy, for cocoon-ml's in-context apparatus at the
# derived model size (a cell takes hours on the scalar autograd and minutes on
# arrays). From Debian, not PyPI, so no new host and no third-party check under
# the installs rule; merging this line is the decision the cocoon-ml README
# reserves for Izzy (standard library until a GPU is needed).

# Global npm installs go somewhere the non-root user owns.
RUN mkdir -p /usr/local/share/npm-global && chown -R node:node /usr/local/share
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

RUN mkdir -p /workspace /home/node/.claude /home/node/.gemini /home/node/cocoon-ai-records \
  && chown -R node:node /workspace /home/node/.claude /home/node/.gemini /home/node/cocoon-ai-records
WORKDIR /workspace

ENV DEVCONTAINER=true
ENV EDITOR=nano VISUAL=nano

# Firewall script may be run via sudo by `node`, and nothing else.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY configs/ /usr/local/share/cocoon/configs/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Gemini CLI system settings, read before the user's own and root-owned, so the agent cannot
# change them. Each line is a gate kept or a leak closed; none is a convenience:
#   general.enableAutoUpdate false      the pin above is the update; nothing updates itself
#   privacy.usageStatisticsEnabled false its telemetry host (play.googleapis.com) is outside the firewall too
#   security.auth.selectedType          API-key auth, the one mode whose only host is in the allowlist
#   tools.allowed                       the ten file, shell and memory tools run without a prompt (the owner,
#                                       2026-10-16: the prompt was theirs to answer at every command, and the
#                                       agent had started widening its own user-level settings and policies
#                                       to stop it; this file is the system level, above the user's and the
#                                       workspace's in the CLI's precedence (its 0.63.0 bundle: settings.json
#                                       here overrides ~/.gemini/settings.json and .gemini/settings.json), so
#                                       the decision is the repository's, reviewed, and not the agent's).
#                                       What refuses inside the sandbox is the wall, the gateway's policy and
#                                       the rulesets, not this prompt; the web tools (web_fetch,
#                                       google_web_search) are not listed and still prompt.
# Folder trust stays ON (the CLI's default): an untrusted folder's own settings, hooks and
# extensions are ignored and auto-approval may not edit there. The first `cocoon gemini`
# asks once to trust /workspace; the answer lives in the gemini config volume.
COPY gemini-settings.json /etc/gemini-cli/settings.json
RUN chmod 0755 /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
  && echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall

USER node
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
  @google/gemini-cli@${GEMINI_CLI_VERSION}
# After the global installs: the agent's npm never runs a package's install scripts.
# The repo's lockfile needs none (checked 2026-10-02); a dependency that does is a
# deliberate, reviewed exception, not a default.
RUN npm config set ignore-scripts true

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]

# The relay to the owner's gateway (gateway shape; entrypoint.sh starts it): the one process holding the client certificate.
COPY gateway-relay.mjs /usr/local/share/cocoon/gateway-relay.mjs
