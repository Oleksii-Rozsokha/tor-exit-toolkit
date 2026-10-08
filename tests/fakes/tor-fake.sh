#!/usr/bin/env bash
# tor-fake.sh - stands in for tor.exe in offline tests: reads a real torrc, writes the same bootstrap lines
# Tor writes to its own log, then behaves like a long-running daemon (sleeps) until killed. No network.
#   tor-fake.sh -f <torrc>
# Switch FAKE_TOR_NO_BOOTSTRAP=1 to test the ceiling/timeout path (never reaches 100%).
# Switch FAKE_TOR_DIE=1 to test the "exited before bootstrapping" path (exits shortly after start).
# Switch FAKE_TOR_BIND_FAIL=1 for a config-time bind failure (seen live: another instance already held the
# port): dies before its own logging starts, so the .log stays EMPTY - the reason is only in .stdio (this is
# the case the bind-failure test points readers at). Verbatim shape from a real run's console output.
# GeoIP, as real Tor does it: the torrc's GeoIPFile/GeoIPv6File are opened at startup ("Parsing GEOIP IPv4 file
# <path>."); one that cannot be opened gets "[warn] Failed to open GEOIP file <path>." and, with ExitNodes set, no
# exit can ever be picked - the bootstrap stalls at 50% (seen in a real run with TOR_EXIT_BIN pointing outside the
# package; a fake that ignored GeoIP is why 41 green checks missed that bug).
# Switch FAKE_TOR_GEOIP_FAIL=1 to log that warning even when the files exist - a file Tor cannot open (only the log
# shows that case; that a CORRUPT file logs the same line is an assumption, not observed).
# Before those lines, like real Tor with this torrc shape, it logs the "Path for ... is relative" warnings the README
# calls harmless, so a grep for the one GeoIP warning has to find it among them (order and wording copied from a
# real Tor Browser log).
set -u
[ "${1:-}" = "-f" ] || { echo "tor-fake: usage: tor-fake.sh -f <torrc>" >&2; exit 1; }
torrc="$2"
if [ "${FAKE_TOR_BIND_FAIL:-0}" = 1 ]; then
  sp=$(grep '^SocksPort ' "$torrc" | sed 's/^SocksPort //')
  echo "Opening Socks listener on $sp"
  echo "Could not bind to $sp: Address already in use [WSAEADDRINUSE ]. Is Tor already running?"
  echo "Failed to parse/validate config: Failed to bind one of the listener ports."
  echo "[err] Reading config failed"
  exit 1
fi
log=$(grep '^Log notice file ' "$torrc" | sed 's/^Log notice file //')
[ -n "$log" ] || { echo "tor-fake: no Log line in $torrc" >&2; exit 1; }
mkdir -p "$(dirname "$log")"
: > "$log"
for key in DataDirectory GeoIPFile GeoIPv6File; do
  f=$(grep "^$key " "$torrc" | sed "s/^$key //")
  [ -n "$f" ] && echo "[warn] Path for $key ($f) is relative and will resolve to $(printf '%s' "$f" | tr / '\\'). Is this what you wanted?" >> "$log"
done
geo_fail=0
for key in GeoIPFile GeoIPv6File; do
  f=$(grep "^$key " "$torrc" | sed "s/^$key //")
  fam=IPv4; [ "$key" = GeoIPv6File ] && fam=IPv6
  if [ "${FAKE_TOR_GEOIP_FAIL:-0}" = 1 ] || [ -z "$f" ] || [ ! -r "$f" ]; then
    echo "[warn] Failed to open GEOIP file $f." >> "$log"; geo_fail=1
  else
    echo "[notice] Parsing GEOIP $fam file $f." >> "$log"
  fi
done
echo "[notice] Bootstrapped 0% (starting): fake bootstrap" >> "$log"
if [ "${FAKE_TOR_DIE:-0}" = 1 ]; then
  echo "[notice] fake: dying on purpose before bootstrap" >> "$log"
  exit 1
fi
sleep 1
echo "[notice] Bootstrapped 50% (loading_status): fake bootstrap" >> "$log"
if [ "$geo_fail" = 1 ] && grep -q '^ExitNodes ' "$torrc"; then
  echo "[warn] We've been configured to use (or avoid) nodes in certain countries, and we need GEOIP information to figure out which ones they are." >> "$log"
  while true; do sleep 1; done
fi
if [ "${FAKE_TOR_NO_BOOTSTRAP:-0}" = 1 ]; then
  # never reaches 100%; just idle so the caller's ceiling loop can time out and kill us
  while true; do sleep 1; done
fi
sleep 1
echo "[notice] Bootstrapped 100% (done): fake bootstrap done" >> "$log"
while true; do sleep 1; done
