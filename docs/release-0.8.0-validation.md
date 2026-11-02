# Mac Polish 0.8.0 — validation report

Release candidate: **0.8.0 (12)** · validation date: **2026-11-03**.

## Changes delivered

- Added direct sidebar Settings access, a larger Settings window, and session-only Last Cleanup details with per-file reasons and Finder reveal.
- Replaced repeated permission-error paragraphs with typed summaries. Permission failures lead to the access setup with affected paths; locked files, managed dependencies and read-only folders receive different guidance. Reviewing access never resumes cleanup automatically.
- Renamed the optional `~/Library/Developer` check to **Xcode user data** and explained that it does not detect installed Command Line Tools.
- Set the runtime application icon at launch/reopen, verified the bundle icon resource during packaging, and refreshed only the installed bundle's Launch Services registration.
- Revalidated duplicate contents and the retained copy before each move. Changed/missing copies are skipped; at least one valid retained copy must remain. Excluded Go module and Node dependency caches from ordinary duplicate removal.
- Rejected symlinks and redirected ancestor folders; protected Mac Polish itself from uninstall selection.
- Included hidden files and application-package contents in allocated-size measurements.
- Moved filesystem scans and access checks into read-only child processes with deadlines. A stalled directory/provider/access request now returns an incomplete-scan state. Process deadlines include escalation for workers that ignore termination.
- Added automated regression checks, a fixture UI test host, GitHub Actions validation and four real application screenshots in README.

## Local environment

Apple Silicon arm64, macOS 27.0.1 (26A434), Apple Swift 6.4.2. Debug and optimized application builds were exercised. The package targets macOS 14+ on Apple Silicon; this local run does not establish compatibility with every supported macOS version.

## Automated checks

Command: `Scripts/test.sh --e2e`.

| Check | Result / coverage |
| --- | --- |
| DuplicateSelectionCheck | PASS — deterministic extra-copy selection, preserve a keeper |
| UpdateCheck | PASS — numeric ordering, preview channels, drafts, required assets, downgrade prevention |
| AccessSetupCheck | PASS — readable, absent, restricted, unknown folders; isolated preferences and setup completion |
| OptimizePolicyCheck | PASS — older-cache selection, personal-file exclusion, Docker zero/positive/unknown gating and scan coverage |
| TrashValidationCheck | PASS — nested Cocoa/POSIX errors, locked/read-only/managed folders, partial success, failed selection retention, no automatic retry |
| DuplicateSafetyCheck | PASS — content changes, missing/changed keeper, symlinks, managed dependency exclusion |
| StorageMeasurementCheck | PASS — packages/hidden files, allocated sizes, symlink exclusion, process deadline and launch failure |
| ScannerRegressionCheck | PASS — isolated Downloads tree with aged Xcode installer and a FIFO; special files ignored |
| RealTrashE2E | PASS — real scan → select extras → revalidate → macOS Trash → restore |

The real Trash E2E created only its own uniquely named cache fixtures, moved **two extra copies**, skipped **one edited file**, preserved both originals, restored both moved files and verified their bytes. Existing Trash contents and personal files were not used as test cleanup targets.

Additional checks: shell syntax, plist validation, `git diff --check`, bundle signature verification, architecture verification and archive checksum generation.

## UI checks

| Scenario | Observation |
| --- | --- |
| Sidebar/navigation | Actual Overview, Cleanup, Duplicates, Applications, Storage Map, System Data, Developer Cleanup, Old Files, Startup Items, Memory, Optimize and Settings opened |
| Actual file scan | Completed and displayed cleanup candidates; UI stayed responsive |
| Applications | Listed installed apps; search worked; Mac Polish and system apps had disabled removal controls |
| Duplicates | Actual scan completed with no eligible duplicates; destructive and error paths exercised separately with fixtures |
| Storage Map / Startup | Actual measurements and startup entries displayed |
| System Data | Actual measurements displayed with partial/unavailable locations marked; Docker build-cache action disabled for zero cache; volumes not selected |
| Optimize | Actual scan produced a review plan; denied areas were disclosed; confirmation showed counts/size; Cancel returned without executing cleanup |
| Memory | Live readings and history updated while scans ran; selection/confirmation/cancel path exercised without quitting personal apps |
| Permissions | Actual check returned readable personal folders, optional absent Xcode user data, restricted Trash; no automatic permission grant |
| Permission recovery UI | Fixture permission alert → details → affected paths → access setup → return; no automatic retry |
| Locked-file UI | Fixture failure showed distinct guidance instead of treating it as a permission grant problem |
| Menu-bar monitor | Native popover exposed live RAM, pressure, Swap and update status; its dashboard button was not independently verified |
| Icon/version | Native About dialog showed the custom icon and 0.8.0 (12) |
| README gallery | Four real screenshots inspected for layout; no document contents or personal file paths published |

An initial in-process directory scan stalled inside macOS directory enumeration for Downloads. A sample identified the blocked read. After moving filesystem work into deadline-controlled child processes, actual scanning, access checks and Optimize completed. Tests additionally cover termination deadlines; the UI does not claim that denied locations were fully scanned.

## CI, publication and installed-app check

- [GitHub Actions run 41531317045](https://github.com/Abdel-RahmanSaied/Mac-Polish/actions/runs/41531317045): **PASS** for build, all eight regression executables, shell syntax and metadata on **macOS 15.8.2 arm64**. An initial SDK isolation error in the shared module header was corrected with explicit `@MainActor` before publishing.
- [v0.8.0 preview release](https://github.com/Abdel-RahmanSaied/Mac-Polish/releases/tag/v0.8.0) published with the arm64 ZIP, pinned installer and SHA256SUMS. Code revision: `f18d5fc`.
- Downloaded the published installer and compared it with the source. `--verify-only` passed. Running-app installation refusal passed.
- Installed from the published asset into the current user's Applications folder; previous installation preserved. Installed signature/version checks passed, the app launched, and its manual updater returned **You're up to date (0.8.0)**.
- **Installed file-scan coverage is incomplete:** the fresh installation's file scan reached its deadline. The app displayed **Incomplete**, enabled retry and opened access setup correctly; returning did not retry automatically. Memory monitoring continued afterward. This is a handled timeout, not a successful full installed-device scan. The exact stalled directory/provider/access request in this installation was not established; no macOS permissions were changed to force the test through.

## Scope limits

- Full Disk Access remains a manual macOS decision. Its grant/relaunch flow was not automated. The app cannot repair ownership, ACLs, immutable flags or read-only volumes by requesting Full Disk Access.
- The visible Dock tile and menu-bar dashboard-button navigation were not independently verified. The menu-bar live status, native About icon, bundle icon and runtime icon assignment were verified.
- Destructive GUI confirmation was cancelled on real personal data. Actual Trash moves/restores used isolated fixtures. Personal app uninstall, force quit, permanent Trash emptying and Docker pruning were not executed in this validation.
- Folder measurements can be partial. System Data locations are not an exact reproduction of Apple's storage category; APFS sharing/snapshots affect recovered space.
- This is an ad-hoc signed personal release, not Apple-notarized; no macOS security settings were changed.
- Update downloads/installation remain manual, as described in Settings.

## Reproduce

```sh
swift build
Scripts/test.sh
Scripts/test.sh --e2e  # creates, trashes, restores and removes only its own fixtures
Scripts/package-release.sh
```

The fixture UI host is built with `Scripts/build-ui-e2e.sh`; it uses a separate bundle identifier and disposable test files. It is not included in the distributed app. Local diagnostic logs and sampled process stacks are excluded from source control.
