#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/checks
typeset -a CORE_SOURCES
for source in Sources/MacPolish/*.swift; do
  case "$source" in
    */MacPolishApp.swift|*/main.swift|*/ContentView.swift|*/AdvancedViews.swift) ;;
    *) CORE_SOURCES+=("$source") ;;
  esac
done
for name in DuplicateSelectionCheck UpdateCheck AccessSetupCheck OptimizePolicyCheck TrashValidationCheck DuplicateSafetyCheck StorageMeasurementCheck ScannerRegressionCheck; do
  print "Running $name"
  swiftc -parse-as-library "${CORE_SOURCES[@]}" "Tests/$name.swift" -o ".build/checks/$name"
  ".build/checks/$name"
done
if [[ "${1:-}" == "--e2e" ]]; then
  print "Running isolated macOS Trash E2E (only newly created MacPolish-E2E fixtures)"
  swiftc -parse-as-library "${CORE_SOURCES[@]}" Tests/RealTrashE2E.swift -o .build/checks/RealTrashE2E
  .build/checks/RealTrashE2E
elif [[ $# -ne 0 ]]; then
  print -u2 "Usage: Scripts/test.sh [--e2e]"
  exit 1
fi
