#!/usr/bin/env bash
# tor-exit.sh - per-process Tor SOCKS proxy, one instance per port. No system proxy, no service, no route changes;
# only a command explicitly pointed at the port goes through Tor (see README "How it works").
#   tor-exit.sh start <cc> [port]   start an instance with exit country <cc> (two lowercase letters, e.g. de, nl)
#   tor-exit.sh stop <port>|--all   stop one instance, or (--all) every instance tracked in the state folder;
#                                    a bare `stop` stops nothing and lists what --all would stop
#   tor-exit.sh status [port]       show one instance, or every tracked instance
#   tor-exit.sh check [port]        prove a running instance really exits through Tor (check.torproject.org/api/ip);
#                                    also run automatically at the end of `start`
#   tor-exit.sh doctor              read-only preflight, no network: commands, binary (+ its recorded hash), GeoIP,
#                                    state folder, stale pid files, untracked tor.exe
# Exit codes: 0 ok | 1 the state folder cannot be created | 2 tor exited before bootstrapping (nothing left running)
#   | 3 a prerequisite is missing or there is nothing to act on: no tor binary; GeoIP missing (refused before
#     launch) or unloadable (tor launched, then stopped at once); no tracked instance; on `check`, a stale pid
#     file or a live process it cannot confirm; a missing state folder (status/stop/check); a doctor PROBLEM
#   | 4 the package's own tor.exe no longer matches the hash setup-tor.sh recorded (refused, nothing started)
#   | 5 bootstrap ceiling reached (stopped)
#   After a 3 from a GeoIP abort, and after a 5, nothing is left running - unless the message says the process
#   still shows after 10s; its files are then kept, for `stop <port>`.
#   | 6 the `check` request failed and the instance IS STILL RUNNING (also from `start`, whose last step is check)
#   | 9 the port already runs an instance, or holds a live tor.exe that cannot be confirmed | 64 usage, a bad argument, a bare `stop`, a missing required command
# env: TOR_EXIT_BIN (default <package>/tools/tor-bundle/tor/tor.exe, from setup-tor.sh)
#      TOR_EXIT_GEOIP_DIR (default <folder of TOR_EXIT_BIN>/../data - the same bundle's geoip + geoip6)
#      TOR_EXIT_STATE (default <package>/state)   TOR_EXIT_BOOTSTRAP_S (90) ceiling to wait for "Bootstrapped 100%"
#      TOR_EXIT_CURL (curl) override, for tests only   TOR_EXIT_DEFAULT_PORT (9199) used when start gets no port
#      TOR_EXIT_CHECK_S (60) how long `check` waits for check.torproject.org - it is usually the session's FIRST
#      fetch through a new circuit, and first fetches of up to ~49 s have been seen
# State (all under TOR_EXIT_STATE, gitignored): tor-<port>.pid, tor-<port>.cc, tor-<port>.torrc, tor-<port>-data/
# (Tor's own DataDirectory) - removed by `stop` and by a failed `start`; logs/tor-<port>-<YYYYMMDD-HHMMSS>.log and
# .stdio (local time) - KEPT by `stop`, so a failed run can still be read afterwards (README "Cleaning up the
# logs"). A NEW log file every run: grepping an old run's "Bootstrapped 100%" can match a PREVIOUS run and return
# before this one has actually bootstrapped -
# the one failure this design exists to avoid (see README, "log per run").
# Exit country is Tor's own claim (ExitNodes + StrictNodes), not an independent measurement; `check` says so.
# Parallel instances are supported BY DESIGN: each has its own port, data directory and log; nothing is shared
# except this state folder, and each instance's files are named by its own port.
set -u
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$SD"
BIN="${TOR_EXIT_BIN:-$PKG/tools/tor-bundle/tor/tor.exe}"
# GeoIP data comes from the SAME bundle as the binary (the Expert Bundle's layout: <bundle>/tor/tor.exe next to
# <bundle>/data/geoip + geoip6), never from this package's folder: without it ExitNodes+StrictNodes cannot pick any
# exit, and every country stalls at ~50% until the ceiling. A fixed <package>/tools/tor-bundle/data here once broke
# the documented TOR_EXIT_BIN reuse of another bundle for every country (found in real use).
GEODIR="${TOR_EXIT_GEOIP_DIR:-$(dirname "$BIN")/../data}"
STATE="${TOR_EXIT_STATE:-$PKG/state}"
LOGS="$STATE/logs"
CEIL="${TOR_EXIT_BOOTSTRAP_S:-90}"
CURL="${TOR_EXIT_CURL:-curl}"
DEFPORT="${TOR_EXIT_DEFAULT_PORT:-9199}"
CHECK_S="${TOR_EXIT_CHECK_S:-60}"
die() { echo "tor-exit: $1" >&2; exit "${2:-1}"; }
W() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
# local date-time for the log names, so "the run at 14:24" is findable by eye
stamp() { date +%Y%m%d-%H%M%S; }
need_cmds() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c" 64; done; }
geo_base() { (cd "$GEODIR" 2>/dev/null && pwd) || printf '%s' "$GEODIR"; }
# prints the first GeoIP file that cannot be read, if any - in C:/ form only when it exists: cygpath cannot resolve a
# `..` through a folder that is not there yet (before an install, <bin>/../data) and printed an error line plus an
# EMPTY path instead (seen in a from-scratch test); a missing one is printed as is
geo_missing() { local g p; for g in geoip geoip6; do p="$1/$g"; [ -r "$p" ] && continue; if [ -e "$p" ]; then W "$p"; else printf '%s' "$p"; fi; return 0; done; return 1; }
# the binary's provenance, one line on stdout. 0 = the package's own tor.exe, matching the hash setup-tor.sh recorded
# after its verified unpack; 1 = the package's own tor.exe, NOT matching; 2 = nothing to compare against (a binary
# outside this package's install, or an install from before the hash was recorded) - never a faked "verified"
bin_check() {
  local rec="$PKG/tools/.tor-verified" want got
  if ! [ "$BIN" -ef "$PKG/tools/tor-bundle/tor/tor.exe" ]; then
    echo "unverified binary: $(W "$BIN") - outside this package's verified install, so there is no recorded hash to compare; know where it came from"
    return 2
  fi
  want="$(sed -n 's/^tor_exe_sha256=//p' "$rec" 2>/dev/null)"
  if [ -z "$want" ]; then
    echo "no recorded tor.exe hash in $(W "$rec") (an install by an older setup-tor.sh) - run setup-tor.sh --force to record one"
    return 2
  fi
  got="$(sha256sum "$BIN" | awk '{print $1}')"
  [ "$got" = "$want" ] && { echo "tor.exe matches the hash setup-tor.sh recorded ($got)"; return 0; }
  echo "tor.exe hash $got differs from the one setup-tor.sh recorded ($want) - the binary changed since install; re-run setup-tor.sh --force"
  return 1
}
# Git Bash/MSYS gives `$!` its OWN pid, for an MSYS script and for a native .exe alike (probed with ping.exe: $! 37037,
# Windows PID 16856); tasklist/taskkill need the Windows PID, exposed at /proc/<msys-pid>/winpid, which another bash can
# still read after the launching one has exited. The fallback to the number itself covers a file holding a Windows PID.
winpid() { cat "/proc/$1/winpid" 2>/dev/null || printf '%s' "$1"; }
# The process image to trust: the binary's own file name, tor.exe for every standard bundle. MSYS runs "tor" as
# tor.exe, so a TOR_EXIT_BIN without the extension still names image tor.exe - add it, or no instance would ever be
# recognized again (a start that its own check then calls stale: an invisible orphan).
IMAGE="${BIN##*/}"; case "${IMAGE,,}" in *.exe) ;; *) IMAGE="$IMAGE.exe";; esac
# A pid file holds only a number, and Windows reuses numbers: after a crash or a reboot a stale pid file can name an
# unrelated program. So every liveness check and every kill of a pid-file process also matches the image name.
running() { local w; w="$(winpid "$1")"; tasklist //NH //FO CSV //FI "PID eq $w" //FI "IMAGENAME eq $IMAGE" 2>/dev/null | grep -q "\"$w\""; }
killpid() { local w; w="$(winpid "$1")"; taskkill //FI "PID eq $w" //FI "IMAGENAME eq $IMAGE" //F >/dev/null 2>&1; }
# the exact -f argument `start` passes to tor for <port> - one function builds it, at launch and at the identity check
torrc_arg() { W "$STATE/tor-$1.torrc"; }
lower_slash() { printf '%s' "$1" | tr '\\' '/' | tr '[:upper:]' '[:lower:]'; }
# the -f argument in <pid>'s command line. /proc/<pid>/cmdline is argv, NUL-separated; for a native process the last
# element has no trailing NUL, and a path with a space keeps its Windows quotes (both seen in a probe)
torrc_of() {
  local a prev=""
  while IFS= read -r -d '' a || [ -n "$a" ]; do
    if [ "$prev" = "-f" ]; then a="${a#\"}"; printf '%s' "${a%\"}"; return 0; fi
    prev="$a"
  done < "/proc/$1/cmdline"
  return 1
}
# Is <pid> THIS state folder's instance on <port>? pid + image is not identity: a copied or stale pid file can name
# another session's tor.exe. Only the process's own command line is - its -f torrc must be THIS port's torrc, compared
# as a FILE (-ef), so the same folder reached by another spelling (a junction, an 8.3 short name, C:/ vs /c/, case)
# still counts as ours. Read from /proc/<pid>/cmdline, which MSYS keeps for every process it launched, native
# tor.exe included; there is no fallback to pid + image when it cannot be read. Codes 2 and 4 mean "do not decide":
# nothing is killed and nothing is cleaned up.
# 0 = ours | 1 = not a live $IMAGE | 2 = a live $IMAGE whose command line cannot be read
# 3 = a live $IMAGE, another instance | 4 = a live $IMAGE running THIS port's torrc name from a folder that is not ours
ours() {
  local c t mine="$STATE/tor-$2.torrc"
  [ -n "$1" ] && running "$1" || return 1
  c="$(tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline")" && [ -n "$c" ] || return 2
  t="$(torrc_of "$1")" || return 3   # a readable command line with no -f: not started by this script
  if [ -e "$mine" ] && [ -e "$t" ]; then
    [ "$t" -ef "$mine" ] && return 0
  elif [ "$(lower_slash "$t")" = "$(lower_slash "$(torrc_arg "$2")")" ]; then
    return 0   # a torrc gone from disk: only the string is left to compare
  fi
  case "$(lower_slash "${t##*[/\\]}")" in "tor-$2.torrc") return 4;; esac
  return 3
}
why() { # why <ours-code> <pid>: the plain words for a non-0 answer of ours()
  case "$1" in
    1) echo "pid ${2:-?} is not a live $IMAGE";;
    2) echo "pid $2 is a live $IMAGE whose command line cannot be read, so it cannot be confirmed as this port's instance";;
    4) echo "pid $2 is a live $IMAGE running this port's torrc from another folder ($(torrc_of "$2")), so it cannot be confirmed as this port's instance";;
    *) echo "pid $2 is a live $IMAGE, but not this port's instance (its command line does not name this port's torrc)";;
  esac
}
# Undo a failed start the way `stop` would: end the process if it is still alive, then remove its pid file, country
# file, torrc and data folder; the logs stay - they hold the reason. ABORTED says what happened, for the message.
# `kill` by PID is safe here, unlike on a pid-file path: <pid> is this very bash's own child (the wait loop's kill -0
# relies on the same); killpid is the image-filtered kill that `stop` uses. If the process survives, its files stay,
# so `stop <port>` can still find it.
abort_start() { # abort_start <pid> <port>
  local t=0
  ABORTED="stopped"
  if kill -0 "$1" 2>/dev/null; then
    killpid "$1"; kill "$1" 2>/dev/null
    while kill -0 "$1" 2>/dev/null && [ "$t" -lt 10 ]; do sleep 1; t=$((t + 1)); done
    if kill -0 "$1" 2>/dev/null; then
      ABORTED="but it still shows after 10s (pid $1) - its files are kept for \`stop $2\`; check by hand"
      return 1
    fi
  fi
  rm -f "$STATE/tor-$2.pid" "$STATE/tor-$2.cc" "$STATE/tor-$2.torrc"; rm -rf "$STATE/tor-$2-data"
}
tracked_ports() { local f p out=""; for f in "$STATE"/tor-*.pid; do [ -f "$f" ] || continue; p="${f##*/tor-}"; out="$out ${p%.pid}"; done; printf '%s' "${out# }"; }
# stop/status only see pid files in THEIR state folder, so a tor.exe started with another TOR_EXIT_STATE is invisible
# to them. When the command found nothing of its own (nothing tracked here, and `stop` found no pid file to act on),
# that is said loudly - a plain "nothing tracked" would reassure falsely; otherwise (instances tracked, or a `stop`
# that just stopped this session's last one) a one-line note is enough. Never killed from here: it may be another
# session's instance, or a Tor Browser's own tor.exe.
untracked_warn() { # untracked_warn [acted]   acted=1: this command found and handled a pid file of its own
  local acted="${1:-0}" mine="" n=0 f pids
  for f in "$STATE"/tor-*.pid; do [ -f "$f" ] && { n=$((n + 1)); mine="$mine $(winpid "$(cat "$f" 2>/dev/null)")"; }; done
  pids="$(tasklist //NH //FO CSV //FI "IMAGENAME eq $IMAGE" 2>/dev/null \
    | awk -F'","' -v mine=" $mine " 'NF > 1 && index(mine, " " $2 " ") == 0 { printf "%s ", $2 }')"
  [ -n "$pids" ] || return 0
  if [ "$n" = 0 ] && [ "$acted" = 0 ]; then
    echo "WARNING: $IMAGE is running but not tracked in $(W "$STATE"): pid ${pids% } - started with another TOR_EXIT_STATE? Run status/stop with that same TOR_EXIT_STATE, or check by hand (a Tor Browser also runs as tor.exe - do not kill by name)" >&2
  else
    echo "note: other $IMAGE running outside this state folder: pid ${pids% }"
  fi
}
# status/stop/check only READ the state folder: a missing one is reported, never created (a mistyped TOR_EXIT_STATE
# used to create a fresh empty folder - inside the package by default - and then answer "nothing tracked"). An
# existing one is made absolute, so torrc_arg matches what `start` passed however the folder was spelled.
need_state() {
  [ -d "$STATE" ] && { STATE="$(cd "$STATE" && pwd)"; LOGS="$STATE/logs"; return 0; }
  echo "tor-exit: state folder does not exist: $(W "$STATE") - nothing is tracked there (a mistyped TOR_EXIT_STATE?)" >&2
  untracked_warn; exit 3
}

