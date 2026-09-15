#!/usr/bin/env bash
# One traffic reading for a VPN tunnel interface, as a single line:
#
#   <rx_bytes> <tx_bytes> <uptime seconds>
#
# rx is traffic arriving through the tunnel (downstream) and tx is traffic
# leaving through it (upstream). The panel turns two readings into a speed, so
# the time comes from /proc/uptime, a steady clock the user cannot move, rather
# than the wall clock.
#
# A name that is not a plain interface name, or an interface without counters
# (the tunnel just went away), prints nothing: a blank reading, not an error.

set -u

iface=${1:-}
case "$iface" in
  "" | . | .. | *[!A-Za-z0-9_.-]*) exit 0 ;;
esac

stats=/sys/class/net/$iface/statistics
[ -r "$stats/rx_bytes" ] && [ -r "$stats/tx_bytes" ] || exit 0

read -r rx < "$stats/rx_bytes" || exit 0
read -r tx < "$stats/tx_bytes" || exit 0
read -r uptime _ < /proc/uptime || exit 0

printf '%s %s %s\n' "$rx" "$tx" "$uptime"
