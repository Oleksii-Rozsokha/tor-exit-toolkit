# Disclaimer

This software is provided "as is", without warranty of any kind, express or implied - no warranty of
merchantability, fitness for a particular purpose, or non-infringement. The authors accept no liability for
any claim, damage or other consequence arising from its use (see `LICENSE`).

**Lawful use is your responsibility.** Laws on anonymity networks, on reading region-restricted content and on
circumventing access controls differ by country. Before you use this toolkit, check what applies in your own
jurisdiction and under the terms of the sites you read. The authors do not advise on that and cannot.

**Intended use, and nothing else.** The toolkit exists for one purpose, stated in the README's "Intended use"
section: reading public pages that refuse a region, through a per-process Tor exit, with one `curl` command
pointed at the port. It is not for logins or accounts, not for getting past bot protection or a human
verification, not for anything system-wide, and not for anything a site's terms or your law forbid. Any other
use is outside what this software is for.

**What the exit sees.** A Tor exit relay is a stranger's machine. Anything you send through it that is not
end-to-end encrypted can be read there. The recipe in the README requests `https://` only and refuses a
redirect to plain `http://`; never send logins, passwords or personal data through the exit.
