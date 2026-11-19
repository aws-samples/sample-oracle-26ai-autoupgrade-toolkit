#!/usr/bin/env bash
###############################################################################
# lib/common.sh
#
# Shared machinery for the Oracle 19c non-CDB -> 26ai PDB migration toolkit.
# Every phase script loads this library. It is a PURE library: loading it has
# no side effects beyond defining functions and a handful of constants. It
# never contacts a database or a remote host at load time.
#
# Design rules enforced here (see plan.md sections B, C, F):
#   * Config, state and secret files are parsed line-by-line. They are NEVER
#     interpreted by the shell (no sourcing, no eval) so a hostile or
#     malformed value can never run as code.
#   * Every sqlplus / rman script this library emits ends with an "exit".
#     run_sql prepends "whenever sqlerror exit failure" unless the body
#     manages its own error handling.
#   * Nothing is hardcoded to one site. All values come from the config.
#   * Secrets are never echoed: log / plan output is masked by redact().
#
# Runtime requires bash >= 4.2 (associative arrays, printf -v). Static syntax
# checks (bash -n) run on the macOS authoring host's bash 3.2, so this file is
# written to PARSE on 3.2 even though it only EXECUTES under the newer bash.
###############################################################################

# Load guard: safe to pull in from multiple phase scripts.
if [ -n "${_MIG_COMMON_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_MIG_COMMON_SH_LOADED=1

# Absolute path to the toolkit root (one level above lib/).
_MIG_SELF="${BASH_SOURCE[0]}"
TOOLKIT_ROOT="$(cd "$(dirname "$_MIG_SELF")/.." 2>/dev/null && pwd)"

#==============================================================================
# Exit-code contract (shared by the orchestrator and every phase). These
# constants are part of the library's public surface: some are referenced only
# by the phase scripts that source this file, so standalone shellcheck flags
# them as unused (SC2034). The contract is intentionally complete.
#==============================================================================
# shellcheck disable=SC2034
EXIT_OK=0          # success
EXIT_ERR=1         # general / unexpected failure
EXIT_CONFIG=2      # configuration or validation error
EXIT_PREFLIGHT=3   # preflight failure, including insufficient free space
# shellcheck disable=SC2034
EXIT_COLLISION=4   # target PDB name collision (resolve with --force)
EXIT_TRANSFER=5    # backup or artifact transfer failure
EXIT_RESTORE=6     # restore / recover / open / nid failure
# shellcheck disable=SC2034
EXIT_UPGRADE=10    # AutoUpgrade or post-migration verification failure

#==============================================================================
# The six orchestrated steps, in order.
#==============================================================================
STEP_NAMES="preflight source_backup transfer target_restore autoupgrade verify"

#==============================================================================
# Runtime globals (populated as the run progresses). Declared here so the
# library reads cleanly under set -u.
#==============================================================================
LOG_MAIN=""           # per-run human-readable log file (set by init_run_dirs)
LOG_DEBUG=""          # per-run verbose log file
PLAN_FILE=""          # per-run plan.txt
RUN_DIR=""            # <LOG_BASE>/<MIGRATION_ID>/run_<ts>
RUN_RENDER_DIR=""     # rendered templates for this run
RUN_TS=""             # UTC timestamp for this run
STATE_FILE=""         # <LOG_BASE>/<MIGRATION_ID>/state
CURRENT_STEP=""       # name of the step currently executing (for the ERR trap)
STAGING_ON_SOURCE_HOST="false"
ASSUME_YES="${ASSUME_YES:-false}"

# Values masked out of every log/plan line.
REDACT_VALUES=()

# Validation error accumulator.
VALIDATION_ERRORS=()

# Temp items cleaned up by the EXIT trap.
LOCAL_TEMP_ITEMS=()
REMOTE_TEMP_ITEMS=()

# Template-render allowlist. Only names present as keys here are substituted
# into a template; any other ${TOKEN} is a hard error. Callers rebuild this
# before each render via render_vars_reset / render_vars_add_config.
declare -A RENDER_VARS

#==============================================================================
# Known configuration keys. load_config assigns ONLY these; any other
# well-formed KEY=value warns and is ignored. Grouped exactly as plan.md B.
#==============================================================================
KNOWN_CONFIG_KEYS="\
SOURCE_HOST SOURCE_SSH_USER SOURCE_SSH_PORT SOURCE_SSH_KEY SOURCE_OS_USER \
SOURCE_ORACLE_BASE SOURCE_ORACLE_HOME SOURCE_ORACLE_SID SOURCE_DB_NAME \
SOURCE_BACKUP_DIR SOURCE_BACKUP_TAG SOURCE_EXPECTED_VERSION \
SOURCE_EXPECTED_CHARSET SOURCE_DATAFILE_PATHS \
SOURCE_CONN_MODE SOURCE_DB_HOST SOURCE_DB_PORT SOURCE_DB_SERVICE SOURCE_CONNECT_STRING \
SOURCE_DB_USER SOURCE_DB_ROLE SOURCE_RMAN_ROLE SOURCE_DB_PASSWORD \
TARGET_HOST TARGET_SSH_USER TARGET_SSH_PORT TARGET_SSH_KEY TARGET_OS_USER \
TARGET_ORACLE_BASE TARGET_STAGING_HOME TARGET_26AI_HOME TARGET_CDB_SID \
TARGET_TRANSFER_DIR TARGET_DATAFILE_DEST TARGET_REDO_DEST TARGET_STAGING_SID \
TARGET_STAGING_DB_NAME TARGET_PDB_NAME TARGET_STAGING_MEMORY_MB TARGET_PDB_SLOT_LIMIT \
TARGET_EXPECTED_VERSION \
TRANSPORT_METHOD TRANSPORT_SSH_KEY TRANSPORT_SSH_PASSWORD TRANSPORT_BANDWIDTH_KBPS \
TRANSPORT_COMPRESS TRANSPORT_SHARED_PATH TRANSPORT_RETRIES FORCE_REMOTE_TRANSPORT \
AUTOUPGRADE_JAR AUTOUPGRADE_JAVA AUTOUPGRADE_LOG_DIR \
AUTOUPGRADE_TARGET_PDB_COPY_OPTION AUTOUPGRADE_EXTRA_OPTIONS \
AUTOUPGRADE_START_TIME AUTOUPGRADE_TIMEOUT_MIN AUTOUPGRADE_DEPLOY_POLL_SEC \
MATCH_SOURCE_NAME BEHAVIOR_LOG_BASE_DIR BEHAVIOR_AUDIT_REMEDIATION \
BEHAVIOR_AUDIT_BACKUP_DIR BEHAVIOR_AUDIT_REMEDIATION_SCOPE BEHAVIOR_PROOF_QUERY \
BEHAVIOR_PROOF_MATCH BEHAVIOR_TEARDOWN_STAGING BEHAVIOR_BACKUP_SPACE_FACTOR \
BEHAVIOR_RESTORE_SPACE_FACTOR SECRETS_FILE"

#==============================================================================
# Small string helpers.
#==============================================================================
_uc() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
_lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
_strip_cr() { local s="$1"; printf '%s' "${s%$'\r'}"; }
_ltrim() { local s="$1"; printf '%s' "${s#"${s%%[![:space:]]*}"}"; }
_rtrim() { local s="$1"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
_trim() { _rtrim "$(_ltrim "$1")"; }

# Indirect read / write of a variable by name (no eval).
_getvar() { local n="$1"; printf '%s' "${!n:-}"; }
_setvar() { printf -v "$1" '%s' "$2"; }

# Remove one surrounding pair of single or double quotes.
strip_quotes() {
  local v="$1"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# Single-quote a string for safe use inside a remote shell command line.
_shq() {
  local s="$1"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# Membership test in a space-delimited list.
_in_list() {
  local needle="$1" list="$2"
  case " $list " in
    *" $needle "*) return 0 ;;
  esac
  return 1
}

config_key_known() { _in_list "$1" "$KNOWN_CONFIG_KEYS"; }

#==============================================================================
# Validation primitives.
#==============================================================================
_is_int() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }
_is_abs() { case "$1" in /*) return 0 ;; *) return 1 ;; esac; }
_is_sid() { printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9_$]{0,11}$'; }
_is_pdb() { printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9_$]{0,29}$'; }
_norm_bool() {
  case "$(_lc "$1")" in
    true|yes|1) printf 'true'; return 0 ;;
    false|no|0) printf 'false'; return 0 ;;
    *) return 1 ;;
  esac
}

#==============================================================================
# Redaction + logging. Every line printed by log / log_role / plan / warn is
# passed through redact() so a registered secret value can never reach a log.
#==============================================================================
register_secret_value() {
  local v="$1"
  [ -n "$v" ] || return 0
  REDACT_VALUES+=("$v")
}

# Defensive: treat the value of any config key whose NAME looks secret
# (*PASSWORD* / *PWD* / *SECRET*) as a value to mask, even though the schema
# forbids storing secrets in the config.
register_secret_config_values() {
  local k v
  for k in $KNOWN_CONFIG_KEYS; do
    case "$k" in
      *PASSWORD*|*PWD*|*SECRET*)
        v="$(_getvar "$k")"
        [ -n "$v" ] && register_secret_value "$v"
        ;;
    esac
  done
}

redact() {
  local s="$*"
  local v
  for v in "${REDACT_VALUES[@]:-}"; do
    [ -n "$v" ] || continue
    s="${s//"$v"/********}"
  done
  printf '%s' "$s"
}

_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Core emitter: LEVEL ROLE MSG. ROLE is "" or SOURCE/TARGET/STAGING.
_emit() {
  local level="$1" role="$2"
  shift 2
  local masked tag line
  masked="$(redact "$*")"
  tag=""
  [ -n "$role" ] && tag="[$role] "
  line="[$(_now)] [$level] ${tag}${masked}"
  case "$level" in
    ERROR|WARN) printf '%s\n' "$line" >&2 ;;
    *) printf '%s\n' "$line" ;;
  esac
  if [ -n "$LOG_MAIN" ]; then printf '%s\n' "$line" >>"$LOG_MAIN" 2>/dev/null || true; fi
  if [ -n "$LOG_DEBUG" ]; then printf '%s\n' "$line" >>"$LOG_DEBUG" 2>/dev/null || true; fi
}

log()       { _emit INFO  "" "$*"; }
log_role()  { local r="$1"; shift; _emit INFO "$r" "$*"; }
log_warn()  { _emit WARN  "" "$*"; }
log_err()   { _emit ERROR "" "$*"; }

# Verbose line: debug log only (plus console when MIG_DEBUG=true).
debug() {
  local masked; masked="$(redact "$*")"
  local line; line="[$(_now)] [DEBUG] ${masked}"
  if [ -n "$LOG_DEBUG" ]; then printf '%s\n' "$line" >>"$LOG_DEBUG" 2>/dev/null || true; fi
  [ "${MIG_DEBUG:-false}" = "true" ] && printf '%s\n' "$line" >&2
  return 0
}

# Plan line: stdout + plan.txt (the dry-run / resolved plan surface).
plan() {
  local masked; masked="$(redact "$*")"
  printf '%s\n' "$masked"
  if [ -n "$PLAN_FILE" ]; then printf '%s\n' "$masked" >>"$PLAN_FILE" 2>/dev/null || true; fi
  return 0
}

die() { log_err "$*"; exit "$EXIT_ERR"; }

# Interactive confirmation gate; auto-yes under --yes (ASSUME_YES=true).
confirm() {
  local prompt="$1"
  if [ "${ASSUME_YES:-false}" = "true" ]; then
    log "auto-confirm (--yes): $prompt"
    return 0
  fi
  local ans=""
  printf '%s [y/N] ' "$prompt" >&2
  if [ -r /dev/tty ]; then
    read -r ans </dev/tty || ans=""
  else
    read -r ans || ans=""
  fi
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

#==============================================================================
# bash version floor.
#==============================================================================
assert_bash_version() {
  local need_major="${TOOLKIT_MIN_BASH_MAJOR:-4}"
  local need_minor="${TOOLKIT_MIN_BASH_MINOR:-2}"
  local major="${BASH_VERSINFO[0]:-0}"
  local minor="${BASH_VERSINFO[1]:-0}"
  if [ "$major" -gt "$need_major" ]; then return 0; fi
  if [ "$major" -eq "$need_major" ] && [ "$minor" -ge "$need_minor" ]; then return 0; fi
  printf 'FATAL: bash >= %s.%s required at runtime; found %s.%s\n' \
    "$need_major" "$need_minor" "$major" "$minor" >&2
  exit "$EXIT_ERR"
}

#==============================================================================
# Configuration loading (non-sourcing, line-by-line).
#==============================================================================
load_config() {
  local file="$1"
  [ -n "$file" ] || { log_err "load_config: no config file given"; exit "$EXIT_CONFIG"; }
  [ -f "$file" ] || { log_err "config file not found: $file"; exit "$EXIT_CONFIG"; }
  local lineno=0 line key val
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(_strip_cr "$line")"
    line="$(_ltrim "$line")"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if ! printf '%s' "$line" | grep -qE '^[A-Z_][A-Z0-9_]*='; then
      log_err "config $file line $lineno: malformed (expected KEY=value): $line"
      exit "$EXIT_CONFIG"
    fi
    key="${line%%=*}"
    val="${line#*=}"
    val="$(strip_quotes "$(_rtrim "$val")")"
    if config_key_known "$key"; then
      _setvar "$key" "$val"
    else
      log_warn "config $file line $lineno: unknown key '$key' ignored"
    fi
  done < "$file"
  register_secret_config_values
}

#==============================================================================
# Secret loading (optional 0600 file). Same non-sourcing parser; every value
# is registered for redaction.
#==============================================================================
_assert_secret_perms() {
  local f="$1" perm="" owner="" me=""
  if command -v stat >/dev/null 2>&1; then
    perm="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || printf '')"
    owner="$(stat -c '%u' "$f" 2>/dev/null || stat -f '%u' "$f" 2>/dev/null || printf '')"
  fi
  if [ -n "$perm" ] && [ "$perm" != "600" ]; then
    log_err "SECRETS_FILE $f must have permissions 0600 (found $perm)"
    exit "$EXIT_CONFIG"
  fi
  me="$(id -u 2>/dev/null || printf '')"
  if [ -n "$owner" ] && [ -n "$me" ] && [ "$owner" != "$me" ]; then
    log_err "SECRETS_FILE $f must be owned by the invoking user (uid $me; found uid $owner)"
    exit "$EXIT_CONFIG"
  fi
}

load_secrets() {
  local file="${1:-${SECRETS_FILE:-}}"
  [ -n "$file" ] || return 0
  [ -f "$file" ] || { log_err "SECRETS_FILE not found: $file"; exit "$EXIT_CONFIG"; }
  _assert_secret_perms "$file"
  local lineno=0 line key val
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(_strip_cr "$line")"
    line="$(_ltrim "$line")"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    # tolerate an "export KEY=value" form in a secrets file
    case "$line" in
      export\ *) line="$(_ltrim "${line#export }")" ;;
    esac
    if ! printf '%s' "$line" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
      log_err "secrets $file line $lineno: malformed (expected KEY=value)"
      exit "$EXIT_CONFIG"
    fi
    key="${line%%=*}"
    val="${line#*=}"
    val="$(strip_quotes "$(_rtrim "$val")")"
    _setvar "$key" "$val"
    register_secret_value "$val"
  done < "$file"
}

#==============================================================================
# Defaults. Applied after load_config, before validate_config, so enum/type
# checks see the effective values.
#==============================================================================
_default_if_empty() {
  local n="$1" v="$2"
  [ -z "$(_getvar "$n")" ] && _setvar "$n" "$v"
  return 0
}

apply_config_defaults() {
  _default_if_empty SOURCE_HOST "localhost"
  _default_if_empty SOURCE_SSH_USER "oracle"
  _default_if_empty SOURCE_SSH_PORT "22"
  _default_if_empty SOURCE_OS_USER "oracle"
  _default_if_empty SOURCE_DB_NAME "$(_getvar SOURCE_ORACLE_SID)"
  _default_if_empty SOURCE_EXPECTED_VERSION "19"
  _default_if_empty SOURCE_EXPECTED_CHARSET "AL32UTF8"

  _default_if_empty TARGET_HOST "localhost"
  _default_if_empty TARGET_SSH_USER "oracle"
  _default_if_empty TARGET_SSH_PORT "22"
  _default_if_empty TARGET_OS_USER "oracle"
  _default_if_empty TARGET_REDO_DEST "$(_getvar TARGET_DATAFILE_DEST)"
  _default_if_empty TARGET_STAGING_MEMORY_MB "2048"
  _default_if_empty TARGET_EXPECTED_VERSION "23"

  _default_if_empty TRANSPORT_METHOD "scp"
  _default_if_empty TRANSPORT_BANDWIDTH_KBPS "0"
  _default_if_empty TRANSPORT_COMPRESS "true"
  _default_if_empty TRANSPORT_RETRIES "2"

  _default_if_empty SOURCE_CONN_MODE "os"
  _default_if_empty SOURCE_DB_PORT "1521"
  _default_if_empty SOURCE_DB_ROLE "normal"
  _default_if_empty SOURCE_RMAN_ROLE "sysbackup"

  _default_if_empty AUTOUPGRADE_JAR "$(_getvar TARGET_26AI_HOME)/rdbms/admin/autoupgrade.jar"
  _default_if_empty AUTOUPGRADE_JAVA "$(_getvar TARGET_26AI_HOME)/jdk/bin/java"
  _default_if_empty AUTOUPGRADE_START_TIME "NOW"
  _default_if_empty AUTOUPGRADE_TIMEOUT_MIN "0"
  _default_if_empty AUTOUPGRADE_DEPLOY_POLL_SEC "30"

  _default_if_empty MATCH_SOURCE_NAME "true"
  _default_if_empty BEHAVIOR_LOG_BASE_DIR "$TOOLKIT_ROOT/run"
  _default_if_empty BEHAVIOR_AUDIT_REMEDIATION "true"
  _default_if_empty BEHAVIOR_AUDIT_REMEDIATION_SCOPE "staging"
  _default_if_empty BEHAVIOR_PROOF_MATCH "exact"
  _default_if_empty BEHAVIOR_TEARDOWN_STAGING "manual"
  _default_if_empty BEHAVIOR_BACKUP_SPACE_FACTOR "1.0"
  _default_if_empty BEHAVIOR_RESTORE_SPACE_FACTOR "1.2"
  return 0
}

#==============================================================================
# Host-locality + placement.
#==============================================================================
host_is_local() {
  local h="$1"
  case "$h" in
    ''|localhost|127.0.0.1|::1) return 0 ;;
  esac
  local me ms mf
  me="$(hostname 2>/dev/null || printf '')"
  [ -n "$me" ] && [ "$h" = "$me" ] && return 0
  ms="$(hostname -s 2>/dev/null || printf '')"
  [ -n "$ms" ] && [ "$h" = "$ms" ] && return 0
  mf="$(hostname -f 2>/dev/null || printf '')"
  [ -n "$mf" ] && [ "$h" = "$mf" ] && return 0
  # Match any IP address bound to this machine, so SOURCE_HOST/TARGET_HOST set
  # to the box's own address (e.g. its private IP) is still recognized as local
  # -> local cp, no SSH, no password. To deliberately exercise the over-the-wire
  # transfer path on a single host, set FORCE_REMOTE_TRANSPORT=true (honored by
  # transfer_artifacts), which does NOT change this function.
  local ip ips=""
  ips="$(hostname -I 2>/dev/null || printf '')"
  if [ -z "$ips" ] && command -v ip >/dev/null 2>&1; then
    ips="$(ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
  fi
  for ip in $ips; do
    [ "$h" = "$ip" ] && return 0
  done
  return 1
}

# Decide whether the staging instance (on the TARGET host) shares a physical
# host with the live SOURCE. Sets STAGING_ON_SOURCE_HOST true/false.
compute_placement() {
  local src tgt
  src="$(_getvar SOURCE_HOST)"
  tgt="$(_getvar TARGET_HOST)"
  if host_is_local "$src" && host_is_local "$tgt"; then
    STAGING_ON_SOURCE_HOST="true"
  elif [ -n "$src" ] && [ "$src" = "$tgt" ]; then
    STAGING_ON_SOURCE_HOST="true"
  else
    STAGING_ON_SOURCE_HOST="false"
  fi
  return 0
}

#==============================================================================
# Validation.
#==============================================================================
add_err() { VALIDATION_ERRORS+=("$1"); }

_require() {
  local n
  for n in "$@"; do
    [ -z "$(_getvar "$n")" ] && add_err "missing required key: $n"
  done
}

_check_abs() {
  local n="$1" v; v="$(_getvar "$n")"
  [ -z "$v" ] && return 0
  _is_abs "$v" || add_err "$n must be an absolute path, got '$v'"
}

_check_int() {
  local n="$1" v; v="$(_getvar "$n")"
  [ -z "$v" ] && return 0
  _is_int "$v" || add_err "$n must be a non-negative integer, got '$v'"
}

_check_bool() {
  local n="$1" v nb; v="$(_getvar "$n")"
  [ -z "$v" ] && return 0
  if nb="$(_norm_bool "$v")"; then
    _setvar "$n" "$nb"
  else
    add_err "$n must be a boolean (true/false/yes/no/1/0), got '$v'"
  fi
}

_check_enum() {
  local n="$1" allowed="$2" v; v="$(_getvar "$n")"
  [ -z "$v" ] && return 0
  _in_list "$v" "$allowed" || add_err "$n must be one of [$allowed], got '$v'"
}

_check_sid() {
  local n="$1" v; v="$(_getvar "$n")"
  [ -z "$v" ] && return 0
  _is_sid "$v" || add_err "$n must match the Oracle SID rule (letter then <=11 of A-Za-z0-9_\$), got '$v'"
}

_check_pdb() {
  local n="$1" v; v="$(_getvar "$n")"
  [ -z "$v" ] && return 0
  _is_pdb "$v" || add_err "$n must match the PDB-name rule (letter then <=29 of A-Za-z0-9_\$), got '$v'"
}

validate_config() {
  VALIDATION_ERRORS=()

  _require SOURCE_ORACLE_BASE SOURCE_ORACLE_HOME SOURCE_ORACLE_SID SOURCE_BACKUP_DIR \
           TARGET_ORACLE_BASE TARGET_STAGING_HOME TARGET_26AI_HOME TARGET_CDB_SID \
           TARGET_TRANSFER_DIR TARGET_DATAFILE_DEST

  _check_abs SOURCE_ORACLE_BASE
  _check_abs SOURCE_ORACLE_HOME
  _check_abs SOURCE_BACKUP_DIR
  _check_abs TARGET_ORACLE_BASE
  _check_abs TARGET_STAGING_HOME
  _check_abs TARGET_26AI_HOME
  _check_abs TARGET_TRANSFER_DIR
  _check_abs TARGET_DATAFILE_DEST
  _check_abs TARGET_REDO_DEST
  _check_abs BEHAVIOR_LOG_BASE_DIR
  _check_abs AUTOUPGRADE_JAR
  _check_abs AUTOUPGRADE_JAVA
  [ -n "$(_getvar AUTOUPGRADE_LOG_DIR)" ] && _check_abs AUTOUPGRADE_LOG_DIR
  [ -n "$(_getvar BEHAVIOR_AUDIT_BACKUP_DIR)" ] && _check_abs BEHAVIOR_AUDIT_BACKUP_DIR
  [ -n "$(_getvar SOURCE_SSH_KEY)" ] && _check_abs SOURCE_SSH_KEY
  [ -n "$(_getvar TARGET_SSH_KEY)" ] && _check_abs TARGET_SSH_KEY
  [ -n "$(_getvar TRANSPORT_SSH_KEY)" ] && _check_abs TRANSPORT_SSH_KEY
  [ -n "$(_getvar SECRETS_FILE)" ] && _check_abs SECRETS_FILE

  _check_int SOURCE_SSH_PORT
  _check_int TARGET_SSH_PORT
  _check_int TRANSPORT_BANDWIDTH_KBPS
  _check_int TRANSPORT_RETRIES
  _check_int TARGET_STAGING_MEMORY_MB
  _check_int AUTOUPGRADE_TIMEOUT_MIN
  _check_int AUTOUPGRADE_DEPLOY_POLL_SEC

  _check_bool MATCH_SOURCE_NAME
  _check_bool TRANSPORT_COMPRESS
  _check_bool FORCE_REMOTE_TRANSPORT
  _check_bool BEHAVIOR_AUDIT_REMEDIATION

  _check_enum TRANSPORT_METHOD "scp rsync shared"
  _check_enum SOURCE_CONN_MODE "os net"
  [ -n "$(_getvar SOURCE_DB_ROLE)" ] && _check_enum SOURCE_DB_ROLE "normal sysdba sysbackup"
  [ -n "$(_getvar SOURCE_RMAN_ROLE)" ] && _check_enum SOURCE_RMAN_ROLE "sysbackup sysdba normal"
  _check_enum BEHAVIOR_AUDIT_REMEDIATION_SCOPE "staging both source"
  _check_enum BEHAVIOR_PROOF_MATCH "exact nonzero"
  _check_enum BEHAVIOR_TEARDOWN_STAGING "manual on_success never"

  _check_sid SOURCE_ORACLE_SID
  _check_sid TARGET_CDB_SID
  [ -n "$(_getvar TARGET_STAGING_SID)" ] && _check_sid TARGET_STAGING_SID
  [ -n "$(_getvar SOURCE_DB_NAME)" ] && _check_sid SOURCE_DB_NAME
  [ -n "$(_getvar TARGET_STAGING_DB_NAME)" ] && _check_sid TARGET_STAGING_DB_NAME
  [ -n "$(_getvar TARGET_PDB_NAME)" ] && _check_pdb TARGET_PDB_NAME

  # staging memory floor
  local mem; mem="$(_getvar TARGET_STAGING_MEMORY_MB)"
  if [ -n "$mem" ] && _is_int "$mem" && [ "$mem" -lt 800 ]; then
    add_err "TARGET_STAGING_MEMORY_MB must be >= 800 (got $mem)"
  fi
  # deploy poll floor
  local poll; poll="$(_getvar AUTOUPGRADE_DEPLOY_POLL_SEC)"
  if [ -n "$poll" ] && _is_int "$poll" && [ "$poll" -lt 5 ]; then
    add_err "AUTOUPGRADE_DEPLOY_POLL_SEC must be >= 5 (got $poll)"
  fi
  # shared transport needs a path
  if [ "$(_getvar TRANSPORT_METHOD)" = "shared" ] && [ -z "$(_getvar TRANSPORT_SHARED_PATH)" ]; then
    add_err "TRANSPORT_SHARED_PATH is required when TRANSPORT_METHOD=shared"
  fi

  # NET source connection (Oracle Net, no SSH / no OS auth on the source).
  if [ "$(_getvar SOURCE_CONN_MODE)" = "net" ]; then
    [ -n "$(_getvar SOURCE_DB_USER)" ] \
      || add_err "SOURCE_DB_USER is required when SOURCE_CONN_MODE=net"
    if [ -z "$(_getvar SOURCE_CONNECT_STRING)" ] \
       && { [ -z "$(_getvar SOURCE_DB_HOST)" ] || [ -z "$(_getvar SOURCE_DB_SERVICE)" ]; }; then
      add_err "SOURCE_CONN_MODE=net requires SOURCE_CONNECT_STRING, or both SOURCE_DB_HOST and SOURCE_DB_SERVICE"
    fi
    [ -n "$(_getvar SOURCE_DB_PASSWORD)" ] \
      || add_err "SOURCE_DB_PASSWORD (in the 0600 SECRETS_FILE) is required when SOURCE_CONN_MODE=net"
    [ "$(_getvar TRANSPORT_METHOD)" = "shared" ] \
      || add_err "SOURCE_CONN_MODE=net requires TRANSPORT_METHOD=shared (no SSH to the source; the backup must land on a shared mount both hosts see)"
    [ "$(_getvar SOURCE_RMAN_ROLE)" = "normal" ] \
      && add_err "SOURCE_RMAN_ROLE must be sysbackup or sysdba (RMAN cannot connect as a normal user)"
  fi

  # Hard isolation invariants for an explicitly-provided staging SID. (A
  # derived staging SID is guaranteed distinct by resolve_derivations.)
  compute_placement
  local ssid cdbsid srcsid
  ssid="$(_getvar TARGET_STAGING_SID)"
  cdbsid="$(_getvar TARGET_CDB_SID)"
  srcsid="$(_getvar SOURCE_ORACLE_SID)"
  if [ -n "$ssid" ]; then
    [ "$ssid" = "$cdbsid" ] && add_err "TARGET_STAGING_SID must differ from TARGET_CDB_SID ('$ssid')"
    if [ "$STAGING_ON_SOURCE_HOST" = "true" ] && [ "$ssid" = "$srcsid" ]; then
      add_err "TARGET_STAGING_SID must differ from SOURCE_ORACLE_SID on a shared host ('$ssid')"
    fi
  fi

  if [ "${#VALIDATION_ERRORS[@]}" -gt 0 ]; then
    local e
    for e in "${VALIDATION_ERRORS[@]}"; do log_err "config: $e"; done
    log_err "configuration has ${#VALIDATION_ERRORS[@]} error(s); aborting"
    exit "$EXIT_CONFIG"
  fi
  log "configuration validated"
  return 0
}

#==============================================================================
# Derivations (MIGRATION_ID, placement, name/SID derivation, backup tag+dir).
#==============================================================================
# Pick a staging SID distinct from every forbidden SID. Tries <base>S first,
# then STG1..STG9. Echoes the chosen SID, or returns non-zero on failure.
derive_staging_sid() {
  local base="$1"; shift
  local forbidden=" $* "
  local cand
  for cand in "${base}S" STG1 STG2 STG3 STG4 STG5 STG6 STG7 STG8 STG9; do
    if _is_sid "$cand" && ! _in_list "$cand" "$forbidden"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

resolve_derivations() {
  compute_placement
  # A net source is reached over Oracle Net, so it is never "on the staging host"
  # for the single-host overlap check, regardless of the host strings.
  if [ "$(_getvar SOURCE_CONN_MODE)" = "net" ]; then STAGING_ON_SOURCE_HOST="false"; fi

  local src_db src_sid cdb_sid match
  src_sid="$(_getvar SOURCE_ORACLE_SID)"
  src_db="$(_getvar SOURCE_DB_NAME)"
  [ -z "$src_db" ] && src_db="$src_sid"
  cdb_sid="$(_getvar TARGET_CDB_SID)"
  match="$(_getvar MATCH_SOURCE_NAME)"

  # --- target names ---------------------------------------------------------
  if [ "$match" = "true" ]; then
    _default_if_empty TARGET_PDB_NAME "$src_db"
    _default_if_empty TARGET_STAGING_DB_NAME "$src_db"
  else
    if [ -z "$(_getvar TARGET_PDB_NAME)" ] || [ -z "$(_getvar TARGET_STAGING_DB_NAME)" ]; then
      log_err "MATCH_SOURCE_NAME=false requires both TARGET_PDB_NAME and TARGET_STAGING_DB_NAME to be set"
      exit "$EXIT_CONFIG"
    fi
  fi

  # --- staging SID ----------------------------------------------------------
  local ssid; ssid="$(_getvar TARGET_STAGING_SID)"
  if [ -z "$ssid" ]; then
    local forbidden="$cdb_sid"
    [ "$STAGING_ON_SOURCE_HOST" = "true" ] && forbidden="$forbidden $src_sid"
    local base="$src_db"
    # keep <base>S within the 12-char SID limit
    if [ "${#base}" -gt 11 ]; then base="STG"; fi
    # $forbidden is a space-separated SID list passed as DISTINCT arguments to
    # derive_staging_sid; the word splitting here is intentional and SID values
    # (^[A-Za-z][A-Za-z0-9_$]{0,11}$) contain no spaces or glob characters.
    # shellcheck disable=SC2086
    if ssid="$(derive_staging_sid "$base" $forbidden)"; then
      _setvar TARGET_STAGING_SID "$ssid"
    else
      log_err "could not derive a staging SID distinct from [$forbidden]; set TARGET_STAGING_SID explicitly"
      exit "$EXIT_CONFIG"
    fi
  fi
  ssid="$(_getvar TARGET_STAGING_SID)"

  # final isolation assertion (covers both derived and explicit SIDs)
  if [ "$ssid" = "$cdb_sid" ]; then
    log_err "resolved TARGET_STAGING_SID ('$ssid') collides with TARGET_CDB_SID"
    exit "$EXIT_CONFIG"
  fi
  if [ "$STAGING_ON_SOURCE_HOST" = "true" ] && [ "$ssid" = "$src_sid" ]; then
    log_err "resolved TARGET_STAGING_SID ('$ssid') collides with SOURCE_ORACLE_SID on a shared host"
    exit "$EXIT_CONFIG"
  fi

  # --- backup tag + run dir -------------------------------------------------
  # The tag must be STABLE across separate --only invocations, otherwise a later
  # phase (transfer/restore) would look in a different backup dir than the one
  # source_backup wrote. If a prior source_backup already recorded a tag in this
  # migration's manifest, reuse it; else mint one (source_backup persists it).
  if [ -z "$(_getvar SOURCE_BACKUP_TAG)" ]; then
    local _mid _base _mf _t=""
    _mid="${cdb_sid}__$(_getvar TARGET_PDB_NAME)"
    _base="$(_getvar BEHAVIOR_LOG_BASE_DIR)"; [ -n "$_base" ] || _base="$TOOLKIT_ROOT/run"
    _mf="$_base/$_mid/manifest.env"
    if [ -f "$_mf" ]; then
      _t="$(grep '^SOURCE_BACKUP_TAG=' "$_mf" 2>/dev/null | tail -1)"; _t="${_t#SOURCE_BACKUP_TAG=}"
    fi
    if [ -n "$_t" ]; then
      _setvar SOURCE_BACKUP_TAG "$_t"
    else
      _setvar SOURCE_BACKUP_TAG "MIG_$(date -u +%Y%m%dT%H%M%SZ)"
    fi
  fi
  _setvar SOURCE_BACKUP_RUN_DIR "$(_getvar SOURCE_BACKUP_DIR)/$(_getvar SOURCE_BACKUP_TAG)"

  # --- shared-transport read location --------------------------------------
  # In 'shared' mode no copy is performed (TRANSPORT_SHARED_PATH is a mount both
  # hosts see), so the backup pieces stay in the tagged run dir where RMAN wrote
  # them. The target reads pieces exclusively via TARGET_TRANSFER_DIR (transfer
  # verify, the restore catalog, and the controlfile-autobackup restore all use
  # it), so repoint it at the tagged run dir. The operator still configures
  # TARGET_TRANSFER_DIR as the flat mount root; the tag is dynamic and cannot be
  # spelled by hand. scp/rsync/local modes copy the tagged pieces down into the
  # flat TARGET_TRANSFER_DIR, so they are deliberately left untouched here.
  if [ "$(_getvar TRANSPORT_METHOD)" = "shared" ]; then
    _setvar TARGET_TRANSFER_DIR "$(_getvar SOURCE_BACKUP_RUN_DIR)"
  fi

  # --- derived identity + audit quarantine ---------------------------------
  _setvar MIGRATION_ID "${cdb_sid}__$(_getvar TARGET_PDB_NAME)"
  _default_if_empty BEHAVIOR_AUDIT_BACKUP_DIR "$(_getvar TARGET_ORACLE_BASE)/audit_quarantine"

  # normalise SOURCE_DB_NAME if it was only a default
  _default_if_empty SOURCE_DB_NAME "$src_db"
  return 0
}

# Emit the resolved plan (used by --dry-run and at the top of a real run).
print_resolved_plan() {
  plan "migration plan:"
  plan "  MIGRATION_ID            = $(_getvar MIGRATION_ID)"
  plan "  staging_on_source_host  = $STAGING_ON_SOURCE_HOST"
  plan "  MATCH_SOURCE_NAME       = $(_getvar MATCH_SOURCE_NAME)"
  plan "  SOURCE host/SID/db_name = $(_getvar SOURCE_HOST) / $(_getvar SOURCE_ORACLE_SID) / $(_getvar SOURCE_DB_NAME)"
  plan "  TARGET host/CDB SID     = $(_getvar TARGET_HOST) / $(_getvar TARGET_CDB_SID)"
  plan "  staging SID / db_name   = $(_getvar TARGET_STAGING_SID) / $(_getvar TARGET_STAGING_DB_NAME)"
  plan "  target PDB name         = $(_getvar TARGET_PDB_NAME)"
  plan "  backup tag / run dir    = $(_getvar SOURCE_BACKUP_TAG) / $(_getvar SOURCE_BACKUP_RUN_DIR)"
  plan "  transfer method         = $(_getvar TRANSPORT_METHOD)"
  return 0
}

#==============================================================================
# Per-run directories, state file, logs.
#==============================================================================
init_run_dirs() {
  local base mid
  base="$(_getvar BEHAVIOR_LOG_BASE_DIR)"
  [ -n "$base" ] || base="$TOOLKIT_ROOT/run"
  mid="$(_getvar MIGRATION_ID)"
  [ -n "$mid" ] || { printf 'MIGRATION_ID must be resolved before init_run_dirs\n' >&2; exit "$EXIT_ERR"; }
  RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="$base/$mid/run_$RUN_TS"
  RUN_RENDER_DIR="$RUN_DIR/rendered"
  mkdir -p "$RUN_RENDER_DIR" || { printf 'cannot create run dir %s\n' "$RUN_DIR" >&2; exit "$EXIT_ERR"; }
  LOG_MAIN="$RUN_DIR/main.log"
  LOG_DEBUG="$RUN_DIR/debug.log"
  PLAN_FILE="$RUN_DIR/plan.txt"
  : >"$LOG_MAIN"; : >"$LOG_DEBUG"; : >"$PLAN_FILE"
  log "run directory: $RUN_DIR"
  return 0
}

#==============================================================================
# State framework. State file is KEY=value, parsed (never sourced). Writes are
# atomic (temp then mv).
#==============================================================================
_state_dir() {
  local base mid
  base="$(_getvar BEHAVIOR_LOG_BASE_DIR)"
  [ -n "$base" ] || base="$TOOLKIT_ROOT/run"
  mid="$(_getvar MIGRATION_ID)"
  printf '%s/%s' "$base" "$mid"
}

# A short digest over the placement/identity subset. Resuming a migration with
# a changed identity is refused.
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}';
  else cksum | awk '{print $1}'; fi
}

compute_config_sha() {
  {
    printf 'MIGRATION_ID=%s\n' "$(_getvar MIGRATION_ID)"
    printf 'SOURCE_ORACLE_SID=%s\n' "$(_getvar SOURCE_ORACLE_SID)"
    printf 'SOURCE_DB_NAME=%s\n' "$(_getvar SOURCE_DB_NAME)"
    printf 'TARGET_CDB_SID=%s\n' "$(_getvar TARGET_CDB_SID)"
    printf 'TARGET_PDB_NAME=%s\n' "$(_getvar TARGET_PDB_NAME)"
    printf 'TARGET_STAGING_SID=%s\n' "$(_getvar TARGET_STAGING_SID)"
    printf 'TARGET_STAGING_DB_NAME=%s\n' "$(_getvar TARGET_STAGING_DB_NAME)"
    printf 'MATCH_SOURCE_NAME=%s\n' "$(_getvar MATCH_SOURCE_NAME)"
    printf 'SOURCE_HOST=%s\n' "$(_getvar SOURCE_HOST)"
    printf 'TARGET_HOST=%s\n' "$(_getvar TARGET_HOST)"
  } | _sha256
}

state_get() {
  local key="$1" line val=""
  [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || { printf ''; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) val="${line#*=}" ;;
    esac
  done < "$STATE_FILE"
  printf '%s' "$val"
}

state_set() {
  local key="$1" value="$2"
  [ -n "$STATE_FILE" ] || { log_err "state_set called before state_init"; return "$EXIT_ERR"; }
  local tmp="$STATE_FILE.tmp.$$" found=0 line
  : >"$tmp"
  if [ -f "$STATE_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*) printf '%s=%s\n' "$key" "$value" >>"$tmp"; found=1 ;;
        *) printf '%s\n' "$line" >>"$tmp" ;;
      esac
    done < "$STATE_FILE"
  fi
  [ "$found" -eq 0 ] && printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

_state_check_config_sha() {
  local stored now
  stored="$(state_get CONFIG_SHA)"
  now="$(compute_config_sha)"
  if [ -n "$stored" ] && [ "$stored" != "$now" ]; then
    log_err "CONFIG_SHA mismatch: this migration's state was created with a different placement/identity. Refusing to resume. Use a fresh MIGRATION_ID or restore the original config."
    exit "$EXIT_CONFIG"
  fi
  return 0
}

state_init() {
  local d; d="$(_state_dir)"
  mkdir -p "$d" || { log_err "cannot create state dir $d"; exit "$EXIT_ERR"; }
  STATE_FILE="$d/state"
  if [ ! -f "$STATE_FILE" ]; then
    local tmp="$STATE_FILE.tmp.$$" s
    {
      printf 'MIGRATION_ID=%s\n' "$(_getvar MIGRATION_ID)"
      printf 'TOOLKIT_VERSION=%s\n' "${TOOLKIT_VERSION:-unknown}"
      printf 'CONFIG_SHA=%s\n' "$(compute_config_sha)"
      printf 'CREATED_AT=%s\n' "$(_now)"
      for s in $STEP_NAMES; do printf 'STEP_%s=PENDING\n' "$(_uc "$s")"; done
    } >"$tmp"
    mv -f "$tmp" "$STATE_FILE"
    log "initialised state: $STATE_FILE"
  else
    _state_check_config_sha
    log "resuming from existing state: $STATE_FILE"
  fi
  return 0
}

step_status() { state_get "STEP_$(_uc "$1")"; }

step_begin() {
  CURRENT_STEP="$1"
  state_set "STEP_$(_uc "$1")" RUNNING
  log "==== step begin: $1 ===="
  return 0
}

step_done() {
  state_set "STEP_$(_uc "$1")" DONE
  log "==== step done: $1 ===="
  [ "$CURRENT_STEP" = "$1" ] && CURRENT_STEP=""
  return 0
}

step_fail() {
  local name="$1" code="${2:-$EXIT_ERR}"
  state_set "STEP_$(_uc "$name")" FAILED
  log_err "==== step FAILED: $name (exit $code) ===="
  exit "$code"
}

#==============================================================================
# Strict mode + traps. The orchestrator opts in via install_runtime_guards so
# that merely loading this library (e.g. for a unit dry-call) has no effect.
#==============================================================================
_on_err() {
  local code="$1"
  if [ -n "${CURRENT_STEP:-}" ] && [ -n "$STATE_FILE" ]; then
    state_set "STEP_$(_uc "$CURRENT_STEP")" FAILED 2>/dev/null || true
  fi
  log_err "unexpected error (rc=$code)${CURRENT_STEP:+ during step $CURRENT_STEP}"
  exit "$code"
}

_on_exit() {
  local code="$?"
  _cleanup_temps
  return 0
}

install_runtime_guards() {
  set -o pipefail
  set -u
  set -e
  trap '_on_err $?' ERR
  trap '_on_exit' EXIT
  return 0
}

#==============================================================================
# Temp tracking + cleanup.
#==============================================================================
_track_local_temp()  { LOCAL_TEMP_ITEMS+=("$1"); }
_track_remote_temp() { REMOTE_TEMP_ITEMS+=("$1|$2"); }

_cleanup_temps() {
  local f item role rdir
  for f in "${LOCAL_TEMP_ITEMS[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done
  for item in "${REMOTE_TEMP_ITEMS[@]:-}"; do
    [ -n "$item" ] || continue
    role="${item%%|*}"
    rdir="${item#*|}"
    [ -n "$rdir" ] || continue
    _role_env "$role" 2>/dev/null || continue
    local so=(-p "$_R_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
    [ -n "$_R_SSH_KEY" ] && so+=(-i "$_R_SSH_KEY")
    ssh "${so[@]}" "${_R_SSH_USER}@${_R_HOST}" "rm -rf $(_shq "$rdir")" </dev/null 2>/dev/null || true
  done
  return 0
}

#==============================================================================
# Host execution. run_on runs an arbitrary command as the role's OS user,
# either locally (sudo / runuser / direct) or over ssh, always with a clean
# environment and stdin from /dev/null.
#==============================================================================
# _role_env ROLE -> sets _R_HOST _R_OS_USER _R_SSH_USER _R_SSH_KEY _R_SSH_PORT
_role_env() {
  local role="$1"
  case "$role" in
    SOURCE)
      _R_HOST="$(_getvar SOURCE_HOST)"; [ -n "$_R_HOST" ] || _R_HOST="localhost"
      _R_OS_USER="$(_getvar SOURCE_OS_USER)"; [ -n "$_R_OS_USER" ] || _R_OS_USER="oracle"
      _R_SSH_USER="$(_getvar SOURCE_SSH_USER)"; [ -n "$_R_SSH_USER" ] || _R_SSH_USER="oracle"
      _R_SSH_KEY="$(_getvar SOURCE_SSH_KEY)"
      _R_SSH_PORT="$(_getvar SOURCE_SSH_PORT)"; [ -n "$_R_SSH_PORT" ] || _R_SSH_PORT="22"
      ;;
    TARGET|STAGING)
      _R_HOST="$(_getvar TARGET_HOST)"; [ -n "$_R_HOST" ] || _R_HOST="localhost"
      _R_OS_USER="$(_getvar TARGET_OS_USER)"; [ -n "$_R_OS_USER" ] || _R_OS_USER="oracle"
      _R_SSH_USER="$(_getvar TARGET_SSH_USER)"; [ -n "$_R_SSH_USER" ] || _R_SSH_USER="oracle"
      _R_SSH_KEY="$(_getvar TARGET_SSH_KEY)"
      _R_SSH_PORT="$(_getvar TARGET_SSH_PORT)"; [ -n "$_R_SSH_PORT" ] || _R_SSH_PORT="22"
      ;;
    *)
      log_err "unknown role: $role"
      return "$EXIT_ERR"
      ;;
  esac
  return 0
}

_run_local() {
  local os_user="$1" home="$2" sid="$3" base="$4" cmd="$5"
  local path="$home/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local me; me="$(id -un 2>/dev/null || printf '')"
  if [ -n "$me" ] && [ "$me" = "$os_user" ]; then
    env -i HOME="${HOME:-/tmp}" ORACLE_BASE="$base" ORACLE_HOME="$home" \
        ORACLE_SID="$sid" PATH="$path" \
        bash --noprofile --norc -c "$cmd" </dev/null
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n -u "$os_user" env -i HOME="/home/$os_user" ORACLE_BASE="$base" \
         ORACLE_HOME="$home" ORACLE_SID="$sid" PATH="$path" \
         bash --noprofile --norc -c "$cmd" </dev/null; then
      return 0
    fi
    debug "sudo exec as $os_user failed; trying runuser"
  fi
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$os_user" -- env -i HOME="/home/$os_user" ORACLE_BASE="$base" \
        ORACLE_HOME="$home" ORACLE_SID="$sid" PATH="$path" \
        bash --noprofile --norc -c "$cmd" </dev/null
    return $?
  fi
  log_err "cannot execute as '$os_user' (not that user, and neither sudo nor runuser is available)"
  return "$EXIT_ERR"
}

# Resolve the SSH/scp authentication for a remote call. Prefers a key
# (non-interactive, BatchMode so it never hangs waiting for input); falls back
# to a password via `sshpass -e` (password read from the SSHPASS env var, never
# from argv) when no key is set and sshpass is installed. The password lives in
# the 0600 SECRETS_FILE as TRANSPORT_SSH_PASSWORD and is already redacted in all
# logs. Sets globals read by the callers:
#   _AUTH_MODE = key | password | none
#   _AUTH_KEY  = key path   (key mode)
#   _AUTH_PW   = password    (password mode)
_resolve_ssh_auth() {
  local key="$1"
  _AUTH_KEY=""; _AUTH_PW=""; _AUTH_MODE="none"
  if [ -n "$key" ]; then
    _AUTH_KEY="$key"; _AUTH_MODE="key"; return 0
  fi
  local pw; pw="$(_getvar TRANSPORT_SSH_PASSWORD)"
  if [ -n "$pw" ] && command -v sshpass >/dev/null 2>&1; then
    _AUTH_PW="$pw"; _AUTH_MODE="password"; return 0
  fi
  return 0
}

_run_remote() {
  local host="$1" ssh_user="$2" ssh_key="$3" ssh_port="$4" home="$5" sid="$6" base="$7" cmd="$8"
  local path="$home/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local ssh_opts=(-p "$ssh_port" -o StrictHostKeyChecking=accept-new)
  local -a auth_pfx=()
  _resolve_ssh_auth "$ssh_key"
  case "$_AUTH_MODE" in
    key)      ssh_opts+=(-o BatchMode=yes -i "$_AUTH_KEY") ;;
    password) auth_pfx=(sshpass -e); ssh_opts+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password) ;;
    *)        ssh_opts+=(-o BatchMode=yes) ;;
  esac
  local remote
  remote="env ORACLE_BASE=$(_shq "$base") ORACLE_HOME=$(_shq "$home") ORACLE_SID=$(_shq "$sid") PATH=$(_shq "$path") bash --noprofile --norc -c $(_shq "$cmd")"
  SSHPASS="$_AUTH_PW" ${auth_pfx[@]+"${auth_pfx[@]}"} ssh "${ssh_opts[@]}" "${ssh_user}@${host}" "$remote" </dev/null
}

run_on() {
  local role="$1" home="$2" sid="$3" base="$4" cmd="$5"
  _role_env "$role" || return $?
  if host_is_local "$_R_HOST"; then
    _run_local "$_R_OS_USER" "$home" "$sid" "$base" "$cmd"
  else
    _run_remote "$_R_HOST" "$_R_SSH_USER" "$_R_SSH_KEY" "$_R_SSH_PORT" "$home" "$sid" "$base" "$cmd"
  fi
}

# Stage a local file onto a remote per-run dir; echoes the remote path. The
# remote dir is tracked for removal by the EXIT trap.
_stage_remote() {
  local role="$1" local_path="$2"
  _role_env "$role" || return $?
  local rdir; rdir="/tmp/mig_stage_$(_getvar MIGRATION_ID)_$$"
  local ssh_opts=(-p "$_R_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  local scp_opts=(-P "$_R_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  if [ -n "$_R_SSH_KEY" ]; then ssh_opts+=(-i "$_R_SSH_KEY"); scp_opts+=(-i "$_R_SSH_KEY"); fi
  if ! ssh "${ssh_opts[@]}" "${_R_SSH_USER}@${_R_HOST}" "mkdir -p $(_shq "$rdir") && chmod 700 $(_shq "$rdir")" </dev/null; then
    log_err "remote mkdir failed on $_R_HOST"
    return "$EXIT_ERR"
  fi
  local bn; bn="$(basename "$local_path")"
  if ! scp "${scp_opts[@]}" "$local_path" "${_R_SSH_USER}@${_R_HOST}:${rdir}/${bn}" >/dev/null; then
    log_err "scp to $_R_HOST failed"
    return "$EXIT_ERR"
  fi
  _track_remote_temp "$role" "$rdir"
  printf '%s/%s' "$rdir" "$bn"
}

#==============================================================================
# Template rendering (pure bash, allowlist-only).
#==============================================================================
render_vars_reset() { RENDER_VARS=(); }
render_vars_put()   { RENDER_VARS["$1"]="$2"; }
render_vars_add_config() {
  local n
  for n in "$@"; do RENDER_VARS["$n"]="$(_getvar "$n")"; done
}
_render_var_allowed() {
  local n="$1"
  [ "${RENDER_VARS[$n]+SET}" = "SET" ]
}

# render_template TMPL OUT: copies TMPL to OUT substituting ${NAME} only for
# NAME present in RENDER_VARS. Any other ${TOKEN} aborts (exit 2) naming the
# template, line and token.
render_template() {
  local tmpl="$1" out="$2"
  [ -f "$tmpl" ] || { log_err "template not found: $tmpl"; exit "$EXIT_CONFIG"; }
  local lineno=0 line result token name needle val
  : >"$out"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    result="$line"
    while printf '%s' "$result" | grep -q '[$]{'; do
      token="${result#*\$\{}"
      token="${token%%\}*}"
      name="$token"
      if [ -z "$name" ]; then
        log_err "template $tmpl line $lineno: empty \${} token"
        exit "$EXIT_CONFIG"
      fi
      if _render_var_allowed "$name"; then
        val="${RENDER_VARS[$name]}"
        needle='${'"$name"'}'
        result="${result//"$needle"/$val}"
      else
        log_err "template $tmpl line $lineno: unknown token \${$name} (not in the render allowlist)"
        exit "$EXIT_CONFIG"
      fi
    done
    printf '%s\n' "$result" >>"$out"
  done < "$tmpl"
  return 0
}

# Ensure a rendered sqlplus/rman script ends with an effective "exit". Trailing
# blank lines and comments (--, #, REM) are ignored. Appends "exit" + warns if
# the last meaningful statement is not exit/quit.
assert_ends_with_exit() {
  local f="$1" line t last="" low
  [ -f "$f" ] || { log_err "assert_ends_with_exit: file not found: $f"; return "$EXIT_ERR"; }
  while IFS= read -r line || [ -n "$line" ]; do
    t="$(_trim "$line")"
    case "$t" in
      ''|'--'*|'#'*) continue ;;
      REM|REM\ *|rem|rem\ *|Rem|Rem\ *) continue ;;
    esac
    last="$t"
  done < "$f"
  low="$(_lc "$last")"
  case "$low" in
    exit|exit\;|quit|quit\;) return 0 ;;
    *)
      printf 'exit\n' >>"$f"
      debug "appended missing 'exit' to $(basename "$f")"
      return 0
      ;;
  esac
}

#==============================================================================
# sqlplus / rman wrappers. Every emitted script ends with "exit"; run_sql
# prepends "whenever sqlerror exit failure" unless the body manages its own.
#==============================================================================
_new_script_path() {
  local role="$1" name="$2" ext="$3" ts p
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -n "$RUN_RENDER_DIR" ] && [ -d "$RUN_RENDER_DIR" ]; then
    printf '%s/%s_%s_%s.%s' "$RUN_RENDER_DIR" "$role" "$name" "$ts" "$ext"
  else
    p="$(mktemp "${TMPDIR:-/tmp}/mig_${role}_${name}_XXXXXX" 2>/dev/null || printf '%s/mig_%s_%s_%s.%s' "${TMPDIR:-/tmp}" "$role" "$name" "$$" "$ext")"
    _track_local_temp "$p"
    printf '%s' "$p"
  fi
}

# Stream a command's output live to the main + debug logs.
_tee_logs() {
  if [ -n "$LOG_MAIN" ] && [ -n "$LOG_DEBUG" ]; then
    tee -a "$LOG_MAIN" "$LOG_DEBUG"
  elif [ -n "$LOG_DEBUG" ]; then
    tee -a "$LOG_DEBUG"
  else
    cat
  fi
}

# _tool_exec ROLE HOME SID BASE TOOL SCRIPTFILE
# =============================================================================
# NET-mode SOURCE connection (Oracle Net; no SSH, no OS authentication).
#
# When SOURCE_CONN_MODE=net, the source database is reached over Oracle Net with
# a configured user/password/role. The sqlplus/rman CLIENTS run on THIS
# (orchestrator) host using the 19c client in TARGET_STAGING_HOME; only the
# server-side backup I/O happens on the source, writing to the shared mount.
#
# The password is placed ONLY inside a 0600 wrapper script (as a "connect" line),
# never on a command line, so it never appears in the process list. The wrapper
# is tracked for cleanup by the EXIT trap.
# =============================================================================
_source_net() { [ "$(_getvar SOURCE_CONN_MODE)" = "net" ]; }

_source_descriptor() {
  local cs; cs="$(_getvar SOURCE_CONNECT_STRING)"
  if [ -n "$cs" ]; then printf '%s' "$cs"; return 0; fi
  local h p s
  h="$(_getvar SOURCE_DB_HOST)"; p="$(_getvar SOURCE_DB_PORT)"; [ -n "$p" ] || p="1521"
  s="$(_getvar SOURCE_DB_SERVICE)"
  printf '//%s:%s/%s' "$h" "$p" "$s"
}

# sqlplus connect identifier (optionally with a role clause).
_source_sql_connect() {
  local u pw role conn
  u="$(_getvar SOURCE_DB_USER)"; pw="$(_getvar SOURCE_DB_PASSWORD)"; role="$(_getvar SOURCE_DB_ROLE)"
  conn="${u}/${pw}@$(_source_descriptor)"
  case "$role" in
    sysdba)    conn="$conn as sysdba" ;;
    sysbackup) conn="$conn as sysbackup" ;;
  esac
  printf '%s' "$conn"
}

# rman target connect identifier WITHOUT the role (role is applied as a quoted
# "... AS <role>" by the caller, which RMAN requires).
_source_rman_connect() {
  local u pw role
  u="$(_getvar SOURCE_DB_USER)"; pw="$(_getvar SOURCE_DB_PASSWORD)"
  role="$(_getvar SOURCE_RMAN_ROLE)"; [ -n "$role" ] || role="sysbackup"
  printf '%s/%s@%s as %s' "$u" "$pw" "$(_source_descriptor)" "$role"
}

# Execute a rendered sqlplus/rman SCRIPT against the net source. capture=yes
# echoes stdout only (for value capture); otherwise output is tee'd to the logs.
_source_net_exec() {
  local tool="$1" script="$2" capture="${3:-no}"
  local chome base wrap invoke
  chome="$(_getvar TARGET_STAGING_HOME)"; base="$(_getvar TARGET_ORACLE_BASE)"
  wrap="${script}.net"
  ( umask 077
    case "$tool" in
      sqlplus) { printf 'connect %s\n' "$(_source_sql_connect)"; cat "$script"; } >"$wrap" ;;
      rman)    { printf 'connect target "%s";\n' "$(_source_rman_connect)"; cat "$script"; } >"$wrap" ;;
    esac )
  chmod 600 "$wrap" 2>/dev/null || true
  LOCAL_TEMP_ITEMS+=("$wrap")
  case "$tool" in
    sqlplus) invoke="sqlplus -s -L /nolog @$(_shq "$wrap")" ;;
    rman)    invoke="rman @$(_shq "$wrap")" ;;
    *) log_err "unknown tool: $tool"; return "$EXIT_ERR" ;;
  esac
  if [ "$capture" = "yes" ]; then
    _run_local "$(_getvar TARGET_OS_USER)" "$chome" "NETSRC" "$base" "$invoke" 2>/dev/null
    return $?
  fi
  _run_local "$(_getvar TARGET_OS_USER)" "$chome" "NETSRC" "$base" "$invoke" 2>&1 | _tee_logs
  return "${PIPESTATUS[0]}"
}

# Run a plain shell command associated with the SOURCE role. In os mode this
# runs on the source host (local or SSH). In net mode there is no OS access to
# the source, so it runs on THIS (orchestrator) host - where the shared backup
# mount is visible - against the same path the source wrote to.
_source_fs_exec() {
  local cmd="$1"
  if _source_net; then
    _run_local "$(_getvar TARGET_OS_USER)" "$(_getvar TARGET_STAGING_HOME)" "NETSRC" \
      "$(_getvar TARGET_ORACLE_BASE)" "$cmd"
    return $?
  fi
  run_on SOURCE "$(_getvar SOURCE_ORACLE_HOME)" "$(_getvar SOURCE_ORACLE_SID)" \
    "$(_getvar SOURCE_ORACLE_BASE)" "$cmd"
}

_tool_exec() {
  local role="$1" home="$2" sid="$3" base="$4" tool="$5" script="$6"
  # NET-mode source: run the client locally and connect over Oracle Net.
  if [ "$role" = "SOURCE" ] && _source_net; then
    debug "_tool_exec net-source $tool script=$script"
    _source_net_exec "$tool" "$script" no
    return $?
  fi
  _role_env "$role" || return $?
  local runpath="$script"
  if ! host_is_local "$_R_HOST"; then
    runpath="$(_stage_remote "$role" "$script")" || return $?
  fi
  local invoke
  case "$tool" in
    sqlplus) invoke="sqlplus -s -L '/ as sysdba' @$(_shq "$runpath")" ;;
    rman)    invoke="rman target / @$(_shq "$runpath")" ;;
    *) log_err "unknown tool: $tool"; return "$EXIT_ERR" ;;
  esac
  run_on "$role" "$home" "$sid" "$base" "$invoke" 2>&1 | _tee_logs
  return "${PIPESTATUS[0]}"
}

# run_sql ROLE HOME SID BASE SQLBODY [name]
run_sql() {
  local role="$1" home="$2" sid="$3" base="$4" body="$5" name="${6:-sql}"
  local script; script="$(_new_script_path "$role" "$name" sql)"
  {
    if ! printf '%s' "$body" | grep -qiE 'whenever[[:space:]]+sqlerror'; then
      printf 'whenever sqlerror exit failure\n'
    fi
    printf '%s\n' "$body"
  } >"$script"
  assert_ends_with_exit "$script"
  debug "run_sql ($role) script=$script"
  _tool_exec "$role" "$home" "$sid" "$base" sqlplus "$script"
}

# run_rman ROLE HOME SID BASE RMANBODY [name]
run_rman() {
  local role="$1" home="$2" sid="$3" base="$4" body="$5" name="${6:-rman}"
  local script; script="$(_new_script_path "$role" "$name" rman)"
  printf '%s\n' "$body" >"$script"
  assert_ends_with_exit "$script"
  debug "run_rman ($role) script=$script"
  _tool_exec "$role" "$home" "$sid" "$base" rman "$script"
}

# run_sql_capture ROLE HOME SID BASE SQLBODY -> echoes the last non-empty line.
run_sql_capture() {
  local role="$1" home="$2" sid="$3" base="$4" body="$5"
  local script; script="$(_new_script_path "$role" capture sql)"
  {
    printf 'set heading off feedback off pagesize 0 verify off echo off\n'
    printf '%s\n' "$body"
  } >"$script"
  assert_ends_with_exit "$script"
  local out
  if [ "$role" = "SOURCE" ] && _source_net; then
    out="$(_source_net_exec sqlplus "$script" yes)"
    printf '%s' "$out" | sed '/^[[:space:]]*$/d' | tail -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    return 0
  fi
  _role_env "$role" || return $?
  local runpath="$script"
  if ! host_is_local "$_R_HOST"; then
    runpath="$(_stage_remote "$role" "$script")" || return $?
  fi
  out="$(run_on "$role" "$home" "$sid" "$base" "sqlplus -s -L '/ as sysdba' @$(_shq "$runpath")" 2>/dev/null)"
  printf '%s' "$out" | sed '/^[[:space:]]*$/d' | tail -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

#==============================================================================
# Artifact transfer. Dispatches scp / rsync / shared, with sha256 verification
# and TRANSPORT_RETRIES attempts. Local-to-local degrades to cp/rsync; shared
# is verify-only (files are already visible through the shared mount).
#==============================================================================
_sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" | awk '{print $1}';
  else cksum "$f" | awk '{print $1}'; fi
}

_transfer_local() {
  local src="$1" dst="$2"
  mkdir -p "$dst" || return "$EXIT_TRANSFER"
  if command -v rsync >/dev/null 2>&1; then
    log "[transfer] exec: rsync -a $src/ $dst/"
    rsync -a "$src/" "$dst/"
  else
    log "[transfer] exec: cp -pR $src/. $dst/"
    cp -pR "$src/." "$dst/"
  fi
}

_transfer_scp() {
  local src="$1" dst="$2"
  # SOURCE host -> TARGET host. Both-local is handled by transfer_artifacts.
  _role_env TARGET || return $?
  local scp_opts=(-P "$_R_SSH_PORT" -o StrictHostKeyChecking=accept-new -r)
  [ "$(_getvar TRANSPORT_COMPRESS)" = "true" ] && scp_opts+=(-C)
  local key; key="$(_getvar TRANSPORT_SSH_KEY)"; [ -n "$key" ] || key="$_R_SSH_KEY"
  local -a auth_pfx=()
  _resolve_ssh_auth "$key"
  case "$_AUTH_MODE" in
    key)      scp_opts+=(-o BatchMode=yes -i "$_AUTH_KEY") ;;
    password) auth_pfx=(sshpass -e); scp_opts+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password) ;;
    *)        scp_opts+=(-o BatchMode=yes) ;;
  esac
  run_on TARGET "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_CDB_SID)" "$(_getvar TARGET_ORACLE_BASE)" "mkdir -p $(_shq "$dst")" || return "$EXIT_TRANSFER"
  local _pfxlog=""; [ "${#auth_pfx[@]}" -gt 0 ] && _pfxlog="${auth_pfx[*]} "
  log "[transfer] exec: ${_pfxlog}scp ${scp_opts[*]} ${src}/* ${_R_SSH_USER}@${_R_HOST}:${dst}/"
  SSHPASS="$_AUTH_PW" ${auth_pfx[@]+"${auth_pfx[@]}"} scp "${scp_opts[@]}" "$src"/* "${_R_SSH_USER}@${_R_HOST}:${dst}/"
}

_transfer_rsync() {
  local src="$1" dst="$2"
  _role_env TARGET || return $?
  local key; key="$(_getvar TRANSPORT_SSH_KEY)"; [ -n "$key" ] || key="$_R_SSH_KEY"
  local -a auth_pfx=()
  _resolve_ssh_auth "$key"
  local rsh="ssh -p $_R_SSH_PORT -o StrictHostKeyChecking=accept-new"
  case "$_AUTH_MODE" in
    key)      rsh="$rsh -o BatchMode=yes -i $_AUTH_KEY" ;;
    password) auth_pfx=(sshpass -e); rsh="$rsh -o PubkeyAuthentication=no -o PreferredAuthentications=password" ;;
    *)        rsh="$rsh -o BatchMode=yes" ;;
  esac
  local ropts=(-a)
  [ "$(_getvar TRANSPORT_COMPRESS)" = "true" ] && ropts+=(-z)
  local bw; bw="$(_getvar TRANSPORT_BANDWIDTH_KBPS)"
  [ -n "$bw" ] && [ "$bw" != "0" ] && ropts+=(--bwlimit="$bw")
  local _pfxlog=""; [ "${#auth_pfx[@]}" -gt 0 ] && _pfxlog="${auth_pfx[*]} "
  log "[transfer] exec: ${_pfxlog}rsync ${ropts[*]} -e '${rsh}' ${src}/ ${_R_SSH_USER}@${_R_HOST}:${dst}/"
  SSHPASS="$_AUTH_PW" ${auth_pfx[@]+"${auth_pfx[@]}"} rsync "${ropts[@]}" -e "$rsh" "$src/" "${_R_SSH_USER}@${_R_HOST}:${dst}/"
}

_transfer_shared() {
  local src="$1" dst="$2"
  local shared; shared="$(_getvar TRANSPORT_SHARED_PATH)"
  [ -n "$shared" ] || { log_err "TRANSPORT_SHARED_PATH not set for shared transfer"; return "$EXIT_CONFIG"; }
  # verify-only: confirm the shared path is populated; no copy performed
  [ -d "$shared" ] || { log_err "shared path not present: $shared"; return "$EXIT_TRANSFER"; }
  log "[transfer] method=shared (verify-only, no copy); artifacts expected at shared path: $shared"
  return 0
}

# After a successful transfer, print where the artifacts landed: the absolute
# destination directory, the host that holds it, each file with its byte size,
# and a count + total summary. The listing runs on whichever host owns the
# destination (local, or TARGET over SSH) via run_on, so it is accurate for
# same-host, remote, and shared transfers alike. Best-effort: never fails the
# step.
_transfer_report_dest() {
  local dst="$1"
  _role_env TARGET || return 0
  log "[transfer] artifacts landed at: ${dst}  (host: ${_R_HOST})"
  local lcmd
  lcmd="d=$(_shq "$dst"); n=0; tot=0; for f in \"\$d\"/*; do [ -f \"\$f\" ] || continue; s=\$(stat -c %s \"\$f\" 2>/dev/null || stat -f %z \"\$f\" 2>/dev/null); n=\$((n+1)); tot=\$((tot+s)); printf '    %14s  %s\n' \"\$s\" \"\$f\"; done; printf '    ---- %d file(s), %d bytes total ----\n' \"\$n\" \"\$tot\""
  run_on TARGET "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_CDB_SID)" "$(_getvar TARGET_ORACLE_BASE)" "$lcmd" 2>/dev/null || true
  return 0
}

transfer_artifacts() {
  local src="$1" dst="$2"
  local method; method="$(_getvar TRANSPORT_METHOD)"; [ -n "$method" ] || method="scp"
  local retries; retries="$(_getvar TRANSPORT_RETRIES)"; _is_int "$retries" || retries=2
  local both_local="false"
  if host_is_local "$(_getvar SOURCE_HOST)" && host_is_local "$(_getvar TARGET_HOST)"; then
    both_local="true"
  fi
  # Force the over-the-wire path (scp/rsync) even when both endpoints resolve to
  # this host - used to exercise the remote transfer on a single box. Never
  # applies to 'shared', which performs no copy.
  if [ "$(_getvar FORCE_REMOTE_TRANSPORT)" = "true" ] && [ "$method" != "shared" ]; then
    both_local="false"
    log "FORCE_REMOTE_TRANSPORT=true: using '$method' over SSH even though hosts are local"
  fi
  local attempt=0 rc=1
  while [ "$attempt" -le "$retries" ]; do
    attempt=$((attempt + 1))
    if [ "$method" = "shared" ]; then
      _transfer_shared "$src" "$dst"; rc=$?
    elif [ "$both_local" = "true" ]; then
      _transfer_local "$src" "$dst"; rc=$?
    else
      case "$method" in
        scp)   _transfer_scp "$src" "$dst"; rc=$? ;;
        rsync) _transfer_rsync "$src" "$dst"; rc=$? ;;
        *) log_err "unknown TRANSPORT_METHOD: $method"; return "$EXIT_CONFIG" ;;
      esac
    fi
    if [ "$rc" -eq 0 ]; then
      local resolved
      if [ "$method" = "shared" ]; then
        resolved="shared (verify-only, no copy)"
      elif [ "$both_local" = "true" ]; then
        resolved="local-cp (same host, no SSH)"
      else
        resolved="$method (over SSH)"
      fi
      log "transfer attempt $attempt succeeded (method=$resolved)"
      _transfer_report_dest "$dst"
      return 0
    fi
    log_warn "transfer attempt $attempt failed (rc=$rc); retrying"
    sleep 3
  done
  log_err "transfer failed after $attempt attempt(s)"
  return "$EXIT_TRANSFER"
}

#==============================================================================
# Free-space check. df -Pk the filesystem that holds DEST (walking up to the
# nearest existing parent) and compare available bytes against a byte estimate.
#==============================================================================
check_free_space() {
  local dest="$1" need="$2" label="${3:-destination}"
  local chk="$dest"
  while [ ! -e "$chk" ] && [ "$chk" != "/" ] && [ -n "$chk" ]; do
    chk="$(dirname "$chk")"
  done
  local avail_kb avail
  avail_kb="$(df -Pk "$chk" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -z "$avail_kb" ]; then
    log_warn "cannot stat filesystem for $dest; skipping free-space check"
    return 0
  fi
  avail=$((avail_kb * 1024))
  if [ "$avail" -lt "$need" ]; then
    local short=$((need - avail))
    log_err "insufficient free space on $label ($dest): need $need bytes, have $avail, short $short"
    exit "$EXIT_PREFLIGHT"
  fi
  log "free space ok on $label ($dest): have $avail bytes, need $need"
  return 0
}

#==============================================================================
# UNIAUD remediation: MOVE (never delete) the unified-audit .bin spillover
# files out of $ORACLE_BASE/audit/$SID into the quarantine dir. Idempotent.
#==============================================================================
remediate_uniaud() {
  local role="$1" home="$2" sid="$3" base="$4"
  local dest; dest="$(_getvar BEHAVIOR_AUDIT_BACKUP_DIR)"
  [ -n "$dest" ] || dest="$base/audit_quarantine"
  dest="$dest/$sid"
  local srcdir="$base/audit/$sid"
  local cmd
  cmd="src=$(_shq "$srcdir"); dst=$(_shq "$dest"); if ls \"\$src\"/*.bin >/dev/null 2>&1; then mkdir -p \"\$dst\" && mv -f \"\$src\"/*.bin \"\$dst\"/ && echo moved; else echo none; fi"
  log_role "$role" "UNIAUD remediation: moving *.bin from $srcdir to $dest (move, never delete)"
  run_on "$role" "$home" "$sid" "$base" "$cmd"
}

#==============================================================================
# nid rename, judged by follow-up state. nid returns non-zero even on success,
# so run it under a scoped "set +e", keep the rc for the log only, then judge
# by a follow-up startup mount + v$database.name check.
#==============================================================================
run_nid_judge_by_state() {
  local role="$1" home="$2" sid="$3" base="$4" expected="$5" pfile="$6"
  log_role "$role" "running nid to rename DB to '$expected' (judged by follow-up state, not by nid rc)"
  local nidcmd; nidcmd="nid TARGET=/ DBNAME=$(_shq "$expected") LOGFILE=/dev/stdout; echo \"nid-rc=\$?\""
  local saved_e="off"
  case "$-" in *e*) saved_e="on" ;; esac
  set +e
  run_on "$role" "$home" "$sid" "$base" "$nidcmd" 2>&1 | _tee_logs
  [ "$saved_e" = "on" ] && set -e

  run_sql "$role" "$home" "$sid" "$base" "startup mount pfile='$pfile';" "nid_mount" \
    || log_warn "startup mount after nid returned non-zero"

  local actual want
  actual="$(run_sql_capture "$role" "$home" "$sid" "$base" "select lower(name) from v\$database;")"
  want="$(_lc "$expected")"
  if [ "$actual" = "$want" ]; then
    log_role "$role" "nid verified: v\$database.name='$actual'"
    return 0
  fi
  log_err "nid verification failed: v\$database.name='$actual' (expected '$want')"
  return "$EXIT_RESTORE"
}
