# debherder.sh

Installs and updates `.deb` packages published as GitHub release assets.

- Reads a plain-text list of `owner/repo` slugs.
- For each repo: fetches the latest release, downloads the matching `.deb`,
  verifies its SHA-256 (when one is published), and installs it via `apt-get`
  (or `gdebi`).
- Tracks installed versions in a state file, so subsequent runs only install
  when the release tag is newer than what's already installed.
- Two-tier cache (pending / rollback) so a failed sudo prompt or a flaky
  install doesn't cost you the download.

## Requirements

- Debian or Ubuntu (or a derivative) with `dpkg`, `apt-get`, `curl`, `python3`,
  `flock`, and the usual coreutils.
- Root, or `sudo` configured. For unattended runs, add a NOPASSWD rule for
  `apt-get` and `dpkg` (see [Sudo](#sudo)).

## Quick start

```bash
# 1. Put the script somewhere on your PATH
install -m 0755 debherder.sh ~/.local/bin/debherder

# 2. Add one or more repositories
debherder --add-repo cli/cli
debherder --add-repo sharkdp/bat

# 3. Preview what it would do
debherder --check
debherder --dry-run

# 4. Install / update
debherder
