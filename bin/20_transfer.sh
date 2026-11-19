#!/usr/bin/env bash
###############################################################################
# bin/20_transfer.sh  ->  step_transfer
#
# Move the backup pieces + controlfile autobackup + manifest.env (and, for
# operator reference only, any spfile/password file) from SOURCE to TARGET using
# the configured transport (scp/rsync/shared), then verify each piece's sha256
# and size against the manifest. Idempotent: already-present matching files are
# skipped; partial copies are re-copied.
#
# This phase renders no template. --dry-run prints the transport plan only.
###############################################################################

if [ -z "${_MIG_COMMON_SH_LOADED:-}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  . "$_d/lib/version.sh"
  . "$_d/lib/common.sh"
fi

_tr_verify() {
  local n count dst bn want got
  count="$(manifest_get PIECE_COUNT)"
  _is_int "$count" || { log_warn "no PIECE_COUNT in manifest; skipping sha256 verification"; return 0; }
  dst="$(_getvar TARGET_TRANSFER_DIR)"
  n=1
  while [ "$n" -le "$count" ]; do
    bn="$(manifest_get "PIECE_${n}")"
    want="$(manifest_get "SHA256_${n}")"
    if [ -n "$bn" ] && [ -n "$want" ]; then
      got="$(run_on TARGET "$(_getvar TARGET_STAGING_HOME)" "$(_getvar TARGET_CDB_SID)" \
        "$(_getvar TARGET_ORACLE_BASE)" \
        "(sha256sum $(_shq "$dst/$bn") 2>/dev/null || shasum -a 256 $(_shq "$dst/$bn") 2>/dev/null) | awk '{print \$1}'" 2>/dev/null)"
      if [ "$got" != "$want" ]; then
        log_err "transfer verify failed for $bn (want $want, got ${got:-<missing>})"
        return 1
      fi
      log_role TARGET "verified $bn"
    fi
    n=$((n + 1))
  done
  return 0
}

step_transfer() {
  local src dst
  src="$(_getvar SOURCE_BACKUP_RUN_DIR)"
  dst="$(_getvar TARGET_TRANSFER_DIR)"
  if dryrun; then
    plan "[transfer] would move backup pieces + ctl autobackup + manifest.env"
    plan "           from $src"
    plan "           to   $dst (method=$(_getvar TRANSPORT_METHOD)), then verify sha256."
    return 0
  fi
  step_begin transfer
  transfer_artifacts "$src" "$dst" || step_fail transfer "$EXIT_TRANSFER"
  _tr_verify || step_fail transfer "$EXIT_TRANSFER"
  step_done transfer
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrate.sh" --only transfer "$@"
fi
