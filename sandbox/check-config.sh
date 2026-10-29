#!/bin/bash
# Validates a configuration file against what run.sh and the entrypoint read (schema/sandbox.schema.json
# is the same contract for tools that speak JSON Schema). Unknown keys are refused: a key nobody reads
# is a decision nobody reviewed. Usage: check-config.sh <config.json>; exit 1 with every problem listed.
set -uo pipefail
CONFIG=${1:?config.json}
command -v jq >/dev/null || { echo "check-config: jq is required" >&2; exit 1; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "check-config: $CONFIG is not valid JSON" >&2; exit 1; }
problems=$(jq -r '
  . as $root |
  def keys_only($allowed): [keys[] | select(. as $k | $allowed | index($k) | not)];
  def req($o; $names): [$names[] | . as $n | select(($o | has($n)) | not)];
  [
    (if .version != 1 then "version must be 1" else empty end),
    (keys_only(["version","sandbox","command","image","account","workspace","clones","profiles","agents","gateway"])[] | "unknown top-level key: " + .),
    (req(.; ["sandbox","image","account","workspace","agents"])[] | "missing: " + .),
    (if (.sandbox|type) == "object" then
       (.sandbox | keys_only(["repo","ref"])[] | "unknown key in sandbox: " + .),
       (req(.sandbox; ["repo","ref"])[] | "missing in sandbox: " + .)
     else "sandbox must be an object" end),
    (if has("command") then
       (if (.command|type) != "object" then "command must be an object" else
          (.command | keys_only(["install","bin"])[] | "unknown key in command: " + .),
          (if (.command | has("install")) and ((.command.install|type) != "boolean") then "command.install must be true or false" else empty end),
          (if (.command | has("bin")) and ((.command.bin|type) != "string") then "command.bin must be a string" else empty end)
        end)
     else empty end),
    (if (.workspace|type) == "object" then
       (.workspace | keys_only(["repo"])[] | "unknown key in workspace: " + .),
       (req(.workspace; ["repo"])[] | "missing in workspace: " + .)
     else "workspace must be an object" end),
    (if has("gateway") then
       (if (.gateway|type) != "object" then "gateway must be an object" else
          (.gateway | keys_only(["domain","address","upstreams","ca","host"])[] | "unknown key in gateway: " + .),
          (req(.gateway; ["domain","address","upstreams","ca","host"])[] | "missing in gateway: " + .),
          (if (.gateway | has("host")) then
             (if (.gateway.host|type) != "object" then "gateway.host must be an object (the launcher'"'"'s box role: cert, key, token)" else
                (.gateway.host | keys_only(["cert","key","token"])[] | "unknown key in gateway.host: " + .),
                (req(.gateway.host; ["cert","key","token"])[] | "missing in gateway.host: " + .),
                (.gateway.host | to_entries[] | select((.value|type) != "string") | "gateway.host." + .key + " must be a string path")
              end)
           else empty end),
          (if (.gateway | has("domain")) and (((.gateway.domain|type) != "string") or ((.gateway.domain | test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")) | not)) then "gateway.domain must be a hostname" else empty end),
          (if (.gateway | has("address")) and (((.gateway.address|type) != "string") or ((.gateway.address | test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")) | not)) then "gateway.address must be an IPv4 address" else empty end),
          (if (.gateway | has("upstreams")) and (((.gateway.upstreams|type) != "array") or ((.gateway.upstreams|length) == 0) or ([.gateway.upstreams[] | select((type != "string") or (test("^[a-z][a-z0-9-]*$") | not))] | length) > 0) then "gateway.upstreams must be a non-empty array of lowercase names" else empty end),
          (if (.gateway | has("ca")) and ((.gateway.ca|type) != "string") then "gateway.ca must be a string" else empty end)
        end)
     else empty end),
    (if has("clones") and ((.clones|type) != "array" or ([.clones[] | select(type != "string")] | length) > 0) then "clones must be an array of strings" else empty end),
    (if has("profiles") and ((.profiles|type) != "array" or ([.profiles[] | select((type != "string") or (test("^[a-z][a-z0-9-]*$") | not))] | length) > 0) then "profiles must be an array of lowercase names" else empty end),
    (if (.agents|type) != "object" or (.agents|length) == 0 then "agents must be an object with at least one agent" else
       (.agents | keys_only(["claude","gemini"])[] | "unknown agent: " + .),
       (.agents | to_entries[] | .key as $a | .value |
          (keys_only(["app_id","key","bot","bot_id","container","workspace_volume","config_volume","tokens_file","env","gateway"])[] | "unknown key in agents." + $a + ": " + .),
          (req(.; ["app_id","key","bot","bot_id","container","workspace_volume","config_volume"])[] | "missing in agents." + $a + ": " + .),
          (if ($root | has("gateway")) and (has("gateway") | not) then "agents." + $a + ".gateway is required when gateway is configured (cert, key, token)" else empty end),
          (if (($root | has("gateway")) | not) and has("gateway") then "agents." + $a + ".gateway is set but no gateway is configured" else empty end),
          (if has("gateway") then
             (if (.gateway|type) != "object" then "agents." + $a + ".gateway must be an object" else
                ({"claude": "anthropic", "gemini": "gemini"}[$a]) as $up |
                (.gateway | keys_only(["cert","key","token","model"])[] | "unknown key in agents." + $a + ".gateway: " + .),
                (req(.gateway; ["cert","key","token","model"])[] | "missing in agents." + $a + ".gateway: " + .),
                ([.gateway | to_entries[] | select(.key != "model" and (.value|type) != "string")] | if length > 0 then "agents." + $a + ".gateway cert, key and token must be strings" else empty end),
                (if (.gateway | has("model")) and ((.gateway.model|type) != "boolean") then "agents." + $a + ".gateway.model must be true or false" else empty end),
                (if (.gateway.model == true) and ($up != null) and (($root.gateway.upstreams|type) == "array") and (($root.gateway.upstreams | index($up)) == null) then "agents." + $a + ".gateway.model is true but gateway.upstreams has no " + $up + " (this agent'"'"'s model upstream)" else empty end)
              end)
           else empty end),
          (if has("env") and ((.env|type) != "object" or ([.env[] | select(type != "string")] | length) > 0) then "agents." + $a + ".env must be an object of strings" else empty end))
     end)
  ] | .[]' "$CONFIG" 2>&1); status=$?
if [ $status -ne 0 ]; then echo "check-config: jq failed: $problems" >&2; exit 1; fi
if [ -n "$problems" ]; then printf 'check-config: %s\n' "$problems" >&2; exit 1; fi
echo "check-config: $CONFIG is valid (version 1; agents: $(jq -r '.agents | keys | join(", ")' "$CONFIG"); profiles: $(jq -r '(.profiles // []) | join(", ")' "$CONFIG"); gateway: $(jq -r 'if .gateway then .gateway.domain + " at " + .gateway.address + "; model through it: " + ((.agents | to_entries | map(select(.value.gateway.model == true) | .key)) | if length == 0 then "no agent" else join(", ") end) else "none (the wall is the allowlist)" end' "$CONFIG"))"
