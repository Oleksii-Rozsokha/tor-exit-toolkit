# Security

## Reporting a problem
1. Use GitHub's private vulnerability reporting: this repository's **Security** tab → **Report a
   vulnerability**. The report stays private until the problem is fixed.
2. If that form is not available to you, open a public issue that says only: "security issue, please open a
   private channel" - no details, no label. The maintainer opens a private channel from there.

There is no e-mail address for reports.

## What counts
- **The pinned-key check** in `setup-tor.sh`: any way a signature by a key other than the pinned Tor Project key
  (fingerprint `EF6E286DDA85EA2A4BA7DE684E2C6E8793298290`) could be accepted - a second key in the keyring, an
  expired or revoked key, a subkey of the wrong primary, a fingerprint compared loosely.
- **The download verification**: any way an unverified or tampered tarball could be unpacked - a SHA-256 or
  signature mismatch that does not refuse, a checksum taken from the wrong file, a download accepted over plain
  `http://`, a bad download left on disk.
- **Anything that could expose the real address**: a request that leaves the machine outside the Tor port, a DNS
  lookup made locally instead of through the exit, a redirect followed to plain `http://`, a log or message that
  writes the real address somewhere.
- **The binary check**: a way to run a `tor.exe` other than the one `setup-tor.sh` verified without the
  "unverified binary" note or the hash refusal.

## What does not count
A site that blocks Tor exits, a bootstrap that stalls, an exit country that Tor could not honour - these are
documented behaviour (README, "Troubleshooting"); open an ordinary issue for them.

## How reports are handled
The toolkit is a small two-script project maintained in spare time. A report gets a reply in the private report.
A public issue gets only a reply that opens a private channel - nothing of the problem is discussed in the
issue. Then a fix if it is confirmed, and an update of the README's "Pinned as of" section if a pin changes. The
offline test suite (`bash tests/run-tests.sh`) is where a fix for any of the points above gets its regression
case.
