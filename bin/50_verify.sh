#!/usr/bin/env bash
###############################################################################
# bin/50_verify.sh  ->  step_verify
#
# Post-migration verification inside the new PDB:
#   * open read write + save state (ORA-65019 "already open" tolerated);
#   * plug-in violations: FAIL (exit 5) only on an unresolved ERROR; a
#     Traditional Audit WARNING/PENDING is benign and only reported;
#   * dba_registry: FAIL (exit 5) if CATALOG or CATPROC is not VALID or its
#     version_full does not begin with TARGET_EXPECTED_VERSION;
#   * data-integrity proof inside the PDB vs manifest PROOF_SOURCE_VALUE
#     (exact) or > 0 (nonzero); skipped with a warning if the proof query is
#     empty.
#
# Exit code 5 denotes a verification failure. --dry-run renders the verify SQL
# and prints the plan.
###############################################################################

if [ -z "${_MIG_COMMON_SH_LOADED:-}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  . "$_d/lib/version.sh"
  . "$_d/lib/common.sh"
fi

# Verification-failure exit code (5), per design section 5 / FEAT-002.
_VERIFY_FAIL=5

_vr_render() {
  render_vars_reset
  render_vars_add_config TARGET_PDB_NAME
  mig_render_sql pdb_open_savestate.sql.tmpl pdb_open_savestate.sql >/dev/null

  render_vars_reset
  render_vars_add_config TARGET_PDB_NAME
  mig_render_sql pdb_violations.sql.tmpl pdb_violations.sql >/dev/null

  render_vars_reset
  render_vars_add_config TARGET_PDB_NAME
  mig_render_sql pdb_registry.sql.tmpl pdb_registry.sql >/dev/null
}

_vr_cdb() { printf '%s' "$(_getvar TARGET_26AI_HOME)"; }

_vr_open_savestate() {
  run_sql TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "$(cat "$RUN_RENDER_DIR/sql/pdb_open_savestate.sql")" pdb_open_savestate
}

_vr_violations() {
  local out line t s rc=0
  out="$(_vr_capture_multi "$RUN_RENDER_DIR/sql/pdb_violations.sql")"
  if [ -z "$out" ]; then
    log_role TARGET "no unresolved plug-in violations"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    t="${line%%|*}"
    s="${line#*|}"; s="${s%%|*}"
    case "$t" in
      ERROR)
        log_err "unresolved plug-in violation (ERROR): $line"
        rc="$_VERIFY_FAIL"
        ;;
      *)
        log_role TARGET "benign plug-in violation ($t/$s): $line"
        ;;
    esac
  done <<EOF
$out
EOF
  return "$rc"
}

# Run a rendered SQL file in the CDB and echo its full stdout.
_vr_capture_multi() {
  local script="$1" runpath
  _role_env TARGET || return $?
  runpath="$script"
  if ! host_is_local "$_R_HOST"; then
    runpath="$(_stage_remote TARGET "$script")" || return $?
  fi
  run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "sqlplus -s -L '/ as sysdba' @$(_shq "$runpath")" 2>/dev/null \
    | sed '/^[[:space:]]*$/d'
}

_vr_registry() {
  local out line comp ver st want rc=0 seen_cat=0 seen_proc=0
  want="$(_getvar TARGET_EXPECTED_VERSION)"; [ -n "$want" ] || want="23"
  out="$(_vr_capture_multi "$RUN_RENDER_DIR/sql/pdb_registry.sql")"
  if [ -z "$out" ]; then
    log_err "registry query returned no CATALOG/CATPROC rows"
    return "$_VERIFY_FAIL"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      CATALOG\|*|CATPROC\|*) ;;
      *) continue ;;
    esac
    comp="${line%%|*}"
    ver="${line#*|}"; ver="${ver%%|*}"
    st="${line##*|}"
    [ "$comp" = "CATALOG" ] && seen_cat=1
    [ "$comp" = "CATPROC" ] && seen_proc=1
    if [ "$st" != "VALID" ]; then
      log_err "registry $comp status '$st' is not VALID"; rc="$_VERIFY_FAIL"
    fi
    case "$ver" in
      "$want"*) : ;;
      *) log_err "registry $comp version_full '$ver' does not begin with '$want'"; rc="$_VERIFY_FAIL" ;;
    esac
    log_role TARGET "registry $comp: version=$ver status=$st"
  done <<EOF
$out
EOF
  if [ "$seen_cat" -eq 0 ] || [ "$seen_proc" -eq 0 ]; then
    log_err "registry missing CATALOG or CATPROC row"; rc="$_VERIFY_FAIL"
  fi
  return "$rc"
}

_vr_proof() {
  local q pdb match srcval body out tgtval
  q="$(_getvar BEHAVIOR_PROOF_QUERY)"
  if [ -z "$q" ]; then
    log_warn "BEHAVIOR_PROOF_QUERY empty: data-integrity proof skipped (no failure)"
    return 0
  fi
  pdb="$(_getvar TARGET_PDB_NAME)"
  match="$(_getvar BEHAVIOR_PROOF_MATCH)"; [ -n "$match" ] || match="exact"
  srcval="$(manifest_get PROOF_SOURCE_VALUE)"
  body="whenever sqlerror exit failure
alter session set container=${pdb};
set heading off feedback off pagesize 0 verify off echo off
select 'PROOF_VALUE=' || (${q}) from dual;"
  out="$(run_sql_capture TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "$body")"
  tgtval="${out#PROOF_VALUE=}"
  log_role TARGET "proof inside PDB=$tgtval (source=$srcval, match=$match)"
  if [ "$match" = "nonzero" ]; then
    if _is_int "$tgtval" && [ "$tgtval" -gt 0 ]; then return 0; fi
    log_err "proof (nonzero) failed: PDB value '$tgtval' is not > 0"
    return "$_VERIFY_FAIL"
  fi
  if [ "$tgtval" = "$srcval" ] && [ -n "$tgtval" ]; then return 0; fi
  log_err "proof (exact) mismatch: PDB '$tgtval' != source '$srcval'"
  return "$_VERIFY_FAIL"
}

step_verify() {
  if dryrun; then
    _vr_render
    plan "[verify] would open+save-state PDB $(_getvar TARGET_PDB_NAME) (tolerate ORA-65019),"
    plan "         check violations (fail only on unresolved ERROR), assert CATALOG/CATPROC"
    plan "         VALID at version prefix $(_getvar TARGET_EXPECTED_VERSION), and compare the"
    plan "         proof ($(_getvar BEHAVIOR_PROOF_MATCH)) against manifest PROOF_SOURCE_VALUE."
    return 0
  fi
  step_begin verify
  _vr_render
  _vr_open_savestate || log_warn "open/save-state returned non-zero (continuing to checks)"
  _vr_violations || step_fail verify "$_VERIFY_FAIL"
  _vr_registry   || step_fail verify "$_VERIFY_FAIL"
  _vr_proof      || step_fail verify "$_VERIFY_FAIL"

  if [ "$(_getvar BEHAVIOR_TEARDOWN_STAGING)" = "on_success" ]; then
    if declare -f _tr_teardown >/dev/null 2>&1; then
      log "BEHAVIOR_TEARDOWN_STAGING=on_success: running confirmation-gated staging teardown"
      _tr_teardown || log_warn "staging teardown returned non-zero"
    fi
  fi
  step_done verify
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrate.sh" --only verify "$@"
fi
