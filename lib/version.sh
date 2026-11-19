#!/usr/bin/env bash
###############################################################################
# lib/version.sh
#
# Toolkit version string and the supported source->target migration matrix.
# Sourced by lib/common.sh (and therefore by every phase script). Contains
# data only: no side effects, no DB/host contact, safe to source anywhere.
#
# Nothing here is site-specific. Site values live in conf/migration.conf.
###############################################################################

# This is a data-only library: every identifier below is consumed by the
# scripts that source it (lib/common.sh, bin/*), never within this file, so
# standalone shellcheck reports them as unused (SC2034). Disable that check
# file-wide here.
# shellcheck disable=SC2034

# Toolkit release identifier. Bump on any change to the documented behaviour
# or config schema. Semantic: MAJOR.MINOR.PATCH.
TOOLKIT_VERSION="1.0.0"

# Minimum bash required at RUNTIME (associative arrays, printf -v, etc.).
# Authoring/static checks (bash -n) run on the macOS host bash 3.2; the
# orchestrator asserts this floor before doing any real work.
TOOLKIT_MIN_BASH_MAJOR=4
TOOLKIT_MIN_BASH_MINOR=2

# Supported-target matrix.
#
# Each entry maps a source major family to the set of target families this
# toolkit has been designed to migrate INTO (19c non-CDB -> pluggable database
# inside a 26ai / 23.x container). The matrix is advisory metadata consumed by
# preflight and surfaced in the plan; the authoritative per-run versions come
# from SOURCE_EXPECTED_VERSION / TARGET_EXPECTED_VERSION in the config.
#
# Keyed "SOURCE_FAMILY" -> space-separated list of supported TARGET families.
# Declared as a plain array of "KEY=VALUE" strings so this file parses cleanly
# on bash 3.2 (associative arrays require bash >= 4.0); callers running under
# the enforced runtime bash can reindex it if they prefer a map.
TOOLKIT_SUPPORTED_MATRIX=(
  "19=26ai 23"
)

# Human-readable one-liners describing each supported path, for the plan/README.
TOOLKIT_SUPPORTED_PATHS=(
  "19c non-CDB  ->  26ai (23.x) pluggable database via RMAN restore + AutoUpgrade"
)
