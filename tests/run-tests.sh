#!/usr/bin/env bash
# run-tests.sh - offline tests for tor-exit.sh and setup-tor.sh. No network, no real Tor, no real GPG key fetch:
# tor.exe is replaced by tests/fakes/tor-fake.sh (copied into a bundle-shaped temp folder and run by a copy of
# bash.exe named tor.exe, so tasklist sees the image name the real binary has), curl by tests/fakes/curl-fake.sh
# (except the file:// cases: the real curl on a local folder, no network),
# and setup-tor.sh's GPG key comes from a self-signed test key in tests/fixtures/ (TOR_SETUP_GPG_KEY_FILE +
# TOR_SETUP_KEY_FPR), never from WKD; the rogue, expired and subkey test keys beside it are throwaway keys made by
# tests/fixtures/make-keybundle-fixtures.sh (no network, public parts only). Run: bash tests/run-tests.sh
set -u
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$SD/.." && pwd)"
FIX="$SD/fixtures"
FAKE="$SD/fakes"
WORK="$SD/work"
rm -rf "$WORK"; mkdir -p "$WORK"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
skip() { SKIP=$((SKIP+1)); echo "skip - $1"; }   # a case this machine cannot set up; not counted as passed
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
expect_rc() { # expect_rc <label> <expected_rc> -- <cmd...>
  local label="$1" want="$2"; shift 2; [ "${1:-}" = "--" ] && shift
  "$@" > "$WORK/out.$$" 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label (rc=$rc, wanted $want): $(cat "$WORK/out.$$")"; fi
  rm -f "$WORK/out.$$"
}
expect_out() { # expect_out <label> <grep-pattern> -- <cmd...>
  local label="$1" pat="$2"; shift 2; [ "${1:-}" = "--" ] && shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  if printf '%s' "$out" | grep -q -- "$pat"; then ok "$label"; else bad "$label (rc=$rc, no match for [$pat] in: $out)"; fi
}
expect_rc_out() { # expect_rc_out <label> <expected_rc> <grep-pattern> -- <cmd...>   both the exit code and the output
  local label="$1" want="$2" pat="$3"; shift 3; [ "${1:-}" = "--" ] && shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -q -- "$pat"; then ok "$label (rc=$rc)"
  else bad "$label (rc=$rc, wanted $want; pattern [$pat]): $out"; fi
}
W() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
# a torrc line's value: torrc_val <torrc> <key>
torrc_val() { sed -n "s/^$2 //p" "$1" 2>/dev/null; }

echo "== tor-exit.sh =="
# The fake tor runs from a bundle-shaped folder OUTSIDE the package, laid out like the real Tor Expert Bundle
# (<bundle>/tor/<binary>, <bundle>/data/geoip + geoip6): the TOR_EXIT_BIN reuse route from real use, which a fixed
# in-package GeoIP path broke for every country. The fake, like real Tor, stalls without its GeoIP files.
EXT="$(mktemp -d "${TMPDIR:-/tmp}/tor-exit-ext.XXXXXX")" || { echo "cannot create a temp folder for the fake bundle"; exit 1; }
trap 'rm -rf "$EXT"' EXIT
EXT="$(cd "$EXT" && pwd)"   # POSIX form (/c/...): a TMPDIR given as C:/... would put the drive colon into PATH below
# The fake's interpreter is a copy of bash.exe named tor.exe (found through PATH, so a space in the temp path cannot
# break the shebang): tasklist then shows every fake as image "tor.exe", and tor-exit.sh's image-name guard against
# stale pid files runs exactly as it does against the real binary - no test-only switch in the script.
mkdir -p "$EXT/interp"; cp /usr/bin/bash.exe "$EXT/interp/tor.exe" || { echo "cannot copy /usr/bin/bash.exe for the fake tor"; exit 1; }
export PATH="$EXT/interp:$PATH"
mkbundle() { mkdir -p "$1/tor" "$1/data"
  { echo '#!/usr/bin/env tor.exe'; tail -n +2 "$FAKE/tor-fake.sh"; } > "$1/tor/tor.exe"; chmod +x "$1/tor/tor.exe"
  printf 'fake geoip\n' > "$1/data/geoip"; printf 'fake geoip6\n' > "$1/data/geoip6"; }
mkbundle "$EXT/bundle"
export TOR_EXIT_BIN="$EXT/bundle/tor/tor.exe"
export TOR_EXIT_CURL="$FAKE/curl-fake.sh"
export TOR_EXIT_STATE="$WORK/state"
export TOR_EXIT_BOOTSTRAP_S=6
mkdir -p "$TOR_EXIT_STATE"
# after a failed start: no pid, country, torrc or data folder left for <port>, but its log kept (it holds the reason)
no_leftovers() { # no_leftovers <label> <port>
  local l; l="$(ls -d "$TOR_EXIT_STATE"/tor-"$2".* "$TOR_EXIT_STATE"/tor-"$2"-data 2>/dev/null)"
  if [ -z "$l" ] && ls "$TOR_EXIT_STATE"/logs/tor-"$2"-*.log >/dev/null 2>&1; then ok "$1"; else bad "$1: left [$l], logs: $(ls "$TOR_EXIT_STATE/logs")"; fi
}

expect_rc  "start: bad country code is refused"      64 -- bash "$PKG/tor-exit.sh" start XX
expect_rc  "start: bad port is refused"               64 -- bash "$PKG/tor-exit.sh" start de notaport
expect_rc  "check: no tracked instance"                3 -- bash "$PKG/tor-exit.sh" check 9299
expect_rc  "stop: nothing tracked is not an error"     0 -- bash "$PKG/tor-exit.sh" stop 9299
TOR_EXIT_BIN="$EXT/none/tor/tor.exe" expect_rc_out "start: a missing binary is refused, its path in C:/ form" 3 "tor.exe not found at $(W "$EXT/none/tor/tor.exe") - " -- bash "$PKG/tor-exit.sh" start de 9298

bash "$PKG/tor-exit.sh" start de 9201 > "$WORK/s9201.out" 2>&1
grep -q "port 9201:.*true" "$WORK/s9201.out" && ok "start: bootstraps and checks (happy path)" || bad "start: bootstraps and checks (happy path): $(cat "$WORK/s9201.out")"
grep -qF "GeoIP loaded: $(W "$EXT/bundle/data/geoip")" "$WORK/s9201.out" \
  && ok "start: prints the GeoIP file Tor says it loaded, next to bootstrapped" || bad "start: prints the GeoIP file Tor says it loaded, next to bootstrapped: $(grep bootstrapped "$WORK/s9201.out")"
grep -qF "note: unverified binary: $(W "$TOR_EXIT_BIN")" "$WORK/s9201.out" \
  && ok "start: a binary outside the package's install gets an 'unverified binary' notice" || bad "start: a binary outside the package's install gets an 'unverified binary' notice: $(cat "$WORK/s9201.out")"
grep -qF "log $(W "$TOR_EXIT_STATE")/logs/tor-9201-" "$WORK/s9201.out" \
  && ok "start: the log path is printed in C:/ form, as doctor prints the state folder" || bad "start: the log path is printed in C:/ form, as doctor prints the state folder: $(grep '^starting' "$WORK/s9201.out")"
ls "$TOR_EXIT_STATE/logs" | grep -qE '^tor-9201-[0-9]{8}-[0-9]{6}\.log$' \
  && ok "start: the log is named by port and local date-time" || bad "start: the log is named by port and local date-time: $(ls "$TOR_EXIT_STATE/logs")"
g4="$(torrc_val "$TOR_EXIT_STATE/tor-9201.torrc" GeoIPFile)"; g6="$(torrc_val "$TOR_EXIT_STATE/tor-9201.torrc" GeoIPv6File)"
[ "$g4" = "$(W "$EXT/bundle/data/geoip")" ] && [ "$g6" = "$(W "$EXT/bundle/data/geoip6")" ] && [ -f "$g4" ] && [ -f "$g6" ] \
  && ok "start: an external TOR_EXIT_BIN gets its own bundle's GeoIP files in the torrc, and they exist" \
  || bad "start: an external TOR_EXIT_BIN gets its own bundle's GeoIP files in the torrc, and they exist: [$g4] [$g6]"
