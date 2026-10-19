#!/bin/bash
# =============================================================================
# init-firewall.sh: egress firewall for the Claude sandbox
# =============================================================================
#
# WHY THIS EXISTS
#   The container has no network isolation by construction. Under rootless podman
#   it gets a pasta network that mirrors the host's LAN address (e.g. 192.168.18.2/24),
#   and under Docker/Colima a bridge that can still route to the LAN. Without these
#   rules the agent could reach the router, the box's own ssh port, every device on
#   the LAN, Tailscale peers, and the whole internet. This script is the wall.
#
# THE POLICY, IN ONE PARAGRAPH
#   Default-deny in every direction. Outbound is allowed only to (a) the DNS
#   resolvers the container was started with, on port 53, and (b) an allowlist of
#   IP ranges built at start-up: GitHub's published ranges, plus the current A
#   records of the npm registry and the Anthropic API/login hosts. Everything else,
#   including every private/LAN range, is rejected. Inbound is allowed only for
#   replies to connections we opened. IPv6 is dropped entirely.
#
# HOW IT RUNS
#   entrypoint.sh runs this as root via sudo on every container start; that is the
#   only command the `node` user may sudo (see Dockerfile, /etc/sudoers.d/node-firewall).
#   The container needs CAP_NET_ADMIN and CAP_NET_RAW (run.sh passes them) so that
#   iptables/ipset can be applied inside the container's own network namespace.
#   The rules live in that namespace only; they never touch the host's firewall.
#
# KNOWN LIMITS (accepted, not bugs)
#   - DNS to a recursive resolver is itself a covert channel: query names can carry
#     data out to whoever owns the queried domain. In the gateway shape it is closed once the
#     self-test has passed (section 8): every name the session needs is pinned in /etc/hosts at
#     the address resolved at start, and the resolver rules are removed. In the direct shape it
#     cannot be closed and still resolve GitHub's many names, so there it stays narrowed to the
#     configured resolvers only (2026-10-19).
#   - The allowlist is a snapshot of DNS at start-up. If an allowed host's IP
#     changes mid-session, that host becomes unreachable until the container restarts; in the
#     gateway shape the same holds for the pinned names (the login hosts' token refresh).
#   - The allowlist is by IP, not by name. Anything else hosted on those IPs
#     (other GitHub repos, other npm packages, other hosts behind the same CDN
#     addresses) is reachable too. Repository scoping is done by the token, not here.
#
# TO CHANGE THE ALLOWLIST
#   Edit a list in configs/ (one host per line, purpose beside it), rebuild the image (the
#   launcher does this), restart. A named config (configs/research.hosts) is off by default
#   and turned on for one session from the host command line: `cocoon claude -- --research`.
#   Do not add hosts from inside a session; the agent must not widen its own wall.
#
# THE GATEWAY SHAPE (a `gateway` section in /etc/cocoon/sandbox.json, mounted by run.sh)
#   The allowlist is ONE address, the owner's gateway, and GitHub's ranges, the base list and
#   the named lists are not read at all: everything reaches GitHub, npm and the research hosts
#   through the gateway's subdomains, which this script maps to that address in /etc/hosts
#   (no public DNS needed). Port 443 to the address is redirected to the container's relay on
#   127.0.0.1:8443 (entrypoint.sh starts it): tools that cannot present a client certificate
#   themselves (gh, npm) talk to the relay, which carries mutual TLS to the gateway on its
#   port 8443, the one port not redirected. With the agent's own agents.<agent>.gateway.model
#   false its model host stays allowed directly; with it true the model API goes through the
#   gateway too, and true needs the agent's model upstream among the subdomains (per agent since
#   2026-10-14: one flag for both agents routed Gemini to a gateway with no Gemini upstream, and
#   its CLI hung at the prompt, 2026-10-13). The agent's login hosts (<agent>-login.hosts) stay
#   allowed directly in both shapes: the login's token refresh goes to them and does not follow
#   the model's base-URL variable.
# =============================================================================

set -euo pipefail   # Exit on any error, on unset variables, and on failures inside pipes.
IFS=$'\n\t'         # Word-split only on newlines and tabs, never on spaces.

