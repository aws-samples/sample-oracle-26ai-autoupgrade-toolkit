#!/usr/bin/env bash
###############################################################################
# bin/10_source_backup.sh  ->  step_source_backup
#
# While SOURCE is OPEN READ WRITE:
#   * capture the manifest inputs (DBID, charset, db_name, every datafile,
#     every online redo member+group#, every tempfile+size) - restore-spec RS1;
#   * capture the data-integrity proof scalar (PROOF_SOURCE_VALUE);
#   * optionally quarantine UNIAUD .bin spillover (scope source/both);
#   * run the compressed level-0 backup + archivelog + controlfile + spfile
#     into ${SOURCE_BACKUP_RUN_DIR};
#   * enumerate the produced pieces, their sha256, and the controlfile
#     autobackup basename into manifest.env.
#
# --dry-run renders source_capture / proof_rowcount / rman_backup and prints the
# plan; it never contacts SOURCE.
###############################################################################

if [ -z "${_MIG_COMMON_SH_LOADED:-}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  . "$_d/lib/version.sh"
  . "$_d/lib/common.sh"
fi

_sb_render() {
  render_vars_reset
  render_vars_put SOURCE_CAPTURE_SPOOL "$(_getvar SOURCE_BACKUP_RUN_DIR)/source_capture.lst"
  mig_render_sql source_capture.sql.tmpl source_capture.sql >/dev/null

  render_vars_reset
  render_vars_add_config BEHAVIOR_PROOF_QUERY
  mig_render_sql proof_rowcount.sql.tmpl proof_rowcount.sql >/dev/null

  render_vars_reset
  render_vars_add_config SOURCE_BACKUP_RUN_DIR SOURCE_BACKUP_TAG
  mig_render_tool rman_backup.rman.tmpl "$RUN_RENDER_DIR/rman_backup.rman"
}

# Run a rendered sqlplus script on SOURCE and echo its full stdout.
_sb_capture_sql() {
  local script="$1"
  if _source_net; then
    _source_net_exec sqlplus "$script" yes
    return $?
  fi
  _role_env SOURCE || return $?
  local runpath="$script"
  if ! host_is_local "$_R_HOST"; then
    runpath="$(_stage_remote SOURCE "$script")" || return $?
  fi
  run_on SOURCE "$(_getvar SOURCE_ORACLE_HOME)" "$(_getvar SOURCE_ORACLE_SID)" \
    "$(_getvar SOURCE_ORACLE_BASE)" "sqlplus -s -L '/ as sysdba' @$(_shq "$runpath")" 2>/dev/null
}

_sb_capture_manifest() {
  local out line k v dcount=0 rcount=0 tcount=0
  out="$(_sb_capture_sql "$RUN_RENDER_DIR/sql/source_capture.sql")"
  [ -n "$out" ] || { log_err "source_capture produced no output"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      KV\|*)
        k="${line#KV|}"; v="${k#*|}"; k="${k%%|*}"
        manifest_put "$k" "$v"
        ;;
      DATAFILE\|*)
        dcount=$((dcount + 1))
        manifest_put "DATAFILE_${dcount}" "${line##*|}"
        ;;
      REDO\|*)
        rcount=$((rcount + 1))
        local rrest="${line#REDO|}"
        manifest_put "REDO_${rcount}_GROUP" "${rrest%%|*}"
        manifest_put "REDO_${rcount}_MEMBER" "${rrest#*|}"
        ;;
      TEMP\|*)
        tcount=$((tcount + 1))
        local trest="${line#TEMP|}"
        manifest_put "TEMP_${tcount}_TS" "${trest%%|*}"
        trest="${trest#*|}"
        manifest_put "TEMP_${tcount}_PATH" "${trest%%|*}"
        manifest_put "TEMP_${tcount}_BYTES" "${trest##*|}"
        ;;
    esac
  done <<EOF
$out
EOF
  manifest_put DATAFILE_COUNT "$dcount"
  manifest_put REDO_COUNT "$rcount"
  manifest_put TEMP_COUNT "$tcount"
  manifest_put SOURCE_BACKUP_TAG "$(_getvar SOURCE_BACKUP_TAG)"
  log_role SOURCE "manifest captured: $dcount datafile(s), $rcount redo member(s), $tcount tempfile(s)"
  return 0
}