expect_out "status: shows the running instance"        "port 9201: running" -- bash "$PKG/tor-exit.sh" status 9201
expect_out "check: re-run reports the exit country"    "requested exit country de" -- bash "$PKG/tor-exit.sh" check 9201
expect_rc  "start: second start on the same port refuses" 9 -- bash "$PKG/tor-exit.sh" start de 9201
expect_out "stop: kills and confirms via tasklist"     "confirmed by tasklist" -- bash "$PKG/tor-exit.sh" stop 9201
expect_out "status: after stop, nothing tracked"       "not running\|nothing tracked" -- bash "$PKG/tor-exit.sh" status 9201
[ -f "$TOR_EXIT_STATE/tor-9201.pid" ] && bad "stop: pid file should be removed" || ok "stop: pid file removed"

expect_out "start: two ports in parallel both come up" "port 9202:.*true" -- bash "$PKG/tor-exit.sh" start de 9202
expect_out "start: a second port does not clash"       "port 9203:.*true" -- bash "$PKG/tor-exit.sh" start nl 9203
expect_out "status: both tracked when no port given"   "port 9202: running" -- bash "$PKG/tor-exit.sh" status
bash "$PKG/tor-exit.sh" status 2>/dev/null | grep -q "port 9203: running" && ok "status: second instance also listed" || bad "status: second instance also listed"
# the untracked-tor.exe warning must never name a TRACKED instance (other tor.exe on the machine may be listed)
tw="$(for f in "$TOR_EXIT_STATE"/tor-920[23].pid; do cat "/proc/$(cat "$f")/winpid"; done)"
wl="$(bash "$PKG/tor-exit.sh" status 2>&1 | grep '^WARNING\|^note: other')"
hit=""; for w in $tw; do case " $wl " in *[!0-9]"$w"[!0-9]*) hit="$hit $w";; esac; done
[ -n "$tw" ] && [ -z "$hit" ] && ok "status: the untracked warning never names a tracked instance" || bad "status: the untracked warning never names a tracked instance: tracked [$tw], warning [$wl]"
expect_rc_out "stop: a bare stop stops nothing and lists the tracked ports" 64 "tracked ports: 9202 9203" -- bash "$PKG/tor-exit.sh" stop
[ "$(bash "$PKG/tor-exit.sh" status 2>/dev/null | grep -c ': running')" = 2 ] && ok "stop: after a bare stop both instances still run" || bad "stop: after a bare stop both instances still run"
expect_out "stop --all: stops every tracked instance" "port 9203: stopped, confirmed" -- bash "$PKG/tor-exit.sh" stop --all
ls "$TOR_EXIT_STATE"/tor-*.pid >/dev/null 2>&1 && bad "stop --all: no pid file left" || ok "stop --all: no pid file left"

LW="$(W "$TOR_EXIT_STATE")/logs"   # the failure messages name the log in C:/ form, as the starting line does
FAKE_TOR_NO_BOOTSTRAP=1 TOR_EXIT_BOOTSTRAP_S=3 expect_rc_out "start: ceiling stops a stuck bootstrap, and says it stopped only because it did" 5 "(ceiling; see $LW/tor-9204-.*) - stopped" -- bash "$PKG/tor-exit.sh" start de 9204
[ -f "$TOR_EXIT_STATE/tor-9204.pid" ] && bad "ceiling: pid file left behind" || ok "ceiling: pid file cleaned up"
no_leftovers "ceiling: torrc, country file and data folder removed too, log kept" 9204

FAKE_TOR_DIE=1 expect_rc_out "start: tor exiting early is reported" 2 "tor exited before bootstrapping - the reason is usually in $LW/tor-9205-" -- bash "$PKG/tor-exit.sh" start de 9205
no_leftovers "early exit: pid, country, torrc and data removed, log kept" 9205

# a bind-time failure (port already held) dies before Tor's own logging starts - the real-life shape seen
# live: the .log is EMPTY, the reason is only in .stdio. The old message named only the (empty) .log.
FAKE_TOR_BIND_FAIL=1 expect_rc_out "start: a bind-time failure is exit 2 and now names .stdio, not just the empty .log" \
  2 "tor exited before bootstrapping - the reason is usually in $LW/tor-9215-.*\.stdio" -- bash "$PKG/tor-exit.sh" start de 9215
logf=$(ls "$TOR_EXIT_STATE/logs"/tor-9215-*.log 2>/dev/null | head -1)
[ -n "$logf" ] && [ ! -s "$logf" ] && ok "start: ... the .log really is empty, like the real bind-error case" \
  || bad "start: ... the .log really is empty, like the real bind-error case: $(ls -la "$TOR_EXIT_STATE/logs" 2>/dev/null)"
stdiof=$(ls "$TOR_EXIT_STATE/logs"/tor-9215-*.stdio 2>/dev/null | head -1)
[ -n "$stdiof" ] && grep -q "WSAEADDRINUSE" "$stdiof" && ok "start: ... and the real reason is in that .stdio" \
  || bad "start: ... and the real reason is in that .stdio: $(cat "$stdiof" 2>/dev/null)"
no_leftovers "bind-time failure: pid, country, torrc and data removed, (empty) log and stdio kept" 9215

FAKE_CURL_ISTOR=false expect_out "check: a false IsTor is reported plainly" "false" -- bash "$PKG/tor-exit.sh" start de 9206
bash "$PKG/tor-exit.sh" stop 9206 >/dev/null 2>&1

bash "$PKG/tor-exit.sh" start de 9207 >/dev/null 2>&1
FAKE_CURL_FAIL=1 expect_rc  "check: a failed check request exits 6 (not start's 2: the instance is alive)" 6 -- bash "$PKG/tor-exit.sh" check 9207
FAKE_CURL_FAIL=1 expect_out "check: a failed check says the instance is STILL RUNNING" "STILL RUNNING" -- bash "$PKG/tor-exit.sh" check 9207
expect_out "status: after a failed check the instance really is still running" "port 9207: running" -- bash "$PKG/tor-exit.sh" status 9207
: > "$WORK/curl-args.log"
FAKE_CURL_ARGLOG="$WORK/curl-args.log" bash "$PKG/tor-exit.sh" check 9207 >/dev/null 2>&1
grep -q -- ' -m 60 ' "$WORK/curl-args.log" && ok "check: waits 60 s by default (-m 60)" || bad "check: waits 60 s by default (-m 60): $(cat "$WORK/curl-args.log")"
: > "$WORK/curl-args.log"
FAKE_CURL_ARGLOG="$WORK/curl-args.log" TOR_EXIT_CHECK_S=33 bash "$PKG/tor-exit.sh" check 9207 >/dev/null 2>&1
grep -q -- ' -m 33 ' "$WORK/curl-args.log" && ok "check: TOR_EXIT_CHECK_S overrides the wait (-m 33)" || bad "check: TOR_EXIT_CHECK_S overrides the wait (-m 33): $(cat "$WORK/curl-args.log")"
bash "$PKG/tor-exit.sh" stop 9207 >/dev/null 2>&1
FAKE_CURL_FAIL=1 expect_rc_out "start: a failed final check exits 6 and says the instance is STILL RUNNING" 6 "STILL RUNNING" -- bash "$PKG/tor-exit.sh" start de 9214
expect_out "start: ... and it really is still running" "port 9214: running" -- bash "$PKG/tor-exit.sh" status 9214
bash "$PKG/tor-exit.sh" stop 9214 >/dev/null 2>&1

# GeoIP: refused up front when missing; TOR_EXIT_GEOIP_DIR overrides; a GeoIP failure that only the log shows stops
# the wait at once; the in-package default (no TOR_EXIT_BIN) still finds <package>/tools/tor-bundle/data
mkbundle "$EXT/nogeo"; rm -f "$EXT/nogeo/data/geoip6"
t0=$(date +%s)
TOR_EXIT_BIN="$EXT/nogeo/tor/tor.exe" TOR_EXIT_BOOTSTRAP_S=30 expect_rc_out "start: a missing GeoIP file is refused up front, naming the path" \
  3 "GeoIP file missing: .*nogeo/data/geoip6" -- bash "$PKG/tor-exit.sh" start de 9208
