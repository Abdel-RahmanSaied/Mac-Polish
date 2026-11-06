#!/bin/zsh
# Source this from a build script: picks a macOS SDK whose SwiftUI this toolchain can compile the app against.
#
# Newer SDKs implement some SwiftUI attributes as macros from the SwiftUIMacros plugin, which Xcode ships and
# Command Line Tools alone may not. The app avoids the one it used (see Sources/MacPolish/ViewState.swift), so the
# default SDK normally works; this stays as a safety net. An SDKROOT you set yourself is always kept. Otherwise the
# default SDK is tried first, then installed SDKs from newest to oldest, by compiling a view written like the app's.
if [[ -z "${SDKROOT:-}" ]]; then
  _macpolish_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/macpolish-sdk.XXXXXX")"
  _macpolish_view_state="${${(%):-%x}:A:h:h}/Sources/MacPolish/ViewState.swift"
  print -r -- 'import SwiftUI
final class ProbeModel: ObservableObject { @Published var value = 0 }
struct Probe: View {
    @StateObject private var model = ProbeModel()
    @ViewState private var text = ""
    var body: some View { TextField("\(model.value)", text: $text) }
}' > "$_macpolish_probe_dir/Probe.swift"
  _macpolish_sdk_works() {
    local -a sdk_flag
    [[ -n "$1" ]] && sdk_flag=(-sdk "$1")
    xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macos14.0 "${sdk_flag[@]}" \
      "$_macpolish_view_state" "$_macpolish_probe_dir/Probe.swift" >/dev/null 2>&1
  }
  if ! _macpolish_sdk_works ""; then
    _macpolish_found=""
    for _macpolish_sdk in ${(On)$(print -l /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk(N))}; do
      if _macpolish_sdk_works "$_macpolish_sdk"; then _macpolish_found="$_macpolish_sdk"; break; fi
    done
    if [[ -n "$_macpolish_found" ]]; then
      export SDKROOT="$_macpolish_found"
      print -u2 "note: the default macOS SDK cannot compile SwiftUI with this toolchain (SwiftUIMacros plugin missing); using ${SDKROOT:t}. Install Xcode or set SDKROOT to choose another."
    else
      print -u2 "warning: no installed macOS SDK compiled a SwiftUI probe with this toolchain. Install Xcode, or set SDKROOT."
    fi
    unset _macpolish_found _macpolish_sdk
  fi
  rm -rf "$_macpolish_probe_dir"
  unset _macpolish_probe_dir _macpolish_view_state
  unfunction _macpolish_sdk_works
fi