#  A second run is refused before any rule is touched: refuses the in-session run of 2026-09-04, which flushed the wall and cut the container off
LOCKDIR="/var/run/cocoon-firewall"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "ERROR: Firewall already initialized or cannot create lock." >&2
    exit 1
fi

# The tools this script needs, declared once and checked before the first rule, as every script
# in this repository does. Every missing one is named in one line, so an image that lacks two
# says so once; a container never starts with a half-built wall.
TOOLS=(
    iptables    # the rules
    ip6tables   # the IPv6 policies (section 6)
    ipset       # the allowlist set
    jq          # the configuration and GitHub's meta JSON
    curl        # GitHub's meta endpoint and the self-test
    aggregate   # merges GitHub's ranges (section 4a)
    dig         # resolves the named hosts (section 4b) and probes the LAN gateway (section 7)
    awk         # reads resolv.conf and dig's answers
    ip          # the default route (section 7) and the IPv6 state (section 6)
    timeout     # bounds the gateway connect in the self-test
    grep        # the resolver check in the self-test
)
missing=()
for tool in "${TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: init-firewall.sh needs tools the image lacks: $(printf '%s ' "${missing[@]}")"
    exit 1
fi

# -----------------------------------------------------------------------------
# 1. Start from a clean slate
# -----------------------------------------------------------------------------
# Every container start runs this script, so flush anything left from a previous
# run (there normally isn't anything: a fresh network namespace is empty). -F flushes
# rules, -X deletes user-defined chains. nat and mangle tables are cleared for
# completeness; we never add rules to them.
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Loopback and DNS: the two things that must work before anything else
# -----------------------------------------------------------------------------
# Loopback carries local IPC (Claude Code's own sockets, dev servers on localhost).
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS is needed by this script (section 4 resolves the allowlisted hosts) and, in the direct
# shape, by the agent for the rest of the session (the model client resolves its host on every
# connection). In the gateway shape every name the session uses is pinned in /etc/hosts by
# section 4, and section 8 removes these rules once the self-test has passed (2026-10-19).
#
# Only the resolvers the container was started with are allowed. Previously this
# rule was `-p udp --dport 53` with no destination, which let the agent talk to ANY
# host on UDP 53: the LAN router answered DNS queries from inside the sandbox, and
# any public resolver on the internet was reachable. Restricting the destination
# closes the LAN side of that and reduces the exfil surface to the configured
# resolvers (under pasta that is 169.254.1.1, a forwarder to the host's resolver).
#
# TCP 53 is included because resolvers fall back to TCP for answers larger than
# 512 bytes (GitHub's records, DNSSEC).
resolvers=$(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf)
if [ -z "$resolvers" ]; then
    echo "ERROR: no nameserver in /etc/resolv.conf; refusing to open DNS to the world"
    exit 1
