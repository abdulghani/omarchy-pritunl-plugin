#!/usr/bin/env bash
# Import a Pritunl profile from a pritunl:// (or https) profile link, a .ovpn
# or .tar file, or a .zip of those as the Pritunl user page downloads it.
#
#   add-profile.sh <link|path>
#
# Profiles go in as user profiles, like the ones the Pritunl app imports, so
# their password mode lands in ~/.config/pritunl/profiles/ where profiles.sh
# reads it. Importing a profile that is already there updates it in place
# rather than adding a copy.

set -uo pipefail

source=${1:-}
if [ -z "$source" ]; then
  echo "Nothing to import." >&2
  exit 2
fi

add() { pritunl-client add --user "$1"; }

case "$source" in
  pritunl://* | https://* | http://*)
    add "$source"
    exit
    ;;
esac

# A path, which may be typed as ~/… into the panel's field.
path=${source/#\~/$HOME}
if [ ! -r "$path" ]; then
  echo "Can't read $source" >&2
  exit 1
fi

case "${path,,}" in
  *.ovpn | *.tar)
    add "$path"
    ;;
  *.zip)
    tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/pritunl-import.XXXXXX") || exit 1
    trap 'rm -rf "$tmp"' EXIT
    if ! unzip -q -o "$path" -d "$tmp" 2>/dev/null; then
      echo "Couldn't open $(basename "$path")" >&2
      exit 1
    fi
    found=0
    failed=0
    while IFS= read -r -d '' profile; do
      found=1
      add "$profile" || failed=1
    done < <(find "$tmp" -type f \( -iname '*.ovpn' -o -iname '*.tar' \) -print0)
    if [ "$found" -eq 0 ]; then
      echo "No .ovpn or .tar profile inside $(basename "$path")" >&2
      exit 1
    fi
    exit "$failed"
    ;;
  *)
    echo "Pick a .ovpn, .tar, or .zip profile, or paste a pritunl:// link." >&2
    exit 1
    ;;
esac