_sb_capture_proof() {
  local q; q="$(_getvar BEHAVIOR_PROOF_QUERY)"
  if [ -z "$q" ]; then
    log_warn "BEHAVIOR_PROOF_QUERY empty: no data-integrity proof will be captured"
    manifest_put PROOF_SOURCE_VALUE ""
    return 0
  fi
  local out val
  out="$(_sb_capture_sql "$RUN_RENDER_DIR/sql/proof_rowcount.sql")"
  val="$(printf '%s\n' "$out" | sed -n 's/^PROOF_VALUE=//p' | tail -1)"
  manifest_put PROOF_SOURCE_VALUE "$val"
  log_role SOURCE "proof scalar captured: PROOF_SOURCE_VALUE=$val"
  return 0
}

_sb_enumerate_pieces() {
  local rundir out line sum bn n=0 ctl="" cmd
  rundir="$(_getvar SOURCE_BACKUP_RUN_DIR)"
  cmd="for f in $(_shq "$rundir")/*; do [ -f \"\$f\" ] || continue; s=\$( (sha256sum \"\$f\" 2>/dev/null || shasum -a 256 \"\$f\" 2>/dev/null) | awk '{print \$1}'); echo \"PIECE|\$(basename \"\$f\")|\$s\"; done"
  out="$(_source_fs_exec "$cmd" 2>/dev/null)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      PIECE\|*)
        bn="${line#PIECE|}"; sum="${bn#*|}"; bn="${bn%%|*}"
        n=$((n + 1))
        manifest_put "PIECE_${n}" "$bn"
        manifest_put "SHA256_${n}" "$sum"
        # Controlfile-restore piece. Prefer the explicit current-controlfile
        # backup (ctl_%U) we take every run. We no longer configure a source
        # autobackup (cf_/c-), but keep matching it as a fallback so a manually
        # re-enabled autobackup still works; ctl_ always wins if present.
        case "$bn" in
          ctl_*)    ctl="$bn" ;;
          cf_*|c-*) [ -n "$ctl" ] || ctl="$bn" ;;
        esac
        ;;
    esac
  done <<EOF
$out
EOF
  manifest_put PIECE_COUNT "$n"
  [ -n "$ctl" ] && manifest_put CTL_AUTOBACKUP_BASENAME "$ctl"
  log_role SOURCE "enumerated $n backup piece(s); controlfile piece='${ctl:-<none>}'"
  return 0
}

step_source_backup() {
  if dryrun; then
    _sb_render
    plan "[source_backup] would capture the manifest + proof from SOURCE (OPEN READ WRITE),"
    plan "                quarantine UNIAUD .bin (scope=$(_getvar BEHAVIOR_AUDIT_REMEDIATION_SCOPE)) if source/both,"
    plan "                then run the RMAN backup into $(_getvar SOURCE_BACKUP_RUN_DIR)"
    plan "                and record pieces + sha256 + proof into manifest.env."
    return 0
  fi
  step_begin source_backup
  _sb_render

  _source_fs_exec "mkdir -p $(_shq "$(_getvar SOURCE_BACKUP_RUN_DIR)")" \
    || step_fail source_backup "$EXIT_TRANSFER"

  _sb_capture_manifest || step_fail source_backup "$EXIT_TRANSFER"
  _sb_capture_proof    || step_fail source_backup "$EXIT_TRANSFER"

  local scope; scope="$(_getvar BEHAVIOR_AUDIT_REMEDIATION_SCOPE)"
  if _source_net; then
    { [ "$scope" = "source" ] || [ "$scope" = "both" ]; } \
      && log_warn "net source: skipping source-side UNIAUD remediation (no OS access to the source)"
  elif [ "$(_getvar BEHAVIOR_AUDIT_REMEDIATION)" = "true" ] && { [ "$scope" = "source" ] || [ "$scope" = "both" ]; }; then
    remediate_uniaud SOURCE "$(_getvar SOURCE_ORACLE_HOME)" "$(_getvar SOURCE_ORACLE_SID)" \
      "$(_getvar SOURCE_ORACLE_BASE)" || log_warn "UNIAUD remediation on SOURCE returned non-zero"
  fi

  run_rman SOURCE "$(_getvar SOURCE_ORACLE_HOME)" "$(_getvar SOURCE_ORACLE_SID)" \
    "$(_getvar SOURCE_ORACLE_BASE)" "$(cat "$RUN_RENDER_DIR/rman_backup.rman")" rman_backup \
    || step_fail source_backup "$EXIT_TRANSFER"

  _sb_enumerate_pieces || step_fail source_backup "$EXIT_TRANSFER"
  step_done source_backup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrate.sh" --only source_backup "$@"
fi