el=$(( $(date +%s) - t0 ))
[ "$el" -lt 10 ] && ok "start: the GeoIP refusal does not wait for the 30 s ceiling (${el}s)" || bad "start: the GeoIP refusal does not wait for the 30 s ceiling (${el}s)"
ls "$TOR_EXIT_STATE"/tor-9208* "$TOR_EXIT_STATE"/logs/tor-9208-* >/dev/null 2>&1 \
  && bad "start: nothing launched or written when GeoIP is missing: $(ls "$TOR_EXIT_STATE" "$TOR_EXIT_STATE/logs")" \
  || ok "start: nothing launched or written when GeoIP is missing"

TOR_EXIT_BIN="$EXT/nogeo/tor/tor.exe" TOR_EXIT_GEOIP_DIR="$EXT/bundle/data" expect_out "start: TOR_EXIT_GEOIP_DIR overrides the GeoIP folder" \
  "port 9209:.*true" -- bash "$PKG/tor-exit.sh" start de 9209
[ "$(torrc_val "$TOR_EXIT_STATE/tor-9209.torrc" GeoIPv6File)" = "$(W "$EXT/bundle/data/geoip6")" ] \
  && ok "start: the override is what the torrc uses" || bad "start: the override is what the torrc uses: $(grep GeoIP "$TOR_EXIT_STATE/tor-9209.torrc")"
bash "$PKG/tor-exit.sh" stop 9209 >/dev/null 2>&1

t0=$(date +%s)
FAKE_TOR_GEOIP_FAIL=1 TOR_EXIT_BOOTSTRAP_S=30 expect_rc_out "start: a 'Failed to open GEOIP file' in the log stops the wait, quoting that line" \
  3 "Failed to open GEOIP file.*(see $LW/tor-9210-" -- bash "$PKG/tor-exit.sh" start de 9210
el=$(( $(date +%s) - t0 ))
[ "$el" -lt 20 ] && ok "start: ... well before the 30 s ceiling (${el}s)" || bad "start: ... well before the 30 s ceiling (${el}s)"
[ -f "$TOR_EXIT_STATE/tor-9210.pid" ] && bad "start: GeoIP failure leaves no pid file" || ok "start: GeoIP failure leaves no pid file"
no_leftovers "GeoIP failure: country, torrc and data removed too, log kept" 9210

PC="$WORK/pkgcopy"; mkdir -p "$PC/tools"; cp "$PKG/tor-exit.sh" "$PC/"; mkbundle "$PC/tools/tor-bundle"
env -u TOR_EXIT_BIN -u TOR_EXIT_GEOIP_DIR TOR_EXIT_STATE="$WORK/pc-state" bash "$PC/tor-exit.sh" start de 9211 > "$WORK/pc.out" 2>&1
[ "$(torrc_val "$WORK/pc-state/tor-9211.torrc" GeoIPFile)" = "$(W "$PC/tools/tor-bundle/data/geoip")" ] && grep -q "port 9211:.*true" "$WORK/pc.out" \
  && ok "start: the in-package default binary still uses <package>/tools/tor-bundle/data" \
  || bad "start: the in-package default binary still uses <package>/tools/tor-bundle/data: $(cat "$WORK/pc.out"; grep GeoIP "$WORK/pc-state/tor-9211.torrc")"
TOR_EXIT_STATE="$WORK/pc-state" bash "$PC/tor-exit.sh" stop 9211 >/dev/null 2>&1
# the package's own binary against the hash setup-tor.sh records (tools/.tor-verified, tor_exe_sha256)
grep -q "^note: no recorded tor.exe hash" "$WORK/pc.out" \
  && ok "start: an own binary with no recorded hash (older install) says so" || bad "start: an own binary with no recorded hash (older install) says so: $(cat "$WORK/pc.out")"
PCB="$PC/tools/tor-bundle/tor/tor.exe"
printf 'sha256=x\nfingerprint=x\nversion=x\ntor_exe_sha256=%s\n' "$(sha256sum "$PCB" | awk '{print $1}')" > "$PC/tools/.tor-verified"
env -u TOR_EXIT_BIN -u TOR_EXIT_GEOIP_DIR TOR_EXIT_STATE="$WORK/pc-state" bash "$PC/tor-exit.sh" start de 9211 > "$WORK/pc2.out" 2>&1
grep -q "port 9211:.*true" "$WORK/pc2.out" && ! grep -q "^note: \(unverified\|no recorded\)" "$WORK/pc2.out" \
  && ok "start: an own binary matching the recorded hash starts with no notice" || bad "start: an own binary matching the recorded hash starts with no notice: $(cat "$WORK/pc2.out")"
TOR_EXIT_STATE="$WORK/pc-state" bash "$PC/tor-exit.sh" stop 9211 >/dev/null 2>&1
echo "# changed after install" >> "$PCB"
expect_rc_out "start: an own binary that no longer matches the recorded hash is refused (rc 4)" 4 "differs from the one setup-tor.sh recorded" \
  -- env -u TOR_EXIT_BIN -u TOR_EXIT_GEOIP_DIR TOR_EXIT_STATE="$WORK/pc-state" bash "$PC/tor-exit.sh" start de 9211
ls "$WORK/pc-state"/tor-9211* >/dev/null 2>&1 && bad "start: ... and nothing is started: $(ls "$WORK/pc-state")" || ok "start: ... and nothing is started"

# a stale pid file naming a live process that is NOT tor.exe (PID reuse after a crash or reboot): never killed, never
# reported as running, and no reason to refuse a start on that port. The stand-in is an ordinary `sleep` of this suite.
sleep 300 & SP=$!
echo "$SP" > "$TOR_EXIT_STATE/tor-9212.pid"
expect_rc_out "stop: a stale pid naming a non-tor process is not killed, and says why" 0 "port 9212: not running (stale pid file: pid $SP is not a live tor.exe) - nothing killed" \
  -- bash "$PKG/tor-exit.sh" stop 9212
kill -0 "$SP" 2>/dev/null && ok "stop: ... that process is still alive afterwards" || bad "stop: ... that process is still alive afterwards"
echo "$SP" > "$TOR_EXIT_STATE/tor-9212.pid"
expect_out "doctor: names a stale pid file" "note - port 9212: stale pid file" -- bash "$PKG/tor-exit.sh" doctor
[ -f "$TOR_EXIT_STATE/tor-9212.pid" ] && ok "doctor: ... and changes nothing (the pid file is still there)" || bad "doctor: ... and changes nothing (the pid file is still there)"
expect_out "status: a stale pid naming a non-tor process is reported stale" "port 9212: not running (stale pid file" -- bash "$PKG/tor-exit.sh" status 9212
echo "$SP" > "$TOR_EXIT_STATE/tor-9212.pid"
expect_out "start: a stale pid naming a non-tor process does not block the port" "port 9212:.*true" -- bash "$PKG/tor-exit.sh" start de 9212
kill -0 "$SP" 2>/dev/null && ok "start: ... and that process is still alive afterwards" || bad "start: ... and that process is still alive afterwards"
bash "$PKG/tor-exit.sh" stop 9212 >/dev/null 2>&1
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null

# pid + image is not identity: a pid file naming ANOTHER live instance's tor.exe (copied, or a reused number) must
# not stop it - only a process whose own command line names this port's torrc is this port's instance
bash "$PKG/tor-exit.sh" start de 9217 >/dev/null 2>&1
cp "$TOR_EXIT_STATE/tor-9217.pid" "$TOR_EXIT_STATE/tor-9218.pid"
expect_rc_out "stop: a pid file naming another instance's live tor.exe kills nothing" 0 \
  "port 9218: not running (stale pid file: pid .* is a live tor.exe, but not this port's instance" -- bash "$PKG/tor-exit.sh" stop 9218
