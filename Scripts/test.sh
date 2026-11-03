#!/bin/zsh
# Usage: Scripts/test.sh            run every regression check
#        Scripts/test.sh <Check>    run one check, e.g. CleanupPolicyCheck
#        Scripts/test.sh --e2e      run every check, then the isolated real-Trash and disk map E2E tests
set -euo pipefail
cd "${0:A:h:h}"
typeset -a CHECKS=(DuplicateSelectionCheck UpdateCheck AccessSetupCheck OptimizePolicyCheck TrashValidationCheck
                   DuplicateSafetyCheck StorageMeasurementCheck ScannerRegressionCheck CleanupPolicyCheck
                   CleanupConfirmationCheck ScanWorkerGuardCheck BackgroundWorkCheck PartialScanCheck HardeningCheck
                   DiskTreeCheck VolumeUsageCheck DiskMapCheck)
RUN_E2E=false
if [[ $# -gt 1 ]]; then
  print -u2 "Usage: Scripts/test.sh [--e2e | <CheckName>]"
  exit 1
elif [[ "${1:-}" == "--e2e" ]]; then
  RUN_E2E=true
elif [[ $# -eq 1 ]]; then
  [[ -f "Tests/$1.swift" ]] || { print -u2 "Unknown check: $1 (expected Tests/$1.swift)"; exit 1; }
  CHECKS=("$1")
fi
mkdir -p .build/checks
typeset -a CORE_SOURCES
for source in Sources/MacPolish/*.swift; do
  case "$source" in
    */MacPolishApp.swift|*/main.swift|*/ContentView.swift|*/AdvancedViews.swift) ;;
    *) CORE_SOURCES+=("$source") ;;
  esac
done
for name in "${CHECKS[@]}"; do
  print "Running $name"
  swiftc -parse-as-library "${CORE_SOURCES[@]}" "Tests/$name.swift" -o ".build/checks/$name"
  ".build/checks/$name"
done
if [[ "$RUN_E2E" == true ]]; then
  print "Running isolated macOS Trash E2E (only newly created MacPolish-E2E fixtures)"
  swiftc -parse-as-library "${CORE_SOURCES[@]}" Tests/RealTrashE2E.swift -o .build/checks/RealTrashE2E
  .build/checks/RealTrashE2E
  print "Running disk map E2E (isolated fixture through real worker processes, then a read-only pass over the startup disk)"
  swiftc -O -parse-as-library "${CORE_SOURCES[@]}" Tests/DiskMapE2E.swift -o .build/checks/DiskMapE2E
  .build/checks/DiskMapE2E
fi
