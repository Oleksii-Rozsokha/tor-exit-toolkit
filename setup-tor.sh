#!/usr/bin/env bash
# setup-tor.sh - download the Tor Expert Bundle for Windows, verify its SHA-256 AND the GPG signature on the
# checksum list, then unpack into tools/tor-bundle/. Portable: nothing installed system-wide, nothing added to
# PATH, no service, no registry change.
#   setup-tor.sh [--force]     --force re-downloads and re-verifies even if a verified tor.exe is already there
# Network: 4 requests - the 3 files from dist.torproject.org, plus 1 WKD lookup of the signing key by gpg (through
# dirmngr) on a torproject.org host; 3 when TOR_SETUP_GPG_KEY_FILE is set (no WKD lookup then). A TOR_SETUP_BASE
# of file:///C:/<folder>/ takes the 3 files from local copies instead (same checks; only the WKD lookup, if any, is
# network); a space in that folder path is sent as %20. On a 404 for the pinned version, WITH the default base
# only (never a custom TOR_SETUP_BASE): 1 more request, a listing of https://dist.torproject.org/torbrowser/, read
# as data to name the current versions - never fetched for a non-404 failure, and never with a custom base.
# Output: one line per check (the SHA-256 comparison, the key fingerprint + signature) and one final line.
# Record: tools/.tor-verified - the tarball's sha256, the key fingerprint, the version, and the unpacked tor.exe's
# own sha256 (tor_exe_sha256, compared by tor-exit.sh start before every run of the package's own binary).
# env: TOR_SETUP_VERSION (15.0.24)   TOR_SETUP_BASE (default https://dist.torproject.org/torbrowser/$VERSION/)
#      TOR_SETUP_TOOLS (default <package>/tools)   TOR_SETUP_CURL (curl) override, for tests only
#      TOR_SETUP_GPG_KEY_FILE  when set, import this local public-key file instead of a WKD lookup (useful
#      offline, or if this network cannot reach WKD) - the key-count and fingerprint checks below run either way,
#      so an untrusted key file still cannot pass silently
#      TOR_SETUP_GNUPGHOME  a GNUPG homedir to use instead of the default: a fresh /tmp/tor-setup-gpg.XXXXXX
#      folder (a SHORT path whatever TMPDIR says, see gpgtmp below), removed on exit; a homedir you
#      pass is left in place - THIS SCRIPT NEVER TOUCHES YOUR REAL ~/.gnupg
#      TOR_SETUP_KEY_FPR  override the expected key fingerprint - TEST USE ONLY, so a self-signed test key can
#      be checked end to end offline; a real install never sets this and always checks Tor Project's own value
# Fingerprint every real install must match (Tor Project's own published value, character for character):
#   EF6E286DDA85EA2A4BA7DE684E2C6E8793298290
# Exit: 0 ok (or already installed and verified, and --force not given) | 1 unpack problem, or the temp folder for
#       the dirmngr check or the tools folder cannot be created | 2 network: a download failed, a file is missing
#       at TOR_SETUP_BASE, or the WKD key lookup failed | 3 SHA-256 mismatch, or the tarball is not listed in the
#       sums file | 4 signature refused: bad, by an expired or revoked key, more than one key in the keyring,
#       fingerprint mismatch, or the key file could not be imported | 64 usage; a required command, or dirmngr, not found.
# On exit 3 or 4 NOTHING is unpacked and the bad download is deleted - a checksum mismatch is refused, not repaired.
set -u
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$SD"
VER="${TOR_SETUP_VERSION:-15.0.24}"
# whether BASE is still the package's own default (unset TOR_SETUP_BASE) - only then do we fall back to the
# directory listing on a 404: a custom base (a mirror, or a local file:// copy) has no such listing to read
BASE_IS_DEFAULT=1; [ -n "${TOR_SETUP_BASE:-}" ] && BASE_IS_DEFAULT=0
BASE="${TOR_SETUP_BASE:-https://dist.torproject.org/torbrowser/$VER/}"
LISTING="https://dist.torproject.org/torbrowser/"
# curl rejects a raw space in a file:// URL ("URL rejected: Malformed input"), and a local folder path often has one
case "$BASE" in file://*) BASE="${BASE// /%20}" ;; esac
TOOLS="${TOR_SETUP_TOOLS:-$PKG/tools}"
CURL="${TOR_SETUP_CURL:-curl}"
FPR="${TOR_SETUP_KEY_FPR:-EF6E286DDA85EA2A4BA7DE684E2C6E8793298290}"
die() { echo "setup-tor: $1" >&2; exit "${2:-1}"; }
# picks the newest version-dir from a torbrowser/ Apache listing page, compared numerically per component
# (15.0.9 < 15.0.24, not lexically) and skipping anything with an alpha suffix (16.0a13) or any shape other
# than N.N.N. The listing is DATA from the web: an instruction-like or malformed entry never passes the
# anchored pattern below, so it can never reach a message or the command line this script prints.
pick_from_listing() {
  local best="" cand b1 b2 b3 c1 c2 c3
  while IFS= read -r cand; do
    [[ "$cand" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [ -z "$best" ]; then best="$cand"; continue; fi
    IFS=. read -r b1 b2 b3 <<< "$best"; IFS=. read -r c1 c2 c3 <<< "$cand"
    if [ "$c1" -gt "$b1" ] || { [ "$c1" -eq "$b1" ] && [ "$c2" -gt "$b2" ]; } \
       || { [ "$c1" -eq "$b1" ] && [ "$c2" -eq "$b2" ] && [ "$c3" -gt "$b3" ]; }; then
      best="$cand"
    fi
  done < <(printf '%s' "$1" | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' | sed -E 's/href="(.*)\/"/\1/')
  printf '%s' "$best"
}
# the message for a gone version: WITH a picked version (anchored N.N.N, re-checked here - never trust one gate
# alone on web data) when the listing was readable and parsed, otherwise static guidance with a placeholder -
# never an empty or half-built command either way
version_gone_msg() {
  local base="$1" tarball="$2" ver="$3" picked="$4"
  [[ "$picked" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || picked=""
  if [ -n "$picked" ]; then
    echo "download failed: $tarball from $base (404) - version $ver looks gone from dist.torproject.org. See $LISTING for the current versions; pick the newest one without an alpha \"a\" suffix (currently $picked) and run: TOR_SETUP_VERSION=$picked bash setup-tor.sh"
  else
    echo "download failed: $tarball from $base (404) - version $ver looks gone from dist.torproject.org. See $LISTING for the current versions; pick the newest one without an alpha \"a\" suffix and run: TOR_SETUP_VERSION=<version> bash setup-tor.sh"
  fi
}
# gpg's temp homedirs: always a SHORT POSIX path under /tmp (Git Bash maps it to the user's temp folder), never taken
# from TMPDIR - gpg-agent builds a socket name from the homedir, and both a deeply nested path (~98 characters seen)
# and a C:/-form one (a shell that exports a Windows-form TMPDIR) fail with "':' are not allowed in the socket name"
gpgtmp() { mktemp -d /tmp/tor-setup-gpg.XXXXXX; }
FORCE=0
if [ $# -gt 0 ]; then
  [ "$1" = "--force" ] || die "usage: setup-tor.sh [--force]" 64
  FORCE=1
fi
for c in "$CURL" tar gpg gpgconf sha256sum; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c" 64; done
# the WKD key lookup runs through gpg's dirmngr; asked via gpgconf, because gpg finds it there, not on PATH.
# --check-programs, not --list-components: the latter only names the program path (no field says whether it is
# installed); --check-programs adds avail and runnable flags (fields 4 and 5) - it runs each component's
# --gpgconf-test once, a local self-test, no network. It runs in its OWN throwaway GNUPGHOME: without one, keyboxd's
# self-test creates ~/.gnupg/public-keys.d in the user's real home (seen in testing) - this script never
# touches ~/.gnupg, and the probe dir is removed right after.
if [ -z "${TOR_SETUP_GPG_KEY_FILE:-}" ]; then
  probe="$(gpgtmp)" || die "cannot create a temp dir for the dirmngr check" 1
  GNUPGHOME="$probe" gpgconf --check-programs 2>/dev/null | grep -q '^dirmngr:[^:]*:[^:]*:1:1'; have=$?
  GNUPGHOME="$probe" gpgconf --kill all >/dev/null 2>&1; rm -rf "$probe"
  [ "$have" = 0 ] || die "required gpg component not found: dirmngr (needed for the WKD key lookup; or set TOR_SETUP_GPG_KEY_FILE)" 64
fi

TARBALL="tor-expert-bundle-windows-x86_64-$VER.tar.gz"
SUMS="sha256sums-signed-build.txt"

if [ "$FORCE" = 0 ] && [ -x "$TOOLS/tor-bundle/tor/tor.exe" ] && [ -f "$TOOLS/.tor-verified" ]; then
  echo "already installed and verified: $TOOLS/tor-bundle/tor/tor.exe (use --force to re-download and re-verify)"
  grep -q '^tor_exe_sha256=' "$TOOLS/.tor-verified" \
    || echo "note: this install's record has no tor.exe hash (an older setup-tor.sh) - run with --force to add it; tor-exit.sh start says so on every run until then"
  exit 0
fi

mkdir -p "$TOOLS" || die "cannot create $TOOLS"
WORK="$TOOLS/.setup-work"; rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

tcode="$("$CURL" -sS --proto =https,file --fail -o "$WORK/$TARBALL" -w '%{http_code}' "$BASE$TARBALL" 2>/dev/null)"; trc=$?
if [ "$trc" != 0 ]; then
  if [ "$tcode" = 404 ]; then
    # the listing is only fetched for the package's own default base - a custom base (a mirror, a local
    # file:// copy) gets the same static guidance, with the <version> placeholder, but no extra request
    picked=""
    if [ "$BASE_IS_DEFAULT" = 1 ] && lst="$("$CURL" -sS --proto =https --proto-redir =https --fail -m 20 "$LISTING" 2>/dev/null)"; then
      picked="$(pick_from_listing "$lst")"
    fi
    die "$(version_gone_msg "$BASE" "$TARBALL" "$VER" "$picked")" 2
  fi
  die "download failed: $TARBALL from $BASE (network error, no such file there, or a malformed base URL)" 2
fi
"$CURL" -sS --proto =https,file --fail -o "$WORK/$SUMS"     "$BASE$SUMS"       || die "download failed: $SUMS from $BASE (network error, no such file there, or a malformed base URL)" 2
"$CURL" -sS --proto =https,file --fail -o "$WORK/$SUMS.asc" "$BASE$SUMS.asc"   || die "download failed: $SUMS.asc from $BASE (network error, no such file there, or a malformed base URL)" 2

# 1) hash: the tarball must match its own line in the signed sums file
want=$(grep -F "$TARBALL" "$WORK/$SUMS" | awk '{print $1}')
[ -n "$want" ] || die "$TARBALL is not listed in $SUMS - version mismatch?" 3
got=$(sha256sum "$WORK/$TARBALL" | awk '{print $1}')
[ "$got" = "$want" ] || die "SHA-256 mismatch: got $got, expected $want" 3
echo "sha256: ok - $TARBALL = $got, the value listed in $SUMS"

# 2) signature: the sums file itself must carry a good signature from Tor Project's key, and the key's
#    fingerprint must equal the one Tor Project publishes (character for character, not just "gpg says good")
# GNUPGHOME must be a SHORT path: gpg-agent builds a Unix-domain-socket path from it, and a homedir nested deep
# under the package (observed: ~98 characters) makes gpg-agent fail with "':' are not allowed in the socket
# name" on Windows - so the default lives under /tmp (gpgtmp above), not under this package, unless overridden.
GNUPGHOME="${TOR_SETUP_GNUPGHOME:-$(gpgtmp)}"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME" 2>/dev/null
export GNUPGHOME
# from here on, EVERY exit - a refusal after gpg has run included - first stops this homedir's gpg-agent/dirmngr,
# then removes the temp homedir (kill before rm: gpgconf finds the agent through the homedir); a homedir you
# passed yourself is left in place
if [ -n "${TOR_SETUP_GNUPGHOME:-}" ]; then
  trap 'gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1; rm -rf "$WORK"' EXIT
else
  trap 'gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1; rm -rf "$WORK" "$GNUPGHOME"' EXIT
fi
if [ -n "${TOR_SETUP_GPG_KEY_FILE:-}" ]; then
  gpg --quiet --import "$TOR_SETUP_GPG_KEY_FILE" >/dev/null 2>&1 || die "could not import $TOR_SETUP_GPG_KEY_FILE" 4
else
  gpg --quiet --auto-key-locate nodefault,wkd --locate-keys torbrowser@torproject.org >/dev/null 2>&1 \
    || die "could not fetch the signing key via WKD (network problem, or set TOR_SETUP_GPG_KEY_FILE to a local copy)" 2
fi
# the per-run temp keyring must hold EXACTLY ONE primary key, and it must be the pinned one: gpg --verify accepts a
# signature by ANY key in the keyring, so a key file or WKD answer bundling a second key could otherwise sign the
# list with that key while the pin is compared against the first one (not queried by identity: WKD and a local
# file can carry a different UID)
keys=$(gpg --with-colons --list-keys 2>/dev/null | grep -c '^pub:')
[ "$keys" = 1 ] || die "keyring holds $keys keys, expected exactly the pinned one - refusing" 4
fpr=$(gpg --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
[ "$fpr" = "$FPR" ] || die "key fingerprint mismatch: got ${fpr:-none}, expected $FPR - refusing" 4
# judged by gpg's status lines, not its exit code alone: a good signature by an EXPIRED key exits 0 (EXPKEYSIG +
# VALIDSIG). GOODSIG names only the signing key's long id (Tor Project signs with a subkey); VALIDSIG's LAST field
# is the PRIMARY key's fingerprint, so that field is the one compared with the pin
st=$(gpg --quiet --status-fd 1 --verify "$WORK/$SUMS.asc" "$WORK/$SUMS" 2>/dev/null); vrc=$?
for s in "EXPKEYSIG:the signing key has expired" "REVKEYSIG:the signing key is revoked" "BADSIG:the signature is bad"; do
  printf '%s\n' "$st" | grep -q "^\[GNUPG:\] ${s%%:*} " && die "GPG signature on $SUMS refused: ${s%%:*} - ${s#*:}" 4
done
printf '%s\n' "$st" | grep -q '^\[GNUPG:\] GOODSIG ' || die "GPG signature on $SUMS refused: no GOODSIG" 4
printf '%s\n' "$st" | awk -v p="$FPR" '$1=="[GNUPG:]" && $2=="VALIDSIG" && $NF==p {f=1} END {exit !f}' \
  || die "GPG signature on $SUMS refused: no VALIDSIG by the pinned key $FPR" 4
[ "$vrc" = 0 ] || die "GPG signature on $SUMS did not verify (gpg exit $vrc)" 4
echo "signature: ok - good signature on $SUMS; key fingerprint $fpr = the pinned $FPR"
gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1

# 3) unpack, only now that both checks passed. The real tarball is FLAT (data/, docs/, tor/ at its own root,
# no wrapping folder) - an earlier version of this script assumed a tor-bundle/ top level that only existed
# because someone had made that folder by hand; fixed after a review caught it against the real download.
rm -rf "$TOOLS/tor-bundle"; mkdir -p "$TOOLS/tor-bundle"
# --force-local: GNU tar reads "C:/..." (a TOR_SETUP_TOOLS given in Windows form) as host "C" plus a remote path
tar --force-local -xzf "$WORK/$TARBALL" -C "$TOOLS/tor-bundle" || die "unpack failed" 1
[ -x "$TOOLS/tor-bundle/tor/tor.exe" ] || die "unpacked, but tor.exe is missing - bundle layout changed upstream?" 1
# the unpacked tor.exe's own hash, taken from the tarball that just passed both checks: tor-exit.sh start compares it
# before every run, so a binary swapped after install is refused instead of run
exe=$(sha256sum "$TOOLS/tor-bundle/tor/tor.exe" | awk '{print $1}')
printf 'sha256=%s\nfingerprint=%s\nversion=%s\ntor_exe_sha256=%s\n' "$got" "$fpr" "$VER" "$exe" > "$TOOLS/.tor-verified"
echo "installed and verified: $TOOLS/tor-bundle/tor/tor.exe ($VER)"
