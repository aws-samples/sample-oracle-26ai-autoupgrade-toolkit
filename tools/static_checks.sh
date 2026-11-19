#!/usr/bin/env bash
###############################################################################
# static_checks.sh - static verification gates for the migration toolkit.
#
# Runs with NO live Oracle, DB, or remote host. Safe on bash 3.2 (authoring
# host) as well as bash >= 4.2. Gates implemented here (per plan.md section E):
#
#   Gate 1  syntax        bash -n on every bin/*.sh lib/*.sh tools/*.sh
#   Gate 5  exit-guarantee every SQL/RMAN template (and rendered artifact)
#                         ends with an effective 'exit'
#   Gate 6  no-literals   no reference literal in bin/ lib/ templates/ tools/
#   Gate 7  autoupgrade   autoupgrade.jar is never invoked without -noconsole
#   Gate 8  secret-leak   no password-valued key in conf/*.example; no secret
#                         variable echoed/logged without redact
#
# Gate 2 (shellcheck) and Gate 3/4 (bash>=4.2 dry-run, SID isolation) are run
# manually and recorded separately.
#
# Prints PASS/FAIL per gate; exits 0 only when every gate passes, 1 otherwise.
###############################################################################

# Resolve the toolkit root (one level above this tools/ dir) and work from it,
# so the gates behave the same regardless of the caller's directory.
_self="${BASH_SOURCE[0]:-$0}"
_tools_dir="$(cd "$(dirname "$_self")" && pwd)"
ROOT="$(cd "$_tools_dir/.." && pwd)"
cd "$ROOT" || { printf 'FATAL: cannot cd to toolkit root %s\n' "$ROOT" >&2; exit 1; }

# Reference literals that must never appear in code or templates. Kept as a
# single alternation so the list is easy to extend.
REF_LITERALS='NCDB19C|CDB26AI|ORCLPDB1|MIGDEMO|/opt/oracle/product|Oracle_2026|ip-172-31'

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf '      %s\n' "$*"; }

#------------------------------------------------------------------------------
# Return the last "meaningful" line of a script: trailing blank lines and
# comment lines (--, #, REM) are ignored. Used by the exit-guarantee gate.
#------------------------------------------------------------------------------
_last_meaningful_line() {
  awk '
    { line=$0; sub(/\r$/,"",line);
      sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line);
      if (line=="") next;
      if (line ~ /^--/) next;
      if (line ~ /^#/) next;
      if (line ~ /^[Rr][Ee][Mm]([ \t]|$)/) next;
      saved=line;
    }
    END { print saved }
  ' "$1"
}

# True when the file's last meaningful line is an effective 'exit'.
_ends_with_exit() {
  local last norm
  last="$(_last_meaningful_line "$1")"
  norm="$(printf '%s' "$last" | tr 'A-Z' 'a-z' | tr -d ';[:space:]')"
  [ "$norm" = "exit" ]
}

