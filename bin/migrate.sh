#!/usr/bin/env bash
###############################################################################
# bin/migrate.sh
#
# Orchestrator for the Oracle 19c non-CDB -> 26ai PDB migration toolkit.
#
# Responsibilities (and ONLY these - it holds no Oracle logic):
#   * parse CLI flags (--config required; --from/--to/--only/--dry-run/--yes/
#     --force);
#   * assert bash >= 4.2;
#   * load + validate + derive config, then initialise the run dir and state;
#   * print the resolved plan;
#   * build the ordered run list (default: resume from the first non-DONE step);
#   * dispatch each phase, which (in --dry-run) renders all templates and prints
#     the plan WITHOUT contacting any database or host.
#
# Exit codes (see lib/common.sh): 0 ok, 1 usage, 2 config, 3 preflight,
# 4 collision/step, 5 transfer/verify, 6 restore, 10 upgrade.
###############################################################################

set -o pipefail

_MIG_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MIG_LIB_DIR="$(cd "$_MIG_BIN_DIR/.." && pwd)/lib"

# shellcheck source=../lib/version.sh
. "$_MIG_LIB_DIR/version.sh"
# shellcheck source=../lib/common.sh
. "$_MIG_LIB_DIR/common.sh"

assert_bash_version

#==============================================================================
# CLI flags (globals read by the phase scripts).
#==============================================================================
CONFIG_FILE=""
OPT_FROM=""
OPT_TO=""
OPT_ONLY=""
DRY_RUN="false"
FORCE="false"
# ASSUME_YES is consumed by common.sh::confirm; default comes from there.
ASSUME_YES="${ASSUME_YES:-false}"

ALL_STEPS=(preflight source_backup transfer target_restore autoupgrade verify)
RUN_LIST=()

usage() {
  cat <<USAGE
Usage: migrate.sh --config <file> [options]

  --config <file>     Migration config (required).
  --from <step>       Run from <step> through the last step.
  --to <step>         Run through <step> (optionally combined with --from).
  --only <s1,s2,...>  Run exactly the listed steps.
  --dry-run           Load/validate/derive config, print the plan, render every
                      template; contact NO database or host.
  --yes               Bypass interactive confirmation prompts.
  --force             Authoritative gate to drop a colliding PDB (still prompts
                      unless --yes).
  -h, --help          Show this help.

Steps (fixed order): ${ALL_STEPS[*]}
USAGE
  exit "${1:-1}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG_FILE="${2:-}"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#*=}"; shift ;;
    --from)     OPT_FROM="${2:-}"; shift 2 ;;
    --from=*)   OPT_FROM="${1#*=}"; shift ;;
    --to)       OPT_TO="${2:-}"; shift 2 ;;
    --to=*)     OPT_TO="${1#*=}"; shift ;;
    --only)     OPT_ONLY="${2:-}"; shift 2 ;;
    --only=*)   OPT_ONLY="${1#*=}"; shift ;;
    --dry-run)  DRY_RUN="true"; shift ;;
    --yes)      ASSUME_YES="true"; shift ;;
    --force)    FORCE="true"; shift ;;
    -h|--help)  usage 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage 1 ;;
  esac
done

[ -n "$CONFIG_FILE" ] || { printf 'ERROR: --config is required\n' >&2; usage 1; }

#==============================================================================
# Shared runtime helpers used by every sourced phase script.
#==============================================================================
TEMPLATES_DIR="$TOOLKIT_ROOT/templates"

# ---- manifest.env (KEY=value, parsed not sourced, atomic writes) -----------
manifest_file() {
  local base mid
  base="$(_getvar BEHAVIOR_LOG_BASE_DIR)"; [ -n "$base" ] || base="$TOOLKIT_ROOT/run"
  mid="$(_getvar MIGRATION_ID)"
  printf '%s/%s/manifest.env' "$base" "$mid"
}

manifest_exists() { [ -f "$(manifest_file)" ]; }

manifest_get() {
  local key="$1" f line val=""
  f="$(manifest_file)"
  [ -f "$f" ] || { printf ''; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key="*) val="${line#*=}" ;; esac
  done < "$f"
  printf '%s' "$val"
}

manifest_put() {
  local key="$1" value="$2" f tmp found=0 line
  f="$(manifest_file)"
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"; : >"$tmp"
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*) printf '%s=%s\n' "$key" "$value" >>"$tmp"; found=1 ;;
        *) printf '%s\n' "$line" >>"$tmp" ;;
      esac
    done < "$f"
  fi
  [ "$found" -eq 0 ] && printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv -f "$tmp" "$f"
}

