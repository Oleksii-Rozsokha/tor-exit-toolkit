#!/usr/bin/env bash
# curl-fake.sh - stands in for curl in offline tests, for both scripts:
#  - tor-exit.sh check: a --socks5-hostname call to check.torproject.org/api/ip -> canned JSON on stdout
#  - setup-tor.sh: a -o <file> <url> download -> copies a matching fixture instead of fetching
#  - setup-tor.sh's gone-version fallback: the dist.torproject.org/torbrowser/ listing (no -o - read via
#    $(...) like the real recipe), and the tarball's own 404 (FAKE_CURL_404, below)
# Switch FAKE_CURL_ISTOR=false to make the check step report IsTor:false (for a negative test).
# Switch FAKE_CURL_FAIL=1 to make every call fail (network-error path).
# Switch FAKE_CURL_404=1 to make a *.tar.gz download answer 404 (http_code, via -w) instead of a generic
# failure - distinct from FAKE_CURL_FAIL, which has no http code at all.
# Switch FAKE_CURL_LISTING_FAIL=1 to fail ONLY the torbrowser/ listing request (tarball unaffected).
# Switch FAKE_CURL_LISTING_FIXTURE=<basename in fixtures/> to pick which listing page is served
# (default torbrowser-listing.html, the real saved page; others are synthetic edge cases - see fixtures/).
# Switch FAKE_CURL_FIXDIR=<dir> to serve downloads from a different fixtures directory (per-test good/bad mixes).
# Set FAKE_CURL_ARGLOG=<file> to append each call's arguments, one call per line (to assert e.g. the -m value,
# or that a given URL was never requested at all).
set -u
FIXDIR="${FAKE_CURL_FIXDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)}"
[ -n "${FAKE_CURL_ARGLOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CURL_ARGLOG"

out=""; url=""; wfmt=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  if [ "$a" = "-o" ]; then i=$((i+1)); out="${args[$i]}";
  elif [ "$a" = "-w" ]; then i=$((i+1)); wfmt="${args[$i]}";
  elif [[ "$a" == http* ]]; then url="$a"; fi
  i=$((i+1))
done

if [[ "$url" == *"dist.torproject.org/torbrowser/" ]]; then
  if [ "${FAKE_CURL_FAIL:-0}" = 1 ] || [ "${FAKE_CURL_LISTING_FAIL:-0}" = 1 ]; then
    echo "fake-curl: simulated network failure (listing)" >&2
    exit 7
  fi
  cat "$FIXDIR/${FAKE_CURL_LISTING_FIXTURE:-torbrowser-listing.html}"
  exit 0
fi

if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  echo "fake-curl: simulated network failure" >&2
  exit 7
fi

if [ "${FAKE_CURL_404:-0}" = 1 ] && [[ "$url" == *.tar.gz ]]; then
  [ -n "$wfmt" ] && printf '404'
  exit 22
fi

if [[ "$url" == *check.torproject.org/api/ip* ]]; then
  istor="${FAKE_CURL_ISTOR:-true}"
  printf '{"IsTor":%s,"IP":"198.51.100.7"}\n' "$istor"
  exit 0
fi

if [ -n "$out" ] && [ -n "$url" ]; then
  base="$(basename "$url")"
  src="$FIXDIR/$base"
  if [ -f "$src" ]; then cp "$src" "$out"; [ -n "$wfmt" ] && printf '200'; exit 0; fi
  echo "fake-curl: no fixture for $base (looked in $FIXDIR)" >&2
  exit 22
fi

echo "fake-curl: unhandled args: ${args[*]}" >&2
exit 2