expect_out "stop: ... and that other instance still runs" "port 9217: running" -- bash "$PKG/tor-exit.sh" status 9217
cp "$TOR_EXIT_STATE/tor-9217.pid" "$TOR_EXIT_STATE/tor-9218.pid"
expect_rc_out "check: refuses a pid file naming another instance" 3 "not this port's instance" -- bash "$PKG/tor-exit.sh" check 9218
bash "$PKG/tor-exit.sh" stop 9218 >/dev/null 2>&1; bash "$PKG/tor-exit.sh" stop 9217 >/dev/null 2>&1

# a live process of the image whose command line cannot be read - a native one that MSYS did not launch, here a
# loopback-only ping started through PowerShell: nothing killed, pid file kept, "check by hand" (no pid+image fallback)
PING="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32/PING.EXE"; up=""
for try in 1 2 3; do
  w="$(powershell -NoProfile -Command "(Start-Process ping -ArgumentList '-n','30','127.0.0.1' -WindowStyle Hidden -PassThru).Id" 2>/dev/null | tr -d '\r')"
  [ -n "$w" ] && [ ! -d "/proc/$w" ] && { up="$w"; break; }   # a /proc entry under that number would be another process
  [ -n "$w" ] && taskkill //FI "PID eq $w" //FI "IMAGENAME eq PING.EXE" //F >/dev/null 2>&1
done
if [ -z "$up" ]; then bad "stop: an unconfirmable identity (could not start a non-MSYS native process to test it)"
else
  echo "$up" > "$TOR_EXIT_STATE/tor-9219.pid"
  expect_rc_out "stop: a live process whose command line cannot be read is not killed" 0 \
    "cannot be confirmed as this port's instance - nothing killed, files kept; check by hand" -- env TOR_EXIT_BIN="$PING" bash "$PKG/tor-exit.sh" stop 9219
  tasklist //NH //FO CSV //FI "PID eq $up" | grep -q "\"$up\"" && ok "stop: ... it is still alive" || bad "stop: ... it is still alive"
  [ -f "$TOR_EXIT_STATE/tor-9219.pid" ] && ok "stop: ... and its pid file is kept" || bad "stop: ... and its pid file is kept"
  taskkill //FI "PID eq $up" //FI "IMAGENAME eq PING.EXE" //F >/dev/null 2>&1; rm -f "$TOR_EXIT_STATE/tor-9219.pid"
fi

# a TOR_EXIT_BIN without ".exe": MSYS runs it as tor.exe, so it must still be recognized as image tor.exe
TOR_EXIT_BIN="$EXT/bundle/tor/tor" expect_out "start: a TOR_EXIT_BIN without .exe starts" "port 9220:.*true" -- bash "$PKG/tor-exit.sh" start de 9220
TOR_EXIT_BIN="$EXT/bundle/tor/tor" expect_out "status: ... and sees it running" "port 9220: running" -- bash "$PKG/tor-exit.sh" status 9220
TOR_EXIT_BIN="$EXT/bundle/tor/tor" expect_out "stop: ... and stops it" "port 9220: stopped, confirmed" -- bash "$PKG/tor-exit.sh" stop 9220

# a state folder that does not exist is reported, not created (a mistyped TOR_EXIT_STATE)
TOR_EXIT_STATE="$WORK/no-such-state" expect_rc_out "status: a missing state folder is reported (rc 3)" 3 "state folder does not exist" -- bash "$PKG/tor-exit.sh" status
TOR_EXIT_STATE="$WORK/no-such-state" expect_rc_out "stop: a missing state folder is reported (rc 3)" 3 "state folder does not exist" -- bash "$PKG/tor-exit.sh" stop 9201
[ -e "$WORK/no-such-state" ] && bad "status/stop: the missing state folder is not created" || ok "status/stop: the missing state folder is not created"

# an instance started with ANOTHER state folder (a session that forgot TOR_EXIT_STATE on stop): stop and status say a
# tor.exe runs untracked, and leave it running
TOR_EXIT_STATE="$WORK/other-state" bash "$PKG/tor-exit.sh" start de 9213 >/dev/null 2>&1
ow="$(cat "/proc/$(cat "$WORK/other-state/tor-9213.pid")/winpid" 2>/dev/null)"
expect_out "stop: nothing tracked, but warns about the untracked tor.exe by pid" "WARNING: tor.exe is running but not tracked in .*pid.*$ow" -- bash "$PKG/tor-exit.sh" stop 9213
expect_out "status: warns about it too" "WARNING: tor.exe is running but not tracked" -- bash "$PKG/tor-exit.sh" status
expect_out "stop: ... and the untracked instance was left running" "port 9213: running" -- env TOR_EXIT_STATE="$WORK/other-state" bash "$PKG/tor-exit.sh" status 9213
# while this folder tracks an instance of its own, the other one is a one-line note, not the loud WARNING
bash "$PKG/tor-exit.sh" start de 9221 >/dev/null 2>&1
bash "$PKG/tor-exit.sh" status > "$WORK/st-note.out" 2>&1
grep -q "^note: other tor.exe running outside this state folder: pid.*$ow" "$WORK/st-note.out" && ! grep -q "WARNING" "$WORK/st-note.out" \
  && ok "status: with instances tracked here, an outside tor.exe is a one-line note, not a WARNING" \
  || bad "status: with instances tracked here, an outside tor.exe is a one-line note, not a WARNING: $(cat "$WORK/st-note.out")"
# a stop that just stopped this folder's LAST instance: the other session's tor.exe is a note there too, not a WARNING
bash "$PKG/tor-exit.sh" stop 9221 > "$WORK/stop-last.out" 2>&1
grep -q "port 9221: stopped" "$WORK/stop-last.out" && grep -q "^note: other tor.exe" "$WORK/stop-last.out" && ! grep -q "WARNING" "$WORK/stop-last.out" \
  && ok "stop: stopping the last own instance notes the other tor.exe, without a WARNING" \
  || bad "stop: stopping the last own instance notes the other tor.exe, without a WARNING: $(cat "$WORK/stop-last.out")"
TOR_EXIT_STATE="$WORK/other-state" bash "$PKG/tor-exit.sh" stop 9213 >/dev/null 2>&1

# identity is a FILE, not a spelling: the same state folder reached through a junction or its 8.3 short name is still
# ours (found, stopped, never cleaned up as "another instance"); a junction to a DIFFERENT folder is not
JR="$WORK/jreal"; JO="$WORK/jother"; mkdir -p "$JR" "$JO"
(cd "$WORK" && cmd //c mklink //J jlink jreal && cmd //c mklink //J jolink jother) >/dev/null 2>&1
: > "$JR/.probe"; : > "$JO/.probe"
if ! [ -f "$WORK/jlink/.probe" ] || ! [ -f "$WORK/jolink/.probe" ]; then
  bad "identity: could not create the junctions (mklink /J) this case needs"
else
  rm -f "$JR/.probe" "$JO/.probe"
  TOR_EXIT_STATE="$JR" bash "$PKG/tor-exit.sh" start de 9222 >/dev/null 2>&1
  expect_out "status: the same state folder through a junction finds the live instance" "port 9222: running" -- env TOR_EXIT_STATE="$WORK/jlink" bash "$PKG/tor-exit.sh" status 9222
  s83="$(cygpath -d "$JR" 2>/dev/null)"
  case "$s83" in
    *"~"*) expect_out "status: ... and through its 8.3 short name" "port 9222: running" -- env TOR_EXIT_STATE="$(cygpath -u "$s83")" bash "$PKG/tor-exit.sh" status 9222;;
    *) skip "status: ... and through its 8.3 short name (no 8.3 names on this volume)";;
  esac
  [ -f "$JR/tor-9222.pid" ] && [ -f "$JR/tor-9222.torrc" ] && [ -d "$JR/tor-9222-data" ] \
    && ok "status: ... and the instance's tracking is intact" || bad "status: ... and the instance's tracking is intact: $(ls "$JR")"
  cp "$JR/tor-9222.pid" "$JO/tor-9223.pid"
  expect_rc_out "stop: a copied pid in another folder, another port, is another instance" 0 \
    "port 9223: not running (stale pid file: pid .* is a live tor.exe, but not this port's instance" -- env TOR_EXIT_STATE="$WORK/jolink" bash "$PKG/tor-exit.sh" stop 9223
  cp "$JR/tor-9222.pid" "$JO/tor-9222.pid"
  expect_rc_out "stop: this port's torrc run from another folder is not decided: nothing killed, files kept" 0 \
    "running this port's torrc from another folder .* - nothing killed, files kept; check by hand" -- env TOR_EXIT_STATE="$WORK/jolink" bash "$PKG/tor-exit.sh" stop 9222
  [ -f "$JO/tor-9222.pid" ] && ok "stop: ... that pid file is kept" || bad "stop: ... that pid file is kept"
  rm -f "$JO/tor-9222.pid"
  expect_out "stop: through the junction, the instance is stopped" "port 9222: stopped, confirmed" -- env TOR_EXIT_STATE="$WORK/jlink" bash "$PKG/tor-exit.sh" stop 9222
