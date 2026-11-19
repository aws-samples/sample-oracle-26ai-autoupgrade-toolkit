#!/usr/bin/env bash
###############################################################################
# bin/00_preflight.sh  ->  step_preflight
#
# Read-only validation before anything is written:
#   * privilege / connectivity probe per role (via run_on, stdin </dev/null);
#   * Oracle homes carry the binaries each phase needs;
#   * SSH key permissions <= 600;
#   * SOURCE is OPEN READ WRITE (restore-spec RS2 / override B) - mounted-only
#     is rejected;
#   * free space on the TARGET destinations and SOURCE_BACKUP_DIR, sized from
#     the live SOURCE v$datafile/v$tempfile/v$log totals x BEHAVIOR_*_FACTOR;
#   * single-host SID isolation + datafile/redo/dbs overlap check.
#
# --dry-run renders source_precheck.sql and prints the intended checks only.
###############################################################################

if [ -z "${_MIG_COMMON_SH_LOADED:-}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  . "$_d/lib/version.sh"
  . "$_d/lib/common.sh"
fi

_preflight_render() {
  render_vars_reset
  render_vars_add_config SOURCE_EXPECTED_VERSION
  mig_render_sql source_precheck.sql.tmpl source_precheck.sql >/dev/null
}

_preflight_privilege() {
  if _source_net; then
    local _p
    _p="$(run_sql_capture SOURCE "" "" "" "select 'NETOK' from dual;")"
    case "$_p" in
      *NETOK*) log_role SOURCE "Oracle Net connect OK (user=$(_getvar SOURCE_DB_USER), $(_source_descriptor))" ;;
      *) log_err "SOURCE Oracle Net connect/privilege probe failed (user=$(_getvar SOURCE_DB_USER), $(_source_descriptor)); check listener/service, credentials, and connect privilege"; return 1 ;;
    esac
  else
    run_on SOURCE "$(_getvar SOURCE_ORACLE_HOME)" "$(_getvar SOURCE_ORACLE_SID)" \
      "$(_getvar SOURCE_ORACLE_BASE)" "true" \
      || { log_err "SOURCE privilege/connectivity probe failed (need root, NOPASSWD sudo to the Oracle user, or run as that user)"; return 1; }
  fi
  run_on TARGET "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_CDB_SID)" \
    "$(_getvar TARGET_ORACLE_BASE)" "true" \
    || { log_err "TARGET privilege/connectivity probe failed"; return 1; }
  return 0
}

_preflight_homes() {
  local sh th ah
  sh="$(_getvar SOURCE_ORACLE_HOME)"
  th="$(_getvar TARGET_STAGING_HOME)"
  ah="$(_getvar TARGET_26AI_HOME)"
  if _source_net; then
    log "net source: skipping SOURCE Oracle-home check (source reached over Oracle Net; the 19c client in TARGET_STAGING_HOME is used)"
  else
    run_on SOURCE "$sh" "$(_getvar SOURCE_ORACLE_SID)" "$(_getvar SOURCE_ORACLE_BASE)" \
      "test -x $(_shq "$sh/bin/sqlplus") && test -x $(_shq "$sh/bin/rman")" \
      || { log_err "SOURCE home missing bin/sqlplus or bin/rman: $sh"; return 1; }
  fi
  run_on TARGET "$th" "$(_getvar TARGET_STAGING_SID)" "$(_getvar TARGET_ORACLE_BASE)" \
    "test -x $(_shq "$th/bin/rman") && test -x $(_shq "$th/bin/nid") && test -x $(_shq "$th/bin/sqlplus")" \
    || { log_err "staging home missing bin/rman, bin/nid or bin/sqlplus: $th"; return 1; }
  run_on TARGET "$ah" "$(_getvar TARGET_CDB_SID)" "$(_getvar TARGET_ORACLE_BASE)" \
    "test -f $(_shq "$(_getvar AUTOUPGRADE_JAR)") && test -x $(_shq "$(_getvar AUTOUPGRADE_JAVA)")" \
    || { log_err "26ai home missing the AutoUpgrade jar ($(_getvar AUTOUPGRADE_JAR)) or java ($(_getvar AUTOUPGRADE_JAVA))"; return 1; }
  return 0
}

