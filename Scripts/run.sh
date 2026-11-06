#!/bin/zsh
# Usage: Scripts/run.sh [arguments]   build and run Mac Polish for development (`swift run MacPolish`),
#                                      with a macOS SDK this toolchain can compile SwiftUI against (see Scripts/sdk.sh).
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/sdk.sh
exec swift run MacPolish "$@"
