#!/bin/bash
# Validates a configuration file against what run.sh and the entrypoint read (schema/sandbox.schema.json
# is the same contract for tools that speak JSON Schema). Unknown keys are refused: a key nobody reads
# is a decision nobody reviewed. Usage: check-config.sh <config.json>; exit 1 with every problem listed.
set -uo pipefail
CONFIG=${1:?config.json}
command -v jq >/dev/null || { echo "check-config: jq is required" >&2; exit 1; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "check-config: $CONFIG is not valid JSON" >&2; exit 1; }
problems=$(jq -r '
  def keys_only($allowed): [keys[] | select(. as $k | $allowed | index($k) | not)];
  def req($o; $names): [$names[] | . as $n | select(($o | has($n)) | not)];
  [
    (if .version != 1 then "version must be 1" else empty end),
    (keys_only(["version","sandbox","image","account","workspace","clones","profiles","agents"])[] | "unknown top-level key: " + .),
    (req(.; ["sandbox","image","account","workspace","agents"])[] | "missing: " + .),
    (if (.sandbox|type) == "object" then
       (.sandbox | keys_only(["repo","ref"])[] | "unknown key in sandbox: " + .),
       (req(.sandbox; ["repo","ref"])[] | "missing in sandbox: " + .)
     else "sandbox must be an object" end),
    (if (.workspace|type) == "object" then
       (.workspace | keys_only(["repo"])[] | "unknown key in workspace: " + .),
       (req(.workspace; ["repo"])[] | "missing in workspace: " + .)
     else "workspace must be an object" end),
    (if has("clones") and ((.clones|type) != "array" or ([.clones[] | select(type != "string")] | length) > 0) then "clones must be an array of strings" else empty end),
    (if has("profiles") and ((.profiles|type) != "array" or ([.profiles[] | select((type != "string") or (test("^[a-z][a-z0-9-]*$") | not))] | length) > 0) then "profiles must be an array of lowercase names" else empty end),
    (if (.agents|type) != "object" or (.agents|length) == 0 then "agents must be an object with at least one agent" else
       (.agents | keys_only(["claude","gemini"])[] | "unknown agent: " + .),
       (.agents | to_entries[] | .key as $a | .value |
          (keys_only(["app_id","key","bot","bot_id","container","workspace_volume","config_volume","tokens_file","env"])[] | "unknown key in agents." + $a + ": " + .),
          (req(.; ["app_id","key","bot","bot_id","container","workspace_volume","config_volume"])[] | "missing in agents." + $a + ": " + .),
          (if has("env") and ((.env|type) != "object" or ([.env[] | select(type != "string")] | length) > 0) then "agents." + $a + ".env must be an object of strings" else empty end))
     end)
  ] | .[]' "$CONFIG" 2>&1); status=$?
if [ $status -ne 0 ]; then echo "check-config: jq failed: $problems" >&2; exit 1; fi
if [ -n "$problems" ]; then printf 'check-config: %s\n' "$problems" >&2; exit 1; fi
echo "check-config: $CONFIG is valid (version 1; agents: $(jq -r '.agents | keys | join(", ")' "$CONFIG"); profiles: $(jq -r '(.profiles // []) | join(", ")' "$CONFIG"))"