_preflight_ssh_keys() {
  local k f perm
  for k in SOURCE_SSH_KEY TARGET_SSH_KEY TRANSPORT_SSH_KEY; do
    f="$(_getvar "$k")"
    [ -n "$f" ] || continue
    [ -f "$f" ] || { log_err "$k not found: $f"; return 1; }
    perm="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || printf '')"
    if [ -n "$perm" ] && _is_int "$perm" && [ "$perm" -gt 600 ]; then
      log_err "$k permissions $perm exceed 600: $f"
      return 1
    fi
  done
  return 0
}

# Non-interactive reachability probe for the transfer channel (TARGET role).
# key non-empty -> key probe; else password probe via sshpass -e.
_preflight_probe_ssh() {
  local key="$1" pw="$2"
  _role_env TARGET || return 1
  local ssh_opts=(-p "$_R_SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  local -a auth_pfx=()
  if [ -n "$key" ]; then
    ssh_opts+=(-o BatchMode=yes -i "$key")
  else
    auth_pfx=(sshpass -e)
    ssh_opts+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password)
  fi
  if SSHPASS="$pw" ${auth_pfx[@]+"${auth_pfx[@]}"} ssh "${ssh_opts[@]}" "${_R_SSH_USER}@${_R_HOST}" true </dev/null 2>/dev/null; then
    return 0
  fi
  log_err "transport auth probe to ${_R_SSH_USER}@${_R_HOST} failed; the backup cannot be copied non-interactively"
  return 1
}