# tasklist/taskkill for every command; curl and node only where a check runs (start ends with one), so a machine
# without node can still stop and inspect its instances
need_cmds tasklist taskkill

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  start)
    cc="${1:-}"; port="${2:-$DEFPORT}"
    [[ "$cc" =~ ^[a-z]{2}$ ]] || die "usage: tor-exit.sh start <cc> [port]   cc = two-letter lowercase country code, e.g. de, nl" 64
    [[ "$port" =~ ^[0-9]{2,5}$ ]] || die "port must be numeric" 64
    need_cmds "$CURL" node sha256sum
    [ -x "$BIN" ] || die "tor.exe not found at $(W "$BIN") - run setup-tor.sh first (or set TOR_EXIT_BIN)" 3
    bv="$(bin_check)"; case $? in 1) die "$bv - refusing to run it" 4;; 2) echo "note: $bv";; esac
    geobase="$(geo_base)"
    # refuse in a second, before anything is launched or written: a missing file would otherwise cost the whole
    # bootstrap ceiling, with the cause buried in the log
    if gm="$(geo_missing "$geobase")"; then
      die "GeoIP file missing: $gm - Tor cannot pin an exit country without it. It is looked for in the data/ folder of the binary's own bundle; set TOR_EXIT_GEOIP_DIR to the folder that holds geoip and geoip6" 3
    fi
    mkdir -p "$STATE" "$LOGS" || die "cannot create $(W "$STATE")" 1
    STATE="$(cd "$STATE" && pwd)"; LOGS="$STATE/logs"   # absolute, so torrc_arg is the same string for stop/status
    pidf="$STATE/tor-$port.pid"
    if [ -f "$pidf" ]; then
      pid=$(cat "$pidf" 2>/dev/null)
      ours "$pid" "$port"; o=$?
      [ "$o" = 0 ] && die "an instance is already running on port $port (pid $pid) - stop it first, or pick another port" 9
      { [ "$o" = 2 ] || [ "$o" = 4 ]; } && die "port $port: $(why "$o" "$pid") - check by hand before starting here" 9
      rm -f "$pidf"
    fi
    data="$STATE/tor-$port-data"; rm -rf "$data"; mkdir -p "$data"
    ts="$(stamp)"; log="$LOGS/tor-$port-$ts.log"; stdio="$LOGS/tor-$port-$ts.stdio"
    torrc="$STATE/tor-$port.torrc"
    cat > "$torrc" <<RC