fi
while read -r ns; do
    # Only IPv4 dotted-quad resolvers are supported; IPv6 is dropped below anyway.
    if [[ ! "$ns" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "Skipping non-IPv4 resolver $ns"
        continue
    fi
    echo "Allowing DNS to resolver $ns"
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done < <(echo "$resolvers")

# Note what is deliberately NOT here:
#   - No `INPUT -p udp --sport 53 -j ACCEPT`. The old script had it, and it accepted
#     any inbound UDP packet whose source port happened to be 53, from anyone. DNS
#     replies are already covered by the ESTABLISHED,RELATED rule in section 5.
#   - No outbound SSH. GitHub is reached over HTTPS with a scoped token.

# -----------------------------------------------------------------------------
# 3. Reject every private and local range, before the allowlist can say yes
# -----------------------------------------------------------------------------
# This is defence in depth against the LAN. The allowlist in section 5 would already
# block these, but the allowlist is built from data we fetch over the network
# (GitHub's meta endpoint and DNS answers). If either ever returned a private
# address, by mistake, by compromise, or by DNS rebinding, the agent would gain a
# path onto the LAN. Rejecting these ranges first means the allowlist cannot open
# them no matter what it contains. The resolver rule above sits before this block
# on purpose: under pasta the resolver is 169.254.1.1, which is link-local.
#
# REJECT (not DROP) so that a connection attempt fails instantly with an error rather
# than hanging until timeout; the agent gets clear feedback that the wall is there.
PRIVATE_RANGES=(
    10.0.0.0/8         # RFC1918 private
    172.16.0.0/12      # RFC1918 private (also Docker's default bridge range)
    192.168.0.0/16     # RFC1918 private (the box's LAN lives here)
    169.254.0.0/16     # link-local (pasta's resolver is here; allowed above)
    100.64.0.0/10      # CGNAT, used by Tailscale for every peer
    224.0.0.0/4        # multicast (mDNS/SSDP device discovery)
    255.255.255.255/32 # broadcast
)
for cidr in "${PRIVATE_RANGES[@]}"; do
    iptables -A OUTPUT -d "$cidr" -j REJECT --reject-with icmp-admin-prohibited
done

# -----------------------------------------------------------------------------
# 4. Build the allowlist: GitHub ranges + resolved IPs of a few named hosts
# -----------------------------------------------------------------------------
# ipset holds the allowed destinations as a set of CIDRs so that a single iptables
# rule (section 5) can match all of them. hash:net accepts both /32 hosts and ranges.
ipset create allowed-domains hash:net

# 4g. The gateway shape: read before anything is fetched. One address in the set, the
#     subdomains mapped to it, the redirect to the relay, and sections 4a and 4b skipped
#     (4b still reads the agent's own model hosts while `model` is false).
CFG=/etc/cocoon/sandbox.json
GATEWAY=0
if [ -r "$CFG" ]; then
    # The host's check-config.sh refused a malformed section before the start. This script does
    # not lean on that: the mounted file is data, and every value is checked here before it is
    # used. The earlier form read `.gateway.upstreams[]` straight into the loop, and a missing or
    # null upstreams passed silently: jq's error inside a process substitution is not an exit
    # under set -e, so the loop mapped nothing and the start went on with no subdomain.
    gw_type=$(jq -r 'if has("gateway") then (.gateway | type) else "absent" end' "$CFG")
    case "$gw_type" in
        absent) ;;
        object) GATEWAY=1 ;;
        *) echo "ERROR: gateway in $CFG must be an object (it is $gw_type)"; exit 1 ;;
    esac
fi
if [ "$GATEWAY" = 1 ]; then
    if ! jq -e '.gateway.domain | type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")' "$CFG" >/dev/null; then
        echo "ERROR: gateway.domain must be a hostname"; exit 1
    fi
    if ! jq -e '.gateway.address | type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")' "$CFG" >/dev/null; then
        echo "ERROR: gateway.address must be an IPv4 address"; exit 1
    fi
    if ! jq -e '.gateway.upstreams | type == "array" and length > 0 and all(.[]; type == "string" and test("^[a-z][a-z0-9-]*$"))' "$CFG" >/dev/null; then
        echo "ERROR: gateway.upstreams must be a non-empty array of lowercase names (missing, null and [] refused)"; exit 1
    fi
    GW_ADDR=$(jq -r '.gateway.address' "$CFG")
    GW_DOMAIN=$(jq -r '.gateway.domain' "$CFG")
    echo "Gateway shape: $GW_DOMAIN at $GW_ADDR"
    ipset add -exist allowed-domains "$GW_ADDR"
    while IFS= read -r name; do
        echo "$GW_ADDR $name.$GW_DOMAIN" >> /etc/hosts
        echo "Mapping $name.$GW_DOMAIN to the gateway"
    done < <(jq -r '.gateway.upstreams[]' "$CFG")
    # Locally generated packets to the gateway on 443 go to the relay instead (REDIRECT rewrites
    # the destination to this host's loopback). The relay itself connects to port 8443, untouched.
    iptables -t nat -A OUTPUT -d "$GW_ADDR" -p tcp --dport 443 -j REDIRECT --to-ports 8443
    # The redirected packet reaches the filter chain with destination 127.0.0.1:8443; it is accepted here by
    # address and port, not by `-o lo`: at the first start through the gateway (2026-10-12 02:0x) the loopback
    # rule did not match it and the final REJECT answered every tool's 443 with "No route to host", while
    # 8443 direct and 127.0.0.1:8443 connected. Section 7 proves the redirect delivers.
    iptables -A OUTPUT -d 127.0.0.1 -p tcp --dport 8443 -j ACCEPT