fi
(cd "$WORK" && cmd //c rmdir jlink; cmd //c rmdir jolink) >/dev/null 2>&1

# doctor: read-only preflight; PROBLEM lines (and rc 3) only for what would make `start` fail
expect_rc_out "doctor: a working setup has no problems, and names an external binary as unverified" 0 "note - unverified binary" -- bash "$PKG/tor-exit.sh" doctor
expect_rc_out "doctor: missing GeoIP is a PROBLEM (rc 3)" 3 "PROBLEM - GeoIP file missing: .*nogeo/data/geoip6" -- env TOR_EXIT_BIN="$EXT/nogeo/tor/tor.exe" bash "$PKG/tor-exit.sh" doctor
expect_rc_out "doctor: a missing binary is a PROBLEM (rc 3)" 3 "PROBLEM - tor.exe not found" -- env TOR_EXIT_BIN="$EXT/none/tor/tor.exe" bash "$PKG/tor-exit.sh" doctor
expect_rc_out "doctor: a state folder not made yet is only a note" 0 "note - state folder does not exist yet" -- env TOR_EXIT_STATE="$WORK/doc-state" bash "$PKG/tor-exit.sh" doctor
[ -e "$WORK/doc-state" ] && bad "doctor: ... and it does not create it" || ok "doctor: ... and it does not create it"
# before an install nothing under tools/ exists, and the GeoIP path holds a `..` through the missing tor/ folder:
# cygpath cannot convert that and printed an error line plus an EMPTY path (seen in a from-scratch test) - the
# missing path is printed in full, as is, and no cygpath text leaks, in doctor and in start's refusal alike
out="$(env TOR_EXIT_BIN="$EXT/none/tor/tor.exe" bash "$PKG/tor-exit.sh" doctor 2>&1)"
printf '%s' "$out" | grep -qF "PROBLEM - GeoIP file missing: $EXT/none/tor/../data/geoip (set" && ! printf '%s' "$out" | grep -q 'cygpath:' \
  && ok "doctor: before an install, the missing GeoIP path is printed in full and no cygpath error leaks" \
  || bad "doctor: before an install, the missing GeoIP path is printed in full and no cygpath error leaks: $out"
out="$(env TOR_EXIT_GEOIP_DIR="$EXT/none/x/../data" bash "$PKG/tor-exit.sh" start de 9230 2>&1)"; rc=$?
[ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "GeoIP file missing: $EXT/none/x/../data/geoip - Tor cannot" \
  && ok "start: a missing GeoIP folder reached through .. is named in full (rc=$rc)" \
  || bad "start: a missing GeoIP folder reached through .. is named in full (rc=$rc, wanted 3): $out"
[ -n "$out" ] && ! printf '%s' "$out" | grep -q 'cygpath:' && ok "start: ... and no cygpath error leaks" || bad "start: ... and no cygpath error leaks (empty output, or a cygpath line): [$out]"

# a machine without node: stop and status still work; start and check refuse up front, naming it
np=""; IFS=: read -r -a pdirs <<< "$PATH"
for d in "${pdirs[@]}"; do [ -e "$d/node" ] || [ -e "$d/node.exe" ] || np="${np:+$np:}$d"; done
if PATH="$np" command -v node >/dev/null 2>&1 || ! PATH="$np" command -v bash >/dev/null 2>&1; then
  bad "no node: could not build a PATH without node (and with bash)"
else
  expect_rc     "no node: stop still works"   0 -- env PATH="$np" bash "$PKG/tor-exit.sh" stop 9299
  expect_rc     "no node: status still works" 0 -- env PATH="$np" bash "$PKG/tor-exit.sh" status
  expect_rc_out "no node: start refuses up front, naming node" 64 "required command not found: node" -- env PATH="$np" bash "$PKG/tor-exit.sh" start de 9216
  expect_rc_out "no node: check refuses up front, naming node" 64 "required command not found: node" -- env PATH="$np" bash "$PKG/tor-exit.sh" check 9216
fi

# every fake tor this section started must be gone (a failure path that kills too early or by the wrong pid would
# leave one idling); read from /proc by path, so another session's real tor.exe never counts
left=""
for f in /proc/[0-9]*/cmdline; do
  c="$(tr '\0' ' ' 2>/dev/null < "$f")" || continue   # a process can end between the glob and the read
  case "$c" in *"$EXT/"*|*"$PC/tools/"*) p="${f#/proc/}"; left="$left pid ${p%/cmdline}: $c;";; esac
done
[ -z "$left" ] && ok "no fake tor left running after the tor-exit.sh cases" || bad "no fake tor left running after the tor-exit.sh cases:$left"

rm -rf "$TOR_EXIT_STATE"; mkdir -p "$TOR_EXIT_STATE"

echo "== setup-tor.sh =="
export TOR_SETUP_CURL="$FAKE/curl-fake.sh"
export TOR_SETUP_VERSION=15.0.23
export TOR_SETUP_GPG_KEY_FILE="$FIX/test-signer-pub.asc"
export TOR_SETUP_KEY_FPR
TOR_SETUP_KEY_FPR="$(cat "$FIX/test-signer.fpr")"

W1="$WORK/setup1"; mkdir -p "$W1"
expect_rc "setup: happy path installs and verifies" 0 -- env TOR_SETUP_TOOLS="$W1" bash "$PKG/setup-tor.sh"
[ -x "$W1/tor-bundle/tor/tor.exe" ] && ok "setup: tor.exe present after install" || bad "setup: tor.exe present after install"
[ -f "$W1/.tor-verified" ] && ok "setup: verified marker written" || bad "setup: verified marker written"
expect_rc "setup: re-run is a no-op (already verified)" 0 -- env TOR_SETUP_TOOLS="$W1" TOR_SETUP_CURL="$FAKE/curl-fake.sh" FAKE_CURL_FAIL=1 bash "$PKG/setup-tor.sh"
[ "$(sed -n 's/^tor_exe_sha256=//p' "$W1/.tor-verified")" = "$(sha256sum "$W1/tor-bundle/tor/tor.exe" | awk '{print $1}')" ] \
  && ok "setup: the record holds the installed tor.exe's own SHA-256" || bad "setup: the record holds the installed tor.exe's own SHA-256: $(cat "$W1/.tor-verified")"
W7="$WORK/setup-oldrecord"; mkdir -p "$W7"; cp -r "$W1"/. "$W7"/; sed -i '/^tor_exe_sha256=/d' "$W7/.tor-verified"
expect_rc_out "setup: a record from an older setup (no tor.exe hash) is pointed out, still no download" 0 "has no tor.exe hash" \
  -- env TOR_SETUP_TOOLS="$W7" FAKE_CURL_FAIL=1 bash "$PKG/setup-tor.sh"

W2="$WORK/setup-force"; mkdir -p "$W2"; cp -r "$W1"/. "$W2"/
expect_rc "setup: --force re-verifies even when already installed" 0 -- env TOR_SETUP_TOOLS="$W2" bash "$PKG/setup-tor.sh" --force

# gpg's temp homedir never comes from TMPDIR: a C:/-form one and a deeply nested one both broke gpg-agent's socket
expect_rc "setup: a C:/-form TMPDIR does not break gpg" 0 -- env TMPDIR="$(W "$EXT")" TOR_SETUP_TOOLS="$WORK/setup-wintmp" bash "$PKG/setup-tor.sh"
DEEP="$WORK/deep-tmp-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; mkdir -p "$DEEP"
expect_rc "setup: a deeply nested TMPDIR does not break gpg" 0 -- env TMPDIR="$DEEP" TOR_SETUP_TOOLS="$WORK/setup-deeptmp" bash "$PKG/setup-tor.sh"
# a TOR_SETUP_TOOLS in C:/ form: GNU tar must not read "C:" as a remote host
expect_rc "setup: a C:/-form TOR_SETUP_TOOLS unpacks" 0 -- env TOR_SETUP_TOOLS="$(W "$WORK/setup-wintools")" bash "$PKG/setup-tor.sh"
[ -x "$WORK/setup-wintools/tor-bundle/tor/tor.exe" ] && ok "setup: ... tor.exe present there" || bad "setup: ... tor.exe present there"

W3="$WORK/setup-badhash"; mkdir -p "$W3/dl"
cp "$FIX/tor-expert-bundle-windows-x86_64-15.0.23-corrupt.tar.gz" "$W3/dl/tor-expert-bundle-windows-x86_64-15.0.23.tar.gz"
cp "$FIX/sha256sums-signed-build.txt" "$FIX/sha256sums-signed-build.txt.asc" "$W3/dl/"
expect_rc "setup: SHA-256 mismatch is refused" 3 -- env TOR_SETUP_TOOLS="$W3" FAKE_CURL_FIXDIR="$W3/dl" bash "$PKG/setup-tor.sh"
[ -d "$W3/tor-bundle" ] && bad "setup: nothing unpacked after hash mismatch" || ok "setup: nothing unpacked after hash mismatch"

W4="$WORK/setup-badsig"; mkdir -p "$W4/dl"
cp "$FIX/tor-expert-bundle-windows-x86_64-15.0.23.tar.gz" "$W4/dl/"
cp "$FIX/sha256sums-bad-sig.txt" "$W4/dl/sha256sums-signed-build.txt"
cp "$FIX/sha256sums-bad-sig.txt.asc" "$W4/dl/sha256sums-signed-build.txt.asc"
expect_rc "setup: bad signature is refused" 4 -- env TOR_SETUP_TOOLS="$W4" FAKE_CURL_FIXDIR="$W4/dl" bash "$PKG/setup-tor.sh"
[ -d "$W4/tor-bundle" ] && bad "setup: nothing unpacked after bad signature" || ok "setup: nothing unpacked after bad signature"

W5="$WORK/setup-badfpr"; mkdir -p "$W5"
expect_rc "setup: wrong expected fingerprint is refused" 4 -- env TOR_SETUP_TOOLS="$W5" TOR_SETUP_KEY_FPR="0000000000000000000000000000000000AAAA" bash "$PKG/setup-tor.sh"

# the pinned key and nothing else: gpg --verify accepts a signature by ANY key in the keyring, so the per-run keyring
# must hold exactly the pinned key, and gpg's status lines - not its exit code alone - decide. The rogue, expired and
# subkey test keys come from fixtures/make-keybundle-fixtures.sh
KB="$WORK/keybundle.asc"; cat "$FIX/test-signer-pub.asc" "$FIX/test-rogue-pub.asc" > "$KB"
W8="$WORK/setup-bundle-rogue"; mkdir -p "$W8/dl"
cp "$FIX/tor-expert-bundle-windows-x86_64-15.0.23.tar.gz" "$FIX/sha256sums-signed-build.txt" "$W8/dl/"
cp "$FIX/sha256sums-signed-build.txt.rogue.asc" "$W8/dl/sha256sums-signed-build.txt.asc"
expect_rc_out "setup: a key file bundling a second key that signed the list is refused (the key count)" 4 "keyring holds 2 keys" \
  -- env TOR_SETUP_TOOLS="$W8" TOR_SETUP_GPG_KEY_FILE="$KB" FAKE_CURL_FIXDIR="$W8/dl" bash "$PKG/setup-tor.sh"
[ -d "$W8/tor-bundle" ] && bad "setup: ... and nothing is unpacked" || ok "setup: ... and nothing is unpacked"
expect_rc "setup: control - the pinned key alone, the list signed by the second key, is refused" 4 \
  -- env TOR_SETUP_TOOLS="$WORK/setup-pinned-alone" TOR_SETUP_GPG_KEY_FILE="$FIX/test-signer-pub.asc" FAKE_CURL_FIXDIR="$W8/dl" bash "$PKG/setup-tor.sh"
expect_rc_out "setup: control - the second key alone fails the pin" 4 "key fingerprint mismatch" \
  -- env TOR_SETUP_TOOLS="$WORK/setup-rogue-alone" TOR_SETUP_GPG_KEY_FILE="$FIX/test-rogue-pub.asc" FAKE_CURL_FIXDIR="$W8/dl" bash "$PKG/setup-tor.sh"
W9="$WORK/setup-bundle-pinned"; mkdir -p "$W9"
expect_rc_out "setup: a key file with a second key is refused even when the pinned key signed the list" 4 "keyring holds 2 keys" \
  -- env TOR_SETUP_TOOLS="$W9" TOR_SETUP_GPG_KEY_FILE="$KB" bash "$PKG/setup-tor.sh"
[ -d "$W9/tor-bundle" ] && bad "setup: ... and nothing is unpacked" || ok "setup: ... and nothing is unpacked"
W10="$WORK/setup-expired"; mkdir -p "$W10/dl"
cp "$FIX/tor-expert-bundle-windows-x86_64-15.0.23.tar.gz" "$FIX/sha256sums-signed-build.txt" "$W10/dl/"
cp "$FIX/sha256sums-signed-build.txt.expired.asc" "$W10/dl/sha256sums-signed-build.txt.asc"
expect_rc_out "setup: a good signature by the pinned key after it expired is refused (EXPKEYSIG, though gpg exits 0)" 4 "EXPKEYSIG" \
  -- env TOR_SETUP_TOOLS="$W10" TOR_SETUP_GPG_KEY_FILE="$FIX/test-expired-pub.asc" TOR_SETUP_KEY_FPR="$(cat "$FIX/test-expired.fpr")" FAKE_CURL_FIXDIR="$W10/dl" bash "$PKG/setup-tor.sh"
[ -d "$W10/tor-bundle" ] && bad "setup: ... and nothing is unpacked" || ok "setup: ... and nothing is unpacked"
# the real Tor Project key signs with a SUBKEY: VALIDSIG names the subkey first and the primary key last, and the pin
# is the primary - a check that read the first field would refuse every real install
W11="$WORK/setup-subkey"; mkdir -p "$W11/dl"
cp "$FIX/tor-expert-bundle-windows-x86_64-15.0.23.tar.gz" "$FIX/sha256sums-signed-build.txt" "$W11/dl/"
cp "$FIX/sha256sums-signed-build.txt.subkey.asc" "$W11/dl/sha256sums-signed-build.txt.asc"
expect_rc_out "setup: a signature by the pinned key's signing subkey is accepted (the real key's shape)" 0 "^signature: ok" \
  -- env TOR_SETUP_TOOLS="$W11" TOR_SETUP_GPG_KEY_FILE="$FIX/test-subkey-signer-pub.asc" TOR_SETUP_KEY_FPR="$(cat "$FIX/test-subkey-signer.fpr")" FAKE_CURL_FIXDIR="$W11/dl" bash "$PKG/setup-tor.sh"
[ -x "$W11/tor-bundle/tor/tor.exe" ] && ok "setup: ... and tor.exe is unpacked" || bad "setup: ... and tor.exe is unpacked"

# the three downloads are https-only (file:// kept for a local base): a plain http:// base is refused by curl itself,
# before any connection. The REAL curl runs here, through a wrapper that only records its exit code; nothing listens
# on 127.0.0.1 port 9, and nothing leaves the machine either way
CW="$WORK/curl-rc.sh"; export CURL_RC_LOG="$WORK/curl-rc.log"; : > "$CURL_RC_LOG"
cat > "$CW" <<'EOF'
#!/usr/bin/env bash
curl "$@"; rc=$?; echo "$rc" >> "$CURL_RC_LOG"; exit "$rc"
EOF
chmod +x "$CW"
expect_rc "setup: a plain http:// TOR_SETUP_BASE is refused" 2 \
  -- env TOR_SETUP_CURL="$CW" TOR_SETUP_BASE="http://127.0.0.1:9/" TOR_SETUP_TOOLS="$WORK/setup-http" bash "$PKG/setup-tor.sh"
[ "$(head -n 1 "$CURL_RC_LOG")" = 1 ] && ok "setup: ... by curl's protocol guard (curl exit 1), never a connection attempt" \
  || bad "setup: ... by curl's protocol guard (curl exit 1), never a connection attempt: curl exit codes $(tr '\n' ' ' < "$CURL_RC_LOG")"

expect_rc "setup: network failure is reported, not silently skipped" 2 -- env TOR_SETUP_TOOLS="$WORK/setup-neterr" FAKE_CURL_FAIL=1 bash "$PKG/setup-tor.sh"

# a local folder as TOR_SETUP_BASE (file://), read by the REAL curl - no network: an existing tarball + list + .asc
# become a verified install through the same checks; without the .asc it is refused, and the message says the file
# may be missing, not only "network"
LB="$WORK/localbase"; mkdir -p "$LB"
cp "$FIX/tor-expert-bundle-windows-x86_64-15.0.23.tar.gz" "$FIX/sha256sums-signed-build.txt" "$FIX/sha256sums-signed-build.txt.asc" "$LB/"
expect_rc_out "setup: a file:// TOR_SETUP_BASE installs from local copies (real curl), signature checked" 0 "^signature: ok" \
  -- env TOR_SETUP_CURL=curl TOR_SETUP_BASE="file:///$(W "$LB")/" TOR_SETUP_TOOLS="$WORK/setup-local" bash "$PKG/setup-tor.sh"
[ "$(sed -n 's/^tor_exe_sha256=//p' "$WORK/setup-local/.tor-verified" 2>/dev/null)" = "$(sha256sum "$WORK/setup-local/tor-bundle/tor/tor.exe" 2>/dev/null | awk '{print $1}')" ] \
  && [ -s "$WORK/setup-local/.tor-verified" ] && ok "setup: ... and records the installed tor.exe's hash" || bad "setup: ... and records the installed tor.exe's hash: $(ls -A "$WORK/setup-local")"
rm -f "$LB/sha256sums-signed-build.txt.asc"
expect_rc_out "setup: ... a missing .asc there is refused (rc 2), named as possibly missing" 2 \
  "download failed: sha256sums-signed-build.txt.asc from file:///.* (network error, no such file there, or a malformed base URL)" \
  -- env TOR_SETUP_CURL=curl TOR_SETUP_BASE="file:///$(W "$LB")/" TOR_SETUP_TOOLS="$WORK/setup-local-noasc" bash "$PKG/setup-tor.sh"
[ -d "$WORK/setup-local-noasc/tor-bundle" ] && bad "setup: ... and nothing is unpacked" || ok "setup: ... and nothing is unpacked"
# a SPACE in the local folder path: the real curl rejects it raw ("URL rejected: Malformed input");
# setup sends it as %20
LS="$WORK/local base"; mkdir -p "$LS"
cp "$FIX/tor-expert-bundle-windows-x86_64-15.0.23.tar.gz" "$FIX/sha256sums-signed-build.txt" "$FIX/sha256sums-signed-build.txt.asc" "$LS/"
expect_rc_out "setup: ... a space in the file:// folder path still installs (sent as %20)" 0 "^signature: ok" \
  -- env TOR_SETUP_CURL=curl TOR_SETUP_BASE="file:///$(W "$LS")/" TOR_SETUP_TOOLS="$WORK/setup-local-space" bash "$PKG/setup-tor.sh"

W6="$WORK/setup-evidence"; mkdir -p "$W6"
env TOR_SETUP_TOOLS="$W6" bash "$PKG/setup-tor.sh" > "$WORK/setup-evidence.out" 2>&1
grep -q '^sha256: ok - .* = [0-9a-f]\{64\}, the value listed in ' "$WORK/setup-evidence.out" \
  && ok "setup: prints the SHA-256 comparison" || bad "setup: prints the SHA-256 comparison: $(cat "$WORK/setup-evidence.out")"
grep -q '^signature: ok - good signature on .*; key fingerprint \([0-9A-F]\{40\}\) = the pinned \1$' "$WORK/setup-evidence.out" \
  && ok "setup: prints the signature and fingerprint comparison" || bad "setup: prints the signature and fingerprint comparison: $(cat "$WORK/setup-evidence.out")"

# the dirmngr gate (only when a WKD lookup is needed, i.e. no TOR_SETUP_GPG_KEY_FILE). A fake gpgconf reports dirmngr
# as FAKE_DIRMNGR (avail:runnable), and a fake gpg fails every call, so no WKD lookup can ever leave this test.
FB="$WORK/fakebin"; mkdir -p "$FB"
cat > "$FB/gpgconf" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--check-programs" ] && printf 'gpg:OpenPGP:/usr/bin/gpg:1:1:\ndirmngr:Network:/usr/bin/dirmngr:%s:\n' "${FAKE_DIRMNGR:-0:0}"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/gpg"; chmod +x "$FB/gpgconf" "$FB/gpg"
expect_rc "setup: no runnable dirmngr (WKD needed) is refused up front" 64 -- env -u TOR_SETUP_GPG_KEY_FILE PATH="$FB:$PATH" TOR_SETUP_TOOLS="$WORK/setup-nodirmngr" bash "$PKG/setup-tor.sh"
[ -e "$WORK/setup-nodirmngr" ] && bad "setup: nothing downloaded when dirmngr is missing" || ok "setup: nothing downloaded when dirmngr is missing"
FAKE_DIRMNGR=1:1 expect_out "setup: a runnable dirmngr passes the gate (then the fake gpg fails the WKD lookup)" "could not fetch the signing key via WKD" -- env -u TOR_SETUP_GPG_KEY_FILE PATH="$FB:$PATH" TOR_SETUP_TOOLS="$WORK/setup-dirmngr-ok" bash "$PKG/setup-tor.sh"
# the REAL gpgconf runs the gate here (only gpg is faked, so the WKD lookup still cannot leave the test), with HOME
# pointed at an empty scratch dir: the run must not create a .gnupg there (keyboxd's self-test would, without the
# gate's own throwaway GNUPGHOME)
FBG="$WORK/fakegpg"; mkdir -p "$FBG" "$WORK/fakehome"; cp "$FB/gpg" "$FBG/gpg"
env -u TOR_SETUP_GPG_KEY_FILE -u GNUPGHOME HOME="$WORK/fakehome" PATH="$FBG:$PATH" TOR_SETUP_TOOLS="$WORK/setup-realgate" bash "$PKG/setup-tor.sh" > /dev/null 2>&1
[ -e "$WORK/fakehome/.gnupg" ] && bad "setup: the dirmngr gate (real gpgconf) leaves no .gnupg in HOME" || ok "setup: the dirmngr gate (real gpgconf) leaves no .gnupg in HOME"

echo "== setup-tor.sh: a gone pinned version is not a dead end =="
# A 404 on the pinned version must name the gone version, point at the listing, and give an exact command -
# never an empty or half-built one. The listing is DATA from a web page (fixtures/torbrowser-listing*.html,
# the real one copied from a live fetch, the others synthetic edge cases): a picked version is only trusted
# when it is anchored N.N.N, so an instruction-like or malformed entry can never reach the message.
GL="$WORK/gonelisting"; mkdir -p "$GL"
AL="$WORK/listing-arglog.log"

: > "$AL"
out="$(env -u TOR_SETUP_BASE FAKE_CURL_404=1 FAKE_CURL_ARGLOG="$AL" TOR_SETUP_TOOLS="$GL/t1" bash "$PKG/setup-tor.sh" 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "setup: a 404 on the default base is exit 2"; else bad "setup: a 404 on the default base is exit 2 (rc=$rc): $out"; fi
case "$out" in
  *"15.0.23"*"dist.torproject.org/torbrowser/"*"TOR_SETUP_VERSION=15.0.24 bash setup-tor.sh"*)
    ok "setup: 404 message names the gone version, the listing, and the exact command with the real picked version" ;;
  *) bad "setup: 404 message names the gone version, the listing, and the exact command with the real picked version: $out" ;;
