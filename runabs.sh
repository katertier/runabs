#!/bin/sh
# =============================================================================
# Audiobookshelf Runner <https://www.audiobookshelf.org>
#
# Strict POSIX shell - no bashisms, runs under dash/ash/bash/ksh/posh/busybox.
# Supports Node.js and Bun runtimes. Cross-platform (macOS, Linux, BSD).
#
# DISCLAIMER: This script is provided "AS IS" with no warranties of any kind.
# Use at your own risk; see the GPL notice below for full legal terms.
# =============================================================================
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
# =============================================================================

# -----------------------------------------------------------------------------
# Strict shell options. errexit + nounset are POSIX. pipefail is enabled when
# the running shell supports it; strict-POSIX shells without pipefail lose
# only pipe-failure detection, the rest of the safety remains intact.
# -----------------------------------------------------------------------------
set -o errexit
set -o nounset
(set -o pipefail) 2>/dev/null && set -o pipefail || true

# >>>>>>>>>>>>>>>>>>>>>>>> USER CONFIGURATION START <<<<<<<<<<<<<<<<<<<<<<<<<<<
# Configuration priority (highest wins):
#   1. Environment variables set before running the script
#   2. ~/.env_abs file (user-global)
#   3. .env file next to this script (directory-local)
#   4. Defaults below
# =============================================================================

# --- Root directory for all ABS data (repo, config, metadata, logs) ---
ABS_ROOT="${ABS_ROOT:-$HOME/audiobookshelf}"

# --- Server settings ---
ABS_HOST="${ABS_HOST:-}"
ABS_HOSTNAME="${ABS_HOSTNAME:-}"
ABS_PORT="${ABS_PORT:-13378}"
ABS_CONFIG_PATH="${ABS_CONFIG_PATH:-config}"
ABS_METADATA_PATH="${ABS_METADATA_PATH:-metadata}"

# --- Binary paths (empty = auto-detect from PATH) ---
ABS_FFMPEG="${ABS_FFMPEG:-}"
ABS_FFPROBE="${ABS_FFPROBE:-}"
ABS_SKIP_BINARIES_CHECK="${ABS_SKIP_BINARIES_CHECK:-}"

# --- Optional features ---
ABS_NUNICODE_PATH="${ABS_NUNICODE_PATH:-}"
ABS_ALLOW_IFRAME="${ABS_ALLOW_IFRAME:-}"
ABS_BACKUP_PATH="${ABS_BACKUP_PATH:-}"

# --- Additional ABS env vars ---
# https://www.audiobookshelf.org/docs#env-configuration
# ABS_ROUTER_BASE_PATH: the `-` (no colon) means "use default only if unset"
# so an explicit empty value is respected.
ABS_ROUTER_BASE_PATH="${ABS_ROUTER_BASE_PATH-/audiobookshelf}"
ABS_REACT_CLIENT_PATH="${ABS_REACT_CLIENT_PATH:-}"
ABS_ALLOW_CORS="${ABS_ALLOW_CORS:-}"
ABS_SSRF_WHITELIST="${ABS_SSRF_WHITELIST:-}"
ABS_DISABLE_SSRF="${ABS_DISABLE_SSRF:-}"
ABS_JWT_SECRET="${ABS_JWT_SECRET:-}"

# --- Runtime selection ---
# Values: "node", "bun", or absolute path to a binary.
# Empty = prompt on first run, then persist choice to $ABS_ROOT/.runtime
ABS_RUNTIME="${ABS_RUNTIME:-}"

# --- Update behavior ---
ABS_AUTO_UPDATE="${ABS_AUTO_UPDATE:-true}"

# --- Log rotation threshold ---
# Accepts:
#   bare number              -> megabytes (e.g. "50" = 50 MB)
#   <number>K|KB|KiB         -> kilobytes
#   <number>M|MB|MiB         -> megabytes
#   <number>G|GB|GiB         -> gigabytes
#   <number>d                -> rotate when log file is older than N days
# Examples: "50", "100M", "1G", "30d"
ABS_LOG_ROTATE="${ABS_LOG_ROTATE:-50M}"

# --- Bun sqlite3 rebuild behavior ---
# Bun occasionally skips the postinstall step that builds sqlite3's native
# bindings. The script can rebuild them via `npm rebuild sqlite3`.
# Values:
#   auto    rebuild only if the .node file is missing (default)
#   always  rebuild on every install
#   never   skip the rebuild even if the .node file is missing
# Ignored when RUNTIME_FAMILY=node (Node's npm builds sqlite3 itself).
ABS_BUN_SQLITE_REBUILD="${ABS_BUN_SQLITE_REBUILD:-auto}"

# >>>>>>>>>>>>>>>>>>>>>>>>> USER CONFIGURATION END <<<<<<<<<<<<<<<<<<<<<<<<<<<<

# =============================================================================
# IMMUTABLE CONSTANTS
# =============================================================================
ABS_RUN_VERSION="4.0.5"
readonly ABS_RUN_VERSION

LAUNCHD_LABEL="org.audiobookshelf.server"
SYSTEMD_UNIT="audiobookshelf.service"
GENERIC_WRAPPER_NAME=".audiobookshelf-autostart.sh"
CRONTAB_MARKER="audiobookshelf-autostart"
readonly LAUNCHD_LABEL SYSTEMD_UNIT GENERIC_WRAPPER_NAME CRONTAB_MARKER

ABS_DOCS_URL="https://www.audiobookshelf.org/docs#env-configuration"
ABS_REPO_URL="https://github.com/advplyr/audiobookshelf.git"
BUN_INSTALL_URL="https://bun.sh/install"
NUNICODE_RELEASE_BASE="https://github.com/mikiher/nunicode-sqlite/releases/latest/download"
readonly ABS_DOCS_URL ABS_REPO_URL BUN_INSTALL_URL NUNICODE_RELEASE_BASE

NODE_MIN_MAJOR_VERSION=20
JWT_SECRET_MIN_LENGTH=32
STARTUP_HEALTH_CHECK_SECONDS=5
GRACEFUL_STOP_TIMEOUT_SECONDS=5
readonly NODE_MIN_MAJOR_VERSION JWT_SECRET_MIN_LENGTH \
         STARTUP_HEALTH_CHECK_SECONDS GRACEFUL_STOP_TIMEOUT_SECONDS

OS_NAME="$(uname -s)"
OS_ARCH="$(uname -m)"
readonly OS_NAME OS_ARCH

# =============================================================================
# MUTABLE GLOBALS (finalized during main's init stages)
# =============================================================================
REPO_DIR=""
PID_FILE=""
LOG_FILE=""
LOG_FILE_ROTATED=""
RUNTIME_FILE=""
LOCK_DIR=""
SCRIPT_PATH=""
SCRIPT_DIR=""
SCRIPT_NAME=""
RUNTIME_BIN=""
RUNTIME_FAMILY=""
CMD=""
DEV_MODE="false"
INIT_HOME="false"
UPDATE_OVERRIDE=""
DO_UPDATE=""
MODE_ARG=""
INSTALL_IN_PROGRESS=0
TERM_HAS_COLOR=0
SYM_OK=""
SYM_WARN=""
SYM_ERR=""
SYM_INFO=""
VALIDATION_FAILURES=0

# =============================================================================
# PATH RESOLUTION
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Resolves a path to an absolute, symlink-free filesystem path.
#              Used to discover where this script actually lives, so service
#              files (launchd plist, systemd unit) bake in a stable path that
#              doesn't break if the script is invoked via symlink.
# Inputs:      $1 - path to resolve (typically $0)
# Outputs:     stdout: absolute path with all symlinks resolved
# Called by:   main (early init)
# -----------------------------------------------------------------------------
resolve_script_path_to_absolute() (
  path_to_resolve="$1"
  [ -n "$path_to_resolve" ] || return 0

  if command -v readlink >/dev/null 2>&1; then
    while [ -L "$path_to_resolve" ]; do
      containing_directory="$(cd -P "$(dirname "$path_to_resolve")" && pwd -P)"
      link_target="$(readlink "$path_to_resolve")"
      case "$link_target" in
        /*) path_to_resolve="$link_target" ;;
         *) path_to_resolve="$containing_directory/$link_target" ;;
      esac
    done
  fi

  containing_directory="$(cd -P "$(dirname "$path_to_resolve")" && pwd -P)"
  file_basename="$(basename "$path_to_resolve")"
  printf '%s/%s\n' "$containing_directory" "$file_basename"
)

# =============================================================================
# INPUT VALIDATION HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Tests whether a string matches RFC 1123 hostname syntax.
# Inputs:      $1 - hostname string
# Outputs:     return: 0 if valid, 1 otherwise
# Called by:   is_valid_hostname_or_ip
# -----------------------------------------------------------------------------
is_valid_rfc1123_hostname() {
  hostname_to_check="$1"
  case "$hostname_to_check" in
    "") return 1 ;;
    *..*) return 1 ;;
    .*|*.) return 1 ;;
    -*|*-) return 1 ;;
  esac
  if [ "${#hostname_to_check}" -gt 253 ]; then
    return 1
  fi
  case "$hostname_to_check" in
    *[!a-zA-Z0-9.-]*) return 1 ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Description: Tests whether a string is a syntactically valid IPv4 dotted
#              quad address (0..255 per octet, no leading zeros).
# Inputs:      $1 - candidate IP string
# Outputs:     return: 0 if valid, 1 otherwise
# Called by:   is_valid_hostname_or_ip
# -----------------------------------------------------------------------------
is_valid_ipv4_address() {
  ipv4_candidate="$1"
  case "$ipv4_candidate" in
    *[!0-9.]*) return 1 ;;
  esac
  separator_count="$(printf '%s' "$ipv4_candidate" | tr -cd '.' | wc -c | tr -d ' ')"
  [ "$separator_count" = "3" ] || return 1

  saved_ifs="$IFS"
  IFS='.'
  # shellcheck disable=SC2086
  set -- $ipv4_candidate
  IFS="$saved_ifs"
  [ "$#" = "4" ] || return 1

  for octet in "$@"; do
    case "$octet" in
      ""|*[!0-9]*) return 1 ;;
      0[0-9]*) return 1 ;;
    esac
    if [ "$octet" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}

# -----------------------------------------------------------------------------
# Description: Tests whether a string is a syntactically valid IPv6 address.
#              Accepts colon-separated hextets, optionally with one "::"
#              compression group. Does not validate IPv4-in-IPv6 mixed forms
#              beyond basic structure.
# Inputs:      $1 - candidate IPv6 string
# Outputs:     return: 0 if valid, 1 otherwise
# Called by:   is_valid_hostname_or_ip
# -----------------------------------------------------------------------------
is_valid_ipv6_address() {
  ipv6_candidate="$1"
  case "$ipv6_candidate" in
    "") return 1 ;;
    *[!0-9a-fA-F:]*) return 1 ;;
    *:::*) return 1 ;;
  esac

  # Count `::` occurrences (at most one allowed).
  reduced_string="$ipv6_candidate"
  double_colon_occurrences=0
  while :; do
    case "$reduced_string" in
      *::*)
        double_colon_occurrences=$((double_colon_occurrences + 1))
        reduced_string="${reduced_string#*::}"
        ;;
      *) break ;;
    esac
  done
  [ "$double_colon_occurrences" -le 1 ] || return 1

  # Validate hextet count and length. Split on `:` using IFS.
  # Without `::`: must be exactly 8 hextets, each 1-4 hex chars.
  # With `::`:    must be 1-7 hextets explicit, each 1-4 hex chars
  #              (`::` represents one or more zero hextets).
  # Edge cases: leading/trailing `:` is only valid as part of `::`,
  # which produces an empty field on that side after the split.
  hextet_count=0
  ipv6_old_ifs="$IFS"
  IFS=":"
  # shellcheck disable=SC2086 # intentional word-splitting on $ipv6_candidate
  for hextet_field in $ipv6_candidate ""; do
    # The trailing "" terminator detects a trailing `:` (POSIX `for`
    # would otherwise drop a trailing empty field after IFS split).
    if [ -z "$hextet_field" ]; then continue; fi
    case "$hextet_field" in
      *[!0-9a-fA-F]*) IFS="$ipv6_old_ifs"; return 1 ;;
    esac
    # Hex length must be 1-4 chars
    hextet_length=${#hextet_field}
    if [ "$hextet_length" -lt 1 ] || [ "$hextet_length" -gt 4 ]; then
      IFS="$ipv6_old_ifs"
      return 1
    fi
    hextet_count=$((hextet_count + 1))
  done
  IFS="$ipv6_old_ifs"

  if [ "$double_colon_occurrences" -eq 0 ]; then
    # No compression: must be exactly 8 hextets.
    [ "$hextet_count" -eq 8 ] || return 1
  else
    # With `::`: between 0 and 7 explicit hextets (the `::` fills the rest).
    [ "$hextet_count" -ge 0 ] && [ "$hextet_count" -le 7 ] || return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Description: Tests whether a string is acceptable as a network hostname
#              (RFC 1123), IPv4 address, or IPv6 address.
# Inputs:      $1 - candidate string
# Outputs:     return: 0 if valid, 1 otherwise
# Called by:   validate_host_and_hostname_and_print_errors
# -----------------------------------------------------------------------------
is_valid_hostname_or_ip() {
  host_candidate="$1"
  is_valid_ipv4_address     "$host_candidate" && return 0
  is_valid_ipv6_address     "$host_candidate" && return 0
  is_valid_rfc1123_hostname "$host_candidate" && return 0
  return 1
}

# -----------------------------------------------------------------------------
# Description: Tests whether a string is a positive integer (digits only).
# Inputs:      $1 - candidate string
# Outputs:     return: 0 if positive integer, 1 otherwise
# Called by:   parse_log_rotate_spec_to_size_and_age, is_in_port_range,
#              pid_is_our_running_daemon, warn_if_node_version_below_minimum
# -----------------------------------------------------------------------------
is_positive_integer() {
  integer_candidate="$1"
  case "$integer_candidate" in
    ""|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Description: Tests whether an integer falls within the TCP/UDP port range
#              1..65535.
# Inputs:      $1 - candidate integer
# Outputs:     return: 0 if in range, 1 otherwise
# Called by:   validate_port_and_print_errors
# -----------------------------------------------------------------------------
is_in_port_range() {
  port_candidate="$1"
  is_positive_integer "$port_candidate" || return 1
  if [ "$port_candidate" -lt 1 ] || [ "$port_candidate" -gt 65535 ]; then
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Description: Tests whether a string is an acceptable boolean-ish value
#              (empty, "0", "1", "true", "false", case-insensitive).
# Inputs:      $1 - candidate string
# Outputs:     return: 0 if valid boolean flag, 1 otherwise
# Called by:   validate_boolean_flags_and_print_errors
# -----------------------------------------------------------------------------
is_valid_boolean_flag() {
  flag_candidate="$1"
  case "$flag_candidate" in
    ""|0|1|true|false|TRUE|FALSE|True|False) return 0 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Description: Normalizes any of the accepted boolean values (0/1/true/false/
#              TRUE/FALSE/True/False) to a lowercase JS boolean literal
#              ("true" or "false"). Empty input returns empty so callers can
#              decide to skip emission entirely.
#              This avoids type mismatches in generated dev.js: if a user
#              writes ABS_ALLOW_IFRAME=1, we'd otherwise emit AllowIframe: 1
#              (a number) which would fail a strict `=== true` check on the
#              consumer side.
# Inputs:      $1 - validated boolean candidate (already passed is_valid_boolean_flag)
# Outputs:     stdout: "true", "false", or empty
# Called by:   write_dev_js_config_file
# -----------------------------------------------------------------------------
normalize_boolean_to_js_literal() {
  case "$1" in
    1|true|TRUE|True)   printf 'true\n' ;;
    0|false|FALSE|False) printf 'false\n' ;;
    *) ;;  # empty: print nothing
  esac
}

# -----------------------------------------------------------------------------
# Description: Tests whether a path is absolute (starts with "/").
# Inputs:      $1 - candidate path
# Outputs:     return: 0 if absolute, 1 otherwise
# Called by:   validate_absolute_paths_and_print_errors
# -----------------------------------------------------------------------------
is_absolute_filesystem_path() {
  path_candidate="$1"
  case "$path_candidate" in
    /*) return 0 ;;
    *)  return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Description: Parses a log-rotate spec into either a byte threshold or a
#              day threshold (exactly one is non-zero).
# Inputs:      $1 - spec string (e.g. "50", "100M", "1G", "30d")
# Outputs:     stdout: two space-separated values "bytes days"
#              return: 0 on success, 1 on parse failure
# Called by:   rotate_log_file_if_threshold_exceeded,
#              validate_log_rotate_spec_and_print_errors
# -----------------------------------------------------------------------------
parse_log_rotate_spec_to_size_and_age() {
  spec_to_parse="$1"
  [ -n "$spec_to_parse" ] || return 1

  spec_numeric_portion="$(printf '%s' "$spec_to_parse" | sed 's/[^0-9].*//')"
  spec_suffix="$(printf '%s' "$spec_to_parse" | sed 's/^[0-9]*//')"

  is_positive_integer "$spec_numeric_portion" || return 1

  case "$spec_suffix" in
    "")
      printf '%s 0\n' "$((spec_numeric_portion * 1024 * 1024))"
      ;;
    [Kk]|[Kk][Bb]|[Kk][Ii][Bb])
      printf '%s 0\n' "$((spec_numeric_portion * 1024))"
      ;;
    [Mm]|[Mm][Bb]|[Mm][Ii][Bb])
      printf '%s 0\n' "$((spec_numeric_portion * 1024 * 1024))"
      ;;
    [Gg]|[Gg][Bb]|[Gg][Ii][Bb])
      printf '%s 0\n' "$((spec_numeric_portion * 1024 * 1024 * 1024))"
      ;;
    d|D)
      printf '0 %s\n' "$spec_numeric_portion"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# =============================================================================
