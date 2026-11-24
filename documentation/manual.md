
# debherder - manual
Version 2.7.2.
## Contents
1. [Overview](#overview)
2. [Installation](#installation)
3. [Configuration file](#configuration-file)
4. [Repository list](#repository-list)
5. [Command reference](#command-reference)
6. [Configuration variables](#configuration-variables)
7. [Cache](#cache)
8. [Plugin system](#plugin-system)
9. [Sudo and privilege escalation](#sudo-and-privilege-escalation)
10. [State file format](#state-file-format)
11. [File layout](#file-layout)
12. [Exit codes](#exit-codes)
13. [Common workflows](#common-workflows)
14. [Troubleshooting](#troubleshooting)
---
## Overview
`debherder` maintains a set of `.deb` packages published as GitHub release
assets. For each configured repository:
1. Fetch the latest release metadata from the GitHub API.
2. Skip the repo if the release tag is not newer than what's installed, or
   if the actual installed deb version (queried from `dpkg-query`) is newer.
3. Select the correct `.deb` asset by architecture, then keyword.
4. Reuse a pending cached copy if one exists; otherwise download and verify
   the asset's SHA-256.
5. Install with `apt-get` (default) or `gdebi`, escalating via `sudo` only
   for the install step.
6. Record the new version in the state file and update the rollback cache.
The script is a single bash file. It has no runtime dependency on `gdebi`
unless you set `INSTALLER=gdebi`.
> **Paths in this manual** reflect the defaults in the script
> (`debherder` namespace). If you rename the script or its defaults,
> adjust accordingly.
---
## Installation
### 1. Place the script
```bash
install -m 0755 debherder.sh ~/.local/bin/debherder
```

Ensure `~/.local/bin` is on `PATH`. If you keep the script as  
`debherder.sh` and don't rename it, substitute `debherder` for `debherder`  
throughout this manual.

### 2. Verify dependencies

```bash
command -v curl python3 dpkg dpkg-deb dpkg-query sha256sum awk sort flock du grep find
```

Install anything missing. If you plan to use `INSTALLER=gdebi`, also install  
`gdebi`.

### 3. Configure sudo for unattended runs

The script does not require root. Sudo is used only around the installer. For  
cron / systemd timer use, add a NOPASSWD rule (see  
Sudo).

### 4. Add repositories

```bash
debherder --add-repo cli/cli
```

Or edit `~/.config/debherder/repos.list` directly.

### 5. Test

```bash
debherder --check
debherder --dry-run
```

### 6. Schedule (optional)

See Common workflows for a systemd timer example.

---

## Configuration file

**Location:** `~/.config/debherder/config.env` (respects `XDG_CONFIG_HOME`).  
Override with `PKG_UPDATER_CONFIG=/path/to/file`, or `--config <path>` on the  
command line.

**Format:** bash — the file is `source`d.

```bash
# ~/.config/debherder/config.env
ARCH=amd64
KEYWORD=gnu
INSTALLER=apt
AUTO_DOWNGRADE_ON_FAIL=true
ROLLBACK_KEEP=2
```

Every variable is documented in  
Configuration variables. Environment variables  
set inline on the command line take precedence over the file:

```bash
ARCH=arm64 debherder --dry-run
```

An annotated sample is at  
[`examples/config.env.example`](https://../examples/config.env.example).

---

## Repository list

**Location:** `~/.config/debherder/repos.list` (respects `XDG_CONFIG_HOME`).  
Override with `REPOS_FILE=/path/to/file`.

**Format:** one `owner/repo` per line. `#` starts a comment. Blank lines are  
ignored. Whitespace around the slug is trimmed.

```text
# line-managed by debherder --add-repo
cli/cli
sharkdp/bat
# junegunn/fzf    # commented out
```

**Management:**

```bash
debherder --add-repo owner/repo
debherder --remove-repo owner/repo
```

Both paths apply the same validation: exactly one `/`, non-empty `owner` and  
`repo`, no `.` or `..` components, and only characters `[A-Za-z0-9_.-]`.

---

## Command reference

Run `debherder --help` for the built-in summary.

### Modes (mutually exclusive)

|Flag|Effect|
|---|---|
|_(none)_|Full update run|
|`--status`|Print configuration, tracked versions, cache state, recent log; exit|
|`--check`|Report available updates; no download, no install, no cache write|
|`--dry-run`|Download and verify assets, but do not install|
|`--add-repo <owner/repo>`|Append a slug to `repos.list`|
|`--remove-repo <owner/repo>`|Remove a slug from `repos.list`|
|`--list-assets <owner/repo>`|Print the latest release's asset names|
|`--cache-info`|Print pending and rollback cache contents|
|`--clear-cache [type]`|Clear cache; `type` = `pending`, `rollback`, or `all` (default)|

### Filters and modifiers

|Flag|Effect|
|---|---|
|`--repo <owner/repo>`|Process only this repo|
|`--force`|Install even if the version is not newer than what's installed|
|`--config <path>`|Use an alternate config file|

### Meta

|Flag|Effect|
|---|---|
|`--version`|Print version and exit|
|`-h`, `--help`|Print usage and exit|

### Mode interactions

- `--dry-run` and `--check` combine with `--repo`; they do not combine with  
    `--add-repo` / `--remove-repo` (last one wins in argument parsing).
    
- `--dry-run --clear-cache` reports what would be removed without clearing.
    
- `--check --force` on an up-to-date repo reports "skipping"; `--check`  
    never forces a reinstall, because there is nothing to reinstall.
    
- `--check` never reads or writes the pending cache and never requires an  
    installer.

---

## Configuration variables

All variables can be set in `config.env` or as environment variables.

### Arch and asset selection

|Variable|Default|Notes|
|---|---|---|
|`ARCH`|`dpkg --print-architecture`|Target architecture. Empty string matches any architecture. Aliased internally: `amd64 ↔ x86_64/x64`, `arm64 ↔ aarch64`, `armhf ↔ armv7l/armv7`, `armel ↔ armv6l/armv6`, `i386 ↔ i686/x86`. Post-download verification reads `Architecture:` from the `.deb` and rejects mismatches (except `all`).|
|`KEYWORD`|_(unset)_|Extra substring filter on the asset filename, e.g. `musl` or `gnu`.|
|`MULTI_DEB_SELECTION`|_(unset)_|When multiple `.deb` assets match and stdin is not a TTY: `first`, `last`, or 1-indexed number. Without this, multi-match is an error in non-interactive runs. Ignored when a TTY is available — you get an interactive menu.|

### Installer

|Variable|Default|Notes|
|---|---|---|
|`INSTALLER`|`apt`|`apt` (or `apt-get`): `apt-get install -y --allow-downgrades <deb>`. `gdebi`: `gdebi -n <deb>`.|
|`AUTO_DOWNGRADE_ON_FAIL`|`false`|On install failure, attempt rollback to the previous version — first from the rollback cache, then from apt repositories.|
|`ROLLBACK_KEEP`|`1`|Number of previous versions to keep per package in the rollback cache. Positive integer.|

### Checksums

|Variable|Default|Notes|
|---|---|---|
|`REQUIRE_CHECKSUM`|`false`|When `true`, fail the repo if no SHA-256 can be extracted from the release.|

Checksum sources, tried in order:

1. A dedicated `*sha256*` or `*checksums*` asset (`.asc` / `.sig` excluded).
    
2. The per-asset `digest` field of the release.
    
3. A 64-hex token on the line mentioning the `.deb` name in the release body.

### Cache

|Variable|Default|Notes|
|---|---|---|
|`USE_PENDING_CACHE`|`true`|When `false`, always download; do not stage or reuse pending.|
|`CACHE_MAX_MB`|`500`|Soft size warning threshold for `cache/`. Never auto-deletes.|

### GitHub API

|Variable|Default|Notes|
|---|---|---|
|`GITHUB_TOKEN`|_(unset)_|Sent as `Authorization: Bearer` on API calls **and** asset downloads. Required for private repos.|
|`GITHUB_API_BASE`|`https://api.github.com`|For GitHub Enterprise.|

### Privilege escalation

|Variable|Default|Notes|
|---|---|---|
|`SUDO`|`sudo`|The sudo binary. Empty disables escalation (installs will fail unless running as root).|
|`SUDO_OPTS`|`-n`|Flags passed to `$SUDO`. Set empty for interactive sudo.|

### Logging

|Variable|Default|Notes|
|---|---|---|
|`LOG_MAX_BYTES`|`1048576`|When `updater.log` exceeds this size, it is rotated to `.1` at the next run.|

### Paths

|Variable|Default|
|---|---|
|`PKG_UPDATER_CONFIG`|`${XDG_CONFIG_HOME:-$HOME/.config}/debherder/config.env`|
|`REPOS_FILE`|`${XDG_CONFIG_HOME:-$HOME/.config}/debherder/repos.list`|
|`XDG_STATE_HOME`|`$HOME/.local/state` (standard XDG)|

State and cache always live under `$XDG_STATE_HOME/debherder/`. See  
File layout.

### Other

|Variable|Default|Notes|
|---|---|---|
|`DRY_RUN`|`false`|Equivalent to `--dry-run`.|
|`DEBIAN_FRONTEND`|`noninteractive`|Set inline on every installer call, so `sudo` cannot strip it.|

---

## Cache

Two independent caches under `$XDG_STATE_HOME/debherder/cache/`.

### `pending/`

**Purpose.** Preserve a verified `.deb` when the install step couldn't run  
(sudo prompt timed out, user was AFK, disk hiccup). The next run reuses it  
without re-downloading.

**Layout.**

```text
cache/pending/<owner_repo>/
  meta
  <filename>.deb
```

`meta` is a small `key=value` file:

```text
tag=2.25.8
sha256=...
filename=windscribe_2.25.8_amd64.deb
staged_at=2026-11-25T...Z
```

**Lifecycle.**

|Event|Action|
|---|---|
|Download + verify succeeds|Staged (unless `DRY_RUN`)|
|Install succeeds|Committed (removed)|
|Install fails|Kept — next run retries|
|GitHub's latest tag ≠ cached `tag`|Pruned|
|`sha256` mismatch on reuse|Pruned|
|`meta` missing or malformed|Pruned|
|`meta` tag matches installed version (orphan)|Pruned|
|`DRY_RUN`|Pruning is skipped; intent is logged|

**Disable.** `USE_PENDING_CACHE=false`.

### `rollback/`

**Purpose.** Hold the last installed `.deb` per package so an install failure  
can roll back without contacting apt repositories.

**Layout.**

```text
cache/rollback/<package>_<deb_version>.deb
```

**Lifecycle.**

|Event|Action|
|---|---|
|Install succeeds|New `.deb` copied here; `ROLLBACK_KEEP` (default 1) newest retained|
|Install fails, `AUTO_DOWNGRADE_ON_FAIL=true`|Most recent matching `.deb` is installed|
|No cached `.deb` available|Falls back to `apt-get install -y --allow-downgrades pkg=old_version`|

**Pruning.** Deterministic: after each successful install of package `P`,  
only the newest `ROLLBACK_KEEP` files matching `P_*.deb` are retained.

### Manual management


```bash
debherder --cache-info              # show contents
debherder --clear-cache             # clear everything
debherder --clear-cache pending     # only pending
debherder --clear-cache rollback    # only rollback
debherder --dry-run --clear-cache   # report what would be removed
```

---

## Plugin system

Executable scripts under `$XDG_STATE_HOME/debherder/plugins.d/*.sh` are  
invoked as:

```text
<plugin> <hook> <repo_slug> <version> <status>
```

- `hook` — `pre_install`, `post_install`, or `dry_run`.
    
- `repo_slug` — `owner/repo`.
    
- `version` — the release tag being installed.
    
- `status` — see table below.

A non-zero exit is logged as a warning but does not abort the run.

### Hooks and statuses

|Hook|Status|When|
|---|---|---|
|`pre_install`|`verified`|After download, checksum, and arch verification, before invoking the installer. `$VT_TARGET_DEB` is exported and points at the `.deb`.|
|`dry_run`|`verified`|After download and verify when `--dry-run` is active.|
|`post_install`|`success`|Installer returned 0.|
|`post_install`|`failure`|Installer returned non-zero; recovery has already run.|
|`post_install`|`rollback`|Rollback to a cached `.deb` succeeded.|
|`post_install`|`checksum_failed`|Checksum verification failed.|
|`post_install`|`arch_mismatch`|Downloaded `.deb`'s `Architecture:` disagrees with `ARCH`.|
|`post_install`|`metadata_error`|Couldn't read `Package` or `Version` from the `.deb`.|
|`post_install`|`sudo_unavailable`|`refresh_sudo` failed (no TTY + password required, or wrong password).|

### Example plugin

See [`examples/plugins/notify.sh`](https://../examples/plugins/notify.sh). Mark any  
plugin executable with `chmod +x`; non-executable files are skipped.

---

## Sudo and privilege escalation

The script never runs as root end-to-end. Sudo is used only around the  
installer call. Two checks gate it:

### `verify_sudo_available` — startup, silent

Runs after config and dependency checks, before any download.

|Condition|Result|
|---|---|
|`EUID == 0`|Pass|
|`SUDO` empty|Pass with a warning; installs will probably fail|
|`sudo -n -v` succeeds|Pass silently (NOPASSWD or primed cache)|
|`sudo -n -v` fails, stdin is a TTY|Pass; logs "password will be requested before the first install"|
|`sudo -n -v` fails, no TTY|**Exit 1** with a sudoers hint|

### `refresh_sudo` — install-time, may prompt

Called immediately before each installer invocation.

|Condition|Result|
|---|---|
|`EUID == 0` or `SUDO` empty|Pass|
|`sudo -n -v` succeeds|Pass (refreshes cache)|
|`sudo -n -v` fails, TTY available|Run `sudo -v` — the one place the password is requested|
|`sudo -n -v` fails, no TTY|Return 2; caller emits `sudo_unavailable` and skips the repo|

### Recommended sudoers rule

```text
# /etc/sudoers.d/debherder
Cmnd_Alias PKG_UPDATER = /usr/bin/apt-get, /usr/bin/dpkg
youruser ALL=(root) NOPASSWD: PKG_UPDATER
```

Validate with `visudo -cf /etc/sudoers.d/debherder`.

### Disabling sudo

`SUDO=""` runs installers as the invoking user. Use only in contexts where  
that is already sufficient (containers, dedicated VMs), or when running as  
root and you want to avoid a no-op sudo.

---

## State file format

`$XDG_STATE_HOME/debherder/installed_versions.tsv`. Tab-separated, one row  
per managed repo:

|#|Column|Example|
|---|---|---|
|1|`repo_slug`|`cli/cli`|
|2|`release_tag`|`2.63.2` (leading `v` stripped)|
|3|`deb_package`|`gh`|
|4|`deb_version`|`2.63.2` (from `dpkg-deb -f … Version`)|
|5|`installed_at`|`2026-11-25T14:32:11Z`|
|6|`sha256`|`abcd…` (the installed `.deb`'s hash)|

**Rollback rows.** After a successful rollback, columns 2 (`release_tag`) and  
6 (`sha256`) are empty and column 4 carries the rolled-back `deb_version`.  
This deliberately avoids recording a rollback as a release install.

**Concurrent access.** Serialized by `flock` on  
`$XDG_STATE_HOME/debherder/.lock`. The lock is held for the duration of any  
state-modifying mode.

**Migration.** A two-column state file (the old format) is migrated once on  
first run. Old rows are preserved with empty columns 3–6.

---

## File layout

```text
$XDG_CONFIG_HOME/debherder/
├── config.env                               optional
└── repos.list                               managed by --add-repo / --remove-repo
$XDG_STATE_HOME/debherder/
├── .lock                                    flock file
├── installed_versions.tsv                   state
├── updater.log                              append-only; rotated by LOG_MAX_BYTES
├── updater.log.1                            previous log after rotation
├── checkpoints/
│   └── state.<repo>.tsv                     transient state snapshots
├── plugins.d/
│   └── *.sh                                 user-supplied hooks
└── cache/
    ├── api/                                 ETag + cached release JSON per repo
    ├── pending/
    │   └── <owner_repo>/
    │       ├── meta
    │       └── <filename>.deb
    └── rollback/
        └── <package>_<deb_version>.deb
```

Files are created with mode `0600` (directories `0700`) via `umask 077`.

---

## Exit codes

|Code|Meaning|
|---|---|
|`0`|All requested repos processed without error (which includes "already up to date" and "no matching asset")|
|`1`|At least one repo failed, or a fatal setup error occurred (bad config, missing dependency, no TTY + sudo password required, unwritable state directory)|

Individual repos are isolated: one failure does not stop the loop. The final  
exit code reflects whether any repo failed.

---

## Common workflows

### Run from cron

```cron
# /etc/cron.d/debherder
0 4 * * * youruser /home/youruser/.local/bin/debherder
```

Requires NOPASSWD for `apt-get` and `dpkg` — see  
Sudo.

### systemd timer

```ini
# ~/.config/systemd/user/debherder.service
[Unit]
Description=Update .deb packages from GitHub releases
[Service]
Type=oneshot
ExecStart=%h/.local/bin/debherder
```

```ini
# ~/.config/systemd/user/debherder.timer
[Unit]
Description=Daily debherder run
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now debherder.timer
journalctl --user -u debherder -f
```

### Watch the log

```bash
tail -f ~/.local/state/debherder/updater.log
```

### Pin a single repo to a specific architecture

```bash
ARCH=arm64 debherder --repo owner/multiarch-package --check
```

### Check before a real run

```bash
debherder --check       # any updates?
debherder --dry-run     # download + verify, no install
debherder               # install
```

### Recover from "sudo: a password is required"

The pending cache already has the `.deb`. When you're back at the keyboard:

```bash
debherder
```

The download is reused; only the install (and its sudo prompt) runs.

---

## Troubleshooting

### `sudo requires a password but no TTY is available`

Running from cron or systemd with a password-protected sudo. Either add a  
NOPASSWD rule, or run the script interactively at least once so the sudo  
cache is primed, or wait for the next interactive run if the pending cache  
already staged the `.deb`.

### `No matching .deb for owner/repo (arch=…, keyword=…)`

The release doesn't publish a `.deb` for your architecture. Diagnose with:

```bash
debherder --list-assets owner/repo
```

Common causes:

- Asset uses `x86_64` — aliased to `amd64` automatically.
    
- Asset filename lacks an arch token — falls back to all `.deb` files, then  
    rejects by the `.deb`'s `Architecture:` field.
    
- Genuinely no `.deb` in this release.

### `SHA-256 mismatch for …`

Either the download was truncated, or the published checksum is wrong. Retry  
once with `--force`. If it persists, check upstream.

To bypass (not recommended): `REQUIRE_CHECKSUM=false`.

### `Architecture mismatch for <name>: package='…', target='…'`

`all` is accepted; this fires only when the `.deb` declares a concrete,  
non-matching arch. Use `ARCH=""` to disable the check entirely.

### `Could not acquire lock on …/.lock`

Another instance is running, or a previous run was killed. The lock is  
advisory (`flock`); verify no `debherder` process is alive. The default  
timeout is 60 seconds.

### `$STATE_DIR is not writable`

A previous `sudo debherder` created root-owned files. Fix:

```bash
sudo chown -R "$USER" ~/.local/state/debherder
```

Then re-run as your normal user. Do not run `debherder` as root.

### `Access forbidden (HTTP 403)` on a private repo

`GITHUB_TOKEN` is required and must have `repo` scope (or the repo must be  
publicly readable). The token is forwarded to asset downloads as well.

### Cache is growing

```bash
debherder --cache-info
debherder --clear-cache pending    # drop retry behavior
debherder --clear-cache rollback   # drop rollback files
```

Tune `CACHE_MAX_MB` for a warning threshold, or `ROLLBACK_KEEP` to reduce  
rollback footprint.

### `A repo reports metadata_error`

The `.deb` is malformed — missing `Package:` or `Version:` in its control  
header. Not something debherder can fix; report upstream.

### `Migrated state file to v2 schema`

A one-time migration from the older 2-column format. Harmless. Old rows  
are preserved with empty `package` / `deb_version` / `sha256` columns.

### Version comparisons look wrong

Comparisons use `dpkg --compare-versions` first, then `sort -V` as a  
fallback. Non-Debian tags (`v2.0-beta.1`, `nightly`) may compare  
unpredictably. Prefer tags matching `[0-9]+\.[0-9]+…`. If a repo gets stuck,  
edit the state row or delete it and re-run to force a fresh install.

---
