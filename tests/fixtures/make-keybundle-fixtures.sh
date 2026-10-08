#!/usr/bin/env bash
# make-keybundle-fixtures.sh - regenerates EVERY test key fixture of run-tests.sh: the primary test signer (the key
# the suite pins and imports, its good signature, and the copy of that signature that is the bad-signature case),
# then the "pinned key and nothing else" cases - a second (rogue) key, an expired key, and a key that signs with a
# subkey. NO NETWORK: gpg only generates keys and signs, locally, in a fresh temp homedir under /tmp (its gpg-agent
# stopped, then the folder removed, on every exit). The SECRET PARTS NEVER SHIP: only public keys, fingerprints and
# detached signatures are written beside this script. Every key is a test key with an example.invalid UID - none is,
# or stands in for, the real Tor Project key. Every signature is over the existing sha256sums-signed-build.txt (left
# unchanged), so the fixture tarball still matches its line in every case.
# Run: bash tests/fixtures/make-keybundle-fixtures.sh   (new keys each run: the .asc/.fpr/-pub.asc files change, the
# cases and their results do not - the suite reads the .fpr files)
# The two tarball fixtures are NOT made here. To regenerate them from their extracted contents (extraction keeps every
# member's mtime; numeric 0/0 owners and a nameless gzip header mean no account name ships - the suite checks the owners):
#   cd <the extracted folder> && tar --sort=name --owner=0 --group=0 --numeric-owner -cf ../bundle.tar data docs tor
#   gzip -n -9 -c ../bundle.tar > tor-expert-bundle-windows-x86_64-15.0.23.tar.gz
#   cp tor-expert-bundle-windows-x86_64-15.0.23.tar.gz tor-expert-bundle-windows-x86_64-15.0.23-corrupt.tar.gz
#   printf 'x' >> tor-expert-bundle-windows-x86_64-15.0.23-corrupt.tar.gz     # one appended byte: tar refuses it, its sha256 differs
#   sha256sum tor-expert-bundle-windows-x86_64-15.0.23.tar.gz    # -> the hash line of sha256sums-signed-build.txt AND sha256sums-bad-sig.txt
# then run this script, so every signature is over the updated list. (The lines above are the ones that made the shipped tarballs.)
set -u
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$FIX/sha256sums-signed-build.txt"
# a SHORT /tmp path whatever TMPDIR says, as setup-tor.sh does: gpg-agent builds a socket name from the homedir
H="$(mktemp -d /tmp/tor-fixgen.XXXXXX)" || { echo "cannot create a temp gpg homedir"; exit 1; }
trap 'gpgconf --homedir "$H" --kill all >/dev/null 2>&1; rm -rf "$H"' EXIT
chmod 700 "$H"
# --yes: in --batch mode gpg refuses to overwrite an existing -o file ("signing failed: File exists"), and every
# .asc here exists from the previous run
g() { gpg --homedir "$H" --batch --yes --quiet --pinentry-mode loopback --passphrase '' "$@"; }
fpr_of() { gpg --homedir "$H" --with-colons --list-keys "$1" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'; }
fail() { echo "make-keybundle-fixtures: $1"; exit 1; }

# the primary test signer: the key run-tests.sh pins (test-signer.fpr) and imports (test-signer-pub.asc); its
# signature over the list is the good case, and a copy of that same signature beside the TAMPERED list is the
# bad-signature case (sha256sums-bad-sig.txt.asc)
g --quick-gen-key "Test Signer <signer@example.invalid>" ed25519 sign never || fail "test signer not generated"
P="$(fpr_of signer@example.invalid)"; [ -n "$P" ] || fail "test signer has no fingerprint"
g -u "$P!" --armor --detach-sign -o "$FIX/sha256sums-signed-build.txt.asc" "$LIST" || fail "signer signature failed"
cp "$FIX/sha256sums-signed-build.txt.asc" "$FIX/sha256sums-bad-sig.txt.asc" || fail "bad-sig copy failed"
g --armor --export "$P" > "$FIX/test-signer-pub.asc" || fail "signer export failed"
printf '%s' "$P" > "$FIX/test-signer.fpr"

# a second, unrelated key: bundled with the pinned test key it must be refused (the key count), alone it fails the pin
g --quick-gen-key "rogue test key <rogue@example.invalid>" ed25519 sign never || fail "rogue key not generated"
R="$(fpr_of rogue@example.invalid)"; [ -n "$R" ] || fail "rogue key has no fingerprint"
g -u "$R!" --armor --detach-sign -o "$FIX/sha256sums-signed-build.txt.rogue.asc" "$LIST" || fail "rogue signature failed"
g --armor --export "$R" > "$FIX/test-rogue-pub.asc" || fail "rogue export failed"

# a key that signed while it was valid and has expired since: made and used at a faked time in 2020 with a 1-day
# expiry, so a verify at any later date reports EXPKEYSIG - together with VALIDSIG, and gpg exit 0
g --faked-system-time 20200101T000000! --quick-gen-key "expired test key <expired@example.invalid>" ed25519 sign 1d \
  2>/dev/null || fail "expired key not generated"
E="$(fpr_of expired@example.invalid)"; [ -n "$E" ] || fail "expired key has no fingerprint"
g --faked-system-time 20200101T120000! -u "$E!" --armor --detach-sign -o "$FIX/sha256sums-signed-build.txt.expired.asc" \
  "$LIST" 2>/dev/null || fail "expired-key signature failed"
g --armor --export "$E" > "$FIX/test-expired-pub.asc" || fail "expired export failed"
printf '%s' "$E" > "$FIX/test-expired.fpr"

# the real Tor Project key's shape: a certify-only primary key plus a signing subkey that makes the signature -
# gpg's VALIDSIG then names the subkey first and the primary key LAST, and the pin is the primary
g --quick-gen-key "subkey test key <subkey@example.invalid>" ed25519 cert never || fail "subkey test key not generated"
S="$(fpr_of subkey@example.invalid)"; [ -n "$S" ] || fail "subkey test key has no fingerprint"
g --quick-add-key "$S" ed25519 sign never || fail "signing subkey not added"
g -u "$S" --armor --detach-sign -o "$FIX/sha256sums-signed-build.txt.subkey.asc" "$LIST" || fail "subkey signature failed"
g --armor --export "$S" > "$FIX/test-subkey-signer-pub.asc" || fail "subkey test key export failed"
printf '%s' "$S" > "$FIX/test-subkey-signer.fpr"

echo "written to $FIX: test-signer-pub.asc + .fpr, test-rogue-pub.asc, test-expired-pub.asc + .fpr, test-subkey-signer-pub.asc"
echo "+ .fpr, sha256sums-signed-build.txt.asc (+ its copy sha256sums-bad-sig.txt.asc) and"
echo "sha256sums-signed-build.txt.{rogue,expired,subkey}.asc - public keys, fingerprints and signatures only"