# ENV FILE LOADING
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Sources an env file if it exists, with a warning on syntax
#              error rather than aborting the script.
# Inputs:      $1 - path to env file
# Outputs:     side effect: variables become script-scope on success
#              stderr: warning on syntax error
# Called by:   main (early init)
# -----------------------------------------------------------------------------
load_env_file_with_warning_on_error() {
  env_file_path="$1"
  [ -f "$env_file_path" ] || return 0

  # Validate syntax first using `sh -n`. In theory POSIX permits `.` to
  # return non-zero from inside an `if !` condition (set -e is suppressed
  # in condition position, XCU 2.8.1) so a syntax error would be catchable.
  # In practice, dash and posh treat parse errors in sourced files as a
  # fatal class that terminates the shell regardless of the surrounding
  # `if`. Only bash actually behaves the way the spec would suggest.
  # Pre-checking with `sh -n` sidesteps the divergence: we never let a
  # broken file reach the `.` builtin under those shells.
  #
  # Use mktemp rather than a predictable /tmp/runabs-env-err.$$ path.
  # On a multi-user system, $$ is guessable and a malicious user could
  # pre-create a symlink at that path pointing to a sensitive file we
  # would then truncate. mktemp atomically creates with O_EXCL and a
  # random suffix, defeating that.
  env_error_capture="$(mktemp "${TMPDIR:-/tmp}/runabs-env-err.XXXXXX")" || {
    printf 'Warning: could not create temp file; skipping env validation for %s\n' "$env_file_path" >&2
    return 0
  }
  if ! sh -n "$env_file_path" 2>"$env_error_capture"; then
    printf 'Warning: syntax error in %s; skipping.\n' "$env_file_path" >&2
    if [ -s "$env_error_capture" ]; then
      sed 's/^/  /' "$env_error_capture" >&2
    fi
    rm -f "$env_error_capture"
    return 0
  fi

  # Syntax is good; now source it. Capture any runtime errors (e.g. a
  # command that fails, an unset variable referenced under nounset).
  # shellcheck source=/dev/null
  if ! . "$env_file_path" 2>"$env_error_capture"; then
    printf 'Warning: error sourcing %s\n' "$env_file_path" >&2
    [ -s "$env_error_capture" ] && sed 's/^/  /' "$env_error_capture" >&2
  elif [ -s "$env_error_capture" ]; then
    # Sourcing succeeded but the shell emitted warnings - show them too.
    sed 's/^/  /' "$env_error_capture" >&2
  fi
  rm -f "$env_error_capture"
}

# =============================================================================
# TERMINAL / COLOR HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Detects whether stdout supports ANSI color and initialises
#              the SYM_* symbol strings used throughout the script.
# Inputs:      env: TERM
# Outputs:     globals set: TERM_HAS_COLOR, SYM_OK, SYM_WARN, SYM_ERR, SYM_INFO
# Called by:   main (early init)
# -----------------------------------------------------------------------------
initialize_terminal_capabilities() {
  detected_color_count=""

  if [ -t 1 ]; then
    if command -v tput >/dev/null 2>&1; then
      detected_color_count="$(tput colors 2>/dev/null || printf '0')"
    fi
    case "${TERM:-}" in
      *color*|*colour*|xterm*|screen*|tmux*|rxvt*|linux|alacritty|kitty|foot|wezterm|ghostty)
        : ;;
      *)
        detected_color_count=0
        ;;
    esac
  fi

  if [ -n "$detected_color_count" ] && [ "$detected_color_count" -ge 8 ] 2>/dev/null; then
    TERM_HAS_COLOR=1
    SYM_OK="$(printf '\033[32m\xe2\x9c\x94\033[0m')"
    SYM_WARN="$(printf '\033[33m!\033[0m')"
    SYM_ERR="$(printf '\033[31m\xe2\x9c\x98\033[0m')"
    SYM_INFO="$(printf '\033[34m\xe2\x86\x92\033[0m')"
  else
    TERM_HAS_COLOR=0
    SYM_OK="[OK]"
    SYM_WARN="[!]"
    SYM_ERR="[ERR]"
    SYM_INFO="[->]"
  fi
}

# -----------------------------------------------------------------------------
# Description: Wraps a string in an ANSI color sequence when color is
#              supported; otherwise returns the string unchanged.
# Inputs:      $1 - ANSI code digits (e.g. "31" for red, "1" for bold)
#              $2 - string to wrap
# Outputs:     stdout: wrapped or plain string (no trailing newline)
# Called by:   color_in_* helpers, used inline throughout
# -----------------------------------------------------------------------------
wrap_in_ansi_color_code() (
  ansi_code_digits="$1"
  text_to_wrap="$2"
  if [ "$TERM_HAS_COLOR" = "1" ]; then
    printf '\033[%sm%s\033[0m' "$ansi_code_digits" "$text_to_wrap"
  else
    printf '%s' "$text_to_wrap"
  fi
)

# Thin convenience wrappers (trivial enough to skip doc blocks).
color_in_red()    ( wrap_in_ansi_color_code "31" "$1" )
color_in_green()  ( wrap_in_ansi_color_code "32" "$1" )
color_in_yellow() ( wrap_in_ansi_color_code "33" "$1" )
color_in_blue()   ( wrap_in_ansi_color_code "34" "$1" )
color_in_cyan()   ( wrap_in_ansi_color_code "36" "$1" )
color_in_bold()   ( wrap_in_ansi_color_code "1"  "$1" )

# -----------------------------------------------------------------------------
# Description: Strips ANSI escape sequences from a string. Used for accurate
#              width calculations when rendering aligned columns.
# Inputs:      $1 - string possibly containing ANSI sequences
# Outputs:     stdout: string with CSI sequences removed
# Called by:   print_help_command_line
# -----------------------------------------------------------------------------
strip_ansi_escape_sequences() (
  string_with_ansi="$1"
  escape_character="$(printf '\033')"
  printf '%s' "$string_with_ansi" | sed "s/${escape_character}\[[0-9;]*m//g"
)

# =============================================================================
# LOCK FILE MANAGEMENT
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Acquires a per-ABS_ROOT lock to prevent concurrent runs of
#              the script against the same installation.
# Inputs:      globals: LOCK_DIR, SCRIPT_NAME, ABS_ROOT
# Outputs:     side effect: creates LOCK_DIR
#              exit: 1 if lock already held
# Called by:   main (state-mutating commands)
# -----------------------------------------------------------------------------
acquire_run_lock_or_exit() {
  if [ -d "$LOCK_DIR" ]; then
    if [ -f "$LOCK_DIR/pid" ]; then
      lock_holder_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
      if [ -n "$lock_holder_pid" ] && kill -0 "$lock_holder_pid" 2>/dev/null; then
        printf '%s\n' "$(color_in_red "Another $SCRIPT_NAME instance is running against $ABS_ROOT.")"
        printf '  Lock: %s (PID: %s)\n' "$LOCK_DIR" "$lock_holder_pid"
        printf '  If this is stale, remove it: rm -rf %s\n' "$LOCK_DIR"
        exit 1
      fi
    fi
    # Stale lock — holder is dead or file is missing.
    rm -rf "$LOCK_DIR"
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$(color_in_red "Another $SCRIPT_NAME instance is running against $ABS_ROOT.")"
    printf '  Lock: %s\n' "$LOCK_DIR"
    printf '  If this is stale, remove it: rm -rf %s\n' "$LOCK_DIR"
    exit 1
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

# -----------------------------------------------------------------------------
# Description: Removes the lock directory if it exists. Tolerant of absence.
# Inputs:      global: LOCK_DIR
# Outputs:     side effect: LOCK_DIR removed
# Called by:   handle_script_exit (via EXIT trap)
# -----------------------------------------------------------------------------
release_run_lock_if_held() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Description: EXIT trap. Releases the lock, and on non-zero exit during the
#              install phase prints cleanup hints.
# Inputs:      special $?
#              globals: INSTALL_IN_PROGRESS, REPO_DIR, SCRIPT_NAME
# Outputs:     stdout: cleanup hint (only on abnormal exit during install)
#              exit: propagates original exit code
# Called by:   trap (EXIT)
# -----------------------------------------------------------------------------
handle_script_exit() {
  captured_exit_code=$?
  release_run_lock_if_held
  if [ "$captured_exit_code" -ne 0 ] && [ "$INSTALL_IN_PROGRESS" -eq 1 ]; then
    printf '\n%s\n' "$(color_in_yellow "Interrupted during installation.")"
    printf '%s\n' "Partial state may exist under: $REPO_DIR"
    printf '%s\n' "To clean up and start fresh:"
    printf '  rm -rf "%s"\n' "$REPO_DIR"
    printf '  ./%s start\n' "$SCRIPT_NAME"
  fi
  exit "$captured_exit_code"
}

# =============================================================================
# DOWNLOAD HELPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Downloads a URL to a file using curl if available, else wget.
# Inputs:      $1 - source URL
#              $2 - destination file path
# Outputs:     side effect: file written on success
#              return: 0 on success, 1 if no downloader or download failed
# Called by:   download_nunicode_and_set_path
# -----------------------------------------------------------------------------
download_url_to_file() (
  source_url="$1"
  destination_file="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$source_url" -o "$destination_file"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$source_url" -O "$destination_file"
  else
    return 1
  fi
)

# -----------------------------------------------------------------------------
# Description: Downloads a URL and streams the body to stdout.
# Inputs:      $1 - source URL
# Outputs:     stdout: response body on success
#              return: 0 on success, 1 if no downloader or download failed
# Called by:   install_bun_via_official_installer_with_consent
# -----------------------------------------------------------------------------
download_url_to_stdout() (
  source_url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$source_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$source_url"
  else
    return 1
  fi
)

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Verifies required and optional system deps; prints install
#              hints and exits 1 if a required dep is missing.
# Inputs:      globals: OS_NAME, OS_ARCH, ABS_FFMPEG, ABS_FFPROBE
# Outputs:     stdout: status, install hints
#              stderr: error messages
#              exit: 1 on missing required deps
# Called by:   main
# -----------------------------------------------------------------------------
check_dependencies_and_print_install_hints() {
  required_missing_list=""
  optional_missing_list=""

  if ! command -v git >/dev/null 2>&1; then
    required_missing_list="${required_missing_list} git"
  fi

  case "$OS_NAME" in
    Darwin)
      :
      ;;
    *)
      if ! command -v curl >/dev/null 2>&1 && \
         ! command -v wget >/dev/null 2>&1; then
        required_missing_list="${required_missing_list} curl|wget"
      fi
      if ! command -v unzip >/dev/null 2>&1; then
        optional_missing_list="${optional_missing_list} unzip"
      fi
      ;;
  esac

  if [ -n "$required_missing_list" ]; then
    printf '\n%s\n' "$(color_in_bold "$(color_in_red "ERROR: Required dependencies missing:${required_missing_list}")")"
    printf 'Quick hint:\n'
    print_package_manager_install_hint "$required_missing_list" "$optional_missing_list"
    printf 'See ABS_NO_DOCKER.md "Prerequisites" for details.\n\n'
    exit 1
  fi

  if [ -n "$optional_missing_list" ]; then
    printf '%s Optional dependency missing:%s (nunicode search will be unavailable)\n' \
      "$(color_in_yellow "[!]")" "$optional_missing_list"
  fi

  check_ffmpeg_availability_and_print_install_hints
}

# -----------------------------------------------------------------------------
# Description: Checks for ffmpeg/ffprobe and prints platform-specific install
#              hints. On Apple Silicon, exits if missing because ABS-downloaded
#              binaries are x86_64 and fail with "Bad CPU type".
# Inputs:      globals: OS_NAME, OS_ARCH, ABS_FFMPEG, ABS_FFPROBE
# Outputs:     stdout: status / hints
#              exit: 1 on Apple Silicon if missing
# Called by:   check_dependencies_and_print_install_hints
# -----------------------------------------------------------------------------
check_ffmpeg_availability_and_print_install_hints() {
  ffmpeg_missing_list=""
  if ! command -v ffmpeg >/dev/null 2>&1 && [ -z "$ABS_FFMPEG" ]; then
    ffmpeg_missing_list="ffmpeg"
  fi
  if ! command -v ffprobe >/dev/null 2>&1 && [ -z "$ABS_FFPROBE" ]; then
    ffmpeg_missing_list="${ffmpeg_missing_list} ffprobe"
  fi

  [ -n "$ffmpeg_missing_list" ] || return 0

  if [ "$OS_NAME" = "Darwin" ] && [ "$OS_ARCH" = "arm64" ]; then
    printf '\n%s\n' "$(color_in_bold "$(color_in_red "ERROR: ffmpeg/ffprobe missing on Apple Silicon.")")"
    printf 'ABS would download x86_64 binaries that fail with "Bad CPU type".\n'
    printf 'Install natively first (see ABS_NO_DOCKER.md "Prerequisites"):\n'
    print_package_manager_install_hint "ffmpeg" ""
    printf '\n'
    exit 1
  fi

  printf '\n%s\n' "$(color_in_yellow "WARNING: ffmpeg/ffprobe not in PATH.")"
  printf 'ABS will attempt to download its own copy. Better to install yourself:\n'
  print_package_manager_install_hint "ffmpeg" ""
  printf 'See ABS_NO_DOCKER.md "Prerequisites" for details.\n\n'
}

# -----------------------------------------------------------------------------
# Description: Prints a platform-appropriate package manager install command.
# Inputs:      $1 - required deps (space-separated)
#              $2 - optional deps (space-separated)
#              global: OS_NAME
# Outputs:     stdout: install command hint
# Called by:   check_dependencies_and_print_install_hints,
#              check_ffmpeg_availability_and_print_install_hints,
#              print_node_install_instructions_and_exit
# -----------------------------------------------------------------------------
print_package_manager_install_hint() {
  required_pkgs="$1"
  optional_pkgs="$2"
  # Ensure each list has exactly one leading space (so "git" → " git"; " git" → " git")
  case "$required_pkgs" in
    ""|" "*) ;;
    *) required_pkgs=" $required_pkgs" ;;
  esac
  case "$optional_pkgs" in
    ""|" "*) ;;
    *) optional_pkgs=" $optional_pkgs" ;;
  esac
  case "$OS_NAME" in
    Darwin)
      printf '  brew install%s%s\n' "$required_pkgs" "$optional_pkgs"
      ;;
    Linux)
      if command -v apk >/dev/null 2>&1; then
        printf '  apk add%s%s\n' "$required_pkgs" "$optional_pkgs"
      elif command -v apt-get >/dev/null 2>&1; then
        printf '  sudo apt-get install%s%s\n' "$required_pkgs" "$optional_pkgs"
      elif command -v dnf >/dev/null 2>&1; then
        printf '  sudo dnf install%s%s\n' "$required_pkgs" "$optional_pkgs"
      elif command -v pacman >/dev/null 2>&1; then
        printf '  sudo pacman -S%s%s\n' "$required_pkgs" "$optional_pkgs"
      else
        printf '  Use your package manager to install:%s%s\n' "$required_pkgs" "$optional_pkgs"
      fi
      ;;
    FreeBSD|OpenBSD|NetBSD)
      printf '  Use pkg/pkg_add to install:%s%s\n' "$required_pkgs" "$optional_pkgs"
      ;;
    *)
      printf '  Use your package manager to install:%s%s\n' "$required_pkgs" "$optional_pkgs"
      ;;
  esac
}

# =============================================================================
# RUNTIME (NODE / BUN) SELECTION
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Detects the runtime family ("node" or "bun") from a binary
#              path or basename.
# Inputs:      $1 - path or basename
# Outputs:     stdout: "node", "bun", or empty
# Called by:   ensure_runtime_selected_and_persisted,
#              check_config_and_print_report
# -----------------------------------------------------------------------------
detect_runtime_family_from_binary_name() (
  binary_to_classify="$1"
  case "$(basename "$binary_to_classify")" in
    node) printf 'node\n' ;;
    bun)  printf 'bun\n'  ;;
    *)    printf '' ;;
  esac
)

