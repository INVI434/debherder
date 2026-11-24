#!/usr/bin/env bash
#
# Sample debherder plugin: desktop notification on install outcomes.
#
# Install:
#   chmod +x notify.sh
#   cp notify.sh ~/.local/state/pkg-updater/plugins.d/
#
# Requires notify-send (libnotify-bin on Debian/Ubuntu).

set -euo pipefail

hook="$1"
repo="$2"
version="$3"
status="$4"

command -v notify-send >/dev/null 2>&1 || exit 0

case "$hook:$status" in
  post_install:success)
    notify-send -a debherder "Updated $repo" "$version installed"
    ;;
  post_install:failure)
    notify-send -u critical -a debherder "FAILED: $repo" "$version"
    ;;
  post_install:rollback)
    notify-send -u normal -a debherder "Rolled back $repo" "at $version"
    ;;
  post_install:checksum_failed)
    notify-send -u critical -a debherder "Checksum failed: $repo" "$version"
    ;;
  post_install:arch_mismatch)
    notify-send -u critical -a debherder "Arch mismatch: $repo" "$version"
    ;;
  post_install:sudo_unavailable)
    notify-send -u normal -a debherder "Sudo unavailable: $repo" \
      "Install deferred; pending cache retains the download."
    ;;
esac

exit 0