# Fail fast (in seconds) when the backup copy would require interactive input,
# instead of dying mid-run after a long backup. 'shared' and same-host runs need
# no SSH at all. A remote copy requires either a passwordless SSH key or a
# password+sshpass; with neither, one-shot end-to-end is impossible and the
# operator is told exactly how to proceed.
_preflight_transport() {
  local method; method="$(_getvar TRANSPORT_METHOD)"; [ -n "$method" ] || method="scp"
  if [ "$method" = "shared" ]; then
    log "transport=shared: backup copied via a pre-mounted path (TRANSPORT_SHARED_PATH); no SSH/password needed"
    return 0
  fi

  local both_local="false"
  if host_is_local "$(_getvar SOURCE_HOST)" && host_is_local "$(_getvar TARGET_HOST)"; then
    both_local="true"
  fi
  [ "$(_getvar FORCE_REMOTE_TRANSPORT)" = "true" ] && both_local="false"
  if [ "$both_local" = "true" ]; then
    log "transport: SOURCE and TARGET are the same host; backup copied locally (no SSH, no password)"
    return 0
  fi

  local key; key="$(_getvar TRANSPORT_SSH_KEY)"; [ -n "$key" ] || key="$(_getvar TARGET_SSH_KEY)"
  local pw; pw="$(_getvar TRANSPORT_SSH_PASSWORD)"
  if [ -n "$key" ]; then
    _preflight_probe_ssh "$key" "" || return 1
    log_role TARGET "transport auth: SSH key OK (non-interactive, one-shot capable)"
    return 0
  fi
  if [ -n "$pw" ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      log_err "TRANSPORT_SSH_PASSWORD is set but 'sshpass' is not installed on this host; install sshpass, or use an SSH key / TRANSPORT_METHOD=shared"
      return 1
    fi
    _preflight_probe_ssh "" "$pw" || return 1
    log_role TARGET "transport auth: password via sshpass OK (non-interactive, one-shot capable)"
    return 0
  fi
  log_err "SOURCE and TARGET are different hosts, but no non-interactive backup transport is configured."
  log_err "One-shot end-to-end cannot run: copying the backup would require an interactive password. Choose ONE:"
  log_err "  (a) configure a passwordless SSH key for the oracle user (TARGET_SSH_KEY or TRANSPORT_SSH_KEY),"
  log_err "  (b) set TRANSPORT_SSH_PASSWORD in the 0600 SECRETS_FILE (requires 'sshpass' on the runner),"
  log_err "  (c) use a shared mount: TRANSPORT_METHOD=shared with TRANSPORT_SHARED_PATH, or"
  log_err "  (d) copy the backup to TARGET_TRANSFER_DIR manually, then resume with --from target_restore."
  return 1
}

_preflight_source_open_rw() {
  local body; body="$(cat "$RUN_RENDER_DIR/sql/source_precheck.sql")"
  run_sql SOURCE "$(_getvar SOURCE_ORACLE_HOME)" "$(_getvar SOURCE_ORACLE_SID)" \
    "$(_getvar SOURCE_ORACLE_BASE)" "$body" source_precheck \
    || { log_err "SOURCE precheck failed: must be OPEN READ WRITE at the expected version"; return 1; }
  return 0
}

_src_sql_scalar() {
  run_sql_capture SOURCE "$(_getvar SOURCE_ORACLE_HOME)" "$(_getvar SOURCE_ORACLE_SID)" \
    "$(_getvar SOURCE_ORACLE_BASE)" "$1"
}

_space_need() { awk -v b="$1" -v f="$2" 'BEGIN { printf "%d", (b * f) }'; }

_check_dest_space() {
  # role dest need label : check on the role's host (local df, or remote via run_on)
  local role="$1" dest="$2" need="$3" label="$4"
  if [ "$role" = "SOURCE" ] && _source_net; then
    # net source: SOURCE_BACKUP_DIR is the shared mount, visible locally here
    check_free_space "$dest" "$need" "$label"
    return 0
  fi
  _role_env "$role"
  if host_is_local "$_R_HOST"; then
    check_free_space "$dest" "$need" "$label"
    return 0
  fi
  local avail_kb avail chk="$dest"
  avail_kb="$(run_on "$role" "/" "DUMMY" "/" "d=$(_shq "$chk"); while [ ! -e \"\$d\" ] && [ \"\$d\" != / ]; do d=\$(dirname \"\$d\"); done; df -Pk \"\$d\" | awk 'NR==2{print \$4}'")"
  _is_int "$avail_kb" || { log_warn "cannot size $label on $_R_HOST; skipping"; return 0; }
  avail=$(( avail_kb * 1024 ))
  if [ "$avail" -lt "$need" ]; then
    log_err "insufficient free space on $label ($dest on $_R_HOST): need $need, have $avail"
    exit "$EXIT_PREFLIGHT"
  fi
  log_role "$role" "free space ok on $label ($dest): have $avail, need $need"
  return 0
}

_preflight_space() {
  local df_total tf_total redo_total bfac rfac
  df_total="$(_src_sql_scalar "select nvl(sum(bytes),0) from v\$datafile;")"
  tf_total="$(_src_sql_scalar "select nvl(sum(bytes),0) from v\$tempfile;")"
  redo_total="$(_src_sql_scalar "select nvl(sum(bytes*members),0) from v\$log;")"
  _is_int "$df_total" || { log_err "could not read SOURCE datafile total for sizing"; return 1; }
  _is_int "$tf_total" || tf_total=0
  _is_int "$redo_total" || redo_total=0
  bfac="$(_getvar BEHAVIOR_BACKUP_SPACE_FACTOR)"; [ -n "$bfac" ] || bfac="1.0"
  rfac="$(_getvar BEHAVIOR_RESTORE_SPACE_FACTOR)"; [ -n "$rfac" ] || rfac="1.2"

  local backup_need restore_need redo_need
  backup_need="$(_space_need "$df_total" "$bfac")"
  restore_need="$(_space_need "$(( df_total + tf_total ))" "$rfac")"
  redo_need="$(_space_need "$redo_total" "$rfac")"

  _check_dest_space SOURCE "$(_getvar SOURCE_BACKUP_DIR)"   "$backup_need"  "SOURCE_BACKUP_DIR"
  _check_dest_space TARGET "$(_getvar TARGET_TRANSFER_DIR)" "$backup_need"  "TARGET_TRANSFER_DIR"
  _check_dest_space TARGET "$(_getvar TARGET_DATAFILE_DEST)" "$restore_need" "TARGET_DATAFILE_DEST"
  if [ "$(_getvar TARGET_REDO_DEST)" != "$(_getvar TARGET_DATAFILE_DEST)" ]; then
    _check_dest_space TARGET "$(_getvar TARGET_REDO_DEST)" "$redo_need" "TARGET_REDO_DEST"
  fi
  return 0
}

_preflight_isolation() {
  if [ "$STAGING_ON_SOURCE_HOST" != "true" ]; then
    log "separate hosts: datafile/redo overlap check not applicable (skipped)"
    return 0
  fi
  # Gather SOURCE datafile/redo directory prefixes (primary: live v$ views;
  # fallback: operator-declared SOURCE_DATAFILE_PATHS when SOURCE is unreadable).
  local dirs
  dirs="$(_src_sql_scalar "select listagg(d,':') within group (order by d) from (select distinct substr(name,1,instr(name,'/',-1)-1) d from (select name from v\$datafile union all select member name from v\$logfile));")"
  if [ -z "$dirs" ]; then
    dirs="$(_getvar SOURCE_DATAFILE_PATHS)"
    dirs="${dirs//[, ]/:}"
    [ -n "$dirs" ] || { log_err "SOURCE file locations unreadable and SOURCE_DATAFILE_PATHS unset; cannot run the single-host overlap check"; return 1; }
  fi
  local dest d
  local -a dir_list
  IFS=':' read -r -a dir_list <<< "$dirs"
  for dest in "$(_getvar TARGET_DATAFILE_DEST)" "$(_getvar TARGET_REDO_DEST)" "$(_getvar TARGET_STAGING_HOME)/dbs"; do
    for d in "${dir_list[@]}"; do
      [ -n "$d" ] || continue
      case "$dest/" in
        "$d/"*) log_err "TARGET destination '$dest' overlaps a live SOURCE path '$d' on a shared host"; return 1 ;;
      esac
      case "$d/" in
        "$dest/"*) log_err "live SOURCE path '$d' sits under TARGET destination '$dest' on a shared host"; return 1 ;;
      esac
    done
  done
  log "single-host overlap check passed"
  return 0
}