fi

# 4a. GitHub publishes its address ranges at api.github.com/meta. We take the
#     `web`, `api`, and `git` lists (HTTPS to github.com, the REST API, and git over
#     HTTPS). Every entry is validated as an IPv4 CIDR before it is added; a
#     surprising value aborts the script and the container start.
#     `aggregate` merges overlapping/adjacent ranges to keep the set small.
#     IPv6 entries in the feed are dropped by the regex; IPv6 is blocked wholesale.
if [ "$GATEWAY" = 0 ]; then
echo "Fetching GitHub IP ranges..."
# -f: an HTTP error is a failure, not a body to parse. The 200 is not trusted either: web, api and
# git must each be a non-empty array of strings before anything is read out of them (a jq error
# inside the process substitution below would otherwise add no range and go unnoticed until the
# self-test).
gh_ranges=$(curl -fsS https://api.github.com/meta) || { echo "ERROR: Failed to fetch GitHub IP ranges (curl exit $?)"; exit 1; }
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges (empty answer)"
    exit 1
fi
if ! echo "$gh_ranges" | jq -e '[.web, .api, .git] | all(type == "array" and length > 0 and all(.[]; type == "string"))' >/dev/null 2>&1; then
    echo "ERROR: GitHub meta response: web, api and git must each be a non-empty array of strings"
    exit 1
fi
echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add -exist allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
fi

# 4b. Named hosts, resolved once now. The lists live in /usr/local/share/cocoon/configs/
#     (the repo's .devcontainer/configs/), one file per list, one host per line with its
#     purpose beside it, so the whole allowlist can be inspected in one place:
#       base.hosts        every container
#       <agent>.hosts     the agent's own model host; each container gets only its own
#       <agent>-login.hosts the agent's login and token-refresh hosts, read in every shape (empty for an API-key agent)
#       <config>.hosts    a named config the host user turns on for one session, e.g. research;
#                         off by default, chosen on the host command line, never from inside
#     Arguments: $1 the agent (claude or gemini), $2.. the configs. A missing file is an error,
#     so a typo cannot start a container with a wider or narrower wall than intended.
#     Each host is validated as a hostname and each answer as a dotted quad. Private answers
#     would be caught by section 3 anyway, but a host that fails to resolve aborts the start,
#     because starting with a partial allowlist would look like a firewall bug later.
AGENT="${1:-claude}"
case "$AGENT" in
    claude|gemini) ;;
    *) echo "ERROR: unknown agent '$AGENT' (claude or gemini)"; exit 1 ;;