# -----------------------------------------------------------------------------
# Description: Resolves a runtime spec ("node"/"bun" or absolute path) to an
#              absolute executable path.
# Inputs:      $1 - runtime spec
# Outputs:     stdout: absolute path on success
#              return: 0 on success, 1 if not found / invalid
# Called by:   ensure_runtime_selected_and_persisted,
#              check_config_and_print_report
# -----------------------------------------------------------------------------
resolve_runtime_to_absolute_path() (
  runtime_spec="$1"
  case "$runtime_spec" in
    /*)
      [ -x "$runtime_spec" ] || return 1
      printf '%s\n' "$runtime_spec"
      ;;
    node|bun)
      command -v "$runtime_spec" >/dev/null 2>&1 || return 1
      command -v "$runtime_spec"
      ;;
    *)
      return 1
      ;;
  esac
)

# -----------------------------------------------------------------------------
# Description: Fetches the version string from a runtime binary.
# Inputs:      $1 - absolute path to runtime binary
# Outputs:     stdout: first line of --version output (empty on failure)
# Called by:   ensure_runtime_selected_and_persisted,
#              check_config_and_print_report,
#              prompt_user_for_runtime_choice_and_print_result
# -----------------------------------------------------------------------------
get_runtime_version_string() (
  binary_to_query="$1"
  "$binary_to_query" --version 2>/dev/null | head -n 1
)

# -----------------------------------------------------------------------------
# Description: Interactively prompts the user to choose between Node.js
#              and Bun, reporting which is currently installed.
# Inputs:      none
# Outputs:     stdout: "node" or "bun"
#              stderr: the prompt itself
#              exit: 0 on user 'q'; 1 if no TTY
# Called by:   ensure_runtime_selected_and_persisted
# -----------------------------------------------------------------------------
prompt_user_for_runtime_choice_and_print_result() {
  if [ ! -t 0 ]; then
    printf 'No runtime configured and stdin is not a TTY.\n' >&2
    printf 'Set ABS_RUNTIME=node or ABS_RUNTIME=bun and re-run.\n' >&2
    exit 1
  fi

  node_installation_status=""
  bun_installation_status=""
  command -v node >/dev/null 2>&1 && node_installation_status="yes"
  command -v bun  >/dev/null 2>&1 && bun_installation_status="yes"

  printf '\n%s\n' "$(color_in_bold "Choose a JavaScript runtime:")" >&2
  if [ -n "$node_installation_status" ]; then
    printf '  1) %s   %s\n' "$(color_in_yellow "node")" "$(get_runtime_version_string "$(command -v node)")" >&2
  else
    printf '  1) %s   not installed (install yourself, then re-run)\n' "$(color_in_yellow "node")" >&2
  fi
  if [ -n "$bun_installation_status" ]; then
    printf '  2) %s    %s\n' "$(color_in_yellow "bun")" "$(get_runtime_version_string "$(command -v bun)")" >&2
  else
    printf '  2) %s    not installed (this script can install it with your consent)\n' "$(color_in_yellow "bun")" >&2
  fi
  printf '\nSee ABS_NO_DOCKER.md for a comparison if unsure.\n' >&2
  printf 'Choose [1=node / 2=bun / q=quit]: ' >&2

  while :; do
    read -r user_answer || exit 1
    case "$user_answer" in
      1|n|node|N|Node|NODE) printf 'node\n'; return 0 ;;
      2|b|bun|B|Bun|BUN)    printf 'bun\n';  return 0 ;;
      q|Q|quit|exit)        exit 0 ;;
      *) printf 'Please answer 1, 2, or q: ' >&2 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Description: Prints Node.js installation instructions and exits 1. Node
#              is never auto-installed (no official one-line installer;
#              users use platform package managers).
# Inputs:      global: OS_NAME, NODE_MIN_MAJOR_VERSION
# Outputs:     stdout: install instructions
#              exit: 1
# Called by:   ensure_runtime_selected_and_persisted
# -----------------------------------------------------------------------------
print_node_install_instructions_and_exit() {
  printf '\n%s\n' "$(color_in_bold "Node.js is not installed.")"
  printf 'This script does not install Node.js; install it yourself first.\n\n'
  printf 'Quick hint:\n'
  print_package_manager_install_hint " nodejs npm" ""
  printf '\nSee ABS_NO_DOCKER.md "Prerequisites" section for full per-OS instructions,\n'
  printf 'or use Bun (which the script can install) at the runtime prompt.\n\n'
  exit 1
}

# -----------------------------------------------------------------------------
# Description: Offers to run Bun's official curl|bash installer with explicit
#              user consent.
# Inputs:      env: HOME; globals: OS_NAME, BUN_INSTALL_URL
# Outputs:     stdout: prompts/progress
#              stderr: errors
#              side effect: prepends ~/.bun/bin to PATH on success
#              exit: 0 on decline; 1 on install failure or no TTY
# Called by:   ensure_runtime_selected_and_persisted
# -----------------------------------------------------------------------------
install_bun_via_official_installer_with_consent() {
  printf '\n%s\n' "$(color_in_bold "Bun is not installed.")"
  printf 'The official installer (%s) downloads Bun to %s and modifies your shell profile.\n\n' \
    "$(color_in_cyan "curl -fsSL $BUN_INSTALL_URL | bash")" "$HOME/.bun"
  printf 'Trust model: this script does not verify the installer or the\n'
  printf 'downloaded Bun binary against a pinned checksum. Trust is\n'
  printf 'transferred to bun.sh + the TLS chain. If you need stricter\n'
  printf 'supply-chain controls, install Bun via your OS package manager\n'
  printf 'instead (e.g. Homebrew: brew install oven-sh/bun/bun) and\n'
  printf 're-run.\n\n'
  printf 'See ABS_NO_DOCKER.md "Prerequisites" for manual install options.\n\n'

  if [ ! -t 0 ]; then
    printf 'stdin is not a TTY; cannot prompt for consent.\n' >&2
    printf 'Install Bun manually and re-run.\n' >&2
    exit 1
  fi

  # Check prerequisites BEFORE asking for consent, so the user is not
  # asked a question they cannot act on.
  if ! command -v bash >/dev/null 2>&1; then
    printf '%s\n' "$(color_in_red "Cannot run Bun's installer: bash is not installed.")" >&2
    printf 'The Bun installer is a bash script. Install bash, or install Bun\n' >&2
    printf 'manually via your package manager and re-run.\n' >&2
    exit 1
  fi

  printf 'Run the official installer now? [y/N]: '
  read -r user_consent_answer || exit 1
  case "$user_consent_answer" in
    y|Y|yes|YES)
      printf '\nInstalling Bun...\n'
      if ! download_url_to_stdout "$BUN_INSTALL_URL" | bash; then
        printf '\n%s\n' "$(color_in_red "Bun installer failed.")" >&2
        printf 'Try installing manually.\n' >&2
        exit 1
      fi
      PATH="$HOME/.bun/bin:$PATH"
      export PATH
      if ! command -v bun >/dev/null 2>&1; then
        printf '\n%s\n' "$(color_in_red "Bun was installed but is not on PATH yet.")" >&2
        printf 'Open a new shell and re-run this script.\n' >&2
        exit 1
      fi
      printf '%s Bun installed: %s\n' "$SYM_OK" "$(get_runtime_version_string "$(command -v bun)")"
      ;;
    *)
      printf '\nInstall Bun manually and re-run.\n'
      exit 0
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Description: Warns if Node.js major version is below NODE_MIN_MAJOR_VERSION.
# Inputs:      $1 - absolute path to node binary
#              global: NODE_MIN_MAJOR_VERSION
# Outputs:     stdout: warning if below minimum
# Called by:   ensure_runtime_selected_and_persisted,
#              check_config_and_print_report
# -----------------------------------------------------------------------------
warn_if_node_version_below_minimum() {
  node_binary_path="$1"
  reported_version="$("$node_binary_path" --version 2>/dev/null | sed 's/^v//')"
  major_version_number="$(printf '%s' "$reported_version" | awk -F. '{print $1}')"
  is_positive_integer "$major_version_number" || return 0
  if [ "$major_version_number" -lt "$NODE_MIN_MAJOR_VERSION" ]; then
    printf '%s\n' "$(color_in_yellow "Warning: Node.js $reported_version is below the recommended minimum ($NODE_MIN_MAJOR_VERSION).")"
    printf '  Audiobookshelf may not work correctly. Consider upgrading.\n\n'
  fi
}

# -----------------------------------------------------------------------------
# Description: Resolves the user's runtime choice, prompting if needed,
#              installing Bun on request, validating the binary, persisting
#              the choice, and setting RUNTIME_BIN/RUNTIME_FAMILY.
# Inputs:      globals: ABS_RUNTIME, RUNTIME_FILE, REPO_DIR
# Outputs:     globals set: RUNTIME_BIN, RUNTIME_FAMILY
#              side effect: writes $RUNTIME_FILE
#              exit: on installation failure or invalid spec
# Called by:   main, install_autostart_service_and_print_result
# -----------------------------------------------------------------------------
ensure_runtime_selected_and_persisted() {
  RUNTIME_BIN=""
  RUNTIME_FAMILY=""

  runtime_spec_to_resolve="$ABS_RUNTIME"
  if [ -z "$runtime_spec_to_resolve" ] && [ -f "$RUNTIME_FILE" ]; then
    runtime_spec_to_resolve="$(cat "$RUNTIME_FILE" 2>/dev/null || true)"
  fi
  if [ -z "$runtime_spec_to_resolve" ]; then
    runtime_spec_to_resolve="$(prompt_user_for_runtime_choice_and_print_result)"
  fi

  if RUNTIME_BIN="$(resolve_runtime_to_absolute_path "$runtime_spec_to_resolve")"; then
    :
  else
    case "$runtime_spec_to_resolve" in
      node) print_node_install_instructions_and_exit ;;
      bun)
        install_bun_via_official_installer_with_consent
        RUNTIME_BIN="$(resolve_runtime_to_absolute_path "bun")" || {
          printf '%s\n' "$(color_in_red "Bun installation did not produce a usable binary.")" >&2
          exit 1
        }
        ;;
      /*)
        printf '%s\n' "$(color_in_red "Configured runtime not found or not executable: $runtime_spec_to_resolve")" >&2
        exit 1
        ;;
      *)
        printf '%s\n' "$(color_in_red "Unknown runtime: $runtime_spec_to_resolve (expected: node, bun, or absolute path)")" >&2
        exit 1
        ;;
    esac
  fi

  RUNTIME_FAMILY="$(detect_runtime_family_from_binary_name "$RUNTIME_BIN")"
  if [ -z "$RUNTIME_FAMILY" ]; then
    if "$RUNTIME_BIN" --version 2>/dev/null | grep -qi bun; then
      RUNTIME_FAMILY="bun"
    else
      RUNTIME_FAMILY="node"
    fi
  fi

  if [ "$RUNTIME_FAMILY" = "node" ]; then
    warn_if_node_version_below_minimum "$RUNTIME_BIN"
  fi

  if [ -f "$RUNTIME_FILE" ]; then
    previously_persisted_runtime="$(cat "$RUNTIME_FILE" 2>/dev/null || true)"
    if [ -n "$previously_persisted_runtime" ] && [ "$previously_persisted_runtime" != "$RUNTIME_BIN" ]; then
      previous_family="$(detect_runtime_family_from_binary_name "$previously_persisted_runtime")"
      if [ -n "$previous_family" ] && [ "$previous_family" != "$RUNTIME_FAMILY" ]; then
        printf '\n%s\n' "$(color_in_bold "$(color_in_yellow "Runtime change detected:")")"
        printf '  previous: %s\n' "$previously_persisted_runtime"
        printf '  current:  %s\n' "$RUNTIME_BIN"
        printf '\n'
        printf 'Mixed node_modules built against different runtimes can produce\n'
        printf 'cryptic errors. To clean up and rebuild:\n'
        printf '  rm -rf "%s/node_modules" "%s/client/node_modules"\n' "$REPO_DIR" "$REPO_DIR"
        printf '\n'
      fi
    fi
  fi

  printf '%s\n' "$RUNTIME_BIN" > "$RUNTIME_FILE"
}

# =============================================================================
# LOG ROTATION
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Returns the size in bytes of $LOG_FILE (0 if absent).
# Inputs:      global: LOG_FILE
# Outputs:     stdout: byte count (integer)
# Called by:   rotate_log_file_if_threshold_exceeded,
#              check_config_and_print_report
# -----------------------------------------------------------------------------
get_log_file_size_in_bytes() (
  if [ ! -f "$LOG_FILE" ]; then
    printf '0\n'
    return 0
  fi
  log_byte_count="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
  case "$log_byte_count" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$log_byte_count" ;;
  esac
)

# -----------------------------------------------------------------------------
# Description: Returns 0 if $LOG_FILE exists and is older than $1 days,
#              non-zero otherwise. Uses POSIX `find -mtime +N`.
#
#              Note on semantics: POSIX `find -mtime +N` matches files
#              whose modification time is *strictly greater than* N
#              24-hour periods ago. To get the user-intuitive "rotate
#              when N days old" behavior, we test against (N-1), so a
#              threshold of "30d" rotates a file at age 30 days, not 31.
# Inputs:      $1 - threshold in days (positive integer)
#              global: LOG_FILE
# Outputs:     return code only (no stdout)
# Called by:   rotate_log_file_if_threshold_exceeded
# -----------------------------------------------------------------------------
log_file_is_older_than_days() (
  threshold_days="$1"
  [ -f "$LOG_FILE" ] || return 1
  [ "$threshold_days" -gt 0 ] || return 1
  # Compensate for find -mtime +N being strictly-greater-than.
  find_threshold=$((threshold_days - 1))
  if [ "$find_threshold" -lt 0 ]; then
    find_threshold=0
  fi
  match="$(find "$LOG_FILE" -mtime "+${find_threshold}" 2>/dev/null)"
  [ -n "$match" ]
)

# -----------------------------------------------------------------------------
# Description: Rotates the active log to LOG_FILE.1 if the size or age
#              threshold (whichever the spec defines) is exceeded.
#              Single-generation; any existing .1 is overwritten.
# Inputs:      globals: LOG_FILE, LOG_FILE_ROTATED, ABS_LOG_ROTATE
# Outputs:     side effect: $LOG_FILE moved to $LOG_FILE_ROTATED
# Called by:   main (start / foreground)
# -----------------------------------------------------------------------------
rotate_log_file_if_threshold_exceeded() {
  [ -f "$LOG_FILE" ] || return 0

  parsed_thresholds="$(parse_log_rotate_spec_to_size_and_age "$ABS_LOG_ROTATE")" || return 0
  threshold_bytes="${parsed_thresholds% *}"
  threshold_days="${parsed_thresholds#* }"

  rotate_now=0
  if [ "$threshold_bytes" -gt 0 ]; then
    current_size_bytes="$(get_log_file_size_in_bytes)"
    if [ "$current_size_bytes" -gt "$threshold_bytes" ]; then
      rotate_now=1
    fi
  fi
  if [ "$rotate_now" = "0" ] && [ "$threshold_days" -gt 0 ]; then
    if log_file_is_older_than_days "$threshold_days"; then
      rotate_now=1
    fi
  fi

  if [ "$rotate_now" = "1" ]; then
    mv "$LOG_FILE" "$LOG_FILE_ROTATED" 2>/dev/null || true
  fi
}

# =============================================================================
# .env TEMPLATE
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Prints the default .env template to stdout.
# Inputs:      none
# Outputs:     stdout: template content
# Called by:   write_env_template_to_file_and_print_result
# -----------------------------------------------------------------------------
print_env_template_to_stdout() (
  cat << 'EndOfEnv'
# Audiobookshelf configuration
# Uncomment and edit values to customize. Delete this file to fall back
# to hardcoded defaults in the script.

# --- Root directory for all ABS data ---
# ABS_ROOT="$HOME/audiobookshelf"

# --- Network binding ---
# ABS_HOST=""              # Empty = all interfaces (0.0.0.0)
# ABS_HOSTNAME=""          # Empty = auto-detect from hostname
# ABS_PORT="13378"

# --- Paths relative to ABS_ROOT ---
# ABS_CONFIG_PATH="config"
# ABS_METADATA_PATH="metadata"

# --- Binary paths (empty = auto-detect from PATH) ---
# ABS_FFMPEG=""
# ABS_FFPROBE=""
# ABS_SKIP_BINARIES_CHECK=""

# --- Optional features ---
# ABS_NUNICODE_PATH=""     # Unicode search extension
# ABS_ALLOW_IFRAME=""      # Allow iframe embedding (security risk)
# ABS_BACKUP_PATH=""       # Backup directory override

# --- Additional ABS env vars ---
# See https://www.audiobookshelf.org/docs#env-configuration
# ABS_ROUTER_BASE_PATH="/audiobookshelf"  # URL subpath ("" for root)
# ABS_REACT_CLIENT_PATH=""                # Experimental React client (dev mode)
# ABS_ALLOW_CORS=""                       # "1" to allow CORS
# ABS_SSRF_WHITELIST=""                   # Comma-separated SSRF allowlist
# ABS_DISABLE_SSRF=""                     # "1" to disable SSRF filter (risky)
# ABS_JWT_SECRET=""                       # JWT signing key (auto-gen if empty)

# --- Runtime ---
# Values: "node", "bun", or absolute path. Empty = prompt on first run.
# ABS_RUNTIME=""

# --- Update behavior ---
# When true, start/restart/foreground pull upstream changes first.
# ABS_AUTO_UPDATE="true"

# --- Log rotation threshold ---
# Accepts: bare number (MB), <n>K/KB/KiB, <n>M/MB/MiB, <n>G/GB/GiB, <n>d
# Examples: "50", "100M", "1G", "30d"
# ABS_LOG_ROTATE="50M"

# --- Bun sqlite3 rebuild behavior ---
# Bun occasionally skips the postinstall step that builds sqlite3 native
# bindings. Values: auto (default - rebuild if missing), always, never.
# Ignored when using Node.js.
# ABS_BUN_SQLITE_REBUILD="auto"

# --- Debug tracing ---
# Set to 1 to enable shell xtrace (set -x) for troubleshooting. Same
# effect as passing --debug on the command line.
# ABS_DEBUG="1"
EndOfEnv
)

# -----------------------------------------------------------------------------
# Description: Writes the env template to a file with 0600 perms.
# Inputs:      $1 - destination file path
# Outputs:     side effect: writes file
#              stdout: confirmation
# Called by:   main (init-config command)
# -----------------------------------------------------------------------------
write_env_template_to_file_and_print_result() {
  destination_env_file="$1"
  mkdir -p "$(dirname "$destination_env_file")"
  print_env_template_to_stdout > "$destination_env_file"
  chmod 600 "$destination_env_file" 2>/dev/null || true
  printf '%s Created config file: %s\n' "$SYM_OK" "$destination_env_file"
  printf '  Edit this file to customize your setup, then restart.\n'
}

# =============================================================================
# NUNICODE LIBRARY DOWNLOAD
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Downloads the nusqlite3 unicode search extension matching the
#              host platform/arch, extracts it, and sets ABS_NUNICODE_PATH.
#
#              Empirically verified to work under both Node and Bun via the
#              npm sqlite3 package; the pre-download saves ABS BinaryManager
#              ~30s on first launch and covers platforms not in BinaryManager's
#              allowlist (e.g., FreeBSD).
# Inputs:      globals: OS_NAME, OS_ARCH, NUNICODE_RELEASE_BASE, ABS_ROOT
# Outputs:     side effect: file under $ABS_ROOT/nunicode/
#              global set: ABS_NUNICODE_PATH (on success)
#              return: 0 on success, 1 on failure
# Called by:   main
# -----------------------------------------------------------------------------
download_nunicode_and_set_path() {
  platform_tag=""
  architecture_tag=""
  musl_suffix=""

  case "$OS_NAME" in
    Darwin)
      platform_tag="osx"
      ;;
    Linux)
      platform_tag="linux"
      if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
        musl_suffix="-musl"
      fi
      ;;
    *)
      printf 'Unsupported OS for nunicode: %s. Skipping.\n' "$OS_NAME"
      return 1
      ;;
  esac

  case "$OS_ARCH" in
    x86_64|amd64)   architecture_tag="x64" ;;
    arm64|aarch64)  architecture_tag="arm64" ;;
    *)
      printf 'Unsupported architecture for nunicode: %s. Skipping.\n' "$OS_ARCH"
      return 1
      ;;
  esac

  release_asset_filename="libnusqlite3-${platform_tag}${musl_suffix}-${architecture_tag}.zip"
  release_asset_url="${NUNICODE_RELEASE_BASE}/${release_asset_filename}"
  nunicode_install_dir="$ABS_ROOT/nunicode"

  mkdir -p "$nunicode_install_dir"

  if [ -f "$nunicode_install_dir/libnusqlite3.dylib" ]; then
    ABS_NUNICODE_PATH="$nunicode_install_dir/libnusqlite3.dylib"
    return 0
  fi
  if [ -f "$nunicode_install_dir/libnusqlite3.so" ]; then
    ABS_NUNICODE_PATH="$nunicode_install_dir/libnusqlite3.so"
    return 0
  fi

  if ! command -v unzip >/dev/null 2>&1; then
    printf 'unzip not available. Skipping nunicode download.\n'
    return 1
  fi

  printf 'Downloading nunicode library: %s\n' "$release_asset_url"
  if ! download_url_to_file "$release_asset_url" "$nunicode_install_dir/nunicode.zip"; then
    printf 'Failed to download nunicode. Unicode search will be basic.\n'
    return 1
  fi

  unzip -o "$nunicode_install_dir/nunicode.zip" -d "$nunicode_install_dir" >/dev/null
  rm -f "$nunicode_install_dir/nunicode.zip"

  if [ -f "$nunicode_install_dir/libnusqlite3.dylib" ]; then
    ABS_NUNICODE_PATH="$nunicode_install_dir/libnusqlite3.dylib"
  elif [ -f "$nunicode_install_dir/libnusqlite3.so" ]; then
    ABS_NUNICODE_PATH="$nunicode_install_dir/libnusqlite3.so"
  else
    printf 'Could not find extracted nunicode library.\n'
    return 1
  fi
  printf 'Nunicode library installed at %s\n' "$ABS_NUNICODE_PATH"
}

# =============================================================================
# URL / NETWORK INSPECTION
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Detects the host's primary local IPv4 address using
#              platform-appropriate tools.
# Inputs:      global: OS_NAME
# Outputs:     stdout: IPv4 address (empty if undetermined)
# Called by:   build_access_url_via_ip, check_config_and_print_report
# -----------------------------------------------------------------------------
get_primary_local_ipv4_address() (
  if [ "$OS_NAME" = "Darwin" ]; then
    if command -v route >/dev/null 2>&1; then
      default_route_interface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
      if [ -n "$default_route_interface" ] && command -v ipconfig >/dev/null 2>&1; then
        primary_ipv4_address="$(ipconfig getifaddr "$default_route_interface" 2>/dev/null || true)"
        if [ -n "$primary_ipv4_address" ]; then
          printf '%s\n' "$primary_ipv4_address"
          return 0
        fi
      fi
    fi
    if command -v ipconfig >/dev/null 2>&1; then
      for fallback_interface in en0 en1 en2 en3; do
        primary_ipv4_address="$(ipconfig getifaddr "$fallback_interface" 2>/dev/null || true)"
        if [ -n "$primary_ipv4_address" ]; then
          printf '%s\n' "$primary_ipv4_address"
          return 0
        fi
      done
    fi
  fi
  if command -v ip >/dev/null 2>&1; then
    detected_ip_address="$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    if [ -n "$detected_ip_address" ]; then
      printf '%s\n' "$detected_ip_address"
      return 0
    fi
  fi
  if command -v ifconfig >/dev/null 2>&1; then
    detected_ip_address="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
    if [ -n "$detected_ip_address" ]; then
      printf '%s\n' "$detected_ip_address"
      return 0
    fi
  fi
  if hostname -I >/dev/null 2>&1; then
    detected_ip_address="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$detected_ip_address" ]; then
      printf '%s\n' "$detected_ip_address"
      return 0
    fi
  fi
  return 1
)

# -----------------------------------------------------------------------------
# Description: Builds the user-facing access URL using ABS_HOSTNAME (or
#              system hostname as fallback).
# Inputs:      globals: ABS_HOSTNAME, ABS_PORT, ABS_ROUTER_BASE_PATH
# Outputs:     stdout: URL
# Called by:   print_access_information_block, check_config_and_print_report
# -----------------------------------------------------------------------------
build_access_url_via_hostname() (
  host_for_url="$ABS_HOSTNAME"
  if [ -z "$host_for_url" ]; then
    host_for_url="$(hostname 2>/dev/null || printf 'localhost')"
  fi
  printf 'http://%s:%s%s\n' "$host_for_url" "$ABS_PORT" "$ABS_ROUTER_BASE_PATH"
)

# -----------------------------------------------------------------------------
# Description: Builds an alternate URL using the detected local IPv4 address.
# Inputs:      globals: ABS_PORT, ABS_ROUTER_BASE_PATH
# Outputs:     stdout: URL, or empty if no IP detected
# Called by:   print_access_information_block, check_config_and_print_report
# -----------------------------------------------------------------------------
build_access_url_via_ip() (
  detected_ip_address="$(get_primary_local_ipv4_address 2>/dev/null || true)"
  if [ -n "$detected_ip_address" ]; then
    printf 'http://%s:%s%s\n' "$detected_ip_address" "$ABS_PORT" "$ABS_ROUTER_BASE_PATH"
  fi
)

# -----------------------------------------------------------------------------
# Description: Prints a decorated "ABS is running" block with both URLs.
# Inputs:      none (delegates to build_access_url_via_* helpers)
# Outputs:     stdout: multi-line block
# Called by:   start_audiobookshelf_daemon_and_print_result,
#              run_audiobookshelf_in_foreground
# -----------------------------------------------------------------------------
print_access_information_block() {
  printf '\n%s\n\n' "$(color_in_bold "========================================")"
  printf '%s\n\n' "$(color_in_bold "Audiobookshelf is running!")"
  hostname_based_url="$(build_access_url_via_hostname)"
  printf 'Access URL: %s\n' "$(color_in_blue "$hostname_based_url")"
  ip_based_url="$(build_access_url_via_ip || true)"
  if [ -n "$ip_based_url" ] && [ "$ip_based_url" != "$hostname_based_url" ]; then
    printf '   IP URL:  %s\n' "$(color_in_blue "$ip_based_url")"
  fi
  printf '%s\n' "$(color_in_bold "========================================")"
}

# =============================================================================
# AUTOSTART SERVICE DETECTION
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Detects which (if any) autostart service is installed.
# Inputs:      env: HOME; globals: OS_NAME, LAUNCHD_LABEL, SYSTEMD_UNIT,
#              GENERIC_WRAPPER_NAME
# Outputs:     stdout: "launchd:<path>", "systemd:<path>", "crontab", or empty
# Called by:   install_autostart_service_and_print_result,
#              uninstall_autostart_service_and_print_result,
#              check_config_and_print_report
# -----------------------------------------------------------------------------
detect_installed_autostart_service() (
  case "$OS_NAME" in
    Darwin)
      darwin_plist_path="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
      if [ -f "$darwin_plist_path" ]; then
        printf 'launchd:%s\n' "$darwin_plist_path"
        return 0
      fi
      ;;
    Linux)
      systemd_unit_path="$HOME/.config/systemd/user/${SYSTEMD_UNIT}"
      if [ -f "$systemd_unit_path" ]; then
        printf 'systemd:%s\n' "$systemd_unit_path"
        return 0
      fi
      ;;
  esac
  if [ -f "$HOME/$GENERIC_WRAPPER_NAME" ]; then
    printf 'crontab\n'
    return 0
  fi
  printf ''
)

# =============================================================================
# CONFIG VALIDATION
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Validates a string for safe single-quoted JS embedding (no
#              quotes, backslash, or newline). Either exits or returns
#              failure depending on mode.
# Inputs:      $1 - mode ("exit" or "warn")
#              $2 - variable name
#              $3 - value
# Outputs:     stderr: error on failure
#              return: 0 if safe, 1 if unsafe (warn mode)
#              exit: 1 if unsafe and mode == "exit"
# Called by:   validate_runtime_config_and_print_errors
# -----------------------------------------------------------------------------
validate_string_safe_for_js_literal_and_print_errors() {
  enforcement_mode="$1"
  variable_name="$2"
  variable_value="$3"
  case "$variable_value" in
    *\'*|*\"*|*\\*)
      printf '%s %s contains a disallowed character (single quote, double quote, or backslash).\n' \
        "$(color_in_red "ERROR:")" "$variable_name" >&2
      printf '  Value: %s\n' "$variable_value" >&2
      printf '  These would break the generated dev.js. Rename to remove them.\n' >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      return 1
      ;;
  esac
  newline_character="$(printf '\nX')"
  newline_character="${newline_character%X}"
  case "$variable_value" in
    *"$newline_character"*)
      printf '%s %s contains a newline.\n' "$(color_in_red "ERROR:")" "$variable_name" >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      return 1
      ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Description: Validates ABS_PORT (positive integer, in 1..65535).
# Inputs:      $1 - mode; global: ABS_PORT
# Outputs:     stderr: error on failure
#              return: 0 if valid, 1 if invalid (warn mode)
#              exit: 1 if invalid and mode == "exit"
# Called by:   validate_runtime_config_and_print_errors
# -----------------------------------------------------------------------------
validate_port_and_print_errors() {
  enforcement_mode="$1"
  if ! is_in_port_range "$ABS_PORT"; then
    printf '%s ABS_PORT must be a positive integer in 1..65535 (got: %s)\n' \
      "$(color_in_red "ERROR:")" "$ABS_PORT" >&2
    [ "$enforcement_mode" = "exit" ] && exit 1
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Description: Validates ABS_HOST and ABS_HOSTNAME as hostnames or IPs.
# Inputs:      $1 - mode; globals: ABS_HOST, ABS_HOSTNAME
# Outputs:     stderr: error on failure
#              return: failure count
#              exit: 1 if invalid and mode == "exit"
# Called by:   validate_runtime_config_and_print_errors
# -----------------------------------------------------------------------------
validate_host_and_hostname_and_print_errors() {
  enforcement_mode="$1"
  failure_count_local=0
  if [ -n "$ABS_HOST" ]; then
    if ! is_valid_hostname_or_ip "$ABS_HOST"; then
      printf '%s ABS_HOST is not a valid hostname or IP (got: %s)\n' \
        "$(color_in_red "ERROR:")" "$ABS_HOST" >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      failure_count_local=$((failure_count_local + 1))
    fi
  fi
  if [ -n "$ABS_HOSTNAME" ]; then
    if ! is_valid_hostname_or_ip "$ABS_HOSTNAME"; then
      printf '%s ABS_HOSTNAME is not a valid hostname or IP (got: %s)\n' \
        "$(color_in_red "ERROR:")" "$ABS_HOSTNAME" >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      failure_count_local=$((failure_count_local + 1))
    fi
  fi
  return "$failure_count_local"
}

# -----------------------------------------------------------------------------
# Description: Validates boolean-shaped env vars.
# Inputs:      $1 - mode
# Outputs:     stderr: errors
#              return: failure count
#              exit: 1 if invalid and mode == "exit"
# Called by:   validate_runtime_config_and_print_errors
# -----------------------------------------------------------------------------
validate_boolean_flags_and_print_errors() {
  enforcement_mode="$1"
  failure_count_local=0
  for boolean_var_name in \
      ABS_ALLOW_CORS ABS_DISABLE_SSRF ABS_ALLOW_IFRAME ABS_SKIP_BINARIES_CHECK; do
    eval "boolean_var_value=\${$boolean_var_name}"
    if ! is_valid_boolean_flag "$boolean_var_value"; then
      printf '%s %s must be empty, "0", "1", "true", or "false" (got: %s)\n' \
        "$(color_in_red "ERROR:")" "$boolean_var_name" "$boolean_var_value" >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      failure_count_local=$((failure_count_local + 1))
    fi
  done
  case "$ABS_AUTO_UPDATE" in
    true|TRUE|True|1|false|FALSE|False|0) : ;;
    *)
      printf '%s ABS_AUTO_UPDATE must be "true" or "false" (got: %s)\n' \
        "$(color_in_red "ERROR:")" "$ABS_AUTO_UPDATE" >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      failure_count_local=$((failure_count_local + 1))
      ;;
  esac
  return "$failure_count_local"
}

# -----------------------------------------------------------------------------
# Description: Validates absolute-path env vars (when set).
# Inputs:      $1 - mode
# Outputs:     stderr: errors
#              return: failure count
#              exit: 1 if invalid and mode == "exit"
# Called by:   validate_runtime_config_and_print_errors
# -----------------------------------------------------------------------------
validate_absolute_paths_and_print_errors() {
  enforcement_mode="$1"
  failure_count_local=0
  for absolute_path_var_name in \
      ABS_FFMPEG ABS_FFPROBE ABS_NUNICODE_PATH ABS_REACT_CLIENT_PATH; do
    eval "absolute_path_value=\${$absolute_path_var_name}"
    if [ -n "$absolute_path_value" ]; then
      if ! is_absolute_filesystem_path "$absolute_path_value"; then
        printf '%s %s must be an absolute path (got: %s)\n' \
          "$(color_in_red "ERROR:")" "$absolute_path_var_name" "$absolute_path_value" >&2
        [ "$enforcement_mode" = "exit" ] && exit 1
        failure_count_local=$((failure_count_local + 1))
      fi
    fi
  done
  return "$failure_count_local"
}

# -----------------------------------------------------------------------------
# Description: Validates ABS_LOG_ROTATE spec parseability.
# Inputs:      $1 - mode
# Outputs:     stderr: error on failure
#              return: 0 if valid, 1 otherwise
#              exit: 1 if invalid and mode == "exit"
# Called by:   validate_runtime_config_and_print_errors
# -----------------------------------------------------------------------------
validate_log_rotate_spec_and_print_errors() {
  enforcement_mode="$1"
  if ! parse_log_rotate_spec_to_size_and_age "$ABS_LOG_ROTATE" >/dev/null; then
    printf '%s ABS_LOG_ROTATE invalid (got: %s)\n' "$(color_in_red "ERROR:")" "$ABS_LOG_ROTATE" >&2
    printf '  Accepted: bare number (MB), <n>K/KB, <n>M/MB, <n>G/GB, <n>d\n' >&2
    [ "$enforcement_mode" = "exit" ] && exit 1
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Description: Runs all configuration validators. Used from check-config
#              (warn mode, aggregates failure count) and from the start
#              path (exit mode, aborts on first failure).
# Inputs:      $1 - mode ("exit" or "warn"; defaults to "exit")
# Outputs:     stderr: errors from individual validators
#              global set: VALIDATION_FAILURES (warn-mode aggregate)
#              return: VALIDATION_FAILURES count (warn mode)
#              exit: 1 if any validator fails in exit mode
# Called by:   check_config_and_print_report, main
# -----------------------------------------------------------------------------
validate_runtime_config_and_print_errors() {
  enforcement_mode="${1:-exit}"
  VALIDATION_FAILURES=0

  for js_string_var_name in \
      ABS_HOST ABS_ROOT ABS_CONFIG_PATH ABS_METADATA_PATH ABS_ROUTER_BASE_PATH \
      ABS_FFMPEG ABS_FFPROBE ABS_NUNICODE_PATH ABS_BACKUP_PATH ABS_REACT_CLIENT_PATH; do
    eval "js_string_var_value=\${$js_string_var_name}"
    if [ -n "$js_string_var_value" ] || [ "$js_string_var_name" = "ABS_ROOT" ]; then
      validate_string_safe_for_js_literal_and_print_errors \
        "$enforcement_mode" "$js_string_var_name" "$js_string_var_value" \
        || VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    fi
  done

  validate_port_and_print_errors "$enforcement_mode" \
    || VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))

  validate_host_and_hostname_and_print_errors "$enforcement_mode" \
    || VALIDATION_FAILURES=$((VALIDATION_FAILURES + $?))

  validate_boolean_flags_and_print_errors "$enforcement_mode" \
    || VALIDATION_FAILURES=$((VALIDATION_FAILURES + $?))

  validate_absolute_paths_and_print_errors "$enforcement_mode" \
    || VALIDATION_FAILURES=$((VALIDATION_FAILURES + $?))

  validate_log_rotate_spec_and_print_errors "$enforcement_mode" \
    || VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))

  case "$ABS_ROUTER_BASE_PATH" in
    ''|/*) ;;
    *)
      printf '%s ABS_ROUTER_BASE_PATH must start with "/" or be empty (got: %s)\n' \
        "$(color_in_red "ERROR:")" "$ABS_ROUTER_BASE_PATH" >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
      ;;
  esac

  case "$ABS_BUN_SQLITE_REBUILD" in
    auto|always|never) ;;
    *)
      printf '%s ABS_BUN_SQLITE_REBUILD must be one of: auto, always, never (got: %s)\n' \
        "$(color_in_red "ERROR:")" "$ABS_BUN_SQLITE_REBUILD" >&2
      [ "$enforcement_mode" = "exit" ] && exit 1
      VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
      ;;
  esac

  return "$VALIDATION_FAILURES"
}

# =============================================================================
# CONFIG REPORT
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Prints a single configuration row aligned to fixed columns.
# Inputs:      $1 - status symbol (or empty)
#              $2 - label
#              $3 - value
# Outputs:     stdout: formatted row
# Called by:   check_config_and_print_report
# -----------------------------------------------------------------------------
print_config_report_row() {
  status_symbol="$1"
  row_label="$2"
  row_value="$3"
  printf "  %-6s %-13s %s\n" "$status_symbol" "$row_label" "$row_value"
}

# -----------------------------------------------------------------------------
# Description: Validates and prints a multi-section configuration report.
# Inputs:      most ABS_* globals
# Outputs:     stdout: report
#              exit: 1 if any section fails
# Called by:   main (check-config command)
# -----------------------------------------------------------------------------
check_config_and_print_report() {
  overall_status="OK"

  printf '\n%s\n' "$(color_in_bold "========================================")"
  printf '%s\n' "$(color_in_bold "Audiobookshelf Configuration Check")"
  printf '%s\n' "$(color_in_bold "========================================")"

  # --- Paths ---
  printf '%s\n' "$(color_in_bold "Paths:")"
  if [ -d "$ABS_ROOT" ]; then
    print_config_report_row "$SYM_OK" "ABS_ROOT" "$ABS_ROOT"
  else
    print_config_report_row "$SYM_INFO" "ABS_ROOT" "$ABS_ROOT (will create)"
  fi
  if [ -d "$REPO_DIR/.git" ]; then
    print_config_report_row "$SYM_OK" "Repo" "EXISTS"
  elif [ -d "$REPO_DIR" ]; then
    print_config_report_row "$SYM_INFO" "Repo" "exists (not git, will clone)"
  else
    print_config_report_row "$SYM_INFO" "Repo" "will clone"
  fi
  if [ -d "${ABS_ROOT}/${ABS_CONFIG_PATH}" ]; then
    print_config_report_row "$SYM_OK" "Config" "EXISTS"
  else
    print_config_report_row "$SYM_INFO" "Config" "will create"
  fi
  if [ -d "${ABS_ROOT}/${ABS_METADATA_PATH}" ]; then
    print_config_report_row "$SYM_OK" "Metadata" "EXISTS"
  else
    print_config_report_row "$SYM_INFO" "Metadata" "will create"
  fi

  # --- Network ---
  printf '%s\n' "$(color_in_bold "Network:")"
  if [ -n "$ABS_HOST" ]; then
    print_config_report_row "" "Bind" "$ABS_HOST"
  else
    print_config_report_row "" "Bind" "0.0.0.0 (all interfaces)"
  fi
  if [ -n "$ABS_HOSTNAME" ]; then
    print_config_report_row "" "Hostname" "$ABS_HOSTNAME"
  else
    print_config_report_row "" "Hostname" "$(hostname 2>/dev/null || printf 'localhost') (auto)"
  fi
  print_config_report_row "" "Port" "$ABS_PORT"
  print_config_report_row "" "URL" "$(build_access_url_via_hostname)"
  ip_url_for_report="$(build_access_url_via_ip || true)"
  if [ -n "$ip_url_for_report" ]; then
    print_config_report_row "" "IP URL" "$ip_url_for_report"
  fi

  # --- Binaries ---
  printf '%s\n' "$(color_in_bold "Binaries:")"
  if [ -n "$ABS_FFMPEG" ]; then
    if [ -x "$ABS_FFMPEG" ]; then
      print_config_report_row "$SYM_OK" "FFmpeg" "$ABS_FFMPEG"
    else
      print_config_report_row "$SYM_ERR" "FFmpeg" "$ABS_FFMPEG (NOT FOUND)"
      overall_status="FAIL"
    fi
  else
    discovered_ffmpeg_path="$(command -v ffmpeg 2>/dev/null || true)"
    if [ -n "$discovered_ffmpeg_path" ]; then
      print_config_report_row "$SYM_OK" "FFmpeg" "$discovered_ffmpeg_path"
    else
      print_config_report_row "$SYM_INFO" "FFmpeg" "not in PATH (ABS will download)"
    fi
  fi
  if [ -n "$ABS_FFPROBE" ]; then
    if [ -x "$ABS_FFPROBE" ]; then
      print_config_report_row "$SYM_OK" "FFprobe" "$ABS_FFPROBE"
    else
      print_config_report_row "$SYM_ERR" "FFprobe" "$ABS_FFPROBE (NOT FOUND)"
      overall_status="FAIL"
    fi
  else
    discovered_ffprobe_path="$(command -v ffprobe 2>/dev/null || true)"
    if [ -n "$discovered_ffprobe_path" ]; then
      print_config_report_row "$SYM_OK" "FFprobe" "$discovered_ffprobe_path"
    else
      print_config_report_row "$SYM_INFO" "FFprobe" "not in PATH (ABS will download)"
    fi
  fi
  if [ -n "$ABS_SKIP_BINARIES_CHECK" ]; then
    print_config_report_row "$SYM_WARN" "SkipCheck" "enabled (set FFmpeg/FFprobe paths)"
  fi
  if [ "$OS_NAME" = "Darwin" ] && [ "$OS_ARCH" = "arm64" ]; then
    print_config_report_row "$SYM_INFO" "Platform" "Apple Silicon (using native ffmpeg)"
  fi

  # --- Runtime ---
  printf '%s\n' "$(color_in_bold "Runtime:")"
  runtime_binary_for_report=""
  runtime_source_label=""
  if [ -n "$ABS_RUNTIME" ]; then
    runtime_source_label="(env/config)"
    if runtime_binary_for_report="$(resolve_runtime_to_absolute_path "$ABS_RUNTIME")"; then
      :
    else
      print_config_report_row "$SYM_ERR" "Runtime" "$ABS_RUNTIME NOT FOUND $runtime_source_label"
      overall_status="FAIL"
      runtime_binary_for_report=""
    fi
  elif [ -f "$RUNTIME_FILE" ]; then
    runtime_source_label="(.runtime)"
    persisted_runtime_path="$(cat "$RUNTIME_FILE" 2>/dev/null || true)"
    if [ -n "$persisted_runtime_path" ] && [ -x "$persisted_runtime_path" ]; then
      runtime_binary_for_report="$persisted_runtime_path"
    elif [ -n "$persisted_runtime_path" ]; then
      print_config_report_row "$SYM_ERR" "Runtime" "$persisted_runtime_path MISSING $runtime_source_label"
      print_config_report_row "" "" "Re-run 'start' to choose a new runtime."
      overall_status="FAIL"
    fi
  fi
  if [ -n "$runtime_binary_for_report" ]; then
    runtime_version_for_report="$(get_runtime_version_string "$runtime_binary_for_report" 2>/dev/null || printf '?')"
    print_config_report_row "$SYM_OK" "Runtime" "$runtime_binary_for_report ($runtime_version_for_report) $runtime_source_label"
    if [ "$(detect_runtime_family_from_binary_name "$runtime_binary_for_report")" = "node" ]; then
      warn_if_node_version_below_minimum "$runtime_binary_for_report"
    fi
  elif [ -z "$runtime_source_label" ]; then
    print_config_report_row "$SYM_INFO" "Runtime" "not configured (will prompt on first run)"
  fi

  if command -v git >/dev/null 2>&1; then
    print_config_report_row "$SYM_OK" "git" "$(command -v git)"
  else
    print_config_report_row "$SYM_ERR" "git" "NOT FOUND (required)"
    overall_status="FAIL"
  fi

  # --- Features (only shown if explicitly configured) ---
  features_section_was_printed=0
  if [ -n "$ABS_NUNICODE_PATH" ]; then
    [ "$features_section_was_printed" -eq 0 ] && printf '%s\n' "$(color_in_bold "Features:")" && features_section_was_printed=1
    if [ -f "$ABS_NUNICODE_PATH" ]; then
      print_config_report_row "$SYM_OK" "Nunicode" "$ABS_NUNICODE_PATH"
    else
      print_config_report_row "$SYM_ERR" "Nunicode" "$ABS_NUNICODE_PATH (NOT FOUND)"
      overall_status="FAIL"
    fi
  fi
  if [ -n "$ABS_ALLOW_IFRAME" ]; then
    case "$ABS_ALLOW_IFRAME" in
      true|TRUE|True|1)
        [ "$features_section_was_printed" -eq 0 ] && printf '%s\n' "$(color_in_bold "Features:")" && features_section_was_printed=1
        print_config_report_row "$SYM_WARN" "Iframe" "enabled (security risk)"
        ;;
    esac
  fi
  if [ -n "$ABS_BACKUP_PATH" ]; then
    [ "$features_section_was_printed" -eq 0 ] && printf '%s\n' "$(color_in_bold "Features:")" && features_section_was_printed=1
    backup_directory_for_report="${ABS_ROOT}/${ABS_BACKUP_PATH}"
    if [ -d "$backup_directory_for_report" ]; then
      print_config_report_row "$SYM_OK" "Backup" "$backup_directory_for_report"
    else
      print_config_report_row "$SYM_INFO" "Backup" "$backup_directory_for_report (will create)"
    fi
  fi

  # --- Additional ABS config ---
  printf '%s\n' "$(color_in_bold "ABS config:")"
  if [ -z "$ABS_ROUTER_BASE_PATH" ]; then
    print_config_report_row "" "Base path" "(root /)"
  else
    print_config_report_row "" "Base path" "$ABS_ROUTER_BASE_PATH"
  fi
  if [ -n "$ABS_REACT_CLIENT_PATH" ]; then
    if [ -d "$ABS_REACT_CLIENT_PATH" ]; then
      print_config_report_row "$SYM_OK"  "ReactClient" "$ABS_REACT_CLIENT_PATH"
    else
      print_config_report_row "$SYM_ERR" "ReactClient" "$ABS_REACT_CLIENT_PATH (NOT FOUND)"
      overall_status="FAIL"
    fi
  fi
  case "$ABS_ALLOW_CORS" in
    1|true|TRUE|True) print_config_report_row "$SYM_WARN" "CORS" "enabled" ;;
  esac
  if [ -n "$ABS_SSRF_WHITELIST" ]; then
    print_config_report_row "$SYM_INFO" "SSRF whitelist" "$ABS_SSRF_WHITELIST"
  fi
  case "$ABS_DISABLE_SSRF" in
    1|true|TRUE|True) print_config_report_row "$SYM_WARN" "SSRF filter" "DISABLED (security risk)" ;;
  esac
  if [ -n "$ABS_JWT_SECRET" ]; then
    secret_length="${#ABS_JWT_SECRET}"
    if [ "$secret_length" -lt "$JWT_SECRET_MIN_LENGTH" ]; then
      print_config_report_row "$SYM_WARN" "JWT secret" "set ($secret_length chars; >=${JWT_SECRET_MIN_LENGTH} recommended)"
    else
      print_config_report_row "$SYM_OK"   "JWT secret" "set ($secret_length chars)"
    fi
  fi

  # --- Update behavior ---
  printf '%s\n' "$(color_in_bold "Updates:")"
  case "$ABS_AUTO_UPDATE" in
    true|TRUE|True|1)  print_config_report_row "" "Auto-update" "ON (every start/restart pulls upstream)" ;;
    *)                 print_config_report_row "" "Auto-update" "OFF (run 'restart --update' to apply)" ;;
  esac

  # --- Logs ---
  printf '%s\n' "$(color_in_bold "Logs:")"
  if [ -f "$LOG_FILE" ]; then
    current_log_size="$(get_log_file_size_in_bytes)"
    print_config_report_row "" "Log file" "$LOG_FILE ($current_log_size bytes)"
  else
    print_config_report_row "" "Log file" "$LOG_FILE (not yet created)"
  fi
  print_config_report_row "" "Rotate" "$ABS_LOG_ROTATE"

  # --- Autostart ---
  printf '%s\n' "$(color_in_bold "Autostart:")"
  detected_service="$(detect_installed_autostart_service)"
  case "$detected_service" in
    launchd:*)  print_config_report_row "$SYM_OK"   "Service" "launchd (${LAUNCHD_LABEL})" ;;
    systemd:*)  print_config_report_row "$SYM_OK"   "Service" "systemd user unit (${SYSTEMD_UNIT})" ;;
    crontab)    print_config_report_row "$SYM_OK"   "Service" "crontab @reboot" ;;
    *)          print_config_report_row "$SYM_INFO" "Service" "not installed (./$SCRIPT_NAME install-service)" ;;
  esac

  # --- Validation ---
  printf '%s\n' "$(color_in_bold "Validation:")"
  if validate_runtime_config_and_print_errors "warn"; then
    print_config_report_row "$SYM_OK" "Values" "all clean"
  else
    print_config_report_row "$SYM_ERR" "Values" "$VALIDATION_FAILURES issue(s) above"
    overall_status="FAIL"
  fi

  # --- Summary ---
  printf '%s\n' "$(color_in_bold "========================================")"
  if [ "$overall_status" = "OK" ]; then
    printf '%s %s - All good!\n' "$SYM_OK" "$(color_in_bold "PASSED")"
  else
    printf '%s %s - Fix issues above.\n' "$SYM_ERR" "$(color_in_bold "FAILED")"
    exit 1
  fi
  printf '%s\n' "$(color_in_bold "========================================")"
}

# =============================================================================
# UPSTREAM UPDATE CHECK
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Compares local HEAD with origin/<branch> and prints an update
#              banner if remote is ahead. Does not perform the update.
# Inputs:      globals: REPO_DIR, SCRIPT_NAME
# Outputs:     stdout: status / banner
# Called by:   main (check-update command), clone_or_update_repo_and_print_progress
# -----------------------------------------------------------------------------
check_upstream_update_and_print_report() {
  [ -d "$REPO_DIR/.git" ] || return 0
  printf 'Checking for upstream updates...\n'
  current_branch="$(cd "$REPO_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'master')"
  local_head_sha="$(cd "$REPO_DIR" && git rev-parse HEAD 2>/dev/null || printf '')"
  remote_head_sha="$(cd "$REPO_DIR" && git rev-parse "origin/${current_branch}" 2>/dev/null || printf '')"
  if [ -n "$local_head_sha" ] && [ -n "$remote_head_sha" ] && [ "$local_head_sha" != "$remote_head_sha" ]; then
    printf '\n%s\n' "$(color_in_bold "************************************************************")"
    printf '%s\n\n' "$(color_in_bold "UPSTREAM UPDATE AVAILABLE!")"
    local_commit_summary="$(cd "$REPO_DIR" && git log --oneline -1 HEAD 2>/dev/null || printf 'unknown')"
    remote_commit_summary="$(cd "$REPO_DIR" && git log --oneline -1 "origin/${current_branch}" 2>/dev/null || printf 'unknown')"
    printf 'Local:  %s\n' "$local_commit_summary"
    printf 'Remote: %s\n' "$remote_commit_summary"
    printf '\n'
    printf "Run './%s restart' to update and restart.\n" "$SCRIPT_NAME"
    printf '%s\n\n' "$(color_in_bold "************************************************************")"
  else
    printf '%s Up to date with upstream.\n' "$SYM_OK"
  fi
}

# =============================================================================
# HELP / USAGE
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Prints one help line with a command/flag column and a
#              description column aligned to a fixed width.
# Inputs:      $1 - command/flag (may contain ANSI sequences)
#              $2 - description
# Outputs:     stdout: formatted line
# Called by:   print_help_screen
# -----------------------------------------------------------------------------
print_help_command_line() (
  command_column_width=18
  command_text="$1"
  description_text="$2"
  visible_command_text="$(strip_ansi_escape_sequences "$command_text")"
  visible_length="${#visible_command_text}"
  padding_amount=$((command_column_width - visible_length))
  printf '  %s' "$command_text"
  padding_index=0
  while [ "$padding_index" -lt "$padding_amount" ]; do
    printf ' '
    padding_index=$((padding_index + 1))
  done
  printf '%s\n' "$description_text"
)

# -----------------------------------------------------------------------------
# Description: Prints the full help screen.
# Inputs:      globals: SCRIPT_NAME, ABS_RUN_VERSION, ABS_AUTO_UPDATE
# Outputs:     stdout: help text
# Called by:   main
# -----------------------------------------------------------------------------
print_help_screen() {
  printf '\n%s\n\n' "$(color_in_bold "$(color_in_blue "Audiobookshelf Runner") v${ABS_RUN_VERSION}")"
  printf 'Run Audiobookshelf server with Node.js or Bun.\n\n'
  printf '%s\n' "$(color_in_bold "$(color_in_green "Usage:")")"
  printf '  %s [COMMAND] [FLAGS]\n\n' "$SCRIPT_NAME"
  printf '%s\n' "$(color_in_bold "$(color_in_green "Commands:")")"
  print_help_command_line "$(color_in_yellow "start")"             "Start as daemon $(color_in_bold "(default)")"
  print_help_command_line "$(color_in_yellow "foreground")"        "Run in terminal with auto-reload"
  print_help_command_line "$(color_in_yellow "stop")"              "Stop the running daemon"
  print_help_command_line "$(color_in_yellow "restart")"           "Stop then start the daemon"
  print_help_command_line "$(color_in_yellow "status")"            "Check if daemon is running"
  print_help_command_line "$(color_in_yellow "logs")"              "View daemon logs (tail -f)"
  print_help_command_line "$(color_in_yellow "check-update")"      "Check if upstream update is available"
  print_help_command_line "$(color_in_yellow "check-config")"      "Validate configuration and print settings"
  print_help_command_line "$(color_in_yellow "install-service")"   "Install autostart service"
  print_help_command_line "$(color_in_yellow "uninstall-service")" "Remove autostart service"
  print_help_command_line "$(color_in_yellow "init-config")"       "Write a sample .env file"
  print_help_command_line "$(color_in_yellow "rebuild-sqlite")"    "Force a rebuild of sqlite3 native bindings (Bun)"
  print_help_command_line "$(color_in_yellow "version")"           "Print version"
  print_help_command_line "$(color_in_yellow "help")"              "Show this help message"
  printf '\n'
  printf '%s\n' "$(color_in_bold "$(color_in_green "Mode flags:")")"
  print_help_command_line "$(color_in_yellow "--dev")"             "Run in development mode"
  print_help_command_line "$(color_in_yellow "--prod")"            "Run in production mode $(color_in_bold "(default)")"
  printf '\n'
  printf '%s\n' "$(color_in_bold "$(color_in_green "Update flags:")")"
  case "$ABS_AUTO_UPDATE" in
    true|TRUE|True|1)
      print_help_command_line "$(color_in_yellow "--no-update")" "Skip pulling upstream changes (default: update on start)"
      ;;
    *)
      print_help_command_line "$(color_in_yellow "--update")"    "Pull upstream changes before start (default: no update)"
      ;;
  esac
  printf '\n'
  printf '%s\n' "$(color_in_bold "$(color_in_green "init-config flags:")")"
  print_help_command_line "$(color_in_yellow "--home")"            "Write ~/.env_abs instead of \$ABS_ROOT/.env"
  printf '\n'
  printf '%s\n' "$(color_in_bold "$(color_in_green "Debug flags:")")"
  print_help_command_line "$(color_in_yellow "--debug")"           "Enable shell xtrace (same as ABS_DEBUG=1)"
  printf '\n'
  printf '%s\n' "$(color_in_bold "$(color_in_green "Configuration:")")"
  printf '  Sources, highest priority first:\n'
  printf '    1. Environment variables (e.g., ABS_PORT=8080 ./%s)\n' "$SCRIPT_NAME"
  printf '    2. ~/.env_abs %s\n' "$(color_in_bold "(user-global)")"
  printf '    3. .env next to this script %s\n' "$(color_in_bold "(directory-local)")"
  printf '    4. Hardcoded defaults in this script\n\n'
}

# =============================================================================
# PID FILE / PROCESS LIVENESS
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Reads the daemon PID from $PID_FILE (empty if absent).
# Inputs:      global: PID_FILE
# Outputs:     stdout: PID or empty
# Called by:   stop/restart, main (status), warn_if_port_is_in_use_by_other_process
# -----------------------------------------------------------------------------
read_daemon_pid_from_file() (
  if [ -f "$PID_FILE" ]; then
    cat "$PID_FILE" 2>/dev/null || true
  fi
)

# -----------------------------------------------------------------------------
# Description: Tests whether a PID is alive AND its command name is "node"
#              or "bun" (avoids false positives from PID recycling).
# Inputs:      $1 - PID to check
# Outputs:     return: 0 if alive and a runtime; 1 otherwise
# Called by:   main, restart_audiobookshelf_daemon_or_skip,
#              stop_audiobookshelf_daemon_and_print_result,
#              start_audiobookshelf_daemon_and_print_result
# -----------------------------------------------------------------------------
pid_is_our_running_daemon() (
  candidate_pid="$1"
  [ -n "$candidate_pid" ] || return 1
  is_positive_integer "$candidate_pid" || return 1
  kill -0 "$candidate_pid" 2>/dev/null || return 1

  # First check: process is a node or bun process. This is the fast path
  # and catches the common case.
  process_command_name="$(ps -p "$candidate_pid" -o comm= 2>/dev/null || true)"
  case "$(basename "$process_command_name")" in
    node|bun) ;;
    *) return 1 ;;
  esac

  # Second check: the full command line should reference our REPO_DIR.
  # This guards against PID reuse - the kernel may have assigned this PID
  # to an unrelated node or bun process after our daemon exited. Without
  # this check, status/stop would act on the wrong process.
  #
  # `ps -o args=` is widely portable (POSIX), and we use grep -F (fixed
  # string) to avoid any regex interpretation of REPO_DIR's path.
  process_command_line="$(ps -p "$candidate_pid" -o args= 2>/dev/null || true)"
  case "$process_command_line" in
    *"$REPO_DIR"*) return 0 ;;
    *)
      # Some BSDs truncate `ps -o args=` output at a small fixed width
      # (e.g. COMMAND_MAX). If the full path isn't visible, fall back to
      # accepting the node/bun match alone rather than producing a false
      # negative. Users with multiple ABS instances on truncating
      # platforms get a less-precise check, which is acceptable.
      if [ ${#process_command_line} -lt 40 ]; then
        return 0
      fi
      return 1
      ;;
  esac
)

# -----------------------------------------------------------------------------
# Description: Sends SIGTERM and waits up to GRACEFUL_STOP_TIMEOUT_SECONDS
#              for exit. Escalates to SIGKILL on timeout.
# Inputs:      $1 - PID
#              global: GRACEFUL_STOP_TIMEOUT_SECONDS
# Outputs:     side effect: signals process
#              stdout: warning if SIGKILL was needed
# Called by:   stop_audiobookshelf_daemon_and_print_result,
#              restart_audiobookshelf_daemon_or_skip, main
# -----------------------------------------------------------------------------
gracefully_stop_pid_with_sigkill_fallback() {
  pid_to_stop="$1"
  [ -n "$pid_to_stop" ] || return 0

  # Defer INT/TERM during the stop window. Without this, a Ctrl+C in
  # the middle of `sleep 1` would fire the script's INT trap and exit
  # immediately, after we've already sent SIGTERM but before we've had
  # a chance to send SIGKILL on timeout. That leaves the daemon in an
  # indeterminate state and a stale PID file. We restore the original
  # traps before returning.
  trap '' INT TERM

  kill "$pid_to_stop" 2>/dev/null || true
  wait_seconds_elapsed=0
  while [ "$wait_seconds_elapsed" -lt "$GRACEFUL_STOP_TIMEOUT_SECONDS" ]; do
    if ! kill -0 "$pid_to_stop" 2>/dev/null; then
      trap 'exit 130' INT
      trap 'exit 143' TERM
      return 0
    fi
    sleep 1
    wait_seconds_elapsed=$((wait_seconds_elapsed + 1))
  done
  printf '%s Process %s did not stop gracefully; sending SIGKILL.\n' "$SYM_WARN" "$pid_to_stop"
  kill -9 "$pid_to_stop" 2>/dev/null || true

  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# =============================================================================
# PORT CONFLICT CHECK
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Warns if ABS_PORT is in use by a process other than our daemon.
# Inputs:      globals: ABS_PORT, SCRIPT_NAME, PID_FILE
# Outputs:     stdout: warning on conflict
# Called by:   main (just before launch)
# -----------------------------------------------------------------------------
warn_if_port_is_in_use_by_other_process() {
  pids_listening_on_port=""
  our_daemon_pid="$(read_daemon_pid_from_file)"

  # Extract PIDs only. `lsof -ti` gives one PID per line. `ss`/`netstat`
  # output is a free-form line with non-PID fields, so we extract the
  # numeric PID from the structured fields each tool emits:
  #   - ss -tlnp:       users:(("name",pid=12345,fd=20))
  #   - netstat -tlnp:  ... LISTEN  12345/process_name
  # Without explicit extraction, the for-loop below would iterate over
  # arbitrary whitespace-separated tokens and falsely flag every line
  # as a conflict.
  #
  # awk is used rather than `grep -o` because grep's -o flag is a
  # GNU/BSD extension, not POSIX. awk's match()/substr() are POSIX.
  if command -v lsof >/dev/null 2>&1; then
    pids_listening_on_port="$(lsof -ti TCP:"$ABS_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  elif command -v ss >/dev/null 2>&1; then
    pids_listening_on_port="$(ss -tlnp 2>/dev/null \
      | awk -v port=":$ABS_PORT " '
          index($0, port) > 0 {
            n = split($0, parts, "pid=")
            for (i = 2; i <= n; i++) {
              if (match(parts[i], /^[0-9]+/)) {
                print substr(parts[i], RSTART, RLENGTH)
              }
            }
          }' \
      | sort -u || true)"
  elif command -v netstat >/dev/null 2>&1; then
    # GNU netstat shows "12345/node"; BSD netstat does not show PIDs at all.
    pids_listening_on_port="$(netstat -tlnp 2>/dev/null \
      | awk -v port=":$ABS_PORT " '
          index($0, port) > 0 {
            for (i = 1; i <= NF; i++) {
              if (match($i, /^[0-9]+\//)) {
                print substr($i, RSTART, RLENGTH - 1)
              }
            }
          }' \
      | sort -u || true)"
  fi

  [ -n "$pids_listening_on_port" ] || return 0

  if [ -n "$our_daemon_pid" ]; then
    other_pids_count=0
    for one_listening_pid in $pids_listening_on_port; do
      if [ "$one_listening_pid" != "$our_daemon_pid" ]; then
        other_pids_count=$((other_pids_count + 1))
      fi
    done
    [ "$other_pids_count" -eq 0 ] && return 0
  fi

  printf '\n%s\n\n' "$(color_in_bold "$(color_in_red "WARNING: Port $ABS_PORT is already in use!")")"
  printf 'Another process is listening on port %s.\n' "$ABS_PORT"
  printf 'ABS may fail to start or conflict with the existing service.\n\n'
  printf 'You can:\n'
  printf '  1. Stop the other process first\n'
  printf '  2. Set a different port: ABS_PORT=8080 ./%s\n\n' "$SCRIPT_NAME"
}

# =============================================================================
# AUTOSTART SERVICE INSTALL / UNINSTALL
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Installs the platform-appropriate autostart service.
# Inputs:      globals: OS_NAME, RUNTIME_BIN, ABS_RUNTIME, ABS_AUTO_UPDATE
# Outputs:     side effect: writes service file
#              stdout: status
#              exit: 1 if service already installed
# Called by:   main (install-service)
# -----------------------------------------------------------------------------
install_autostart_service_and_print_result() {
  already_installed_service="$(detect_installed_autostart_service)"
  if [ -n "$already_installed_service" ]; then
    printf '%s An autostart service is already installed.\n' "$SYM_WARN"
    case "$already_installed_service" in
      launchd:*) printf '  launchd: %s\n' "${already_installed_service#launchd:}" ;;
      systemd:*) printf '  systemd: %s\n' "${already_installed_service#systemd:}" ;;
      crontab)   printf '  crontab: ~/%s\n' "$GENERIC_WRAPPER_NAME" ;;
    esac
    printf '\nTo replace it: ./%s uninstall-service && ./%s install-service\n' \
      "$SCRIPT_NAME" "$SCRIPT_NAME"
    exit 1
  fi

  ensure_runtime_selected_and_persisted

  case "$OS_NAME" in
    Darwin)
      install_launchd_service_and_print_result
      ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1 && \
         { [ -d "$HOME/.config/systemd/user" ] || systemctl --user status >/dev/null 2>&1; }; then
        install_systemd_user_service_and_print_result
      else
        install_generic_crontab_service_and_print_result
      fi
      ;;
    *)
      install_generic_crontab_service_and_print_result
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Description: Dispatches autostart-service removal.
# Inputs:      none
# Outputs:     stdout: status
# Called by:   main (uninstall-service)
# -----------------------------------------------------------------------------
uninstall_autostart_service_and_print_result() {
  service_to_remove="$(detect_installed_autostart_service)"
  case "$service_to_remove" in
    launchd:*) uninstall_launchd_service_and_print_result ;;
    systemd:*) uninstall_systemd_user_service_and_print_result ;;
    crontab)   uninstall_generic_crontab_service_and_print_result ;;
    *)         printf 'No autostart service found.\n' ;;
  esac
}

# -----------------------------------------------------------------------------
# Description: Writes a launchd LaunchAgent plist and loads it.
# Inputs:      env: HOME; globals: LAUNCHD_LABEL, SCRIPT_PATH, ABS_ROOT,
#                                  RUNTIME_BIN, ABS_RUNTIME, ABS_AUTO_UPDATE
# Outputs:     side effect: writes plist, loads via launchctl
#              stdout: status
# Called by:   install_autostart_service_and_print_result
# -----------------------------------------------------------------------------
install_launchd_service_and_print_result() {
  plist_destination_path="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  pinned_runtime_path="${ABS_RUNTIME:-$RUNTIME_BIN}"
  pinned_update_flag="${ABS_AUTO_UPDATE:-true}"
  printf 'Installing launchd service for macOS...\n'
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist_destination_path" << EndOfPlist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>${SCRIPT_PATH}</string>
    <string>start</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${ABS_ROOT}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${ABS_ROOT}/audiobookshelf-daemon.log</string>
  <key>StandardErrorPath</key>
  <string>${ABS_ROOT}/audiobookshelf-daemon.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${HOME}/.bun/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>ABS_RUNTIME</key>
    <string>${pinned_runtime_path}</string>
    <key>ABS_AUTO_UPDATE</key>
    <string>${pinned_update_flag}</string>
  </dict>
</dict>
</plist>
EndOfPlist
  launchctl unload "$plist_destination_path" 2>/dev/null || true
  launchctl load "$plist_destination_path" 2>/dev/null || true
  printf '%s Installed launchd service.\n' "$SYM_OK"
  printf '  Plist: %s\n' "$plist_destination_path"
  printf '  Runtime pinned to: %s\n' "$pinned_runtime_path"
  printf '  Auto-update: %s\n' "$pinned_update_flag"
}

# -----------------------------------------------------------------------------
# Description: Unloads and removes the launchd plist.
# Inputs:      env: HOME; global: LAUNCHD_LABEL
# Outputs:     side effect: removes plist
#              stdout: status
# Called by:   uninstall_autostart_service_and_print_result
# -----------------------------------------------------------------------------
uninstall_launchd_service_and_print_result() {
  plist_destination_path="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  if [ -f "$plist_destination_path" ]; then
    launchctl unload "$plist_destination_path" 2>/dev/null || true
    rm -f "$plist_destination_path"
    printf '%s Removed launchd service.\n' "$SYM_OK"
  else
    printf 'No launchd service found at %s\n' "$plist_destination_path"
  fi
}

# -----------------------------------------------------------------------------
# Description: Writes a systemd user unit, reloads, enables, starts.
# Inputs:      env: HOME; globals: SYSTEMD_UNIT, ABS_ROOT, SCRIPT_PATH,
#                                  RUNTIME_BIN, ABS_RUNTIME, ABS_AUTO_UPDATE
# Outputs:     side effect: writes unit, reloads/enables/starts
#              stdout: status
# Called by:   install_autostart_service_and_print_result
# -----------------------------------------------------------------------------
install_systemd_user_service_and_print_result() {
  systemd_user_directory="$HOME/.config/systemd/user"
  pinned_runtime_path="${ABS_RUNTIME:-$RUNTIME_BIN}"
  pinned_update_flag="${ABS_AUTO_UPDATE:-true}"
  printf 'Installing systemd user service...\n'
  mkdir -p "$systemd_user_directory"
  cat > "$systemd_user_directory/$SYSTEMD_UNIT" << EndOfService
[Unit]
Description=Audiobookshelf Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${ABS_ROOT}
ExecStart=/bin/sh "${SCRIPT_PATH}" start
Restart=on-failure
Environment="PATH=${HOME}/.bun/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
Environment="HOME=${HOME}"
Environment="ABS_RUNTIME=${pinned_runtime_path}"
Environment="ABS_AUTO_UPDATE=${pinned_update_flag}"

[Install]
WantedBy=default.target
EndOfService
  systemctl --user daemon-reload
  systemctl --user enable "$SYSTEMD_UNIT"
  systemctl --user start "$SYSTEMD_UNIT"
  printf '%s Installed systemd user service.\n' "$SYM_OK"
  printf '  Unit: %s\n' "$systemd_user_directory/$SYSTEMD_UNIT"
  printf '  Runtime pinned to: %s\n' "$pinned_runtime_path"
  printf '  Auto-update: %s\n' "$pinned_update_flag"
  printf '  Manage with: systemctl --user {start|stop|status} audiobookshelf\n'
  # systemd user units only run when the user is logged in. To make the
  # service start at boot (before any interactive login) and survive
  # logout, lingering must be enabled. Mention it here so the user is
  # not surprised when the service disappears after they ssh out.
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
      printf '\n%s For boot-time start (not just login), enable lingering:\n' "$SYM_INFO"
      printf '  sudo loginctl enable-linger %s\n' "$USER"
      printf '  Without this, the service only runs while you are logged in.\n'
    fi
  fi
}

# -----------------------------------------------------------------------------
# Description: Stops, disables, and removes the systemd user unit.
# Inputs:      env: HOME; global: SYSTEMD_UNIT
# Outputs:     side effect: removes unit
#              stdout: status
# Called by:   uninstall_autostart_service_and_print_result
# -----------------------------------------------------------------------------
uninstall_systemd_user_service_and_print_result() {
  systemd_user_directory="$HOME/.config/systemd/user"
  if [ -f "$systemd_user_directory/$SYSTEMD_UNIT" ]; then
    systemctl --user stop    "$SYSTEMD_UNIT" 2>/dev/null || true
    systemctl --user disable "$SYSTEMD_UNIT" 2>/dev/null || true
    rm -f "$systemd_user_directory/$SYSTEMD_UNIT"
    systemctl --user daemon-reload
    printf '%s Removed systemd user service.\n' "$SYM_OK"
  else
    printf 'No systemd service found.\n'
  fi
}

# -----------------------------------------------------------------------------
# Description: Writes a POSIX wrapper and registers @reboot in crontab.
# Inputs:      env: HOME; globals: GENERIC_WRAPPER_NAME, CRONTAB_MARKER,
#                                  SCRIPT_PATH, ABS_ROOT, RUNTIME_BIN,
#                                  ABS_RUNTIME, ABS_AUTO_UPDATE
# Outputs:     side effect: writes wrapper, updates crontab
#              stdout: status
# Called by:   install_autostart_service_and_print_result
# -----------------------------------------------------------------------------
install_generic_crontab_service_and_print_result() {
  wrapper_destination_path="$HOME/$GENERIC_WRAPPER_NAME"
  pinned_runtime_path="${ABS_RUNTIME:-$RUNTIME_BIN}"
  pinned_update_flag="${ABS_AUTO_UPDATE:-true}"
  printf 'Installing generic autostart wrapper for %s...\n' "$OS_NAME"
  cat > "$wrapper_destination_path" << EndOfWrapper
#!/bin/sh
# Audiobookshelf autostart wrapper (generated by ${SCRIPT_NAME})
export PATH="${HOME}/.bun/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME}"
export ABS_RUNTIME="${pinned_runtime_path}"
export ABS_AUTO_UPDATE="${pinned_update_flag}"
cd "${ABS_ROOT}" || exit 1
nohup "${SCRIPT_PATH}" start > "${ABS_ROOT}/audiobookshelf-daemon.log" 2>&1 < /dev/null &
EndOfWrapper
  chmod +x "$wrapper_destination_path"

  if command -v crontab >/dev/null 2>&1; then
    crontab_temporary_file="$(mktemp "$ABS_ROOT/.crontab.tmp.XXXXXX")" || {
      printf '%s Cannot create temp file in %s for crontab edit.\n' \
        "$SYM_ERR" "$ABS_ROOT" >&2
      return 1
    }
    crontab -l 2>/dev/null | grep -v "$CRONTAB_MARKER" > "$crontab_temporary_file" 2>/dev/null || true
    printf '@reboot %s  # %s\n' "$wrapper_destination_path" "$CRONTAB_MARKER" >> "$crontab_temporary_file"
    crontab "$crontab_temporary_file"
    rm -f "$crontab_temporary_file"
    printf '%s Added @reboot entry to crontab.\n' "$SYM_OK"
  else
    printf '%s crontab not available. Manual startup required.\n' "$SYM_WARN"
    printf '  Wrapper script: %s\n' "$wrapper_destination_path"
    printf '  Add to your system autostart mechanism manually.\n'
  fi
  printf '  Runtime pinned to: %s\n' "$pinned_runtime_path"
  printf '  Auto-update: %s\n' "$pinned_update_flag"
}

# -----------------------------------------------------------------------------
# Description: Removes the crontab @reboot entry and wrapper script. Replaces
#              the crontab with content stripped of our line, installing an
#              empty crontab if our line was the only entry.
# Inputs:      env: HOME; globals: GENERIC_WRAPPER_NAME, CRONTAB_MARKER, ABS_ROOT
# Outputs:     side effect: removes wrapper, updates crontab
#              stdout: status
# Called by:   uninstall_autostart_service_and_print_result
# -----------------------------------------------------------------------------
uninstall_generic_crontab_service_and_print_result() {
  wrapper_destination_path="$HOME/$GENERIC_WRAPPER_NAME"
  if command -v crontab >/dev/null 2>&1; then
    crontab_temporary_file="$(mktemp "$ABS_ROOT/.crontab.tmp.XXXXXX")" || {
      printf '%s Cannot create temp file in %s for crontab edit.\n' \
        "$SYM_ERR" "$ABS_ROOT" >&2
      return 1
    }
    crontab -l 2>/dev/null | grep -v "$CRONTAB_MARKER" > "$crontab_temporary_file" 2>/dev/null || true
    if [ -s "$crontab_temporary_file" ]; then
      crontab "$crontab_temporary_file"
    else
      : | crontab -
    fi
    rm -f "$crontab_temporary_file"
  fi
  if [ -f "$wrapper_destination_path" ]; then
    rm -f "$wrapper_destination_path"
    printf '%s Removed generic autostart wrapper.\n' "$SYM_OK"
  else
    printf 'No generic autostart service found.\n'
  fi
}

# =============================================================================
# FIRST-RUN NUDGE
# =============================================================================

# -----------------------------------------------------------------------------
# Description: On the first interactive `start` (no repo cloned yet),
#              suggests foreground mode for visibility.
# Inputs:      globals: REPO_DIR, CMD, RUNTIME_BIN, RUNTIME_FAMILY, SCRIPT_NAME
# Outputs:     stdout: prompt
#              exit: 0 if user declines
# Called by:   main
# -----------------------------------------------------------------------------
prompt_first_run_nudge_and_maybe_exit() {
  [ -t 0 ] || return 0
  [ ! -d "$REPO_DIR/.git" ] || return 0
  [ "$CMD" = "start" ] || return 0

  printf '\n%s\n' "$(color_in_bold "First run.")"
  printf 'Initial setup takes 2-3 minutes (clone, install deps, build client).\n'
  printf 'Recommended for first run: %s (shows progress in your terminal).\n\n' \
    "$(color_in_yellow "./$SCRIPT_NAME foreground")"
  printf 'Continue with daemon? [y/N]: '
  read -r first_run_answer || exit 0
  case "$first_run_answer" in
    y|Y|yes|YES) printf '\n' ;;
    *)
      printf '\nExiting. Re-run with: ./%s foreground\n' "$SCRIPT_NAME"
      exit 0
      ;;
  esac
}

# =============================================================================
# REPO CLONE / UPDATE
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Clones the ABS repo if absent, or pulls if present and updates
#              are enabled. Resets to remote head to discard local changes
#              (intentional - this is a runner, not a dev checkout).
# Inputs:      globals: REPO_DIR, ABS_REPO_URL, DO_UPDATE
# Outputs:     side effect: filesystem changes
#              stdout: progress
# Called by:   main (start / foreground / restart)
# -----------------------------------------------------------------------------
clone_or_update_repo_and_print_progress() {
  if [ -d "$REPO_DIR/.git" ]; then
    if [ "$DO_UPDATE" = "true" ]; then
      # Check for local modifications before destroying them. `git reset
      # --hard` + `git clean -fd` is appropriate for the runner usecase
      # (the script promises to be a runner, not a dev checkout) but
      # silently wiping a user's work is hostile if they tried to patch
      # ABS in place.
      local_changes="$(cd "$REPO_DIR" && git status --porcelain 2>/dev/null || true)"
      if [ -n "$local_changes" ]; then
        if [ -t 0 ] && [ -t 2 ]; then
          # Interactive: ask before destroying.
          printf '\n%s\n' "$(color_in_bold "$(color_in_yellow "Local modifications detected in $REPO_DIR:")")" >&2
          printf '%s\n' "$local_changes" | head -n 10 >&2
          local_changes_total="$(printf '%s\n' "$local_changes" | wc -l | awk '{print $1}')"
          [ "$local_changes_total" -gt 10 ] && \
            printf '  ...and %s more\n' "$((local_changes_total - 10))" >&2
          printf '\nUpdating will discard these changes (git reset --hard).\n' >&2
          printf 'Continue? [y/N]: ' >&2
          read -r confirm_destructive_update || exit 1
          case "$confirm_destructive_update" in
            y|Y|yes|YES) ;;
            *)
              printf '%s Skipping update; keeping local changes.\n' "$SYM_INFO"
              printf '  To update later: commit/stash your changes, then re-run.\n'
              printf '  Or: set ABS_AUTO_UPDATE=false to suppress this check.\n'
              return 0
              ;;
          esac
        else
          # Non-interactive (launchd, cron, systemd): skip the update
          # rather than destroy data silently. The user must explicitly
          # set ABS_AUTO_UPDATE=false (or commit their changes) to make
          # this go away.
          printf '%s Local modifications detected in %s; skipping update.\n' "$SYM_WARN" "$REPO_DIR" >&2
          printf '  Cannot prompt from non-interactive context.\n' >&2
          printf '  Commit/stash your changes, or set ABS_AUTO_UPDATE=false.\n' >&2
          return 0
        fi
      fi
      printf 'Updating audiobookshelf repository...\n'
      ( cd "$REPO_DIR" && git fetch origin )
      # Discover the upstream default branch dynamically rather than
      # hardcoding master/main. `git symbolic-ref refs/remotes/origin/HEAD`
      # returns refs/remotes/origin/<branch>; strip the prefix to get
      # just the branch name. Falls back to legacy master->main detection
      # if symbolic-ref isn't set (some older clones don't have origin/HEAD).
      upstream_default_branch="$(cd "$REPO_DIR" && \
        git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's|^origin/||' \
        || true)"
      if [ -z "$upstream_default_branch" ]; then
        # symbolic-ref unset - probe the two historical defaults
        if ( cd "$REPO_DIR" && git rev-parse --verify origin/master >/dev/null 2>&1 ); then
          upstream_default_branch="master"
        elif ( cd "$REPO_DIR" && git rev-parse --verify origin/main >/dev/null 2>&1 ); then
          upstream_default_branch="main"
        else
          printf '%s Cannot determine upstream default branch.\n' "$SYM_ERR" >&2
          printf '  Neither origin/HEAD, origin/master, nor origin/main resolves.\n' >&2
          return 1
        fi
      fi
      ( cd "$REPO_DIR" && git reset --hard "origin/$upstream_default_branch" )
      ( cd "$REPO_DIR" && git clean -fd )
      check_upstream_update_and_print_report
    else
      printf 'Skipping update (--no-update or ABS_AUTO_UPDATE=false).\n'
    fi
  elif [ -f "$REPO_DIR/index.js" ]; then
    printf 'Using existing audiobookshelf directory (manual download detected).\n'
    printf '%s Skipping git update. To enable updates, delete and clone via git.\n' "$SYM_WARN"
  else
    printf 'Cloning audiobookshelf repository...\n'
    if [ -d "$REPO_DIR" ]; then
      # The directory exists but contains neither .git nor index.js. Refuse
      # to nuke it: it may be unrelated data a user accidentally placed at
      # this path (e.g. by setting ABS_ROOT to an existing location).
      if [ -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
        printf '%s %s exists and is not a recognizable audiobookshelf checkout:\n' \
          "$(color_in_red "ERROR:")" "$REPO_DIR" >&2
        printf '  no .git directory, no index.js. Refusing to remove it.\n' >&2
        printf '  Move or remove %s manually if you want a clean clone,\n' "$REPO_DIR" >&2
        printf '  or set ABS_ROOT to a different location.\n' >&2
        exit 1
      fi
      # Empty directory: safe to remove and clone over.
      rmdir "$REPO_DIR" 2>/dev/null || true
    fi
    git clone "$ABS_REPO_URL" "$REPO_DIR"
  fi

  # Hide script-generated files from git status so they don't trigger the
  # "discard local changes?" prompt on every update.
  if [ -d "$REPO_DIR/.git" ]; then
    for generated_pattern in "/socket.io-patch.js" "/bun.lock" "/client/bun.lock"; do
      grep -qxF "$generated_pattern" "$REPO_DIR/.git/info/exclude" 2>/dev/null || \
        printf '%s\n' "$generated_pattern" >> "$REPO_DIR/.git/info/exclude"
    done
  fi
}

# =============================================================================
# DEV.JS / SOCKET.IO PATCH WRITERS
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Writes the dev.js file ABS reads at startup. Caller must be
#              in REPO_DIR. Assumes validation has already run.
# Inputs:      most ABS_* globals
# Outputs:     side effect: writes ./dev.js
# Called by:   main
# -----------------------------------------------------------------------------
write_dev_js_config_file() {
  # Quoted heredoc delimiter ('EndOfDevConfig') disables ALL shell
  # expansion inside the body. Variables are inserted exclusively via
  # printf, the same way optional fields are handled below. This is
  # defense-in-depth: even though the current validator blocks the
  # characters that could break the generated JS (single quote, double
  # quote, backslash, newline), the quoted-heredoc form is provably
  # safe by construction. A future maintainer can't accidentally break
  # the safety contract by adding an unvalidated variable to the
  # heredoc body.
  cat > dev.js << 'EndOfDevConfig'
const Path = require('path')
module.exports.config = {
EndOfDevConfig

  printf "  Host: '%s',\n"                       "$ABS_HOST"                          >> dev.js
  printf "  Port: %d,\n"                         "$ABS_PORT"                          >> dev.js
  printf "  ConfigPath: Path.resolve('%s', '%s'),\n"   "$ABS_ROOT" "$ABS_CONFIG_PATH" >> dev.js
  printf "  MetadataPath: Path.resolve('%s', '%s'),\n" "$ABS_ROOT" "$ABS_METADATA_PATH" >> dev.js

  [ -z "$ABS_FFMPEG" ]              || printf "  FFmpegPath: Path.resolve('%s'),\n"  "$ABS_FFMPEG"  >> dev.js
  [ -z "$ABS_FFPROBE" ]             || printf "  FFProbePath: Path.resolve('%s'),\n" "$ABS_FFPROBE" >> dev.js
  [ -z "$ABS_SKIP_BINARIES_CHECK" ] || printf "  SkipBinariesCheck: %s,\n" "$(normalize_boolean_to_js_literal "$ABS_SKIP_BINARIES_CHECK")" >> dev.js
  [ -z "$ABS_NUNICODE_PATH" ]       || printf "  NunicodePath: Path.resolve('%s'),\n" "$ABS_NUNICODE_PATH" >> dev.js
  [ -z "$ABS_ALLOW_IFRAME" ]        || printf "  AllowIframe: %s,\n" "$(normalize_boolean_to_js_literal "$ABS_ALLOW_IFRAME")" >> dev.js
  [ -z "$ABS_BACKUP_PATH" ]         || printf "  BackupPath: Path.resolve('%s', '%s'),\n" "$ABS_ROOT" "$ABS_BACKUP_PATH" >> dev.js
  # ABS_ROUTER_BASE_PATH is always emitted: empty value is meaningful
  # (serve at root) and must be passed through, not omitted (which would
  # cause ABS to use its internal default of /audiobookshelf).
  printf "  RouterBasePath: '%s',\n" "$ABS_ROUTER_BASE_PATH" >> dev.js
  [ -z "$ABS_REACT_CLIENT_PATH" ]   || printf "  ReactClientPath: Path.resolve('%s'),\n" "$ABS_REACT_CLIENT_PATH" >> dev.js

  cat >> dev.js << 'EndOfDevConfig'
}
EndOfDevConfig
}

# -----------------------------------------------------------------------------
# Description: Writes the Bun Socket.IO patch file. Forces websocket
#              transport because Bun's HTTP server doesn't support
#              long-polling.
# Inputs:      none (caller must be in REPO_DIR)
# Outputs:     side effect: writes ./socket.io-patch.js
# Called by:   main (only when RUNTIME_FAMILY == bun)
# -----------------------------------------------------------------------------
write_bun_socket_io_patch_file() {
  cat > socket.io-patch.js << 'EndOfPatch'
// Bun Socket.IO fixes. Intercept the Server constructor (modern Socket.IO passes
// options to new Server(), not .listen()) to inject Bun-safe engine.io options:
//   - websocket-only transport (Bun's HTTP server long-polling is unreliable)
//   - destroyUpgrade:false, which stops Bun's missing socket.bytesWritten from
//     letting engine.io's stray-upgrade cleanup kill live connections after ~1s
//     when ABS runs more than one Socket.IO server (RouterBasePath subpath).
// Runtime patch; no upstream source is modified.
const Module = require('module');
const originalRequire = Module.prototype.require;

function forceWebsocketOpts(args) {
  // Socket.IO constructor signatures:
  //   new Server(port, opts)     -> opts is 2nd arg
  //   new Server(server, opts)   -> opts is 2nd arg
  //   new Server(opts)           -> opts is 1st arg
  let optsIdx;
  if (args.length === 0) {
    args.push({});
    optsIdx = 0;
  } else if (typeof args[0] === 'number' || typeof args[0] === 'string') {
    optsIdx = 1;
  } else if (args[0] && typeof args[0].listen === 'function') {
    optsIdx = 1;
  } else {
    optsIdx = 0;
  }
  if (!args[optsIdx]) args[optsIdx] = {};
  const opts = args[optsIdx];
  opts.transports = ['websocket'];
  opts.allowUpgrades = false;
  opts.perMessageDeflate = false;
  opts.pingTimeout = 60000;
  opts.pingInterval = 30000;
  // The real Bun fix: ABS opens a second Socket.IO server when RouterBasePath is
  // set, so both engine.io instances see every upgrade. The non-matching one
  // arms engine.io's stray-upgrade cleanup (destroyUpgradeTimeout, default
  // 1000ms), which only no-ops on Node because it checks socket.bytesWritten > 0.
  // Bun doesn't track bytesWritten on upgraded sockets, so the guard is wrongly
  // true and the live connection is ended at ~1s ("transport close" loop).
  // Disabling the cleanup makes the dual-server (reverse-proxy subpath) setup
  // stable under Bun; harmless because ABS only serves known socket.io paths.
  opts.destroyUpgrade = false;
}

Module.prototype.require = function(id) {
  const mod = originalRequire.apply(this, arguments);
  if (id === 'socket.io' || id.endsWith('/socket.io')) {
    const OriginalServer = mod.Server || mod;

    function PatchedServer(...args) {
      forceWebsocketOpts(args);
      const instance = new OriginalServer(...args);
      return instance;
    }

    // Preserve prototype chain and static properties
    Object.setPrototypeOf(PatchedServer, OriginalServer);
    PatchedServer.prototype = OriginalServer.prototype;
    for (const key of Object.getOwnPropertyNames(OriginalServer)) {
      if (key !== 'length' && key !== 'name' && key !== 'prototype') {
        try {
          PatchedServer[key] = OriginalServer[key];
        } catch (_) {}
      }
    }
    Object.defineProperty(PatchedServer, 'name', { value: 'Server' });

    mod.Server = PatchedServer;
  }
  return mod;
};

const dashIdx = process.argv.indexOf('--');
if (dashIdx !== -1) {
  process.argv.splice(dashIdx, 1);
}
require('./index');
EndOfPatch
}

# =============================================================================
# DEPENDENCY INSTALL + CLIENT BUILD
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Rebuilds the npm `sqlite3` package's native binding inside
#              the ABS repo. Under Bun, the postinstall step that builds
#              `node_sqlite3.node` is sometimes skipped, which then prevents
#              ABS from loading the unicode search extension (libnusqlite3
#              is loaded via sqlite3.loadExtension()). This function fixes
#              that by running `npm rebuild sqlite3` against the existing
#              installation.
#
#              Mode controls behavior:
#                "auto"   rebuild only if the compiled .node file is missing
#                "always" rebuild on every install
#                "never"  do nothing (warn if the binding is missing)
#
#              No-op for Node runtime: `npm install` builds sqlite3 natively
#              during the normal install path, so no rebuild is needed.
# Inputs:      $1 - mode ("auto", "always", "never"); defaults to
#                   $ABS_BUN_SQLITE_REBUILD if set, else "auto"
#              globals: RUNTIME_FAMILY, REPO_DIR
# Outputs:     side effect: rebuilt sqlite3 binding
#              stdout: status
#              return: 0 on success/skip; 1 if rebuild was needed but
#                      could not run (e.g. npm missing)
# Called by:   install_dependencies_and_build_client_and_print_progress,
#              main (rebuild-sqlite command)
# -----------------------------------------------------------------------------
rebuild_sqlite3_bindings_if_needed_and_print_result() {
  rebuild_mode="${1:-${ABS_BUN_SQLITE_REBUILD:-auto}}"

  if [ "$RUNTIME_FAMILY" != "bun" ]; then
    printf '%s sqlite3 rebuild is only needed under Bun; skipping (runtime=%s).\n' \
      "$SYM_INFO" "$RUNTIME_FAMILY"
    return 0
  fi

  if [ ! -d "$REPO_DIR/node_modules/sqlite3" ]; then
    printf '%s sqlite3 not yet installed at %s/node_modules/sqlite3\n' \
      "$SYM_WARN" "$REPO_DIR"
    printf '  Run start/foreground first to install dependencies.\n'
    return 0
  fi

  sqlite3_binding_release="$REPO_DIR/node_modules/sqlite3/build/Release/node_sqlite3.node"
  sqlite3_binding_debug="$REPO_DIR/node_modules/sqlite3/build/Debug/node_sqlite3.node"

  case "$rebuild_mode" in
    never)
      printf '%s ABS_BUN_SQLITE_REBUILD=never; skipping sqlite3 rebuild.\n' "$SYM_INFO"
      if [ ! -f "$sqlite3_binding_release" ] && [ ! -f "$sqlite3_binding_debug" ]; then
        printf '%s sqlite3 native binding is missing; unicode search will fail.\n' "$SYM_WARN"
        printf '  Re-run with ABS_BUN_SQLITE_REBUILD=auto, or:\n'
        printf '    ./%s rebuild-sqlite\n' "$SCRIPT_NAME"
      fi
      return 0
      ;;
    auto)
      if [ -f "$sqlite3_binding_release" ] || [ -f "$sqlite3_binding_debug" ]; then
        return 0
      fi
      printf 'sqlite3 native binding missing; rebuilding...\n'
      ;;
    always)
      printf 'Rebuilding sqlite3 native bindings (ABS_BUN_SQLITE_REBUILD=always)...\n'
      ;;
    *)
      printf '%s Unknown ABS_BUN_SQLITE_REBUILD value: %s (expected: auto, always, never)\n' \
        "$SYM_ERR" "$rebuild_mode" >&2
      return 1
      ;;
  esac

  if ! command -v npm >/dev/null 2>&1; then
    printf '%s npm not found; cannot rebuild sqlite3.\n' "$SYM_WARN"
    printf '  Install Node.js+npm (the rebuild itself does not need to run Node),\n'
    printf '  or set ABS_BUN_SQLITE_REBUILD=never if you have manually built it.\n'
    return 1
  fi

  ( cd "$REPO_DIR" && npm rebuild sqlite3 2>&1 | tail -n 3 )

  if [ -f "$sqlite3_binding_release" ] || [ -f "$sqlite3_binding_debug" ]; then
    printf '%s sqlite3 native binding built.\n' "$SYM_OK"
    return 0
  else
    printf '%s sqlite3 native binding still missing after rebuild attempt.\n' "$SYM_ERR"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Description: Installs server + client deps and builds the Nuxt client.
#              Caller must be in REPO_DIR.
# Inputs:      globals: RUNTIME_FAMILY, RUNTIME_BIN
# Outputs:     side effect: node_modules + client build
#              stdout: progress
# Called by:   main
# -----------------------------------------------------------------------------
install_dependencies_and_build_client_and_print_progress() {
  printf 'Installing server dependencies (%s)...\n' "$RUNTIME_FAMILY"
  if [ "$RUNTIME_FAMILY" = "bun" ]; then
    "$RUNTIME_BIN" install --trust
    rebuild_sqlite3_bindings_if_needed_and_print_result || true
  else
    if ! command -v npm >/dev/null 2>&1; then
      printf '%s\n' "$(color_in_red "npm not found alongside node. Install Node.js with npm.")" >&2
      exit 1
    fi
    npm install --no-fund --no-audit
  fi

  printf 'Installing client dependencies and building...\n'
  cd client
  if [ "$RUNTIME_FAMILY" = "bun" ]; then
    "$RUNTIME_BIN" install --trust
    NODE_NO_WARNINGS=1 "$RUNTIME_BIN" run generate
  else
    npm install --no-fund --no-audit
    NODE_NO_WARNINGS=1 npm run generate
  fi
  cd ..
}

# =============================================================================
# RUNTIME ENV EXPORTS
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Exports env-only ABS variables (not written to dev.js).
# Inputs:      globals: ABS_ALLOW_CORS, ABS_SSRF_WHITELIST, ABS_DISABLE_SSRF,
#                       ABS_JWT_SECRET
# Outputs:     side effect: exports env vars
# Called by:   main
# -----------------------------------------------------------------------------
export_abs_env_only_variables_to_runtime() {
  if [ -n "$ABS_ALLOW_CORS" ];     then export ALLOW_CORS="$ABS_ALLOW_CORS"; fi
  if [ -n "$ABS_SSRF_WHITELIST" ]; then export SSRF_REQUEST_FILTER_WHITELIST="$ABS_SSRF_WHITELIST"; fi
  if [ -n "$ABS_DISABLE_SSRF" ];   then export DISABLE_SSRF_REQUEST_FILTER="$ABS_DISABLE_SSRF"; fi
  if [ -n "$ABS_JWT_SECRET" ];     then export JWT_SECRET_KEY="$ABS_JWT_SECRET"; fi
}

# =============================================================================
# RUN: FOREGROUND OR DAEMON
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Runs ABS in the foreground with file-watch. Replaces the
#              current process via exec.
# Inputs:      globals: RUNTIME_FAMILY, RUNTIME_BIN, MODE_ARG
# Outputs:     replaces process
# Called by:   main (foreground command)
# -----------------------------------------------------------------------------
run_audiobookshelf_in_foreground() {
  if [ "$DEV_MODE" = "true" ]; then
    printf 'Starting Audiobookshelf in foreground (with file watch)...\n'
  else
    printf 'Starting Audiobookshelf in foreground...\n'
  fi
  print_access_information_block
  if [ "$RUNTIME_FAMILY" = "bun" ]; then
    if [ "$DEV_MODE" = "true" ]; then
      exec "$RUNTIME_BIN" --watch socket.io-patch.js -- "$MODE_ARG"
    else
      "$RUNTIME_BIN" socket.io-patch.js -- "$MODE_ARG"
    fi
  else
    if [ "$DEV_MODE" = "true" ]; then
      exec "$RUNTIME_BIN" --watch index.js "$MODE_ARG"
    else
      "$RUNTIME_BIN" index.js "$MODE_ARG"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Description: Starts ABS as a backgrounded daemon, writes the PID file, and
#              polls for STARTUP_HEALTH_CHECK_SECONDS to verify liveness.
# Inputs:      globals: RUNTIME_FAMILY, RUNTIME_BIN, MODE_ARG, LOG_FILE,
#                       PID_FILE, STARTUP_HEALTH_CHECK_SECONDS
# Outputs:     side effect: daemon + PID file
#              stdout: status
#              exit: 1 on startup failure
# Called by:   main (start command)
# -----------------------------------------------------------------------------
start_audiobookshelf_daemon_and_print_result() {
  printf 'Starting Audiobookshelf as daemon...\n'
  if [ "$RUNTIME_FAMILY" = "bun" ]; then
    nohup "$RUNTIME_BIN" socket.io-patch.js -- "$MODE_ARG" >> "$LOG_FILE" 2>&1 < /dev/null &
  else
    nohup "$RUNTIME_BIN" index.js "$MODE_ARG" >> "$LOG_FILE" 2>&1 < /dev/null &
  fi
  newly_started_pid=$!
  printf '%s\n' "$newly_started_pid" > "$PID_FILE"

  health_check_seconds_elapsed=0
  daemon_died_during_health_check=0
  while [ "$health_check_seconds_elapsed" -lt "$STARTUP_HEALTH_CHECK_SECONDS" ]; do
    sleep 1
    if ! pid_is_our_running_daemon "$newly_started_pid"; then
      daemon_died_during_health_check=1
      break
    fi
    health_check_seconds_elapsed=$((health_check_seconds_elapsed + 1))
  done

  if [ "$daemon_died_during_health_check" -eq 0 ]; then
    printf '%s Audiobookshelf started. PID: %s\n' "$SYM_OK" "$newly_started_pid"
    printf '  Logs: %s\n' "$(color_in_yellow "tail -f $LOG_FILE")"
    print_access_information_block
  else
    printf '%s\n' "$(color_in_red "Daemon died within ${STARTUP_HEALTH_CHECK_SECONDS} seconds of startup.")" >&2
    printf 'Last log lines:\n' >&2
    [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE"
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Description: Stops the running daemon if any.
# Inputs:      global: PID_FILE
# Outputs:     side effect: stops daemon, removes PID file
#              stdout: status
# Called by:   main (stop command)
# -----------------------------------------------------------------------------
stop_audiobookshelf_daemon_and_print_result() {
  current_daemon_pid="$(read_daemon_pid_from_file)"
  if pid_is_our_running_daemon "$current_daemon_pid"; then
    printf 'Stopping Audiobookshelf (PID: %s)...\n' "$current_daemon_pid"
    gracefully_stop_pid_with_sigkill_fallback "$current_daemon_pid"
    rm -f "$PID_FILE"
    printf '%s Stopped.\n' "$SYM_OK"
  else
    printf '%s Audiobookshelf is not running.\n' "$SYM_WARN"
    rm -f "$PID_FILE"
  fi
}

# -----------------------------------------------------------------------------
# Description: Stops an existing daemon (if any) for the restart flow.
# Inputs:      global: PID_FILE
# Outputs:     side effect: stops daemon, removes PID file
#              stdout: status
# Called by:   main (restart command)
# -----------------------------------------------------------------------------
restart_audiobookshelf_daemon_or_skip() {
  current_daemon_pid="$(read_daemon_pid_from_file)"
  if pid_is_our_running_daemon "$current_daemon_pid"; then
    printf 'Stopping Audiobookshelf (PID: %s)...\n' "$current_daemon_pid"
    gracefully_stop_pid_with_sigkill_fallback "$current_daemon_pid"
    rm -f "$PID_FILE"
    printf '%s Stopped. Restarting...\n' "$SYM_OK"
  else
    printf '%s Audiobookshelf was not running. Starting...\n' "$SYM_WARN"
    rm -f "$PID_FILE"
  fi
}

# =============================================================================
# MAIN
# =============================================================================

# -----------------------------------------------------------------------------
# Description: Entry point. Performs early init, parses arguments, dispatches
#              commands, and orchestrates the start/foreground/restart flow.
# Inputs:      $@ - script arguments
# Outputs:     varies by command
# Called by:   bottom of script (the only call site)
# -----------------------------------------------------------------------------
main() {
  # --- Stage 1: Path resolution ---
  SCRIPT_PATH="$(resolve_script_path_to_absolute "$0")"
  SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
  SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
  readonly SCRIPT_PATH SCRIPT_DIR SCRIPT_NAME

  # --- Stage 2: Load env files ---
  load_env_file_with_warning_on_error "$HOME/.env_abs"
  load_env_file_with_warning_on_error "$SCRIPT_DIR/.env"

  # Defend against ABS_ROOT being set to empty (e.g. user wrote ABS_ROOT= in
  # an env file). The ${VAR:-default} expansion above only triggers when
  # VAR is unset, not when it is set-but-empty, so an empty assignment slips
  # through and would make REPO_DIR resolve to "/audiobookshelf" (the root!).
  if [ -z "$ABS_ROOT" ]; then
    printf '%s ABS_ROOT is empty after loading config files.\n' \
      "$(color_in_red "ERROR:")" >&2
    printf '  Set it to a non-empty directory, or remove the empty assignment\n' >&2
    printf '  from ~/.env_abs or %s/.env.\n' "$SCRIPT_DIR" >&2
    exit 1
  fi

  # Same defense for ABS_PORT. An empty value here would silently fall
  # through to ABS's built-in default rather than 13378, which is
  # surprising for a user who thought they were setting it explicitly.
  if [ -z "$ABS_PORT" ]; then
    printf '%s ABS_PORT is empty after loading config files.\n' \
      "$(color_in_red "ERROR:")" >&2
    printf '  Set it to a port number (1-65535) or remove the empty assignment.\n' >&2
    exit 1
  fi

  # --- Stage 3: Re-derive paths after env sourcing (ABS_ROOT may change) ---
  REPO_DIR="${ABS_ROOT}/audiobookshelf"
  PID_FILE="${ABS_ROOT}/audiobookshelf.pid"
  LOG_FILE="${ABS_ROOT}/audiobookshelf.log"
  LOG_FILE_ROTATED="${LOG_FILE}.1"
  RUNTIME_FILE="${ABS_ROOT}/.runtime"
  LOCK_DIR="${ABS_ROOT}/.runabs.lock"
  readonly REPO_DIR PID_FILE LOG_FILE LOG_FILE_ROTATED RUNTIME_FILE LOCK_DIR

  # --- Stage 4: Apple Silicon ffmpeg auto-detection ---
  #
  # ABS's BinaryManager downloads macOS x86_64 ffmpeg binaries when ffmpeg is
  # not in PATH. On Apple Silicon those binaries fail with "Bad CPU type in
  # executable". Pre-populating ABS_FFMPEG / ABS_FFPROBE prevents the download.
  #
  # `command -v` only checks $PATH; if the script runs via launchd, cron, or
  # a sudo-stripped environment, /opt/homebrew/bin may not be on PATH yet.
  # Search known install locations explicitly as a fallback so the script
  # still finds native binaries in those contexts.
  if [ "$OS_NAME" = "Darwin" ] && [ "$OS_ARCH" = "arm64" ]; then
    if [ -z "$ABS_FFMPEG" ]; then
      for candidate_ffmpeg in \
          "$(command -v ffmpeg 2>/dev/null || true)" \
          /opt/homebrew/bin/ffmpeg \
          /usr/local/bin/ffmpeg \
          /opt/local/bin/ffmpeg; do
        if [ -n "$candidate_ffmpeg" ] && [ -x "$candidate_ffmpeg" ]; then
          ABS_FFMPEG="$candidate_ffmpeg"
          break
        fi
      done
    fi
    if [ -z "$ABS_FFPROBE" ]; then
      for candidate_ffprobe in \
          "$(command -v ffprobe 2>/dev/null || true)" \
          /opt/homebrew/bin/ffprobe \
          /usr/local/bin/ffprobe \
          /opt/local/bin/ffprobe; do
        if [ -n "$candidate_ffprobe" ] && [ -x "$candidate_ffprobe" ]; then
          ABS_FFPROBE="$candidate_ffprobe"
          break
        fi
      done
    fi
  fi

  # --- Stage 5: Terminal init ---
  initialize_terminal_capabilities

  # --- Stage 6: Traps + ABS_ROOT directory ---
  if [ ! -d "$ABS_ROOT" ]; then
    mkdir_err_capture="$(mktemp "${TMPDIR:-/tmp}/runabs-mkdir-err.XXXXXX" 2>/dev/null || true)"
    if [ -z "$mkdir_err_capture" ]; then
      # Couldn't make a temp file; fall through with a generic error
      if ! mkdir -p "$ABS_ROOT" 2>/dev/null; then
        printf '%s Cannot create ABS_ROOT directory: %s\n' \
          "$(color_in_red "ERROR:")" "$ABS_ROOT" >&2
        printf '  Check that the parent directory exists and is writable,\n' >&2
        printf '  or override ABS_ROOT to a different location.\n' >&2
        exit 1
      fi
    else
      if ! mkdir -p "$ABS_ROOT" 2>"$mkdir_err_capture"; then
        mkdir_error_text="$(cat "$mkdir_err_capture" 2>/dev/null || true)"
        rm -f "$mkdir_err_capture"
        printf '%s Cannot create ABS_ROOT directory: %s\n' \
          "$(color_in_red "ERROR:")" "$ABS_ROOT" >&2
        [ -n "$mkdir_error_text" ] && printf '  %s\n' "$mkdir_error_text" >&2
        printf '  Check that the parent directory exists and is writable,\n' >&2
        printf '  or override ABS_ROOT to a different location.\n' >&2
        exit 1
      fi
      rm -f "$mkdir_err_capture"
    fi
  fi
  if [ ! -w "$ABS_ROOT" ]; then
    printf '%s ABS_ROOT is not writable: %s\n' \
      "$(color_in_red "ERROR:")" "$ABS_ROOT" >&2
    exit 1
  fi
  trap handle_script_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # --- Stage 7: Parse arguments ---
  for argument_value in "$@"; do
    case "$argument_value" in
      --dev|-d)        DEV_MODE="true" ;;
      --prod|-p)       DEV_MODE="false" ;;
      --update)        UPDATE_OVERRIDE="yes" ;;
      --no-update)     UPDATE_OVERRIDE="no" ;;
      --home)          INIT_HOME="true" ;;
      --debug)         ABS_DEBUG="1" ;;
      --help|-h)       print_help_screen; exit 0 ;;
      --version|-V)    printf '%s v%s\n' "$SCRIPT_NAME" "$ABS_RUN_VERSION"; exit 0 ;;
      -*)
        printf '%s\n' "$(color_in_bold "$(color_in_red "Unknown flag: $argument_value")")" >&2
        print_help_screen >&2
        exit 1
        ;;
      *)
        if [ -z "$CMD" ]; then
          CMD="$argument_value"
        else
          printf '%s\n' "$(color_in_bold "$(color_in_red "Unknown argument: $argument_value")")" >&2
          print_help_screen >&2
          exit 1
        fi
        ;;
    esac
  done

  # Enable xtrace if --debug was passed or ABS_DEBUG=1 is in the env.
  # Doing it here, after arg parsing, avoids tracing the variable init
  # at the top of the script (which would flood the output before any
  # interesting decisions are made).
  if [ -n "${ABS_DEBUG:-}" ] && [ "${ABS_DEBUG:-}" != "0" ]; then
    set -o xtrace
    printf '%s ABS_DEBUG enabled - shell tracing active.\n' "$SYM_INFO" >&2
  fi

  [ -n "$CMD" ] || CMD="start"

  case "$CMD" in
    start|daemon)                  CMD="start" ;;
    foreground|run|fg)             CMD="foreground" ;;
    stop)                          CMD="stop" ;;
    restart)                       CMD="restart" ;;
    status)                        CMD="status" ;;
    logs)                          CMD="logs" ;;
    check-update|update-check)     CMD="check-update" ;;
    check-config|config)           CMD="check-config" ;;
    install-service|install)       CMD="install-service" ;;
    uninstall-service|uninstall)   CMD="uninstall-service" ;;
    init-config|init)              CMD="init-config" ;;
    rebuild-sqlite|rebuild-sqlite3) CMD="rebuild-sqlite" ;;
    version)                       printf '%s v%s\n' "$SCRIPT_NAME" "$ABS_RUN_VERSION"; exit 0 ;;
    help)                          print_help_screen; exit 0 ;;
    *)
      printf '%s\n' "$(color_in_bold "$(color_in_red "Unknown command: $CMD")")" >&2
      print_help_screen >&2
      exit 1
      ;;
  esac

  # Effective update behavior
  if [ -n "$UPDATE_OVERRIDE" ]; then
    case "$UPDATE_OVERRIDE" in
      yes) DO_UPDATE="true" ;;
      no)  DO_UPDATE="false" ;;
    esac
  else
    case "$ABS_AUTO_UPDATE" in
      true|TRUE|True|1) DO_UPDATE="true" ;;
      *)                DO_UPDATE="false" ;;
    esac
  fi

  # --- Stage 8: Early commands that don't need runtime ---
  case "$CMD" in
    init-config)
      if [ "$INIT_HOME" = "true" ]; then
        write_env_template_to_file_and_print_result "$HOME/.env_abs"
      else
        mkdir -p "$ABS_ROOT"
        write_env_template_to_file_and_print_result "$ABS_ROOT/.env"
      fi
      exit 0
      ;;
    uninstall-service)
      uninstall_autostart_service_and_print_result
      exit 0
      ;;
    status)
      current_daemon_pid="$(read_daemon_pid_from_file)"
      if pid_is_our_running_daemon "$current_daemon_pid"; then
        printf '%s Audiobookshelf is running (PID: %s)\n' "$SYM_OK" "$current_daemon_pid"
        printf '  Logs: tail -f %s\n' "$LOG_FILE"
      else
        printf '%s Audiobookshelf is not running.\n' "$SYM_WARN"
        rm -f "$PID_FILE"
      fi
      exit 0
      ;;
    logs)
      if [ -f "$LOG_FILE" ]; then
        printf '%s Showing logs (Ctrl+C to exit)...\n' "$SYM_OK"
        tail -f "$LOG_FILE"
      else
        printf '%s No log file found at %s\n' "$SYM_WARN" "$LOG_FILE"
        printf '  The server may not have been started yet.\n'
        exit 1
      fi
      exit 0
      ;;
    stop)
      stop_audiobookshelf_daemon_and_print_result
      exit 0
      ;;
  esac

  # --- Stage 9: Acquire lock for state-mutating commands ---
  case "$CMD" in
    start|foreground|restart|install-service|check-update|rebuild-sqlite)
      acquire_run_lock_or_exit
      ;;
  esac

  # --- Stage 10: Dependency check ---
  check_dependencies_and_print_install_hints

  # --- Stage 11: Commands that need config but not runtime ---
  if [ "$CMD" = "check-config" ]; then
    check_config_and_print_report
    exit 0
  fi
  if [ "$CMD" = "check-update" ]; then
    check_upstream_update_and_print_report
    exit 0
  fi
  if [ "$CMD" = "install-service" ]; then
    install_autostart_service_and_print_result
    exit 0
  fi

  # --- Stage 12: Validate config strictly (exits on failure) ---
  validate_runtime_config_and_print_errors "exit"

  # --- Stage 12b: Early port-conflict check ---
  # Run before the heavy install phase so a port collision is caught in
  # seconds rather than after a 2-3 minute clone + npm install + client
  # build. Only applies to commands that will actually try to bind the
  # port. The same check is repeated just before launch (Stage 17) to
  # catch a process that grabbed the port during the install window.
  case "$CMD" in
    start|foreground|restart)
      warn_if_port_is_in_use_by_other_process
      ;;
  esac

  # --- Stage 13: Resolve runtime ---
  ensure_runtime_selected_and_persisted

  # --- Stage 13b: rebuild-sqlite command (needs runtime resolved, not start flow) ---
  if [ "$CMD" = "rebuild-sqlite" ]; then
    if [ ! -d "$REPO_DIR" ]; then
      printf '%s Repository not found at %s\n' "$SYM_ERR" "$REPO_DIR" >&2
      printf '  Run "./%s start" or "./%s foreground" first.\n' "$SCRIPT_NAME" "$SCRIPT_NAME" >&2
      exit 1
    fi
    rebuild_sqlite3_bindings_if_needed_and_print_result "always"
    exit $?
  fi

  # --- Stage 14: First-run nudge ---
  prompt_first_run_nudge_and_maybe_exit

  # --- Stage 15: Restart handling ---
  if [ "$CMD" = "restart" ]; then
    restart_audiobookshelf_daemon_or_skip
  fi

  # --- Stage 16: Heavy install phase ---
  INSTALL_IN_PROGRESS=1
  clone_or_update_repo_and_print_progress

  cd "$REPO_DIR"

  if [ -z "$ABS_NUNICODE_PATH" ]; then
    # Empirically verified to work under both Node and Bun; saves
    # BinaryManager ~30s on first launch.
    download_nunicode_and_set_path || true
  fi

  write_dev_js_config_file
  [ "$RUNTIME_FAMILY" = "bun" ] && write_bun_socket_io_patch_file

  install_dependencies_and_build_client_and_print_progress
  INSTALL_IN_PROGRESS=0

  # --- Stage 17: Launch ---
  warn_if_port_is_in_use_by_other_process
  rotate_log_file_if_threshold_exceeded

  if [ "$DEV_MODE" = "true" ]; then
    MODE_ARG="--dev"
  else
    MODE_ARG="--prod-with-dev-env"
  fi

  export_abs_env_only_variables_to_runtime

  if [ "$CMD" = "foreground" ]; then
    run_audiobookshelf_in_foreground
    # exec'd; never returns
  fi

  current_daemon_pid="$(read_daemon_pid_from_file)"
  if pid_is_our_running_daemon "$current_daemon_pid"; then
    printf 'Restarting existing daemon (PID: %s)...\n' "$current_daemon_pid"
    gracefully_stop_pid_with_sigkill_fallback "$current_daemon_pid"
    rm -f "$PID_FILE"
  fi

  start_audiobookshelf_daemon_and_print_result
}

# =============================================================================
# ENTRY POINT
# =============================================================================
main "$@"