esac
grep -q 'dist\.torproject\.org/torbrowser/$' "$AL" \
  && ok "setup: the listing WAS requested on a default-base 404" || bad "setup: the listing WAS requested on a default-base 404: $(cat "$AL")"

: > "$AL"
out="$(env -u TOR_SETUP_BASE FAKE_CURL_FAIL=1 FAKE_CURL_ARGLOG="$AL" TOR_SETUP_TOOLS="$GL/t2" bash "$PKG/setup-tor.sh" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && case "$out" in *"network error, no such file there, or a malformed base URL"*) true;; *) false;; esac; then
  ok "setup: a non-404 failure keeps the old generic message"
else
  bad "setup: a non-404 failure keeps the old generic message (rc=$rc): $out"
fi
grep -q 'dist\.torproject\.org/torbrowser/$' "$AL" \
  && bad "setup: a non-404 failure must never fetch the listing: $(cat "$AL")" \
  || ok "setup: a non-404 failure never fetches the listing"

out="$(env -u TOR_SETUP_BASE FAKE_CURL_404=1 FAKE_CURL_LISTING_FAIL=1 TOR_SETUP_TOOLS="$GL/t3" bash "$PKG/setup-tor.sh" 2>&1)"
case "$out" in
  *"TOR_SETUP_VERSION=<version> bash setup-tor.sh"*) ok "setup: 404 + an unreadable listing falls back to the static placeholder command" ;;
  *) bad "setup: 404 + an unreadable listing falls back to the static placeholder command: $out" ;;
