#!/bin/zsh
# Opt-in performance and load suite for the disk engine. Builds Tests/PerformanceLoadCheck.swift with optimisations
# and runs it on generated fixtures in a unique temporary folder (always removed afterwards).
#
# Usage: Scripts/perf.sh
#   MACPOLISH_PERF_SCALE=smoke|standard|heavy   fixture size (default standard; smoke < 60 s, heavy >= 1,000,000 files)
#   MACPOLISH_PERF_REAL=1                        also run a read-only benchmark of the startup data volume
#   MACPOLISH_PERF_BUDGETS=warn                  report performance budget overruns without failing
#   MACPOLISH_PERF_STRICT=1                      fail on known engine findings (reported, not fixed, by default)
#   Budget overrides: MACPOLISH_PERF_MAX_SCAN_MB, MACPOLISH_PERF_MAX_BYTES_PER_FILE, MACPOLISH_PERF_THREAD_TOLERANCE,
#   MACPOLISH_PERF_DEADLINE_SLACK, MACPOLISH_PERF_MAX_JSON_MB, MACPOLISH_PERF_MIN_FILES_PER_SEC, MACPOLISH_PERF_TIME_FACTOR,
#   MACPOLISH_PERF_DUP_MEMORY_FRACTION (safety cap on bytes the duplicate fixture reads, share of RAM, default 1.0)
# Metrics are written to .build/perf/perf-<ISO8601>.json so runs can be compared.
set -euo pipefail
cd "${0:A:h:h}"
# Other core files import SwiftUI; pick an SDK this toolchain can compile it against.
source Scripts/sdk.sh
export MACPOLISH_CLEANUP_HISTORY="${MACPOLISH_CLEANUP_HISTORY:-$(mktemp -d "${TMPDIR:-/tmp}/macpolish-history.XXXXXX")/cleanup-history.json}"
export MACPOLISH_HEALTH_HISTORY="${MACPOLISH_HEALTH_HISTORY:-$(mktemp -d "${TMPDIR:-/tmp}/macpolish-health.XXXXXX")/health-history.json}"
mkdir -p .build/checks .build/perf
typeset -a CORE_SOURCES
for source in Sources/MacPolish/*.swift; do
  case "$source" in
    */MacPolishApp.swift|*/main.swift|*/ContentView.swift|*/AdvancedViews.swift) ;;
    *) CORE_SOURCES+=("$source") ;;
  esac
done
print "Building PerformanceLoadCheck (-O)"
swiftc -O -parse-as-library "${CORE_SOURCES[@]}" Tests/PerformanceLoadCheck.swift -o .build/checks/PerformanceLoadCheck
export MACPOLISH_PERF_SCALE="${MACPOLISH_PERF_SCALE:-standard}"
export MACPOLISH_PERF_REAL="${MACPOLISH_PERF_REAL:-0}"
export MACPOLISH_PERF_OUT="${MACPOLISH_PERF_OUT:-$PWD/.build/perf}"
export MACPOLISH_PERF_COMMIT="${MACPOLISH_PERF_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || print unknown)}"
print "Running PerformanceLoadCheck (scale $MACPOLISH_PERF_SCALE, real disk ${MACPOLISH_PERF_REAL})"
.build/checks/PerformanceLoadCheck
