#!/usr/bin/env bash
###############################################################################
# bin/30_target_restore.sh  ->  step_target_restore   (+ --teardown helper)
#
# Restore the 19c non-CDB into a transient staging instance on TARGET, applying
# the restore-spec overrides (plan.md section F):
#   * staging pfile db_name = SOURCE_DB_NAME (ORA-01103), datafiles via OMF;
#   * RMAN scoped to controlfile + catalog + restore + recover only;
#   * redo relocation (UNIQUE names), tempfile relocation, and OPEN RESETLOGS
#     via sqlplus, all rendered from manifest.env (no mid-restore DB query);
#   * nid rename only when TARGET_STAGING_DB_NAME != SOURCE_DB_NAME, judged by
#     follow-up state (nid returns non-zero even on success).
#
# --dry-run renders every restore artifact (real manifest paths when a manifest
# exists, else a marked placeholder) and contacts nothing.
###############################################################################

if [ -z "${_MIG_COMMON_SH_LOADED:-}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  . "$_d/lib/version.sh"
  . "$_d/lib/common.sh"
fi

STAGING_PFILE=""
STAGING_CONTROL_FILE=""
STAGING_ADUMP_DIR=""
STAGING_SGA_MB=""
STAGING_PGA_MB=""
STAGING_COMPATIBLE=""
STAGING_UNDO_TABLESPACE=""
STAGING_DB_BLOCK_SIZE=""
SHIPPED_CTL_AUTOBACKUP_PIECE=""
SOURCE_DBID_VAL=""

_tr_derive_tokens() {
  local sid home base mem sga pga ver bn dbid
  sid="$(_getvar TARGET_STAGING_SID)"
  home="$(_getvar TARGET_STAGING_HOME)"
  base="$(_getvar TARGET_ORACLE_BASE)"
  STAGING_PFILE="$home/dbs/init${sid}.ora"
  STAGING_CONTROL_FILE="$(_getvar TARGET_DATAFILE_DEST)/control01_${sid}.ctl"
  STAGING_ADUMP_DIR="$base/admin/${sid}/adump"
  mem="$(_getvar TARGET_STAGING_MEMORY_MB)"; _is_int "$mem" || mem=2048
  sga=$(( mem * 3 / 4 )); pga=$(( mem - sga ))
  STAGING_SGA_MB="$sga"; STAGING_PGA_MB="$pga"
  # compatible/undo_tablespace/db_block_size are physical attributes of the
  # SOURCE captured into the manifest while it was OPEN READ WRITE; they must
  # NOT be assumed (HC9). compatible keeps the major-version derivation only as
  # a dry-run fallback when no manifest exists yet.
  local comp undo blk
  comp="$(manifest_get SOURCE_COMPATIBLE)"
  if [ -n "$comp" ]; then
    STAGING_COMPATIBLE="$comp"
  else
    ver="$(_getvar SOURCE_EXPECTED_VERSION)"; [ -n "$ver" ] || ver="19"
    STAGING_COMPATIBLE="${ver}.0.0"
  fi
  undo="$(manifest_get UNDO_TABLESPACE)"
  if [ -n "$undo" ]; then STAGING_UNDO_TABLESPACE="$undo"; else STAGING_UNDO_TABLESPACE="<source-undo-tablespace-from-manifest>"; fi
  blk="$(manifest_get DB_BLOCK_SIZE)"
  if [ -n "$blk" ]; then STAGING_DB_BLOCK_SIZE="$blk"; else STAGING_DB_BLOCK_SIZE="<source-db-block-size-from-manifest>"; fi
  bn="$(manifest_get CTL_AUTOBACKUP_BASENAME)"
  if [ -n "$bn" ]; then
    SHIPPED_CTL_AUTOBACKUP_PIECE="$(_getvar TARGET_TRANSFER_DIR)/$bn"
  else
    SHIPPED_CTL_AUTOBACKUP_PIECE="$(_getvar TARGET_TRANSFER_DIR)/<controlfile-autobackup-basename-from-manifest>"
  fi
  dbid="$(manifest_get SOURCE_DBID)"
  if [ -n "$dbid" ]; then SOURCE_DBID_VAL="$dbid"; else SOURCE_DBID_VAL="<source-dbid-from-manifest>"; fi
}

_tr_build_redo_body() {
  local count redodest i grp mem body=""
  count="$(manifest_get REDO_COUNT)"
  redodest="$(_getvar TARGET_REDO_DEST)"
  if ! _is_int "$count" || [ "$count" -eq 0 ]; then
    printf -- '-- <generated at run time from manifest: one ALTER DATABASE RENAME FILE per online redo member, to UNIQUE redo_g<group#>_m<idx>.log names>'
    return 0
  fi
  declare -A _gc
  i=1
  while [ "$i" -le "$count" ]; do
    grp="$(manifest_get "REDO_${i}_GROUP")"
    mem="$(manifest_get "REDO_${i}_MEMBER")"
    _gc[$grp]=$(( ${_gc[$grp]:-0} + 1 ))
    body="${body}alter database rename file '${mem}' to '${redodest}/redo_g${grp}_m${_gc[$grp]}.log';
"
    i=$(( i + 1 ))
  done
  printf '%s' "$body"
}

_tr_build_temp_body() {
  local count datadest i ts path bytes body=""
  count="$(manifest_get TEMP_COUNT)"
  datadest="$(_getvar TARGET_DATAFILE_DEST)"
  if ! _is_int "$count" || [ "$count" -eq 0 ]; then
    printf -- '-- <generated at run time from manifest: per tempfile, ADD TEMPFILE under TARGET_DATAFILE_DEST at the captured size, then DROP the missing source tempfile>'
    return 0
  fi
  i=1
  while [ "$i" -le "$count" ]; do
    ts="$(manifest_get "TEMP_${i}_TS")"
    path="$(manifest_get "TEMP_${i}_PATH")"
    bytes="$(manifest_get "TEMP_${i}_BYTES")"
    if ! _is_int "$bytes" || [ "$bytes" -lt 10485760 ]; then bytes=104857600; fi
    body="${body}alter tablespace ${ts} add tempfile '${datadest}/$(_getvar TARGET_PDB_NAME)_${ts}_temp_${i}.dbf' size ${bytes} autoextend on;
alter database tempfile '${path}' drop including datafiles;
"
    i=$(( i + 1 ))
  done
  printf '%s' "$body"
}

_tr_render() {
  _tr_derive_tokens
  mkdir -p "$RUN_RENDER_DIR/sql"

  render_vars_reset
  render_vars_add_config SOURCE_DB_NAME TARGET_STAGING_SID TARGET_DATAFILE_DEST TARGET_ORACLE_BASE
  render_vars_put STAGING_CONTROL_FILE "$STAGING_CONTROL_FILE"
  render_vars_put STAGING_ADUMP_DIR "$STAGING_ADUMP_DIR"
  render_vars_put STAGING_SGA_MB "$STAGING_SGA_MB"
  render_vars_put STAGING_PGA_MB "$STAGING_PGA_MB"
  render_vars_put STAGING_COMPATIBLE "$STAGING_COMPATIBLE"
  render_vars_put STAGING_UNDO_TABLESPACE "$STAGING_UNDO_TABLESPACE"
  render_vars_put STAGING_DB_BLOCK_SIZE "$STAGING_DB_BLOCK_SIZE"
  mig_render staging_init.ora.tmpl "$RUN_RENDER_DIR/staging_init.ora"

  render_vars_reset
  render_vars_add_config TARGET_TRANSFER_DIR TARGET_DATAFILE_DEST
  render_vars_put STAGING_PFILE "$STAGING_PFILE"
  render_vars_put SOURCE_DBID "$SOURCE_DBID_VAL"
  render_vars_put SHIPPED_CTL_AUTOBACKUP_PIECE "$SHIPPED_CTL_AUTOBACKUP_PIECE"
  mig_render_tool rman_restore.rman.tmpl "$RUN_RENDER_DIR/rman_restore.rman"

  render_vars_reset
  render_vars_put RELOCATE_REDO_BODY "$(_tr_build_redo_body)"
  mig_render_sql staging_relocate_redo.sql.tmpl staging_relocate_redo.sql >/dev/null

  render_vars_reset
  render_vars_put RELOCATE_TEMP_BODY "$(_tr_build_temp_body)"
  mig_render_sql staging_relocate_temp.sql.tmpl staging_relocate_temp.sql >/dev/null

  render_vars_reset
  mig_render_sql staging_open_resetlogs.sql.tmpl staging_open_resetlogs.sql >/dev/null

  render_vars_reset
  render_vars_put STAGING_PFILE "$STAGING_PFILE"
  mig_render_sql staging_nid_verify.sql.tmpl staging_nid_verify.sql >/dev/null
}

_tr_mkdirs() {
  run_on TARGET "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_STAGING_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" \
    "mkdir -p $(_shq "$STAGING_ADUMP_DIR") $(_shq "$(_getvar TARGET_DATAFILE_DEST)") $(_shq "$(_getvar TARGET_REDO_DEST)") $(_shq "$(_getvar TARGET_STAGING_HOME)/dbs")"
}

_tr_install_pfile() {
  _role_env TARGET || return $?
  local rendered="$RUN_RENDER_DIR/staging_init.ora"
  run_on TARGET "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_STAGING_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "mkdir -p $(_shq "$(dirname "$STAGING_PFILE")")" || return 1
  if host_is_local "$_R_HOST"; then
    cp -f "$rendered" "$STAGING_PFILE" || return 1
  else
    local rp; rp="$(_stage_remote TARGET "$rendered")" || return 1
    run_on TARGET "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_STAGING_SID)" \
      "$(_getvar TARGET_ORACLE_BASE)" "cp -f $(_shq "$rp") $(_shq "$STAGING_PFILE")" || return 1
  fi
  return 0
}

_tr_run_restore() {
  local home sid base piece dbid
  home="$(_getvar TARGET_STAGING_HOME)"; sid="$(_getvar TARGET_STAGING_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  piece="$SHIPPED_CTL_AUTOBACKUP_PIECE"
  dbid="$(manifest_get SOURCE_DBID)"
  if run_on TARGET "$home" "$sid" "$base" "test -f $(_shq "$piece")"; then
    log_role TARGET "controlfile restore branch: named shipped piece $piece"
    run_rman STAGING "$home" "$sid" "$base" "$(cat "$RUN_RENDER_DIR/rman_restore.rman")" rman_restore
    return $?
  fi
  log_role TARGET "controlfile restore branch: autobackup-format fallback under $(_getvar TARGET_TRANSFER_DIR) (named piece absent)"
  local body
  body="startup nomount pfile='${STAGING_PFILE}';
set dbid ${dbid};
set controlfile autobackup format for device type disk to '$(_getvar TARGET_TRANSFER_DIR)/cf_%F';
restore controlfile from autobackup;
alter database mount;
catalog start with '$(_getvar TARGET_TRANSFER_DIR)' noprompt;
run {
  set newname for database to new;
  restore database;
  switch database to copy;
  recover database;
}
exit"
  run_rman STAGING "$home" "$sid" "$base" "$body" rman_restore_fallback
}

_tr_rename_staging_db() {
  local home sid base tgt pfile
  home="$(_getvar TARGET_STAGING_HOME)"; sid="$(_getvar TARGET_STAGING_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  tgt="$(_getvar TARGET_STAGING_DB_NAME)"; pfile="$STAGING_PFILE"
  log_role TARGET "staging DB_NAME change requested: '$(_getvar SOURCE_DB_NAME)' -> '$tgt' (running nid)"
  run_sql STAGING "$home" "$sid" "$base" "whenever sqlerror continue
shutdown immediate;" shutdown_for_nid || true
  run_sql STAGING "$home" "$sid" "$base" "startup mount pfile='${pfile}';" mount_for_nid \
    || { log_err "mount before nid failed"; return "$EXIT_RESTORE"; }
  # Update the pfile db_name to the target BEFORE run_nid_judge_by_state re-mounts
  # with it (the control file carries the target name after nid).
  run_on TARGET "$home" "$sid" "$base" \
    "sed -i -E \"s/(db_name[[:space:]]*=[[:space:]]*).*/\\\\1'${tgt}'/I\" $(_shq "$pfile")" \
    || log_warn "could not sed pfile db_name; verify manually"
  run_nid_judge_by_state STAGING "$home" "$sid" "$base" "$tgt" "$pfile" \
    || { log_err "nid rename verification failed"; return "$EXIT_RESTORE"; }
  run_sql STAGING "$home" "$sid" "$base" "$(cat "$RUN_RENDER_DIR/sql/staging_open_resetlogs.sql")" open_after_rename \
    || { log_err "open resetlogs after rename failed"; return "$EXIT_RESTORE"; }
  return 0
}

_tr_teardown() {
  local home sid base pfile datadest redodest adump ctl
  home="$(_getvar TARGET_STAGING_HOME)"; sid="$(_getvar TARGET_STAGING_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  pfile="$home/dbs/init${sid}.ora"
  datadest="$(_getvar TARGET_DATAFILE_DEST)"; redodest="$(_getvar TARGET_REDO_DEST)"
  adump="$base/admin/${sid}/adump"
  ctl="$datadest/control01_${sid}.ctl"
  confirm "TEARDOWN staging instance '$sid': shutdown abort and REMOVE its control file, pfile/spfile and adump under $datadest / $home/dbs / $adump?" \
    || { log "teardown aborted by user"; return 0; }
  run_sql STAGING "$home" "$sid" "$base" "whenever sqlerror continue
shutdown abort;" teardown_shutdown || log_warn "shutdown abort returned non-zero (may already be down)"
  run_on STAGING "$home" "$sid" "$base" \
    "rm -f $(_shq "$ctl") $(_shq "$pfile") $(_shq "$home/dbs/spfile${sid}.ora"); rm -rf $(_shq "$adump")" \
    || log_warn "teardown file removal returned non-zero"
  log "staging instance '$sid' torn down (datafiles under $datadest left for the operator to reclaim)"
  return 0
}

step_target_restore() {
  if dryrun; then
    _tr_render
    if manifest_exists; then
      plan "[target_restore] manifest present: restore artifacts rendered with real paths."
    else
      plan "[target_restore] no manifest yet: redo/temp blocks rendered as marked placeholders."
    fi
    plan "                 staging SID=$(_getvar TARGET_STAGING_SID) pfile=$STAGING_PFILE (db_name=$(_getvar SOURCE_DB_NAME))"
    if [ "$(_getvar TARGET_STAGING_DB_NAME)" != "$(_getvar SOURCE_DB_NAME)" ]; then
      plan "                 nid rename WOULD run: $(_getvar SOURCE_DB_NAME) -> $(_getvar TARGET_STAGING_DB_NAME)"
    else
      plan "                 nid rename skipped (staging db_name == source db_name)"
    fi
    return 0
  fi
  step_begin target_restore
  _tr_render
  _tr_mkdirs          || step_fail target_restore "$EXIT_RESTORE"
  _tr_install_pfile   || step_fail target_restore "$EXIT_RESTORE"
  _tr_run_restore     || step_fail target_restore "$EXIT_RESTORE"

  local home sid base
  home="$(_getvar TARGET_STAGING_HOME)"; sid="$(_getvar TARGET_STAGING_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  run_sql STAGING "$home" "$sid" "$base" "$(cat "$RUN_RENDER_DIR/sql/staging_relocate_redo.sql")" relocate_redo \
    || step_fail target_restore "$EXIT_RESTORE"
  run_sql STAGING "$home" "$sid" "$base" "$(cat "$RUN_RENDER_DIR/sql/staging_open_resetlogs.sql")" open_resetlogs \
    || step_fail target_restore "$EXIT_RESTORE"
  run_sql STAGING "$home" "$sid" "$base" "$(cat "$RUN_RENDER_DIR/sql/staging_relocate_temp.sql")" relocate_temp \
    || step_fail target_restore "$EXIT_RESTORE"

  if [ "$(_getvar TARGET_STAGING_DB_NAME)" != "$(_getvar SOURCE_DB_NAME)" ]; then
    _tr_rename_staging_db || step_fail target_restore "$EXIT_RESTORE"
  else
    log_role TARGET "staging db_name matches source; nid skipped"
  fi

  if [ "$(_getvar BEHAVIOR_TEARDOWN_STAGING)" = "on_success" ]; then
    log "BEHAVIOR_TEARDOWN_STAGING=on_success: teardown will run after verify, not here"
  fi
  step_done target_restore
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  case " $* " in
    *" --teardown "*)
      _cfg=""; _yes="false"
      while [ $# -gt 0 ]; do
        case "$1" in
          --config)   _cfg="${2:-}"; shift 2 ;;
          --config=*) _cfg="${1#*=}"; shift ;;
          --yes)      _yes="true"; shift ;;
          --teardown) shift ;;
          *) shift ;;
        esac
      done
      [ -n "$_cfg" ] || { printf 'ERROR: --teardown requires --config <file>\n' >&2; exit 1; }
      . "$_self_dir/../lib/version.sh"
      . "$_self_dir/../lib/common.sh"
      # ASSUME_YES is read by confirm() in the dynamically-sourced common.sh,
      # and DRY_RUN is set for parity with the orchestrator entry path (the
      # teardown branch never dry-runs). Standalone shellcheck cannot see the
      # cross-file read, so both look unused (SC2034).
      # shellcheck disable=SC2034
      ASSUME_YES="$_yes"
      # shellcheck disable=SC2034
      DRY_RUN="false"
      assert_bash_version
      load_config "$_cfg"; load_secrets; apply_config_defaults
      validate_config; resolve_derivations; init_run_dirs; state_init
      _tr_teardown
      exit $?
      ;;
    *)
      exec "$_self_dir/migrate.sh" --only target_restore "$@"
      ;;
  esac
fi
