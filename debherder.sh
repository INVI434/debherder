#!/usr/bin/env bash
#
# debherder.sh — install/update .deb packages from GitHub releases.
#
# Notes:
#   * INSTALLER=apt is the default (no gdebi dependency).
#   * Two-tier cache under $STATE_DIR/cache/:
#       pending/   verified downloads awaiting install (retry on next run)
#       rollback/  last installed version per package (for auto-rollback)
#   * Sudo prompt, if needed, is deferred to just before the first install;
#     startup fails fast if no TTY is available.
set -euo pipefail
umask 077

SCRIPT_VERSION="2.7.2"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONFIG_FILE="${DEBHERDER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/debherder/config.env}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/debherder"
STATE_FILE="$STATE_DIR/installed_versions.tsv"
LOG_FILE="$STATE_DIR/updater.log"
PLUGIN_DIR="$STATE_DIR/plugins.d"
CHECKPOINT_DIR="$STATE_DIR/checkpoints"
PENDING_DIR="$STATE_DIR/cache/pending"
ROLLBACK_DIR="$STATE_DIR/cache/rollback"
API_CACHE_DIR="$STATE_DIR/cache/api"
LOCK_FILE="$STATE_DIR/.lock"
TMP_DIR="$(mktemp -d)"

# shellcheck disable=SC2317  # invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$STATE_DIR" "$PLUGIN_DIR" "$CHECKPOINT_DIR" \
         "$PENDING_DIR" "$ROLLBACK_DIR" "$API_CACHE_DIR" \
         "$(dirname "${XDG_CONFIG_HOME:-$HOME/.config}/debherder/repos.list")" 2>/dev/null || true
touch "$STATE_FILE" "$LOG_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Logs to stderr and best-effort to $LOG_FILE. Never fails.
log() {
  local level="$1"; shift
  local msg
  msg="$(printf '%s [%s] %s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*")"
  printf '%s\n' "$msg" >&2
  if [[ -n "$LOG_FILE" && -w "$LOG_FILE" ]]; then
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

rotate_log_if_needed() {
  [[ -f "$LOG_FILE" && -w "$LOG_FILE" ]] || return 0
  local max="${LOG_MAX_BYTES:-1048576}" size
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > max )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
MODE="update"
TARGET_REPO=""
REPO_FILTER=""
CONFIG_OVERRIDE=""
FORCE="false"
CHECK_ONLY="false"
REPOS=()
SUDO_CMD=()

load_config() {
  if [[ -n "$CONFIG_OVERRIDE" ]]; then
    CONFIG_FILE="$CONFIG_OVERRIDE"
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi

  REPOS_FILE="${REPOS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/debherder/repos.list}"
  ARCH="${ARCH-$(dpkg --print-architecture 2>/dev/null || echo '')}"
  KEYWORD="${KEYWORD:-}"
  REQUIRE_CHECKSUM="${REQUIRE_CHECKSUM:-false}"
  AUTO_DOWNGRADE_ON_FAIL="${AUTO_DOWNGRADE_ON_FAIL:-false}"
  DRY_RUN="${DRY_RUN:-false}"
  GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
  MULTI_DEB_SELECTION="${MULTI_DEB_SELECTION:-}"
  LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
  SUDO="${SUDO:-sudo}"
  SUDO_OPTS="${SUDO_OPTS:--n}"
  INSTALLER="${INSTALLER:-apt}"
  USE_PENDING_CACHE="${USE_PENDING_CACHE:-true}"
  ROLLBACK_KEEP="${ROLLBACK_KEEP:-1}"
  CACHE_MAX_MB="${CACHE_MAX_MB:-500}"

  SUDO_CMD=()
  if [[ -n "$SUDO" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    # shellcheck disable=SC2206
    read -ra SUDO_CMD <<< "$SUDO $SUDO_OPTS"
  fi

  mkdir -p "$(dirname "$REPOS_FILE")" 2>/dev/null || true
  touch "$REPOS_FILE" 2>/dev/null || true
}

validate_config() {
  local var val
  for var in REQUIRE_CHECKSUM AUTO_DOWNGRADE_ON_FAIL DRY_RUN FORCE USE_PENDING_CACHE; do
    val="${!var}"
    case "$val" in
      true|false) ;;
      *) log "ERROR" "Invalid $var='$val' (expected true|false)"; return 1 ;;
    esac
  done
  if [[ -n "$MULTI_DEB_SELECTION" && ! "$MULTI_DEB_SELECTION" =~ ^(first|last|[0-9]+)$ ]]; then
    log "ERROR" "Invalid MULTI_DEB_SELECTION='$MULTI_DEB_SELECTION' (first|last|<index>)"
    return 1
  fi
  case "$INSTALLER" in
    apt|apt-get|gdebi) ;;
    *) log "ERROR" "Invalid INSTALLER='$INSTALLER' (expected apt|apt-get|gdebi)"; return 1 ;;
  esac
  if ! [[ "$ROLLBACK_KEEP" =~ ^[1-9][0-9]*$ ]]; then
    log "ERROR" "Invalid ROLLBACK_KEEP='$ROLLBACK_KEEP' (expected positive integer)"
    return 1
  fi
  return 0
}

