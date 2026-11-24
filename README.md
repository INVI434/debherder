# debherder

Install and update `.deb` packages that are published as GitHub release
assets.

- Reads a plain-text list of `owner/repo` slugs.
- For each repo: fetches the latest release, picks the matching `.deb`,
  verifies its SHA-256 (when one is published), and installs it via
  `apt-get` (or `gdebi`).
- Tracks installed versions in a state file, so subsequent runs only install
  when the release is newer than what's already there.
- Two-tier cache so a failed sudo prompt or a flaky install doesn't cost you
  the download.

## Requirements

Debian or Ubuntu (or a derivative) with `dpkg`, `apt-get`, `curl`, `python3`,
`flock`, and coreutils. Root, or `sudo`. For unattended runs, a NOPASSWD rule
for `apt-get` and `dpkg` - see [Sudo](#sudo).

## Quick start

```bash
# Install
install -m 0755 debherder.sh ~/.local/bin/debherder

# Add repos
debherder --add-repo cli/cli
debherder --add-repo sharkdp/bat

# Preview
debherder --check
debherder --dry-run

# Install / update
debherder
```

Repos live at `~/.config/debherder/repos.list`. You can edit it directly  
(one `owner/repo` per line, `#` starts a comment).

## Common commands

```bash
debherder                     # check, download, verify, install
debherder --check             # report available updates, no download
debherder --dry-run           # download + verify, no install
debherder --repo owner/name   # restrict to one repo
debherder --status            # config, installed versions, cache, recent log
debherder --list-assets r/n   # list a release's assets (diagnostic)
debherder --cache-info        # pending and rollback cache contents
debherder --clear-cache       # clear all cache (or: pending | rollback)
```
## Configuration

Optional config file: `~/.config/debherder/config.env`. Sourced as bash:

```bash
ARCH=amd64
KEYWORD=musl
INSTALLER=apt                # or gdebi
AUTO_DOWNGRADE_ON_FAIL=true
REQUIRE_CHECKSUM=true
```

Full variable list:  
[`documentation/manual.md`](https://github.com/INVI434/debherder/blob/main/documentation/manual.md#configuration-variables).

## Sudo

Sudo is used only for the install step. The password prompt, if needed, is  
deferred to just before the first install - after downloads finish.

For unattended runs (cron, systemd timer):

```text
# /etc/sudoers.d/debherder  (validate: visudo -cf …)
Cmnd_Alias DEBHERDER = /usr/bin/apt-get, /usr/bin/dpkg
youruser ALL=(root) NOPASSWD: DEBHERDER
```

## Cache

- `pending/` - verified downloads not yet installed. Reused on the next run  
    and re-verified each time. Cleared on successful install.
    
- `rollback/` - the most recent installed version per package. Used to roll  
    back if a future install fails and `AUTO_DOWNGRADE_ON_FAIL=true`.

Both live under `~/.local/state/debherder/cache/`. A soft limit  
`CACHE_MAX_MB` (default 500) warns when exceeded; nothing is auto-deleted.

## Plugins

Executable scripts in `~/.local/state/debherder/plugins.d/*.sh` are invoked  
with `<hook> <repo_slug> <version> <status>` at `pre_install`, `post_install`,  
and `dry_run`. See the  
[manual](https://github.com/INVI434/debherder/blob/main/documentation/manual.md#plugin-system) and  
[`examples/plugins/notify.sh`](https://github.com/INVI434/debherder/blob/main/examples/plugins/notify.sh).

## Documentation

Full reference, configuration tables, workflows, and troubleshooting:

**[`documentation/manual.md`](https://github.com/INVI434/debherder/blob/main/documentation/manual.md)**

## License

MIT. See [`LICENSE`](https://github.com/INVI434/debherder/blob/main/LICENSE).
