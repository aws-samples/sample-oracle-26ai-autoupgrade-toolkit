#!/usr/bin/env bash
###############################################################################
# bin/40_autoupgrade.sh  ->  step_autoupgrade
#
# Plug + upgrade the restored staging non-CDB into the 26ai CDB with AutoUpgrade
# (analyze, then detached deploy + monitor). AutoUpgrade is ALWAYS invoked
# -noconsole with stdin from /dev/null.
#
# Flow (real run):
#   * staging_open_check: staging SID + OPEN READ WRITE, else exit 4;
#   * collision guard: default FAIL (exit 4); drop only with --force + confirm;
#   * analyze -> parse Final Summary; on ORA-00600[kzafp_read_one_field] move
#     UNIAUD .bin once and re-analyze exactly once;
#   * deploy detached (nohup ... & ; pid file), monitor until the PID exits;
#   * three-part success test (parseable Final Summary + >=1 finished & 0 failed
#     + no fatal banner); PID gone with no Final Summary => exit 4 indeterminate.
#
# --dry-run renders autoupgrade.cfg + the SQL guards and prints the plan.
###############################################################################

if [ -z "${_MIG_COMMON_SH_LOADED:-}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  . "$_d/lib/version.sh"
  . "$_d/lib/common.sh"
fi

AU_LOG_DIR=""
AU_CFG_PATH=""
AU_DEPLOY_OUT=""
AU_DEPLOY_PID=""

_au_optional_lines() {
  local out="" copt eopt
  copt="$(_getvar AUTOUPGRADE_TARGET_PDB_COPY_OPTION)"
  eopt="$(_getvar AUTOUPGRADE_EXTRA_OPTIONS)"
  [ -n "$copt" ] && out="upg1.target_pdb_copy_option=${copt}"
  if [ -n "$eopt" ]; then
    if [ -n "$out" ]; then out="${out}
${eopt}"; else out="$eopt"; fi
  fi
  printf '%s' "$out"
}

_au_derive() {
  AU_LOG_DIR="$(_getvar AUTOUPGRADE_LOG_DIR)"
  [ -n "$AU_LOG_DIR" ] || AU_LOG_DIR="$(_getvar TARGET_ORACLE_BASE)/autoupgrade/$(_getvar MIGRATION_ID)"
  AU_CFG_PATH="$AU_LOG_DIR/autoupgrade.cfg"
  AU_DEPLOY_OUT="$AU_LOG_DIR/deploy.out"
  AU_DEPLOY_PID="$AU_LOG_DIR/deploy.pid"
}

_au_render() {
  _au_derive
  render_vars_reset
  render_vars_put AUTOUPGRADE_LOG_DIR "$AU_LOG_DIR"
  render_vars_add_config TARGET_STAGING_HOME TARGET_26AI_HOME TARGET_STAGING_SID \
                         TARGET_CDB_SID TARGET_PDB_NAME AUTOUPGRADE_START_TIME
  render_vars_put AUTOUPGRADE_OPTIONAL_LINES "$(_au_optional_lines)"
  mig_render autoupgrade.cfg.tmpl "$RUN_RENDER_DIR/autoupgrade.cfg"

  render_vars_reset
  render_vars_add_config TARGET_STAGING_SID
  mig_render_sql staging_open_check.sql.tmpl staging_open_check.sql >/dev/null

  render_vars_reset
  render_vars_add_config TARGET_PDB_NAME
  mig_render_sql target_collision_check.sql.tmpl target_collision_check.sql >/dev/null

  render_vars_reset
  render_vars_add_config TARGET_PDB_NAME
  mig_render_sql target_drop_pdb.sql.tmpl target_drop_pdb.sql >/dev/null
}

_au_install_cfg() {
  _role_env TARGET || return $?
  run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "mkdir -p $(_shq "$AU_LOG_DIR")" || return 1
  local rendered="$RUN_RENDER_DIR/autoupgrade.cfg"
  if host_is_local "$_R_HOST"; then
    cp -f "$rendered" "$AU_CFG_PATH" || return 1
  else
    local rp; rp="$(_stage_remote TARGET "$rendered")" || return 1
    run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
      "$(_getvar TARGET_ORACLE_BASE)" "cp -f $(_shq "$rp") $(_shq "$AU_CFG_PATH")" || return 1
  fi
  return 0
}

_au_clear_recovery() {
  # Clear any stale AutoUpgrade recovery data so a (re)deploy starts clean and
  # never trips the "config altered after a deploy" / "unfinished execution"
  # interlock after a fixed-and-retried failure. Clean-restart model: a partial
  # PDB from an aborted deploy is caught by the collision guard. Best effort.
  run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" \
    "$(_shq "$(_getvar AUTOUPGRADE_JAVA)") -jar $(_shq "$(_getvar AUTOUPGRADE_JAR)") -config $(_shq "$AU_CFG_PATH") -clear_recovery_data </dev/null" >/dev/null 2>&1 \
    && log_role TARGET "cleared stale AutoUpgrade recovery data" \
    || log_role TARGET "no stale AutoUpgrade recovery data to clear"
  return 0
}

_au_staging_ensure_open() {
  # Idempotently bring the staging instance to OPEN READ WRITE before the hard
  # open-check below. A prior failed/aborted deploy leaves the staging non-CDB
  # shut down (AutoUpgrade shuts it to describe/plug), so a retry would otherwise
  # die in the open-check with ORA-01034. 'startup' from down does nomount+mount
  # +open; if it is already mounted, 'alter database open' finishes the job; if
  # it is already open, both are harmless. Best effort - the open-check that
  # follows is the authority on whether the staging DB is truly READ WRITE.
  run_sql STAGING "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_STAGING_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" \
    "whenever sqlerror continue
startup
alter database open;" staging_ensure_open >/dev/null 2>&1 || true
  return 0
}

_au_staging_open_check() {
  run_sql STAGING "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_STAGING_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "$(cat "$RUN_RENDER_DIR/sql/staging_open_check.sql")" staging_open_check
}

_au_collision_guard() {
  local home cdb base out n
  home="$(_getvar TARGET_26AI_HOME)"; cdb="$(_getvar TARGET_CDB_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  out="$(run_sql_capture TARGET "$home" "$cdb" "$base" "$(cat "$RUN_RENDER_DIR/sql/target_collision_check.sql")")"
  n="${out#PDB_EXISTS=}"
  _is_int "$n" || n=0
  if [ "$n" -eq 0 ]; then
    log_role TARGET "no PDB named $(_getvar TARGET_PDB_NAME) in CDB $cdb; safe to plug"
    return 0
  fi
  if [ "$FORCE" != "true" ]; then
    log_err "PDB $(_getvar TARGET_PDB_NAME) already exists in CDB $cdb; re-run with --force to drop it"
    return "$EXIT_COLLISION"
  fi
  confirm "DROP PLUGGABLE DATABASE $(_getvar TARGET_PDB_NAME) INCLUDING DATAFILES in CDB $cdb?" \
    || { log_err "collision drop declined at prompt"; return "$EXIT_COLLISION"; }
  run_sql TARGET "$home" "$cdb" "$base" "$(cat "$RUN_RENDER_DIR/sql/target_drop_pdb.sql")" drop_pdb \
    || { log_err "drop of colliding PDB failed"; return "$EXIT_COLLISION"; }
  return 0
}

_au_analyze_once() {
  local home cdb base cmd
  home="$(_getvar TARGET_26AI_HOME)"; cdb="$(_getvar TARGET_CDB_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  cmd="$(_shq "$(_getvar AUTOUPGRADE_JAVA)") -jar $(_shq "$(_getvar AUTOUPGRADE_JAR)") -config $(_shq "$AU_CFG_PATH") -mode analyze -noconsole </dev/null"
  run_on TARGET "$home" "$cdb" "$base" "$cmd" 2>&1 | _tee_logs
  return "${PIPESTATUS[0]}"
}

_au_analyze_hit_uniaud() {
  # scan the newest analyze output under the log dir for the UNIAUD ORA-600
  run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" \
    "grep -RilE 'ORA-00600.*kzafp_read_one_field' $(_shq "$AU_LOG_DIR") 2>/dev/null | head -1" 2>/dev/null
}

_au_analyze() {
  _au_analyze_once || log_warn "analyze returned non-zero; inspecting for UNIAUD ORA-600"
  local hit; hit="$(_au_analyze_hit_uniaud)"
  if [ -n "$hit" ]; then
    log_role TARGET "analyze hit ORA-00600[kzafp_read_one_field]; quarantining staging UNIAUD .bin once and re-analyzing"
    remediate_uniaud STAGING "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_STAGING_SID)" \
      "$(_getvar TARGET_ORACLE_BASE)" || log_warn "UNIAUD remediation returned non-zero"
    _au_analyze_once || log_warn "re-analyze returned non-zero"
    hit="$(_au_analyze_hit_uniaud)"
    if [ -n "$hit" ]; then
      log_err "UNIAUD ORA-600 persists after one remediation+reanalyze; aborting"
      return "$EXIT_UPGRADE"
    fi
  fi
  return 0
}

_au_final_summary_status() {
  # echoes "finished=<n> failed=<n>" parsed from the AutoUpgrade logs
  local fin fail
  fin="$(run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" \
    "grep -RhiE 'jobs *finished' $(_shq "$AU_LOG_DIR") $(_shq "$AU_DEPLOY_OUT") 2>/dev/null | grep -oE '[0-9]+' | tail -1" 2>/dev/null)"
  fail="$(run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" \
    "grep -RhiE 'jobs *failed' $(_shq "$AU_LOG_DIR") $(_shq "$AU_DEPLOY_OUT") 2>/dev/null | grep -oE '[0-9]+' | tail -1" 2>/dev/null)"
  _is_int "$fin" || fin=""
  _is_int "$fail" || fail=""
  printf 'finished=%s failed=%s' "$fin" "$fail"
}