#==============================================================================
# Gate 1 - syntax: bash -n on every shell script.
#==============================================================================
gate1() {
  local f bad=0
  for f in bin/*.sh lib/*.sh tools/*.sh; do
    [ -e "$f" ] || continue
    if ! bash -n "$f" 2>/tmp/_sc_bashn.$$; then
      fail "gate1 syntax: $f"
      sed 's/^/        /' /tmp/_sc_bashn.$$ 2>/dev/null
      bad=1
    fi
  done
  rm -f /tmp/_sc_bashn.$$ 2>/dev/null
  [ "$bad" -eq 0 ] && pass "gate1 syntax: bash -n clean on all bin/lib/tools scripts"
}

#==============================================================================
# Gate 5 - exit-guarantee: SQL/RMAN templates and rendered artifacts end with
# an effective 'exit'. Pfile/config templates (.ora, .cfg) are excluded by
# design - they are not sqlplus/rman scripts.
#==============================================================================
gate5() {
  local f bad=0 count=0
  for f in templates/*.rman.tmpl templates/sql/*.tmpl; do
    [ -e "$f" ] || continue
    count=$((count + 1))
    if ! _ends_with_exit "$f"; then
      fail "gate5 exit-guarantee: template does not end with exit: $f"
      bad=1
    fi
  done
  # Rendered artifacts from any prior dry-run (optional - only if present).
  if [ -d run ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      count=$((count + 1))
      if ! _ends_with_exit "$f"; then
        fail "gate5 exit-guarantee: rendered artifact does not end with exit: $f"
        bad=1
      fi
    done <<EOF
$(find run -type f \( -name '*.sql' -o -name '*.rman' \) 2>/dev/null)
EOF
  fi
  [ "$bad" -eq 0 ] && pass "gate5 exit-guarantee: $count SQL/RMAN scripts end with exit"
}

#==============================================================================
# Gate 6 - no reference literals in code or templates.
#==============================================================================
gate6() {
  local hits
  # Exclude this harness itself: it must name the literals in order to detect
  # them, so its own pattern definition is not a code/template violation.
  hits="$(grep -REn --exclude=static_checks.sh "$REF_LITERALS" bin lib templates tools 2>/dev/null)"
  if [ -n "$hits" ]; then
    fail "gate6 no-literals: reference literal found in code/templates:"
    printf '%s\n' "$hits" | sed 's/^/        /'
  else
    pass "gate6 no-literals: no reference literal in bin/ lib/ templates/ tools/"
  fi
}

#==============================================================================
# Gate 7 - autoupgrade.jar is never invoked without -noconsole.
#==============================================================================
gate7() {
  local hits
  hits="$(grep -REn 'autoupgrade\.jar' bin templates 2>/dev/null | grep -v -- '-noconsole')"
  if [ -n "$hits" ]; then
    fail "gate7 autoupgrade: autoupgrade.jar invoked without -noconsole:"
    printf '%s\n' "$hits" | sed 's/^/        /'
  else
    pass "gate7 autoupgrade: every autoupgrade.jar invocation carries -noconsole"
  fi
}

#==============================================================================
# Gate 8 - secret-leak:
#   (a) no password-/secret-named key in conf/*.example carries a value.
#   (b) no secret-named variable is echoed/logged without going through redact.
#==============================================================================
gate8() {
  local bad=0 f hits

  # (a) conf/*.example: a key whose name contains PWD/PASSWORD/SECRET must be
  #     empty (nothing after '='). A value present means a secret was committed.
  for f in conf/*.example; do
    [ -e "$f" ] || continue
    hits="$(grep -nE '^[[:space:]]*[A-Za-z_]*(PWD|PASSWORD|SECRET)[A-Za-z_]*=[^[:space:]]+' "$f" 2>/dev/null)"
    if [ -n "$hits" ]; then
      fail "gate8 secret-leak: password-valued key in $f:"
      printf '%s\n' "$hits" | sed 's/^/        /'
      bad=1
    fi
  done

  # (b) direct echo/printf/log/plan of a secret-named variable, not redacted.
  #     Variable NAMES ending in _FILE (e.g. SECRETS_FILE) are paths, not
  #     secrets, so they are excluded; lines routed through redact pass.
  hits="$(grep -REn '(echo|printf|log|log_role|log_warn|log_err|debug|plan)[^#]*\$\{?[A-Za-z_]*(PWD|PASSWORD|SECRET)[A-Za-z0-9_]*' bin lib 2>/dev/null \
            | grep -vE '\$\{?[A-Za-z_]*(PWD|PASSWORD|SECRET)[A-Za-z0-9_]*_FILE' \
            | grep -vE 'SECRETS_FILE' \
            | grep -v 'redact')"
  if [ -n "$hits" ]; then
    fail "gate8 secret-leak: secret variable emitted without redact:"
    printf '%s\n' "$hits" | sed 's/^/        /'
    bad=1
  fi

  [ "$bad" -eq 0 ] && pass "gate8 secret-leak: no secret value in conf/*.example; no unredacted secret emission"
}

#==============================================================================
# Run every gate. Each gate records its own PASS/FAIL; FAILED is the aggregate.
#==============================================================================
printf '=== static_checks.sh (toolkit root: %s) ===\n' "$ROOT"
gate1
gate5
gate6
gate7
gate8
printf '===========================================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'RESULT: ALL GATES PASS\n'
  exit 0
fi
printf 'RESULT: ONE OR MORE GATES FAILED\n'
exit 1