SocksPort 127.0.0.1:$port
DataDirectory $(W "$data")
GeoIPFile $(W "$geobase/geoip")
GeoIPv6File $(W "$geobase/geoip6")
ExitNodes {$cc}
StrictNodes 1
Log notice file $(W "$log")
RC
    # truncate BEFORE launching, unconditionally: `ts` has 1-second resolution, so a stop immediately followed
    # by a start on the same port within the same second would otherwise reuse last run's filename, whose
    # content already says "Bootstrapped 100%" - the bootstrap-wait grep below would match at once against a
    # process that has not actually finished, defeating the whole point of a log per run (found in review)
    : > "$log"
    # redirected, and never inherited from the caller: a background process that keeps stdout/stderr open
    # makes any caller capturing this script's output via `$(...)` hang forever waiting for EOF that never
    # comes (tor never exits on its own) - this bit us in testing, so it is fixed here, not just in the test
    "$BIN" -f "$(torrc_arg "$port")" > "$stdio" 2>&1 < /dev/null &
    pid=$!
    echo "$pid" > "$pidf"
    printf '%s\n' "$cc" > "$STATE/tor-$port.cc"
    echo "starting: port $port, exit country $cc, pid $pid, log $(W "$log")"
    echo "note: Tor may print \"Path ... is relative ... Is this what you wanted?\" for these paths - harmless, expected"
    waited=0
    while [ "$waited" -lt "$CEIL" ]; do
      # GeoIP files that exist but cannot be opened show up only here, as one [warn] among the harmless "Path ...
      # is relative" ones - stop at once, quoting it, instead of spending the ceiling on a bootstrap that cannot finish
      if gw="$(grep -m1 "Failed to open GEOIP" "$log" 2>/dev/null)"; then
        abort_start "$pid" "$port"
        die "tor could not load its GeoIP data, so no exit country can be pinned: $gw (see $(W "$log")) - $ABORTED" 3
      fi
      if grep -q "Bootstrapped 100%" "$log" 2>/dev/null; then
        # Tor's own "Parsing GEOIP IPv4 file <path>." notice is the proof of which GeoIP data it actually loaded
        g4="$(sed -n 's/.*Parsing GEOIP IPv4 file \(.*\)\.$/\1/p' "$log" | head -1)"
        echo "bootstrapped: ${waited}s, GeoIP loaded: ${g4:-not confirmed - no \"Parsing GEOIP\" line in the log}"
        break
      fi
      # kill -0, not running()/tasklist: this loop runs in the SAME bash process that forked tor, where a
      # plain liveness check is reliable at once - going through tasklist here raced against /proc/<pid>/winpid
      # not being populated yet right after fork, and reported a live process as already exited (seen in testing)
      if ! kill -0 "$pid" 2>/dev/null; then
        abort_start "$pid" "$port"
        die "tor exited before bootstrapping - the reason is usually in $(W "$stdio") (full Tor log: $(W "$log"))" 2
      fi
      sleep 2; waited=$((waited + 2))
    done
    if ! grep -q "Bootstrapped 100%" "$log" 2>/dev/null; then
      abort_start "$pid" "$port"
      die "bootstrap did not finish in ${CEIL}s (ceiling; see $(W "$log")) - $ABORTED" 5
    fi
    "$SD/tor-exit.sh" check "$port"
    ;;

  stop)
    port="${1:-}"
    need_state
    # a bare stop used to stop every instance in the state folder - in parallel use, other sessions' ones too. Now it
    # stops nothing and lists them; stopping them all takes an explicit --all
    if [ -z "$port" ]; then
      t="$(tracked_ports)"; [ -n "$t" ] && t="tracked ports: $t" || t="nothing tracked there"
      die "stop needs a port, or --all for every instance tracked in $(W "$STATE") ($t) - nothing stopped" 64
    fi
    if [ "$port" = "--all" ]; then port=""; pidfs=("$STATE"/tor-*.pid); else pidfs=("$STATE/tor-$port.pid"); fi
    any=0
    for pidf in "${pidfs[@]}"; do
      [ -f "$pidf" ] || continue
      any=1
      p="${pidf##*/tor-}"; p="${p%.pid}"
      pid=$(cat "$pidf" 2>/dev/null)
      ours "$pid" "$p"; o=$?
      if [ "$o" = 2 ] || [ "$o" = 4 ]; then
        echo "port $p: $(why "$o" "$pid") - nothing killed, files kept; check by hand" >&2
        continue
      elif [ "$o" != 0 ]; then
        echo "port $p: not running (stale pid file: $(why "$o" "$pid")) - nothing killed, files cleaned up"
      else
        killpid "$pid"
        waited=0
        while running "$pid"; do sleep 1; waited=$((waited + 1)); [ "$waited" -gt 10 ] && break; done
        if running "$pid"; then
          echo "port $p: still shows in tasklist after 10s (pid $pid) - check by hand" >&2
        else
          echo "port $p: stopped, confirmed by tasklist (pid $pid)"
        fi
      fi
      rm -f "$pidf" "$STATE/tor-$p.cc" "$STATE/tor-$p.torrc"
      rm -rf "$STATE/tor-$p-data"
    done
    [ "$any" = 1 ] || echo "nothing tracked${port:+ on port $port}"
    untracked_warn "$any"
    ;;

  status)
    port="${1:-}"
    need_state
    if [ -n "$port" ]; then pidfs=("$STATE/tor-$port.pid"); else pidfs=("$STATE"/tor-*.pid); fi
    any=0
    for pidf in "${pidfs[@]}"; do
      [ -f "$pidf" ] || continue
      any=1
      p="${pidf##*/tor-}"; p="${p%.pid}"
      pid=$(cat "$pidf" 2>/dev/null)
      cc=$(cat "$STATE/tor-$p.cc" 2>/dev/null || echo "?")
      ours "$pid" "$p"; o=$?
      if [ "$o" = 0 ]; then
        echo "port $p: running, pid $pid, exit country $cc (Tor's own claim)"
      elif [ "$o" = 2 ] || [ "$o" = 4 ]; then
        echo "port $p: $(why "$o" "$pid") - files kept; check by hand" >&2
      else
        echo "port $p: not running (stale pid file: $(why "$o" "$pid")) - cleaning up"
        rm -f "$pidf" "$STATE/tor-$p.cc" "$STATE/tor-$p.torrc"
        rm -rf "$STATE/tor-$p-data"
      fi
    done
    [ "$any" = 1 ] || echo "nothing tracked${port:+ on port $port}"
    untracked_warn
    ;;

  check)
    port="${1:-}"
    need_cmds "$CURL" node
    need_state
    if [ -z "$port" ]; then
      shopt -s nullglob; cand=("$STATE"/tor-*.pid); shopt -u nullglob
      [ "${#cand[@]}" = 1 ] || die "usage: tor-exit.sh check <port>   (0 or 2+ tracked instances - name the port)" 64
      p="${cand[0]##*/tor-}"; port="${p%.pid}"
    fi
    pidf="$STATE/tor-$port.pid"
    [ -f "$pidf" ] || die "no tracked instance on port $port" 3
    pid=$(cat "$pidf")
    ours "$pid" "$port"; o=$?
    [ "$o" = 0 ] || die "port $port: $(why "$o" "$pid")$({ [ "$o" = 2 ] || [ "$o" = 4 ]; } && echo " - check by hand" || echo " (stale pid file)")" 3
    out=$("$CURL" -sS --socks5-hostname "127.0.0.1:$port" -m "$CHECK_S" https://check.torproject.org/api/ip 2>&1) \
      || die "check request failed: $out - the instance on port $port is STILL RUNNING: run check again, or stop it" 6
    parsed=$(printf '%s' "$out" | node -e '
      let s=""; process.stdin.on("data",d=>s+=d);
      process.stdin.on("end",()=>{ try { const j=JSON.parse(s); console.log((j.IsTor?"true":"false")+" ip="+(j.IP||"?")); }
        catch { console.log("parse-error raw="+JSON.stringify(s.slice(0,120))); } });' 2>/dev/null)
    cc=$(cat "$STATE/tor-$port.cc" 2>/dev/null || echo "?")
    echo "port $port: $parsed - requested exit country $cc (Tor's own claim, from ExitNodes+StrictNodes - not an independent measurement)"
    ;;

  doctor)
    # read-only, no network: one look at everything `start` needs, and at what earlier runs left behind. It
    # changes nothing (a stale pid file is only named - `status` cleans it). PROBLEM = `start` would fail.
    n=0
    say() { echo "$1"; case "$1" in PROBLEM*) n=$((n + 1));; esac; }
    for c in "$CURL" node sha256sum; do
      command -v "$c" >/dev/null 2>&1 && say "ok - command found: $c" || say "PROBLEM - required command not found: $c"
    done
    if [ -x "$BIN" ]; then
      say "ok - binary: $(W "$BIN")"
      bv="$(bin_check)"; case $? in 0) say "ok - $bv";; 1) say "PROBLEM - $bv";; *) say "note - $bv";; esac
    else
      say "PROBLEM - tor.exe not found at $(W "$BIN") - run setup-tor.sh first (or set TOR_EXIT_BIN)"
    fi
    gb="$(geo_base)"
    if gm="$(geo_missing "$gb")"; then say "PROBLEM - GeoIP file missing: $gm (set TOR_EXIT_GEOIP_DIR?)"
    else say "ok - GeoIP: $(W "$gb")/geoip and geoip6"; fi
    if [ ! -d "$STATE" ]; then say "note - state folder does not exist yet: $(W "$STATE") (start creates it)"
    elif [ -w "$STATE" ]; then say "ok - state folder writable: $(W "$STATE")"; STATE="$(cd "$STATE" && pwd)"
    else say "PROBLEM - state folder not writable: $(W "$STATE")"; fi
    for f in "$STATE"/tor-*.pid; do
      [ -f "$f" ] || continue
      p="${f##*/tor-}"; p="${p%.pid}"; pid="$(cat "$f" 2>/dev/null)"
      ours "$pid" "$p"; o=$?
      if [ "$o" = 0 ]; then say "note - port $p: running, pid $pid"
      elif [ "$o" = 2 ] || [ "$o" = 4 ]; then say "note - port $p: $(why "$o" "$pid") - check by hand"
      else say "note - port $p: stale pid file ($(why "$o" "$pid")) - \`status $p\` cleans it up"; fi
    done
    untracked_warn
    [ "$n" = 0 ] || die "doctor: $n problem(s) - see the PROBLEM lines" 3
    echo "doctor: no problems found"
    ;;

  *)
    die "usage: tor-exit.sh start <cc> [port] | stop <port>|--all | status [port] | check [port] | doctor" 64
    ;;
esac