# ---- template rendering into the per-run rendered/ tree ---------------------
# mig_render  TMPL_REL  OUT_ABS         (plain config/pfile template)
mig_render() {
  render_template "$TEMPLATES_DIR/$1" "$2"
}
# mig_render_sql  TMPL_BASENAME  OUT_BASENAME   (under templates/sql + rendered/sql)
mig_render_sql() {
  mkdir -p "$RUN_RENDER_DIR/sql"
  render_template "$TEMPLATES_DIR/sql/$1" "$RUN_RENDER_DIR/sql/$2"
  assert_ends_with_exit "$RUN_RENDER_DIR/sql/$2"
  printf '%s' "$RUN_RENDER_DIR/sql/$2"
}
# mig_render_tool  TMPL_REL  OUT_ABS   (rman template: ensure trailing exit)
mig_render_tool() {
  render_template "$TEMPLATES_DIR/$1" "$2"
  assert_ends_with_exit "$2"
}

dryrun() { [ "$DRY_RUN" = "true" ]; }

#==============================================================================
# Config pipeline (exact order mandated by lib/common.sh).
#==============================================================================
load_config "$CONFIG_FILE"
load_secrets
apply_config_defaults
validate_config
resolve_derivations
init_run_dirs
state_init

print_resolved_plan
if [ "$FORCE" = "true" ]; then
  plan "  PDB collision policy    = DROP colliding PDB (--force) after confirm"
else
  plan "  PDB collision policy    = FAIL if target PDB exists (pass --force to drop)"
fi
plan "  dry-run                 = $DRY_RUN"

#==============================================================================
# Load the phase scripts (each defines a step_<name> function).
#==============================================================================
for _p in 00_preflight 10_source_backup 20_transfer 30_target_restore 40_autoupgrade 50_verify; do
  # shellcheck source=/dev/null
  . "$_MIG_BIN_DIR/$_p.sh"
done

#==============================================================================
# Run-list construction.
#==============================================================================
_step_index() {
  local want="$1" i
  for i in "${!ALL_STEPS[@]}"; do
    [ "${ALL_STEPS[$i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  printf '%s' "-1"
}

build_run_list() {
  RUN_LIST=()
  if [ -n "$OPT_ONLY" ]; then
    local s
    local -a only_list
    IFS=',' read -r -a only_list <<< "$OPT_ONLY"
    for s in "${only_list[@]}"; do
      [ "$(_step_index "$s")" -ge 0 ] || { log_err "unknown step in --only: $s"; exit "$EXIT_ERR"; }
      RUN_LIST+=("$s")
    done
    return 0
  fi

  local start_i=0 end_i=$(( ${#ALL_STEPS[@]} - 1 )) i name
  if [ -n "$OPT_FROM" ]; then
    start_i="$(_step_index "$OPT_FROM")"
    [ "$start_i" -ge 0 ] || { log_err "unknown step in --from: $OPT_FROM"; exit "$EXIT_ERR"; }
  fi
  if [ -n "$OPT_TO" ]; then
    end_i="$(_step_index "$OPT_TO")"
    [ "$end_i" -ge 0 ] || { log_err "unknown step in --to: $OPT_TO"; exit "$EXIT_ERR"; }
  fi
  [ "$start_i" -le "$end_i" ] || { log_err "--from step comes after --to step"; exit "$EXIT_ERR"; }

  local resume="false"
  [ -z "$OPT_FROM" ] && [ -z "$OPT_TO" ] && resume="true"

  for (( i=start_i; i<=end_i; i++ )); do
    name="${ALL_STEPS[$i]}"
    if [ "$resume" = "true" ] && [ "$(step_status "$name")" = "DONE" ]; then
      log "skip step '$name' (already DONE); use --only/--from to force"
      continue
    fi
    RUN_LIST+=("$name")
  done
}

build_run_list

if [ "${#RUN_LIST[@]}" -eq 0 ]; then
  plan "nothing to do: all requested steps are already DONE"
  exit "$EXIT_OK"
fi
plan "  steps to run            = ${RUN_LIST[*]}"

#==============================================================================
# Dispatch. Strict-mode guards are installed only for a real run (a dry-run
# stays lenient so rendering/plan code can never trip set -e).
#==============================================================================
dryrun || install_runtime_guards

dispatch_step() {
  case "$1" in
    preflight)      step_preflight ;;
    source_backup)  step_source_backup ;;
    transfer)       step_transfer ;;
    target_restore) step_target_restore ;;
    autoupgrade)    step_autoupgrade ;;
    verify)         step_verify ;;
    *) log_err "no dispatcher for step '$1'"; exit "$EXIT_ERR" ;;
  esac
}

for _step in "${RUN_LIST[@]}"; do
  dispatch_step "$_step"
done

if dryrun; then
  plan "dry-run complete: plan printed and all templates rendered under:"
  plan "  $RUN_RENDER_DIR"
else
  log "migration run complete for steps: ${RUN_LIST[*]}"
fi
exit "$EXIT_OK"