_au_deploy_detached() {
  local home cdb base cmd
  home="$(_getvar TARGET_26AI_HOME)"; cdb="$(_getvar TARGET_CDB_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  cmd="nohup $(_shq "$(_getvar AUTOUPGRADE_JAVA)") -jar $(_shq "$(_getvar AUTOUPGRADE_JAR)") -config $(_shq "$AU_CFG_PATH") -mode deploy -noconsole </dev/null >> $(_shq "$AU_DEPLOY_OUT") 2>&1 & echo \$! > $(_shq "$AU_DEPLOY_PID")"
  run_on TARGET "$home" "$cdb" "$base" "$cmd" || return "$EXIT_UPGRADE"
  log_role TARGET "deploy launched detached; pid file $AU_DEPLOY_PID, output $AU_DEPLOY_OUT"
  return 0
}

_au_pid_alive() {
  local pid
  pid="$(run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "cat $(_shq "$AU_DEPLOY_PID") 2>/dev/null" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "kill -0 $(_shq "$pid") 2>/dev/null"
}

_au_monitor_deploy() {
  local poll timeout_min waited=0 limit=0
  poll="$(_getvar AUTOUPGRADE_DEPLOY_POLL_SEC)"; _is_int "$poll" || poll=30
  timeout_min="$(_getvar AUTOUPGRADE_TIMEOUT_MIN)"; _is_int "$timeout_min" || timeout_min=0
  [ "$timeout_min" -gt 0 ] && limit=$(( timeout_min * 60 ))
  while _au_pid_alive; do
    log_role TARGET "deploy running (elapsed ${waited}s); tailing $AU_DEPLOY_OUT"
    run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
      "$(_getvar TARGET_ORACLE_BASE)" "tail -n 5 $(_shq "$AU_DEPLOY_OUT") 2>/dev/null" 2>/dev/null | _tee_logs
    sleep "$poll"
    waited=$(( waited + poll ))
    if [ "$limit" -gt 0 ] && [ "$waited" -ge "$limit" ]; then
      log_err "deploy exceeded AUTOUPGRADE_TIMEOUT_MIN=${timeout_min}m; job keeps running and can be resumed"
      return "$EXIT_UPGRADE"
    fi
  done
  return 0
}