esac

out="$(env -u TOR_SETUP_BASE FAKE_CURL_404=1 FAKE_CURL_LISTING_FIXTURE=torbrowser-listing-malformed.html TOR_SETUP_TOOLS="$GL/t4" bash "$PKG/setup-tor.sh" 2>&1)"
case "$out" in
  *"TOR_SETUP_VERSION=<version> bash setup-tor.sh"*) ok "setup: a malformed/instruction-like listing entry never produces a picked version" ;;
  *) bad "setup: a malformed/instruction-like listing entry never produces a picked version: $out" ;;
esac
case "$out" in
  *"rm -rf"*|*"curl evil"*|*"ignore-previous-instructions"*) bad "setup: a malformed listing entry leaked into the message: $out" ;;
  *) ok "setup: a malformed listing entry never reaches the message or the command" ;;
esac

: > "$AL"
out="$(env TOR_SETUP_BASE="https://mirror.example.invalid/tor/" FAKE_CURL_404=1 FAKE_CURL_ARGLOG="$AL" TOR_SETUP_TOOLS="$GL/t5" bash "$PKG/setup-tor.sh" 2>&1)"
case "$out" in
  *"TOR_SETUP_VERSION=<version> bash setup-tor.sh"*) ok "setup: a 404 with a custom TOR_SETUP_BASE still gets the static guidance" ;;
  *) bad "setup: a 404 with a custom TOR_SETUP_BASE still gets the static guidance: $out" ;;