esac
shift $(( $# > 0 ? 1 : 0 ))
CONFIG_DIR=/usr/local/share/cocoon/configs
DOMAINS=()
read_hosts() {
    local file="$CONFIG_DIR/$1.hosts" line host
    if [ ! -f "$file" ]; then echo "ERROR: no hosts list '$1' ($file)"; exit 1; fi
    echo "Hosts from $1.hosts:"
    while IFS= read -r line || [ -n "$line" ]; do
        host="${line%%#*}"; host="${host//[[:space:]]/}"
        [ -z "$host" ] && continue
        if [[ ! "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            echo "ERROR: '$host' in $1.hosts is not a hostname"; exit 1
        fi
        echo "  $host"
        DOMAINS+=("$host")
    done < "$file"
}
# The agent's login hosts (<agent>-login.hosts) are read in every shape: the login's token refresh goes to them
# and does not follow the model's base-URL variable, so a wall without them ends the session when the token
# expires (the first start with the model through the gateway, 2026-10-13). The model host (<agent>.hosts) is
# read until this agent's model goes through the gateway (agents.<agent>.gateway.model true), and not after.
if [ "$GATEWAY" = 0 ]; then
    read_hosts base
    read_hosts "$AGENT"
    read_hosts "$AGENT-login"
    for config in "$@"; do
        # a slash would read a file outside configs/
        if [[ "$config" == */* ]]; then
            echo "ERROR: invalid config name '$config' (path traversal attempt)" >&2
            exit 1
        fi
        read_hosts "$config"
    done
else
    # This agent's model path (agents.<agent>.gateway.model; per agent since 2026-10-14). The mounted file is
    # data, so the value is checked here as the gateway section was. True also needs the agent's model upstream
    # among the subdomains (claude: anthropic; gemini: gemini), or the model would be sent to a name the gateway
    # does not serve: on 2026-10-13 one flag for both agents did that to Gemini, and its CLI hung at the prompt
    # retrying a host this wall refused.
    case "$AGENT" in
        claude) model_upstream=anthropic ;;
        gemini) model_upstream=gemini ;;
        *) echo "ERROR: no model upstream known for agent '$AGENT'"; exit 1 ;;
    esac
    if ! jq -e --arg a "$AGENT" '.agents[$a].gateway.model | type == "boolean"' "$CFG" >/dev/null; then
        echo "ERROR: agents.$AGENT.gateway.model must be true or false"; exit 1
    fi
    GW_MODEL=$(jq -r --arg a "$AGENT" '.agents[$a].gateway.model' "$CFG")
    if [ "$GW_MODEL" = true ]; then
        if ! jq -e --arg u "$model_upstream" '.gateway.upstreams | index($u) != null' "$CFG" >/dev/null; then
            echo "ERROR: agents.$AGENT.gateway.model is true but gateway.upstreams has no $model_upstream (this agent's model upstream)"; exit 1
        fi
        echo "Model host for $AGENT: through the gateway ($model_upstream.$GW_DOMAIN)"
    else
        echo "Model host for $AGENT: direct ($AGENT.hosts)"
        read_hosts "$AGENT"
    fi
    read_hosts "$AGENT-login"
    [ $# -eq 0 ] || echo "NOTE: profiles (${*}) are ignored in the gateway shape; the research hosts are its subdomains"
fi
for domain in "${DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
        # In the gateway shape the name is pinned at this address too, so the session resolves it with no
        # DNS once section 8 has closed the resolvers (the login hosts' token refresh, the model host while
        # `model` is false); the direct shape keeps its resolvers and needs no pin.
        if [ "$GATEWAY" = 1 ]; then
            echo "$ip $domain" >> /etc/hosts
        fi
    done < <(echo "$ips")
done

# -----------------------------------------------------------------------------
# 5. Default-deny, then the two positive rules that make the sandbox usable
# -----------------------------------------------------------------------------
# Policies apply to any packet no rule matched. DROP everywhere:
#   INPUT   nothing may connect in (no listening service is reachable from the LAN)
#   FORWARD the container never routes for anyone
#   OUTPUT  nothing goes out unless a rule above or below says so
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# Replies to connections we opened (TCP handshakes, DNS answers, ICMP errors for
# our own packets) are allowed via connection tracking. This is what lets DNS
# answers in now that the blanket sport-53 rule is gone. The match is conntrack,
# the module that does the tracking; `-m state` is its legacy alias and is not used.
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# The allowlist. Any protocol/port to these destinations; the destinations are the
# constraint. Section 3 has already rejected private ranges so nothing here can
# reach the LAN.
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Everything else outbound: REJECT with an ICMP error so failures are immediate
# and obvious (a DROP would make every blocked call hang for its full timeout).
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# -----------------------------------------------------------------------------
# 6. IPv6: block it all
# -----------------------------------------------------------------------------
# The allowlist is IPv4-only, so any IPv6 route would be an unfiltered bypass.
# Today the container has only a link-local v6 address and no default v6 route,
# but that is a property of the host, not of this script, so drop v6 regardless.
# ip6tables may be unavailable if the kernel lacks v6 netfilter. Then the start goes on only
# if this namespace verifiably has no IPv6 to leak through: no global address and no default
# route, read with `ip -6` (a link-local fe80:: address alone reaches nothing past the
# segment). A namespace with either and no ip6tables aborts the start: better no session
# than an unfiltered stack. Section 7 then proves the result whichever path was taken.
if ip6tables -P OUTPUT DROP 2>/dev/null; then
    ip6tables -F
    ip6tables -P INPUT   DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT  DROP
    ip6tables -A INPUT  -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    echo "IPv6: all traffic dropped except loopback"
else
    v6_global=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6 || true)
    v6_default=$(ip -6 route show default 2>/dev/null | grep -c . || true)
    if [ "$v6_global" != 0 ] || [ "$v6_default" != 0 ]; then
        echo "ERROR: ip6tables unavailable and IPv6 is routable here ($v6_global global addresses, $v6_default default routes); refusing to start unfiltered"
        exit 1
    fi
    echo "WARNING: ip6tables unavailable; no global IPv6 address and no IPv6 default route, so nothing to filter (proved below)"
fi

# -----------------------------------------------------------------------------
# 7. Self-test: the wall must both hold and not be too high
# -----------------------------------------------------------------------------
# A failed self-test aborts the container start (set -e), which is the right
# failure mode: better no session than a session with a broken wall.
echo "Firewall configuration complete"
echo "Verifying firewall rules..."

# Must be blocked: an ordinary public site.
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Must be blocked: the same site over IPv6, whichever path section 6 took (the policies, or
# no stack to filter). curl -6 resolves the AAAA record over the allowed resolver and
# connects over IPv6 only; any failure to connect is the pass.
if curl -6 --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com over IPv6"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com over IPv6 as expected"
fi

# Must be blocked: the LAN default gateway, on the port DNS uses. This is the
# exact hole that existed before the resolver restriction; keep it tested.
gw=$(ip -4 route show default | awk '{print $3; exit}')
if [ -n "$gw" ] && ! grep -qx "$gw" <<<"$resolvers"; then
    if dig +time=2 +tries=1 @"$gw" github.com A >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - LAN gateway $gw answered DNS"
        exit 1
    else
        echo "Firewall verification passed - LAN gateway $gw unreachable on UDP 53"
    fi
fi

# Must work: GitHub directly, or the gateway's port in the gateway shape (a TCP connect; the TLS
# handshake needs the client certificate the relay holds, so the connect is what this proves).
if [ "$GATEWAY" = 1 ]; then
    # The redirect must deliver: a connect to the gateway's 443 lands on the relay's loopback port, which
    # the entrypoint has not opened yet, so the right answer is a refusal from loopback ("Connection
    # refused"), never the wall's "No route to host".
    redirect_err=$(timeout 5 bash -c "exec 3<>/dev/tcp/$GW_ADDR/443" 2>&1 || true)
    case "$redirect_err" in
        *"Connection refused"*) echo "Firewall verification passed - 443 to the gateway is redirected to the relay's port (refused there until the relay starts)" ;;
        *) echo "ERROR: Firewall verification failed - 443 to the gateway is not redirected to the relay: ${redirect_err:-connected without a relay}"; exit 1 ;;
    esac
    if timeout 5 bash -c "exec 3<>/dev/tcp/$GW_ADDR/8443" 2>/dev/null; then
        echo "Firewall verification passed - able to reach the gateway at $GW_ADDR:8443 as expected"
    else
        echo "ERROR: Firewall verification failed - unable to reach the gateway at $GW_ADDR:8443"
        exit 1
    fi
elif ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# -----------------------------------------------------------------------------
# 8. The gateway shape: no DNS after start
# -----------------------------------------------------------------------------
# Every name this session will use is known and pinned now: the six subdomains (section 4g) and the
# hosts of the lists read (section 4b wrote each resolved address into /etc/hosts beside them). The
# resolver rules of section 2 are therefore removed, and the covert channel the header names is closed
# for the rest of the session (2026-10-19). The self-test above needed them (the IPv6 and LAN checks
# resolve), so this comes last; a resolver that still answers afterwards fails the start. The direct
# shape keeps its resolvers: GitHub's names are many and its addresses come as ranges.
if [ "$GATEWAY" = 1 ]; then
    while read -r ns; do
        [[ "$ns" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || continue
        iptables -D OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
        iptables -D OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
        if dig +time=2 +tries=1 @"$ns" example.com A >/dev/null 2>&1; then
            echo "ERROR: Firewall verification failed - resolver $ns still answers after its rules were removed"
            exit 1
        fi
        echo "DNS closed: resolver $ns no longer reachable; the session's names are pinned in /etc/hosts"
    done < <(echo "$resolvers")
fi