_au_fatal_banner() {
  run_on TARGET "$(_getvar TARGET_26AI_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" \
    "tail -n 200 $(_shq "$AU_DEPLOY_OUT") 2>/dev/null | grep -qE 'Exception|Error: Unable to|Cannot|OutOfMemoryError' && echo FATAL || echo OK" 2>/dev/null
}

_au_judge_deploy() {
  local status fin fail banner
  status="$(_au_final_summary_status)"
  fin="${status#finished=}"; fin="${fin%% *}"
  fail="${status##*failed=}"
  if [ -z "$fin" ] && [ -z "$fail" ]; then
    log_err "deploy result indeterminate - inspect $AU_DEPLOY_OUT / $AU_LOG_DIR (no parseable Final Summary; JVM may have crashed / bad path / rejected config)"
    return "$EXIT_UPGRADE"
  fi
  banner="$(_au_fatal_banner)"
  if [ "$banner" = "FATAL" ]; then
    log_err "fatal banner found in $AU_DEPLOY_OUT despite a Final Summary; treating deploy as failed"
    return "$EXIT_UPGRADE"
  fi
  _is_int "$fin" || fin=0
  _is_int "$fail" || fail=0
  if [ "$fin" -ge 1 ] && [ "$fail" -eq 0 ]; then
    log_role TARGET "deploy succeeded (jobs finished=$fin, failed=$fail)"
    return 0
  fi
  log_err "deploy failed (jobs finished=$fin, failed=$fail)"
  return "$EXIT_UPGRADE"
}

step_autoupgrade() {
  if dryrun; then
    _au_render
    plan "[autoupgrade] would assert staging OPEN READ WRITE, guard PDB collision"
    plan "              (policy: $( [ "$FORCE" = true ] && echo 'DROP with --force' || echo 'FAIL unless --force' ))," 
    plan "              render config -> $AU_CFG_PATH, run analyze (-noconsole </dev/null),"
    plan "              then detached deploy + monitor with a three-part success test."
    return 0
  fi
  step_begin autoupgrade
  _au_render
  _au_install_cfg        || step_fail autoupgrade "$EXIT_UPGRADE"
  _au_clear_recovery
  _au_staging_ensure_open
  _au_staging_open_check || step_fail autoupgrade "$EXIT_COLLISION"
  _au_collision_guard    || step_fail autoupgrade "$EXIT_COLLISION"
  _au_analyze            || step_fail autoupgrade "$EXIT_UPGRADE"
  confirm "proceed with AutoUpgrade DEPLOY (creates PDB $(_getvar TARGET_PDB_NAME) in CDB $(_getvar TARGET_CDB_SID))?" \
    || step_fail autoupgrade "$EXIT_UPGRADE"
  _au_deploy_detached    || step_fail autoupgrade "$EXIT_UPGRADE"
  _au_monitor_deploy     || step_fail autoupgrade "$EXIT_UPGRADE"
  _au_judge_deploy       || step_fail autoupgrade "$EXIT_UPGRADE"
  step_done autoupgrade
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrate.sh" --only autoupgrade "$@"
fi