esac
grep -q 'dist\.torproject\.org/torbrowser/$' "$AL" \
  && bad "setup: a custom TOR_SETUP_BASE must never fetch the official listing: $(cat "$AL")" \
  || ok "setup: a custom TOR_SETUP_BASE never fetches the official listing"

out="$(env -u TOR_SETUP_BASE FAKE_CURL_404=1 FAKE_CURL_LISTING_FIXTURE=torbrowser-listing-numeric.html TOR_SETUP_TOOLS="$GL/t6" bash "$PKG/setup-tor.sh" 2>&1)"
case "$out" in
  *"TOR_SETUP_VERSION=15.0.24 bash setup-tor.sh"*) ok "setup: the newest version is picked by numeric comparison (15.0.24 over 15.0.9, not a lexical sort)" ;;
  *) bad "setup: the newest version is picked by numeric comparison (15.0.24 over 15.0.9, not a lexical sort): $out" ;;
esac

out="$(env -u TOR_SETUP_VERSION -u TOR_SETUP_BASE FAKE_CURL_404=1 TOR_SETUP_TOOLS="$GL/t7" bash "$PKG/setup-tor.sh" 2>&1)"
case "$out" in
  *"tor-expert-bundle-windows-x86_64-15.0.24.tar.gz"*) ok "setup: the default TOR_SETUP_VERSION is now 15.0.24" ;;
  *) bad "setup: the default TOR_SETUP_VERSION is now 15.0.24: $out" ;;
esac

echo "== fixtures =="
# the fixture tarballs ship with neutral owners: every member's owner field is numeric 0/0. A tar made on a
# workstation carries the account name in every member header, which grep -I never sees (found in review)
badown=""
for t in "$FIX"/*.tar.gz; do
  own="$(tar -tvzf "$t" 2>/dev/null | awk 'NF > 5 {print $2}' | sort -u | tr '\n' ' ')"
  [ "$own" = "0/0 " ] || badown="$badown ${t##*/} (owner fields not numeric 0/0, or unreadable);"
done
[ -z "$badown" ] && ok "fixtures: every tarball member is owned by numeric 0/0 - no account name in the tar headers" \
  || bad "fixtures: every tarball member is owned by numeric 0/0 - no account name in the tar headers:$badown"

echo "== pins =="
# the README's "Pinned as of" names the VER= and FPR= assignments of setup-tor.sh as the places to re-pin; a second
# assignment of either would silently win over the one a re-pin edits
nv="$(grep -cE '^\s*(export\s+)?VER=' "$PKG/setup-tor.sh")"; nf="$(grep -cE '^\s*(export\s+)?FPR=' "$PKG/setup-tor.sh")"
[ "$nv" = 1 ] && [ "$nf" = 1 ] && ok "pins: VER= and FPR= are each assigned exactly once in setup-tor.sh" \
  || bad "pins: VER= and FPR= are each assigned exactly once in setup-tor.sh (VER= x$nv, FPR= x$nf)"

echo "== privacy =="
# the shipped files carry no IPv4 address but loopback and the documentation ranges (RFC 5737: 192.0.2.0/24,
# 198.51.100.0/24); the one other IPv4-shaped token is the browser version inside the README's user-agent string,
# allowed only in its full form "Chrome/128.0.0.0" (the bare token would pass as an address, so it is not allowed).
# tests/work/, state/ and tools/ are not shipped (gitignored) and are skipped
hits="$(grep -rInoE '(Chrome/)?\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$PKG" --exclude-dir=work --exclude-dir=state --exclude-dir=tools --exclude-dir=.git 2>/dev/null \
  | grep -vE ':(127\.0\.0\.1|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|Chrome/128\.0\.0\.0)$')"
[ -z "$hits" ] && ok "privacy: no IPv4 address outside loopback and the documentation ranges in the shipped files" \
  || bad "privacy: an IPv4 address outside loopback and the documentation ranges in the shipped files: $hits"

echo
sk=""; [ "$SKIP" -gt 0 ] && sk=", $SKIP skipped"
echo "== $PASS passed, $FAIL failed$sk =="
rm -rf "$WORK"
[ "$FAIL" = 0 ]
