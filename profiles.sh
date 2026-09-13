#!/usr/bin/env bash
# One reading of the Pritunl client, as a single JSON object:
#
#   { "installed": true|false,
#     "profiles": [ { id, name, run_state, connected, status, uptime,
#                     server_address, client_address, system,
#                     password_mode }, ... ],
#     "error": "<message>" }          (only when the list could not be read)
#
# password_mode is not part of `pritunl-client list`; the client keeps it in
# each user profile's conf, so it is joined in from there ("" when unknown).

set -uo pipefail
export LC_ALL=C

if ! command -v pritunl-client >/dev/null 2>&1; then
  echo '{"installed":false,"profiles":[]}'
  exit 0
fi

# The CLI talks to pritunl-client-service; with the service down it fails
# rather than printing an empty list, and that message is worth showing.
if ! list=$(pritunl-client list -j 2>&1); then
  jq -cn --arg e "$list" '{installed: true, profiles: [], error: $e}'
  exit 0
fi

conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/pritunl/profiles"
modes='{}'
for conf in "$conf_dir"/*.conf; do
  [ -r "$conf" ] || continue
  mode=$(jq -r '.password_mode // ""' "$conf" 2>/dev/null) || mode=""
  modes=$(jq -c --arg id "$(basename "$conf" .conf)" --arg m "$mode" '. + {($id): $m}' <<<"$modes")
done

jq -c --argjson modes "$modes" '
  { installed: true,
    profiles: [ (if type == "array" then .[] else empty end)
                | . + { password_mode: ($modes[.id] // "") } ] }' <<<"$list" 2>/dev/null ||
  jq -cn '{installed: true, profiles: [], error: "The Pritunl client returned an unreadable profile list."}'