# Prerequisite: the tool MUST run on the target host. The staging-instance build
# (startup nomount), nid, and AutoUpgrade are local OS operations that cannot be
# driven over Oracle Net, so TARGET_HOST must resolve to this machine. SOURCE may
# still be remote (SOURCE_CONN_MODE=net). Fail fast and explain, rather than dying
# deep in target_restore/autoupgrade on a wrong host.
_preflight_target_is_local() {
  local th; th="$(_getvar TARGET_HOST)"
  if host_is_local "$th"; then
    log_role TARGET "running on the target host ($th) as required"
    return 0
  fi
  log_err "this tool must run ON the target host, but TARGET_HOST='$th' does not resolve to this machine."
  log_err "  The staging-instance build (startup nomount), nid, and AutoUpgrade are local OS"
  log_err "  operations and cannot be driven over Oracle Net. Run the migration from the target"
  log_err "  CDB host. (SOURCE may still be remote via SOURCE_CONN_MODE=net.)"
  return 1
}

# Proactive PDB-slot headroom check against the target CDB. ORA-65010 at plug
# time is expensive (it surfaces ~10 min into AutoUpgrade DEPLOY), so refuse here
# when there is no free slot. The enforced cap can be LOWER than the max_pdbs
# parameter: without the Oracle Multitenant option (and on AWS EC2) the DB
# commonly enforces 3 user PDBs regardless of max_pdbs. Operators who know their
# licensed ceiling set TARGET_PDB_SLOT_LIMIT; otherwise we fall back to max_pdbs
# and still emit the licensing caveat.
_preflight_pdb_slots() {
  local home cdb base pdb out used maxp lim eff
  home="$(_getvar TARGET_26AI_HOME)"; cdb="$(_getvar TARGET_CDB_SID)"; base="$(_getvar TARGET_ORACLE_BASE)"
  pdb="$(_getvar TARGET_PDB_NAME)"
  out="$(run_sql_capture TARGET "$home" "$cdb" "$base" \
    "set heading off feedback off pagesize 0 lines 200
select 'PDBSLOT=' || used || ':' || maxp from (select (select count(*) from v\$pdbs where con_id>2 and upper(name)<>upper('$pdb')) used, (select value from v\$parameter where name='max_pdbs') maxp from dual);")"
  out="${out##*PDBSLOT=}"; out="${out%%[!0-9:]*}"
  used="${out%%:*}"; maxp="${out##*:}"
  _is_int "$used" || { log_warn "could not read current PDB count from CDB $cdb; skipping slot check"; return 0; }
  lim="$(_getvar TARGET_PDB_SLOT_LIMIT)"
  if _is_int "$lim"; then eff="$lim"; else eff="$maxp"; fi
  if ! _is_int "$eff"; then
    log_warn "no effective PDB limit resolved (max_pdbs='${maxp:-?}', TARGET_PDB_SLOT_LIMIT unset); skipping slot check"
    return 0
  fi
  log_role TARGET "PDB slots: $used user PDB(s) in use (excluding $pdb); effective limit $eff (max_pdbs=${maxp:-?}${lim:+, TARGET_PDB_SLOT_LIMIT=$lim})"
  if [ "$(( used + 1 ))" -gt "$eff" ]; then
    log_err "no free PDB slot in CDB $cdb: $used user PDB(s) already present; adding $pdb would exceed the limit $eff (this is what raises ORA-65010 at plug time)."
    log_err "  Free a slot: drop an unused PDB ('alter pluggable database <name> close immediate; drop pluggable database <name> including datafiles;'),"
    log_err "  or, if you are licensed for more, raise it ('alter system set max_pdbs=<n> scope=both') and set TARGET_PDB_SLOT_LIMIT to your licensed ceiling."
    return 1
  fi
  if [ -z "$lim" ]; then
    log_role TARGET "note: without the Multitenant option (and on AWS EC2) Oracle may enforce a lower cap than max_pdbs (commonly 3 user PDBs). If the plug still fails with ORA-65010, drop an unused PDB or set TARGET_PDB_SLOT_LIMIT to your licensed maximum."
  fi
  return 0
}

step_preflight() {
  if dryrun; then
    _preflight_render
    plan "[preflight] would assert the tool runs ON the target host, verify a non-interactive"
    plan "            backup transport (SSH key, sshpass password, shared mount, or same-host"
    plan "            local copy), probe privilege drop (SOURCE+TARGET), verify Oracle"
    plan "            homes/binaries, SSH key perms, SOURCE OPEN READ WRITE, a free PDB slot in"
    plan "            the target CDB, free space sized from live SOURCE totals, and single-host"
    plan "            SID/datafile/redo isolation."
    return 0
  fi
  step_begin preflight
  _preflight_render
  _preflight_target_is_local || step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_transport     || step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_privilege     || step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_homes         || step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_ssh_keys      || step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_source_open_rw|| step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_pdb_slots     || step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_space         || step_fail preflight "$EXIT_PREFLIGHT"
  _preflight_isolation     || step_fail preflight "$EXIT_PREFLIGHT"
  step_done preflight
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrate.sh" --only preflight "$@"
fi