as_root() {
  if (( ${#SUDO_CMD[@]} > 0 )); then
    "${SUDO_CMD[@]}" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Privilege escalation
# ---------------------------------------------------------------------------
# 0: credentials fresh; 1: prompt failed; 2: prompt needed but no TTY.
refresh_sudo() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
  (( ${#SUDO_CMD[@]} == 0 )) && return 0
  if "$SUDO" -n -v 2>/dev/null; then
    return 0
  fi
  if [[ -t 0 ]]; then
    "$SUDO" -v || return 1
    return 0
  fi
  return 2
}

# Startup probe only; never prompts.
verify_sudo_available() {
  [[ "$MODE" == "update" ]] || return 0
  [[ "$DRY_RUN" != "true" && "$CHECK_ONLY" != "true" ]] || return 0
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
  if (( ${#SUDO_CMD[@]} == 0 )); then
    log "WARN" "SUDO is empty; installs will run without escalation and may fail"
    return 0
  fi
  if "$SUDO" -n -v 2>/dev/null; then
    return 0
  fi
  if [[ -t 0 ]]; then
    log "INFO" "sudo requires a password; it will be requested before the first install"
    return 0
  fi
  log "ERROR" "sudo requires a password but no TTY is available (non-interactive run)."
  log "ERROR" "Fix: add NOPASSWD for apt-get/dpkg in /etc/sudoers.d/ (recommended for cron),"
  log "ERROR" "or run from a terminal. See 'man sudoers' for Cmnd_Alias."
  return 1
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
require_cmds() {
  local missing=() c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log "ERROR" "Missing required command(s): ${missing[*]}"
    return 1
  fi
}

check_installer_available() {
  case "$INSTALLER" in
    apt|apt-get)
      command -v apt-get >/dev/null 2>&1 || { log "ERROR" "apt-get required for INSTALLER=apt"; return 1; }
      ;;
    gdebi)
      command -v gdebi >/dev/null 2>&1 || { log "ERROR" "gdebi required for INSTALLER=gdebi"; return 1; }
      ;;
  esac
}

check_dependencies_for_mode() {
  case "$MODE" in
    update|check)
      require_cmds curl python3 dpkg dpkg-deb dpkg-query sha256sum awk sort flock date tee mktemp tr du grep find || return 1
      if [[ "$DRY_RUN" != "true" && "$CHECK_ONLY" != "true" ]]; then
        check_installer_available || return 1
      fi
      ;;
    status|list-assets)
      require_cmds curl python3 awk date tee tr du grep || return 1 ;;
    cache-info)
      require_cmds awk date du grep || return 1 ;;
    clear-cache)
      require_cmds date tee || return 1 ;;
    add-repo|remove-repo)
      require_cmds awk date tee || return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -w 60 9; then
    log "ERROR" "Could not acquire lock on $LOCK_FILE (another instance may be running)"
    return 1
  fi
}

# shellcheck disable=SC2317  # invoked via trap EXIT
release_lock() {
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Plugins
# ---------------------------------------------------------------------------
run_plugins() {
  local hook_name="$1" repo_slug="$2" version="$3" status="$4" plugin
  shopt -s nullglob
  for plugin in "$PLUGIN_DIR"/*.sh; do
    if [[ ! -x "$plugin" ]]; then
      continue
    fi
    if ! "$plugin" "$hook_name" "$repo_slug" "$version" "$status"; then
      log "WARN" "Plugin $(basename "$plugin") exited non-zero on $hook_name for $repo_slug"
    fi
  done
  shopt -u nullglob
}

# ---------------------------------------------------------------------------
# Repo list
# ---------------------------------------------------------------------------
validate_repo_slug() {
  local slug="$1" owner repo
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  owner="${slug%%/*}"
  repo="${slug#*/}"
  [[ "$owner" != "." && "$owner" != ".." && "$repo" != "." && "$repo" != ".." ]]
}

load_repos() {
  REPOS=()
  [[ -f "$REPOS_FILE" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && REPOS+=("$line")
  done < "$REPOS_FILE"
}

add_repo_to_file() {
  local slug="$1" existing
  if ! validate_repo_slug "$slug"; then
    echo "Invalid repository format '$slug'. Expected owner/repo." >&2
    return 1
  fi
  load_repos
  for existing in "${REPOS[@]+"${REPOS[@]}"}"; do
    if [[ "$existing" == "$slug" ]]; then
      echo "Repository '$slug' is already in $REPOS_FILE"
      return 0
    fi
  done
  printf '%s\n' "$slug" >> "$REPOS_FILE"
  echo "Added '$slug' to $REPOS_FILE"
}

remove_repo_from_file() {
  local slug="$1" tmp="$TMP_DIR/repos.list.tmp" line clean found=0
  if ! validate_repo_slug "$slug"; then
    echo "Invalid repository format '$slug'. Expected owner/repo." >&2
    return 1
  fi
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    clean="${line%%#*}"
    clean="${clean#"${clean%%[![:space:]]*}"}"
    clean="${clean%"${clean##*[![:space:]]}"}"
    if [[ "$clean" == "$slug" ]]; then
      found=1
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$REPOS_FILE"
  if (( found == 0 )); then
    echo "Repository '$slug' not found in $REPOS_FILE" >&2
    return 1
  fi
  mv "$tmp" "$REPOS_FILE"
  echo "Removed '$slug' from $REPOS_FILE"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
# Columns: repo_slug, release_tag, deb_package, deb_version, installed_at, sha256
state_get() {
  local repo="$1" field="$2"
  awk -F'\t' -v r="$repo" -v f="$field" '$1 == r { print $f; exit }' "$STATE_FILE"
}

get_installed_version() { state_get "$1" 2; }

set_installed_version() {
  local repo="$1" tag="$2" pkg="$3" debver="$4" deb_path="$5"
  local ts sha="" tmp="$TMP_DIR/state.tsv"
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ -n "$deb_path" && -f "$deb_path" ]]; then
    sha="$(sha256sum "$deb_path" 2>/dev/null | awk '{print tolower($1)}')" || sha=""
  fi
  awk -F'\t' -v r="$repo" '$1 != r' "$STATE_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$tag" "$pkg" "$debver" "$ts" "$sha" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

migrate_state_if_needed() {
  [[ -f "$STATE_FILE" ]] || return 0
  if awk -F'\t' 'NF==2 {found=1; exit} END{exit !found}' "$STATE_FILE" 2>/dev/null; then
    local tmp="$TMP_DIR/state.migrated"
    awk -F'\t' 'BEGIN{OFS="\t"} NF==2 { print $1, $2, "", "", "", ""; next } { print }' \
        "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    log "INFO" "Migrated state file to v2 schema"
  fi
}

create_state_checkpoint() {
  local repo="$1" cp_file
  cp_file="$CHECKPOINT_DIR/state.$(printf '%s' "$repo" | tr '/:' '__').tsv"
  cp -p "$STATE_FILE" "$cp_file"
  printf '%s\n' "$cp_file"
}

restore_state_checkpoint() {
  local cp_file="$1"
  if [[ -f "$cp_file" ]]; then
    cp -p "$cp_file" "$STATE_FILE"
    log "INFO" "Restored state file from checkpoint $(basename "$cp_file")"
  fi
}

get_installed_deb_pkg_version() {
  local deb_path="$1" pkg_name
  pkg_name="$(dpkg-deb -f "$deb_path" Package 2>/dev/null || true)"
  [[ -z "$pkg_name" ]] && return 0
  dpkg-query -W -f='${Version}\n' "$pkg_name" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------
# Returns 0 iff $1 > $2, stripping a leading 'v'.
version_gt() {
  local a="${1#v}" b="${2#v}"
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ "$a" == "$b" ]] && return 1
  if dpkg --compare-versions "$a" gt "$b" 2>/dev/null; then
    return 0
  fi
  local sorted
  sorted="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
  [[ "$sorted" == "$a" ]]
}

# ---------------------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------------------
arch_aliases() {
  case "$1" in
    amd64)  printf '%s\n' amd64 x86_64 x64 ;;
    arm64)  printf '%s\n' arm64 aarch64 ;;
    armhf)  printf '%s\n' armhf armv7l armv7 ;;
    armel)  printf '%s\n' armel armv6l armv6 ;;
    i386)   printf '%s\n' i386 i686 x86 ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

verify_deb_arch() {
  local deb_path="$1" deb_arch alias matched=0
  deb_arch="$(dpkg-deb -f "$deb_path" Architecture 2>/dev/null || true)"
  if [[ -z "$deb_arch" || "$deb_arch" == "all" || -z "$ARCH" ]]; then
    return 0
  fi
  while IFS= read -r alias; do
    [[ "$deb_arch" == "$alias" ]] && matched=1
  done < <(arch_aliases "$ARCH")
  if (( matched == 0 )); then
    log "ERROR" "Architecture mismatch for $(basename "$deb_path"): package='$deb_arch', target='$ARCH'"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Pending cache
# ---------------------------------------------------------------------------
pending_dir_for_repo() {
  local repo="$1"
  printf '%s/%s\n' "$PENDING_DIR" "$(printf '%s' "$repo" | tr '/:' '__')"
}

# Always returns 0; a missing file or key yields empty output.
pending_meta_get() {
  local meta="$1" key="$2"
  [[ -f "$meta" ]] || return 0
  grep -m1 "^${key}=" "$meta" 2>/dev/null | cut -d= -f2- || true
}

# Removes a pending entry, unless DRY_RUN is set (in which case the
# entry is left intact and only the intent is logged).
_prune_pending() {
  local dir="$1" level="$2" msg="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "$level" "$msg (dry-run: pending cache unchanged)"
    return 0
  fi
  log "$level" "$msg"
  rm -rf "$dir" || true
}

# Echoes the path to a usable pending .deb, or nothing.
get_pending_cached_deb() {
  local repo="$1" expected_tag="$2"
  local dir
  dir="$(pending_dir_for_repo "$repo")"
  [[ -d "$dir" ]] || return 0

  local meta="$dir/meta"
  if [[ ! -f "$meta" ]]; then
    _prune_pending "$dir" WARN "Pending cache for $repo has no metadata"
    return 0
  fi

  local tag sha filename
  tag="$(pending_meta_get "$meta" tag)"
  sha="$(pending_meta_get "$meta" sha256)"
  filename="$(pending_meta_get "$meta" filename)"

  if [[ -z "$tag" || -z "$sha" || -z "$filename" ]]; then
    _prune_pending "$dir" WARN "Pending cache metadata for $repo is malformed"
    return 0
  fi

  if [[ "$tag" != "$expected_tag" ]]; then
    _prune_pending "$dir" INFO "Stale pending cache for $repo (cached=$tag, latest=$expected_tag)"
    return 0
  fi

  local deb="$dir/$filename"
  if [[ ! -f "$deb" ]]; then
    _prune_pending "$dir" WARN "Pending cache metadata for $repo exists but .deb missing"
    return 0
  fi

  local actual
  actual="$(sha256sum "$deb" | awk '{print tolower($1)}')"
  if [[ "$actual" != "$sha" ]]; then
    _prune_pending "$dir" WARN "Pending cached deb for $repo is corrupt (sha256 mismatch)"
    return 0
  fi

  printf '%s\n' "$deb"
}

# Best-effort. Failure cleans up and returns 1 without aborting the caller.
stage_pending() {
  local repo="$1" tag="$2" deb_path="$3" sha256="$4"
  local dir
  dir="$(pending_dir_for_repo "$repo")"
  mkdir -p "$dir" || return 1

  find "$dir" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true

  local filename
  filename="$(basename "$deb_path")"
  if ! cp -f "$deb_path" "$dir/$filename"; then
    log "WARN" "Failed to stage $deb_path to pending cache"
    return 1
  fi

  if ! cat > "$dir/meta" <<EOF
tag=$tag
sha256=$sha256
filename=$filename
staged_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  then
    log "WARN" "Failed to write pending meta for $repo"
    rm -rf "$dir"
    return 1
  fi
  log "INFO" "Staged $(basename "$deb_path") to pending cache for $repo"
}

commit_pending() {
  local repo="$1"
  rm -rf "$(pending_dir_for_repo "$repo")"
}

# ---------------------------------------------------------------------------
# Rollback cache
# ---------------------------------------------------------------------------
find_cached_previous_deb() {
  local pkg="$1" exclude="$2" f best=""
  shopt -s nullglob
  for f in "$ROLLBACK_DIR/${pkg}_"*.deb; do
    [[ "$f" == "$exclude" ]] && continue
    if [[ -z "$best" || "$f" -nt "$best" ]]; then
      best="$f"
    fi
  done
  shopt -u nullglob
  printf '%s\n' "$best"
}

# Keep only the newest $ROLLBACK_KEEP .deb files per package.
prune_rollback_cache() {
  local pkg="$1" keep="${ROLLBACK_KEEP:-1}"
  local -a files=()
  local f

  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(
    find "$ROLLBACK_DIR" -maxdepth 1 -type f -name "${pkg}_*.deb" \
         -printf '%T@\t%p\n' 2>/dev/null \
      | sort -rn \
      | cut -f2-
  )

  (( ${#files[@]} <= keep )) && return 0

  for f in "${files[@]:keep}"; do
    log "INFO" "Pruning rollback cache: $(basename "$f")"
    rm -f "$f"
  done
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
curl_api() {
  local url="$1" headers_out="$2" body_out="$3" etag_file="${4:-}"
  local -a args=(-sS -D "$headers_out" -o "$body_out" -w '%{http_code}'
                 --connect-timeout 15 --max-time 60
                 -H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  if [[ -n "$etag_file" && -f "$etag_file" ]]; then
    args+=(-H "If-None-Match: $(tr -d '\r\n' < "$etag_file")")
  fi
  curl "${args[@]}" "$url"
}

curl_download() {
  local url="$1" out="$2"
  local -a args=(-sSL --fail
                 --connect-timeout 15 --max-time 600
                 --retry 3 --retry-delay 5)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer $GITHUB_TOKEN"
           -H "Accept: application/octet-stream")
  fi
  curl "${args[@]}" -o "$out" "$url"
}

get_header() {
  tr -d '\r' < "$1" | awk -F': ' -v want="$2" '
    tolower($1) == want { last = $2 }
    END { if (last != "") print last }
  '
}

# ---------------------------------------------------------------------------
# Installer
# ---------------------------------------------------------------------------
# Returns the installer's exit code only; logging failures never affect it.
install_local_deb() {
  local deb_path="$1" rc=0
  local out="$TMP_DIR/install.$$.out"

  case "$INSTALLER" in
    apt|apt-get)
      log "INFO" "Installing via apt-get: $(basename "$deb_path")"
      as_root env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --allow-downgrades "$deb_path" > "$out" 2>&1 || rc=$?
      ;;
    gdebi)
      log "INFO" "Installing via gdebi: $(basename "$deb_path")"
      as_root env DEBIAN_FRONTEND=noninteractive \
        gdebi -n "$deb_path" > "$out" 2>&1 || rc=$?
      ;;
    *)
      log "ERROR" "Unknown INSTALLER='$INSTALLER'"
      return 1
      ;;
  esac

  if [[ -s "$out" ]]; then
    cat "$out" >&2 2>/dev/null || true
    if [[ -n "$LOG_FILE" && -w "$LOG_FILE" ]]; then
      cat "$out" >> "$LOG_FILE" 2>/dev/null || true
    fi
  fi
  rm -f "$out" 2>/dev/null || true

  return "$rc"
}

# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------
# Echoes the path to the cached release JSON on success.
fetch_latest_release_json() {
  local repo="$1"
  local api_url="$GITHUB_API_BASE/repos/$repo/releases/latest"
  local max_retries=3 attempt=1
  local resp="$TMP_DIR/release.json" headers="$TMP_DIR/headers.txt"
  local etag_file="$API_CACHE_DIR/${repo//\//_}.etag"
  local json_cache="$API_CACHE_DIR/${repo//\//_}.json"

  while (( attempt <= max_retries )); do
    local http_code remaining reset_ts retry_after now wait_sec etag

    if ! http_code="$(curl_api "$api_url" "$headers" "$resp" "$etag_file")"; then
      log "WARN" "Network error fetching $repo (attempt $attempt/$max_retries)"
      if (( attempt == max_retries )); then
        log "ERROR" "Giving up on $repo after $max_retries attempts"
        return 1
      fi
      sleep $(( 5 * attempt ))
      (( attempt++ ))
      continue
    fi

    if [[ "$http_code" == "304" && -f "$json_cache" ]]; then
      printf '%s\n' "$json_cache"
      return 0
    fi

    remaining="$(get_header "$headers" "x-ratelimit-remaining")"
    reset_ts="$(get_header "$headers" "x-ratelimit-reset")"
    retry_after="$(get_header "$headers" "retry-after")"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      if [[ -n "$remaining" && "$remaining" -le 2 ]]; then
        log "WARN" "GitHub API quota running low ($remaining remaining) after checking $repo"
      fi
      etag="$(get_header "$headers" "etag")"
      if [[ -n "$etag" ]]; then
        printf '%s\n' "$etag" > "$etag_file"
      fi
      cp -f "$resp" "$json_cache" 2>/dev/null || true
      printf '%s\n' "$json_cache"
      return 0
    fi

    if [[ "$http_code" -eq 403 || "$http_code" -eq 429 ]]; then
      if [[ -z "$retry_after" && "${remaining:-1}" -gt 0 ]] \
         && ! grep -qiF -e 'rate limit' -e 'abuse' "$resp" 2>/dev/null; then
        log "ERROR" "Access forbidden (HTTP 403) for $repo; check permissions or token"
        return 1
      fi

      now="$(date -u +%s)"
      wait_sec=0
      if [[ -n "$retry_after" && "$retry_after" =~ ^[0-9]+$ ]]; then
        wait_sec="$retry_after"
      elif [[ "${remaining:-}" == "0" && -n "$reset_ts" && "$reset_ts" =~ ^[0-9]+$ ]]; then
        wait_sec=$(( reset_ts - now + 2 ))
        (( wait_sec < 1 )) && wait_sec=1
      else
        wait_sec=$(( 60 * (2 ** (attempt - 1)) ))
      fi

      if (( attempt == max_retries )); then
        log "ERROR" "Rate limit persisted for $repo after $max_retries attempts (HTTP $http_code)"
        return 2
      fi
      log "WARN" "Rate limited on $repo (HTTP $http_code). Sleeping ${wait_sec}s (attempt $attempt/$max_retries)"
      sleep "$wait_sec"
      (( attempt++ ))
      continue
    fi

    log "ERROR" "Failed to fetch release for $repo (HTTP $http_code)"
    return 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# Asset selection
# ---------------------------------------------------------------------------
# Echoes the chosen .deb URL, or nothing. UI goes to /dev/tty; only the
# result is written to stdout.
select_deb_url() {
  local json_file="$1"
  local -a names=() urls=()
  local name url choice idx selected
  local py_out="$TMP_DIR/assets.tsv"
  local all_out="$TMP_DIR/assets_all.tsv"
  local aliases
  aliases="$(arch_aliases "$ARCH" | tr '\n' ' ')"

  if ! python3 -c '
import json, re, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
aliases = sys.argv[2].split()
kw = sys.argv[3].strip().lower()
pats = [re.compile(r"(^|[^a-z0-9])" + re.escape(a) + r"([^a-z0-9]|$)")
        for a in (x.lower() for x in aliases)]
for a in data.get("assets", []):
    name = a.get("name") or ""
    url  = a.get("browser_download_url") or ""
    low  = name.lower()
    if not low.endswith(".deb"):
        continue
    if pats and not any(p.search(low) for p in pats):
        continue
    if kw and kw not in low:
        continue
    print(name + "\t" + url)
' "$json_file" "$aliases" "$KEYWORD" > "$py_out"; then
    log "ERROR" "Asset selection failed (python error) for release"
    return 1
  fi

  if [[ ! -s "$py_out" && -n "$ARCH" ]]; then
    if ! python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
kw = sys.argv[2].strip().lower()
for a in data.get("assets", []):
    name = a.get("name") or ""
    url  = a.get("browser_download_url") or ""
    low  = name.lower()
    if not low.endswith(".deb"):
        continue
    if kw and kw not in low:
        continue
    print(name + "\t" + url)
' "$json_file" "$KEYWORD" > "$all_out"; then
      log "ERROR" "Asset selection failed (python error) for release"
      return 1
    fi
    if [[ -s "$all_out" ]]; then
      log "WARN" "No .deb filename matched arch '$ARCH'; falling back to all .deb assets (Architecture: will be verified after download)"
      cp -f "$all_out" "$py_out"
    fi
  fi

  while IFS=$'\t' read -r name url; do
    [[ -n "$name" && -n "$url" ]] || continue
    names+=("$name")
    urls+=("$url")
  done < "$py_out"

  if (( ${#urls[@]} == 0 )); then
    return 0
  fi
  if (( ${#urls[@]} == 1 )); then
    printf '%s\n' "${urls[0]}"
    return 0
  fi

  if [[ -t 0 ]]; then
    selected=""
    {
      echo "Multiple .deb files found:"
      local i
      for i in "${!names[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${names[$i]}"
      done
      while true; do
        printf 'Select a package [1-%d]: ' "${#urls[@]}"
        if ! read -r choice; then
          exit 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#urls[@]} )); then
          idx=$(( choice - 1 ))
          selected="${urls[$idx]}"
          break
        fi
        echo "Invalid selection. Please enter a number between 1 and ${#urls[@]}."
      done
    } > /dev/tty || return 1
    printf '%s\n' "$selected"
    return 0
  fi

  case "${MULTI_DEB_SELECTION:-}" in
    first)
      log "WARN" "Multiple .deb files; MULTI_DEB_SELECTION=first -> ${names[0]}"
      printf '%s\n' "${urls[0]}"; return 0 ;;
    last)
      local last_idx=$(( ${#urls[@]} - 1 ))
      log "WARN" "Multiple .deb files; MULTI_DEB_SELECTION=last -> ${names[$last_idx]}"
      printf '%s\n' "${urls[$last_idx]}"; return 0 ;;
    '')
      log "ERROR" "Multiple .deb files in non-interactive mode; set MULTI_DEB_SELECTION=first|last|<index>"
      return 1 ;;
    *)
      idx=$(( MULTI_DEB_SELECTION - 1 ))
      if (( idx >= 0 && idx < ${#urls[@]} )); then
        printf '%s\n' "${urls[$idx]}"; return 0
      fi
      log "ERROR" "MULTI_DEB_SELECTION=$MULTI_DEB_SELECTION out of range [1..${#urls[@]}]"
      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Checksum
# ---------------------------------------------------------------------------
extract_expected_sha256() {
  local json_file="$1" deb_filename="$2"
  local sums_file="$TMP_DIR/checksums.txt"
  local sums_url expected_hash

  sums_url="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for a in data.get("assets", []):
    name = (a.get("name") or "").lower()
    url  = a.get("browser_download_url") or ""
    if url and any(k in name for k in ("sha256", "checksums")):
        if not name.endswith((".asc", ".sig")):
            print(url)
            break
' "$json_file" 2>/dev/null || true)"

  if [[ -n "$sums_url" ]]; then
    if curl_download "$sums_url" "$sums_file"; then
      expected_hash="$(tr -d '\r' < "$sums_file" | awk -v target="$deb_filename" '
        $0 ~ /^[0-9a-fA-F]{64}[[:space:]]+\*?/ {
          hash = $1
          name = $0
          sub(/^[0-9a-fA-F]{64}[[:space:]]+\*?/, "", name)
          sub(/^.*\//, "", name)
          if (name == target) { print tolower(hash); exit }
        }
      ')"
      if [[ -n "$expected_hash" ]]; then
        printf '%s\n' "$expected_hash"
        return 0
      fi
    else
      log "WARN" "Failed to download checksums from $sums_url"
    fi
  fi

  python3 -c '
import json, re, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
deb_name = sys.argv[2]
for a in data.get("assets", []):
    if a.get("name") == deb_name and isinstance(a.get("digest"), str):
        m = re.search(r"(?:sha256:)?([0-9a-fA-F]{64})", a["digest"])
        if m:
            print(m.group(1).lower())
            sys.exit(0)
body = data.get("body") or ""
for line in body.splitlines():
    if deb_name in line or "sha256" in line.lower():
        m = re.search(r"\b([0-9a-fA-F]{64})\b", line)
        if m:
            print(m.group(1).lower())
            sys.exit(0)
' "$json_file" "$deb_filename" 2>/dev/null || true
}

# Echoes the computed sha256 on success.
verify_checksum_if_present() {
  local json_file="$1" deb_path="$2"
  local deb_filename actual_hash expected_hash
  deb_filename="$(basename "$deb_path")"
  actual_hash="$(sha256sum "$deb_path" | awk '{print tolower($1)}')"
  expected_hash="$(extract_expected_sha256 "$json_file" "$deb_filename")"

  if [[ -z "$expected_hash" ]]; then
    if [[ "$REQUIRE_CHECKSUM" == "true" ]]; then
      log "ERROR" "No SHA-256 checksum found for $deb_filename and REQUIRE_CHECKSUM=true"
      return 1
    fi
    log "WARN" "No SHA-256 checksum found for $deb_filename; proceeding per default policy"
    printf '%s\n' "$actual_hash"
    return 0
  fi

  if [[ "$actual_hash" != "$expected_hash" ]]; then
    log "ERROR" "SHA-256 mismatch for $deb_filename (expected=$expected_hash, actual=$actual_hash)"
    return 1
  fi
  log "INFO" "SHA-256 verified for $deb_filename"
  printf '%s\n' "$actual_hash"
  return 0
}

# ---------------------------------------------------------------------------
# Install / rollback
# ---------------------------------------------------------------------------
install_package() {
  local repo="$1" version="$2" deb_path="$3"
  local cp_file prev_pkg_ver pkg_name deb_pkg_ver actual cached_prev cached_ver
  local cache_target

  pkg_name="$(dpkg-deb -f "$deb_path" Package 2>/dev/null || true)"
  deb_pkg_ver="$(dpkg-deb -f "$deb_path" Version 2>/dev/null || true)"
  prev_pkg_ver="$(get_installed_deb_pkg_version "$deb_path")"

  if [[ -z "$pkg_name" || -z "$deb_pkg_ver" ]]; then
    log "ERROR" "Unable to read package metadata from $deb_path"
    run_plugins "post_install" "$repo" "$version" "metadata_error"
    return 1
  fi

  cache_target="$ROLLBACK_DIR/${pkg_name}_${deb_pkg_ver}.deb"

  if [[ "$DRY_RUN" == "true" ]]; then
    local -a cmd=(${SUDO_CMD[@]+"${SUDO_CMD[@]}"} env DEBIAN_FRONTEND=noninteractive)
    case "$INSTALLER" in
      apt|apt-get) cmd+=(apt-get install -y --allow-downgrades "$deb_path") ;;
      gdebi)       cmd+=(gdebi -n "$deb_path") ;;
    esac
    log "INFO" "[DRY-RUN] Would install: $( printf '%q ' "${cmd[@]}" )"
    log "INFO" "[DRY-RUN] Package=${pkg_name} deb_version=${deb_pkg_ver} prev=${prev_pkg_ver:-none}"
    run_plugins "dry_run" "$repo" "$version" "verified"
    return 0
  fi

  cp_file="$(create_state_checkpoint "$repo")"

  if ! refresh_sudo; then
    log "ERROR" "Cannot obtain sudo credentials for $repo; skipping install"
    rm -f "$cp_file"
    run_plugins "post_install" "$repo" "$version" "sudo_unavailable"
    return 1
  fi

  if install_local_deb "$deb_path"; then
    set_installed_version "$repo" "$version" "$pkg_name" "$deb_pkg_ver" "$deb_path"
    cp -f "$deb_path" "$cache_target" 2>/dev/null || true
    prune_rollback_cache "$pkg_name"
    commit_pending "$repo"
    rm -f "$cp_file"
    log "INFO" "Installed $repo ($version -> ${pkg_name}=${deb_pkg_ver})"
    run_plugins "post_install" "$repo" "$version" "success"

    actual="$(dpkg-query -W -f='${Version}\n' "$pkg_name" 2>/dev/null || true)"
    if [[ "$actual" != "$deb_pkg_ver" ]]; then
      log "WARN" "Post-install version mismatch for $pkg_name: expected $deb_pkg_ver, got ${actual:-none}"
    fi
    return 0
  fi

  log "ERROR" "Install failed for $repo ($version); starting recovery"
  restore_state_checkpoint "$cp_file"
  as_root dpkg --configure -a >/dev/null 2>&1 || true

  if [[ "$AUTO_DOWNGRADE_ON_FAIL" == "true" && -n "$pkg_name" && -n "$prev_pkg_ver" ]]; then
    cached_prev="$(find_cached_previous_deb "$pkg_name" "$cache_target")"
    if [[ -n "$cached_prev" ]]; then
      log "WARN" "Attempting rollback of $pkg_name from cached deb $cached_prev"
      if install_local_deb "$cached_prev"; then
        cached_ver="$(dpkg-deb -f "$cached_prev" Version 2>/dev/null || true)"
        set_installed_version "$repo" "" "$pkg_name" "$cached_ver" "$cached_prev"
        log "INFO" "Rolled back $pkg_name to $cached_ver (from cache)"
        run_plugins "post_install" "$repo" "$version" "rollback"
        rm -f "$cp_file"
        return 1
      fi
      log "WARN" "Cached deb rollback failed; trying apt repositories"
    fi

    log "WARN" "Attempting rollback of $pkg_name to previous version $prev_pkg_ver via apt"
    if as_root env DEBIAN_FRONTEND=noninteractive \
         apt-get install -y --allow-downgrades "${pkg_name}=${prev_pkg_ver}"; then
      set_installed_version "$repo" "" "$pkg_name" "$prev_pkg_ver" ""
      log "INFO" "Rolled back $pkg_name to $prev_pkg_ver"
    else
      log "ERROR" "Rollback to $prev_pkg_ver failed for $pkg_name; manual intervention may be needed"
    fi
  fi

  run_plugins "post_install" "$repo" "$version" "failure"
  rm -f "$cp_file"
  return 1
}

# ---------------------------------------------------------------------------
# Per-repo workflow
# ---------------------------------------------------------------------------
process_repo() {
  local repo="$1"
  local current_ver latest_ver release_json_file deb_url deb_file deb_sha
  local state_pkg installed_deb_ver skip_reason=""

  current_ver="$(get_installed_version "$repo")"
  current_ver="${current_ver#v}"

  # Orphan cleanup: pending entry for a version that's already installed.
  if [[ "$USE_PENDING_CACHE" == "true" && -n "$current_ver" ]]; then
    local pdir ptag
    pdir="$(pending_dir_for_repo "$repo")"
    if [[ -d "$pdir" ]]; then
      ptag="$(pending_meta_get "$pdir/meta" tag)"
      if [[ -n "$ptag" && "$ptag" == "$current_ver" ]]; then
        _prune_pending "$pdir" INFO "Orphaned pending cache for $repo (v$ptag already installed)"
      fi
    fi
  fi

  if ! release_json_file="$(fetch_latest_release_json "$repo")"; then
    return 1
  fi
  if [[ -z "$release_json_file" || ! -f "$release_json_file" ]]; then
    log "ERROR" "Release JSON missing for $repo"
    return 1
  fi

  if ! latest_ver="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)
print((d.get("tag_name") or "").lstrip("v"))
' "$release_json_file")"; then
    log "ERROR" "Failed to parse latest version for $repo"
    return 1
  fi

  if [[ -z "$latest_ver" ]]; then
    log "WARN" "No tag_name found for $repo"
    return 0
  fi

  # Skip if already at or beyond $latest_ver, per either the state tag or
  # the actual installed deb version (which may have advanced outside
  # this script, e.g. via apt upgrade).
  if [[ -n "$current_ver" ]]; then
    if [[ "$current_ver" == "$latest_ver" ]]; then
      skip_reason="already up to date ($current_ver)"
    elif version_gt "$current_ver" "$latest_ver"; then
      skip_reason="state tag $current_ver is newer than latest $latest_ver"
    fi
  fi

  if [[ -z "$skip_reason" ]]; then
    state_pkg="$(state_get "$repo" 3)"
    if [[ -n "$state_pkg" ]]; then
      installed_deb_ver="$(dpkg-query -W -f='${Version}\n' "$state_pkg" 2>/dev/null || true)"
      if [[ -n "$installed_deb_ver" ]] && version_gt "$installed_deb_ver" "$latest_ver"; then
        skip_reason="installed deb $installed_deb_ver is newer than latest $latest_ver"
      fi
    fi
  fi

  if [[ -n "$skip_reason" ]]; then
    if [[ "$FORCE" == "true" && "$CHECK_ONLY" != "true" ]]; then
      log "WARN" "Forcing reinstall of $repo ($skip_reason)"
    else
      log "INFO" "$repo: $skip_reason; skipping"
      return 0
    fi
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "INFO" "$repo: update available ${current_ver:-<none>} -> $latest_ver (check only)"
    return 0
  fi

  deb_file=""
  if [[ "$USE_PENDING_CACHE" == "true" ]]; then
    deb_file="$(get_pending_cached_deb "$repo" "$latest_ver")"
    if [[ -n "$deb_file" ]]; then
      log "INFO" "Using pending cached deb for $repo: $(basename "$deb_file")"
      if ! verify_deb_arch "$deb_file"; then
        _prune_pending "$(pending_dir_for_repo "$repo")" WARN "Cached deb for $repo has wrong arch"
        deb_file=""
      fi
    fi
  fi

  if [[ -z "$deb_file" ]]; then
    if ! deb_url="$(select_deb_url "$release_json_file")"; then
      log "ERROR" "Asset selection failed for $repo"
      return 1
    fi
    if [[ -z "$deb_url" ]]; then
      log "WARN" "No matching .deb for $repo (arch=${ARCH:-any}, keyword=${KEYWORD:-any})"
      return 0
    fi

    deb_file="$TMP_DIR/$(basename "$deb_url")"
    log "INFO" "Downloading $deb_url"
    if ! curl_download "$deb_url" "$deb_file"; then
      log "ERROR" "Download failed for $deb_url"
      return 1
    fi

    if ! deb_sha="$(verify_checksum_if_present "$release_json_file" "$deb_file")"; then
      log "ERROR" "Checksum verification failed for $deb_file"
      run_plugins "post_install" "$repo" "$latest_ver" "checksum_failed"
      return 1
    fi

    if ! verify_deb_arch "$deb_file"; then
      run_plugins "post_install" "$repo" "$latest_ver" "arch_mismatch"
      return 1
    fi

    if [[ "$USE_PENDING_CACHE" == "true" && "$DRY_RUN" != "true" ]]; then
      stage_pending "$repo" "$latest_ver" "$deb_file" "$deb_sha" || true
    fi
  fi

  export VT_TARGET_DEB="$deb_file"
  run_plugins "pre_install" "$repo" "$latest_ver" "verified"
  unset VT_TARGET_DEB

  install_package "$repo" "$latest_ver" "$deb_file"
}

# ---------------------------------------------------------------------------
# Cache management
# ---------------------------------------------------------------------------
check_cache_size() {
  local max="${CACHE_MAX_MB:-500}" total_mb
  total_mb="$(du -sm "$STATE_DIR/cache" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "$total_mb" ]] && (( total_mb > max )); then
    log "WARN" "Cache size ${total_mb}MB exceeds CACHE_MAX_MB=${max}MB; consider --clear-cache"
  fi
}

cache_info() {
  echo "=== Pending cache ($PENDING_DIR) ==="
  if [[ -d "$PENDING_DIR" ]] && compgen -G "$PENDING_DIR/*" >/dev/null; then
    local d repo tag size
    for d in "$PENDING_DIR"/*/; do
      [[ -d "$d" ]] || continue
      repo="$(basename "$d")"
      tag="$(pending_meta_get "$d/meta" tag)"
      size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
      printf '  %-40s tag=%-15s size=%s\n' "$repo" "${tag:-unknown}" "${size:-?}"
    done
    printf '  total: %s\n' "$(du -sh "$PENDING_DIR" 2>/dev/null | awk '{print $1}')"
  else
    echo "  (empty)"
  fi

  echo ""
  echo "=== Rollback cache ($ROLLBACK_DIR) ==="
  if [[ -d "$ROLLBACK_DIR" ]] && compgen -G "$ROLLBACK_DIR/*.deb" >/dev/null; then
    local f
    for f in "$ROLLBACK_DIR"/*.deb; do
      [[ -f "$f" ]] || continue
      printf '  %-60s %s\n' "$(basename "$f")" "$(du -h "$f" 2>/dev/null | awk '{print $1}')"
    done
    printf '  total: %s\n' "$(du -sh "$ROLLBACK_DIR" 2>/dev/null | awk '{print $1}')"
  else
    echo "  (empty)"
  fi
}

clear_cache() {
  local which="${1:-all}" count=0 f
  local verb="Cleared"
  [[ "$DRY_RUN" == "true" ]] && verb="[DRY-RUN] Would clear"

  case "$which" in
    pending)
      if [[ -d "$PENDING_DIR" ]] && compgen -G "$PENDING_DIR/*" >/dev/null; then
        if [[ "$DRY_RUN" != "true" ]]; then
          rm -rf "$PENDING_DIR"
          mkdir -p "$PENDING_DIR" 2>/dev/null || true
        fi
        echo "$verb pending cache"
      else
        echo "Pending cache is already empty"
      fi
      ;;
    rollback)
      if [[ -d "$ROLLBACK_DIR" ]] && compgen -G "$ROLLBACK_DIR/*.deb" >/dev/null; then
        for f in "$ROLLBACK_DIR"/*.deb; do
          [[ -f "$f" ]] || continue
          count=$(( count + 1 ))
          [[ "$DRY_RUN" != "true" ]] && rm -f "$f"
        done
        echo "$verb rollback cache ($count file(s))"
      else
        echo "Rollback cache is already empty"
      fi
      ;;
    all|'')
      local had_pending=0
      if [[ -d "$PENDING_DIR" ]] && compgen -G "$PENDING_DIR/*" >/dev/null; then
        had_pending=1
        if [[ "$DRY_RUN" != "true" ]]; then
          rm -rf "$PENDING_DIR"
          mkdir -p "$PENDING_DIR" 2>/dev/null || true
        fi
      fi
      if [[ -d "$ROLLBACK_DIR" ]]; then
        for f in "$ROLLBACK_DIR"/*.deb; do
          [[ -f "$f" ]] || continue
          count=$(( count + 1 ))
          [[ "$DRY_RUN" != "true" ]] && rm -f "$f"
        done
      fi
      if (( had_pending )) || (( count > 0 )); then
        echo "$verb all cache (pending entries: $had_pending, rollback files: $count)"
      else
        echo "Cache is already empty"
      fi
      ;;
    *)
      echo "Invalid cache type '$which' (pending|rollback|all)" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
list_assets() {
  local repo="$1" json_file latest_ver
  if ! validate_repo_slug "$repo"; then
    echo "Invalid repository format '$repo'. Expected owner/repo." >&2
    return 1
  fi
  if ! json_file="$(fetch_latest_release_json "$repo")"; then
    return 1
  fi
  latest_ver="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)
print((d.get("tag_name") or "").lstrip("v"))
' "$json_file")"

  echo "=== $repo ($latest_ver) ==="
  echo "target arch: ${ARCH:-any}"
  echo "aliases:     $(arch_aliases "$ARCH" | tr '\n' ' ')"
  echo "installer:   $INSTALLER"
  echo "assets:"
  python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for a in data.get("assets", []):
    print("  - " + (a.get("name") or ""))
' "$json_file"
}

show_status() {
  echo "=== Script ==="
  echo "  version: $SCRIPT_VERSION"

  echo ""
  echo "=== Configuration ==="
  echo "  config file: $CONFIG_FILE"
  echo "  repos file:  $REPOS_FILE"
  echo "  state file:  $STATE_FILE"
  echo "  log file:    $LOG_FILE"
  echo "  arch:        ${ARCH:-any}"
  echo "  aliases:     $(arch_aliases "$ARCH" | tr '\n' ' ')"
  echo "  keyword:     ${KEYWORD:-any}"
  echo "  api base:    $GITHUB_API_BASE"
  echo "  installer:   $INSTALLER"
  echo "  pending cache:      $USE_PENDING_CACHE"
  echo "  rollback keep:      $ROLLBACK_KEEP version(s) per package"
  echo "  cache soft limit:   ${CACHE_MAX_MB} MB"
  echo "  require checksum:   $REQUIRE_CHECKSUM"
  echo "  auto downgrade:     $AUTO_DOWNGRADE_ON_FAIL"
  echo "  dry run:            $DRY_RUN"

  echo ""
  echo "=== Privilege escalation ==="
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "  running as root (no escalation needed)"
  elif (( ${#SUDO_CMD[@]} == 0 )); then
    echo "  SUDO is empty; installs run without escalation"
  elif "$SUDO" -n -v 2>/dev/null; then
    echo "  ${SUDO_CMD[*]} (cached; no prompt will occur)"
  elif [[ -t 0 ]]; then
    echo "  ${SUDO_CMD[*]} (password will be requested before install)"
  else
    echo "  ${SUDO_CMD[*]} (password required, no TTY — installs will fail)"
    echo "  hint: add NOPASSWD in /etc/sudoers.d/ for unattended runs"
  fi

  echo ""
  echo "=== Repos ($REPOS_FILE) ==="
  if (( ${#REPOS[@]} > 0 )); then
    printf '  - %s\n' "${REPOS[@]}"
  else
    echo "  (no repositories configured)"
  fi

  echo ""
  echo "=== Tracked Packages ($STATE_FILE) ==="
  if [[ -s "$STATE_FILE" ]]; then
    printf 'repo\trelease\tpackage\tdeb_version\tinstalled_at\tsha256\n'
    column -t -s $'\t' "$STATE_FILE" 2>/dev/null || cat "$STATE_FILE"
  else
    echo "(no tracked packages yet)"
  fi

  echo ""
  cache_info

  echo ""
  echo "=== Recent Log ($LOG_FILE) ==="
  tail -n 15 "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
debherder.sh $SCRIPT_VERSION

Usage: debherder.sh [options]

Modes:
  --status                    Show config, tracked versions, cache state, and recent log
  --check                     Report available updates (no download, no install)
  --dry-run                   Download and verify, but do not install
  --add-repo <owner/repo>     Add a repository
  --remove-repo <owner/repo>  Remove a repository
  --list-assets <owner/repo>  Print the release assets for a repo (diagnostic)
  --cache-info                Show pending and rollback cache contents
  --clear-cache [type]        Clear cache: pending|rollback|all (default: all)

Filters:
  --repo <owner/repo>         Restrict processing to a single repo
  --force                     Install even if the version is not newer

Other:
  --config <path>             Use an alternate config file
  --version                   Print version and exit
  -h, --help                  Show this help

Cache:
  pending/   Verified downloads not yet installed. Reused on the next run and
             re-verified each time. Pruned if its tag no longer matches
             GitHub's latest, if the .deb is corrupt, or after a successful
             install.
  rollback/  The most recently installed .deb per package. Kept so an install
             failure can be rolled back without a network fetch. Keeps
             ROLLBACK_KEEP versions per package (default 1).

  Both live under \$XDG_STATE_HOME/debherder/cache/.
  Soft limit CACHE_MAX_MB (default 500) only warns; it never auto-deletes.
  --dry-run combined with --clear-cache reports what would be removed.

Environment / config file variables:
  ARCH                        Target arch (default: dpkg --print-architecture; "" = any)
  KEYWORD                     Filename keyword filter for .deb assets
  INSTALLER                   apt (default) or gdebi
  USE_PENDING_CACHE           true|false (default: true)
  ROLLBACK_KEEP               Versions to keep per package in rollback cache (default: 1)
  CACHE_MAX_MB                Soft size warning threshold (default: 500)
  REQUIRE_CHECKSUM            true|false (default: false)
  AUTO_DOWNGRADE_ON_FAIL      true|false (default: false)
  GITHUB_TOKEN                GitHub API token (also used for asset downloads)
  GITHUB_API_BASE             API base URL (default: https://api.github.com)
  MULTI_DEB_SELECTION         first|last|<index> for non-interactive asset selection
  SUDO / SUDO_OPTS            Privilege escalation (default: sudo -n; SUDO="" disables)
  LOG_MAX_BYTES               Rotate updater.log above this size (default: 1 MiB)

Privilege escalation:
  * Passwordless sudo (NOPASSWD): no prompt, ever.
  * Interactive terminal: the sudo password is requested once, immediately
    before the first install — after downloads finish.
  * No TTY + password required: the script exits before downloading, unless
    the pending cache already has a usable .deb for that repo.

For unattended runs, add NOPASSWD for apt-get/dpkg in /etc/sudoers.d/.
See 'man sudoers' for Cmnd_Alias.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)       MODE="status"; shift ;;
      --check)        MODE="check"; CHECK_ONLY="true"; shift ;;
      --dry-run)      DRY_RUN="true"; shift ;;
      --force)        FORCE="true"; shift ;;
      --repo)
        [[ $# -ge 2 ]] || { echo "Missing argument for --repo" >&2; exit 1; }
        REPO_FILTER="$2"; shift 2 ;;
      --add-repo)
        [[ $# -ge 2 ]] || { echo "Missing argument for --add-repo" >&2; exit 1; }
        MODE="add-repo"; TARGET_REPO="$2"; shift 2 ;;
      --remove-repo)
        [[ $# -ge 2 ]] || { echo "Missing argument for --remove-repo" >&2; exit 1; }
        MODE="remove-repo"; TARGET_REPO="$2"; shift 2 ;;
      --list-assets)
        [[ $# -ge 2 ]] || { echo "Missing argument for --list-assets" >&2; exit 1; }
        MODE="list-assets"; TARGET_REPO="$2"; shift 2 ;;
      --cache-info)
        MODE="cache-info"; shift ;;
      --clear-cache)
        MODE="clear-cache"
        TARGET_REPO="all"
        shift
        if [[ $# -gt 0 ]]; then
          case "$1" in
            pending|rollback|all) TARGET_REPO="$1"; shift ;;
            -*) : ;;
            *) echo "Invalid cache type '$1' (pending|rollback|all)" >&2; exit 1 ;;
          esac
        fi
        ;;
      --config)
        [[ $# -ge 2 ]] || { echo "Missing argument for --config" >&2; exit 1; }
        CONFIG_OVERRIDE="$2"; shift 2 ;;
      --version)      echo "$SCRIPT_VERSION"; exit 0 ;;
      -h|--help)      usage; exit 0 ;;
      *)              echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  load_config
  validate_config || exit 1

  if [[ -e "$STATE_DIR" && ! -w "$STATE_DIR" ]]; then
    echo "autoupdate: $STATE_DIR is not writable (owned by another user?)." >&2
    echo "autoupdate: fix with: sudo chown -R \"$USER\" \"$STATE_DIR\"" >&2
    exit 1
  fi

  rotate_log_if_needed

  case "$MODE" in
    update|check|add-repo|remove-repo|clear-cache)
      check_dependencies_for_mode || exit 1
      acquire_lock || exit 1
      trap 'release_lock; cleanup' EXIT
      ;;
    *)
      check_dependencies_for_mode || exit 1
      ;;
  esac

  verify_sudo_available || exit 1

  migrate_state_if_needed

  case "$MODE" in
    cache-info)  cache_info; exit 0 ;;
    clear-cache) clear_cache "$TARGET_REPO"; exit $? ;;
    list-assets) list_assets "$TARGET_REPO"; exit $? ;;
    add-repo)    add_repo_to_file "$TARGET_REPO"; exit $? ;;
    remove-repo) remove_repo_from_file "$TARGET_REPO"; exit $? ;;
  esac

  load_repos

  if [[ "$MODE" == "status" ]]; then
    show_status
    exit 0
  fi

  if [[ -n "$REPO_FILTER" ]]; then
    REPOS=("$REPO_FILTER")
  fi

  if (( ${#REPOS[@]} == 0 )); then
    log "WARN" "No repositories found in $REPOS_FILE"
    exit 0
  fi

  check_cache_size

  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "Running in DRY-RUN mode; no packages or state files will be modified"
  fi
  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "INFO" "Running in CHECK-ONLY mode"
  fi

  local failures=0 repo
  for repo in "${REPOS[@]}"; do
    if ! process_repo "$repo"; then
      failures=$(( failures + 1 ))
    fi
  done

  if (( failures > 0 )); then
    log "ERROR" "$failures repo(s) failed"
    exit 1
  fi
  exit 0
}

main "$@"
