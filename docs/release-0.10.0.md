# Mac Polish 0.10.0 — Scan details & guided setup

## Guided permissions
- Five-step onboarding explains Full Disk Access, checks 16 locations, offers optional App Management guidance, and summarizes limited access.
- Folder results appear as checks finish. Setup resumes at the saved step after reopening.
- Xcode user data is explicitly labeled as the optional ~/Library/Developer folder, not the Xcode installation.

## Deeper inspection
- Choose Disk or Folder in Storage Map to inspect a selected mounted disk or folder.
- Inspect every item lists small, hidden and empty entries, with 200-row pagination and on-demand folder navigation.
- Inaccessible and timed-out locations stay visible. macOS permissions do not guarantee access to every file; other mounted volumes must be selected separately.

## Scan engine fixes
- Include hidden cleanup/Trash entries and report partial installer measurements.
- Deduplicate overlapping roots and hard links before finding duplicate content.
- Filter same-sized candidates using small samples, then confirm matches using complete SHA-256 hashing.
- Preserve verified duplicate groups when the cooperative deadline is reached; display an incomplete warning.
- Estimate duplicate disk allocation separately from content length, and retain warnings when small tree entries are folded.

## Validation
Local arm64 release build, 23 Swift checks, isolated installer verification and disk-map E2E passed during development. Real-Trash E2E passed for the engine changes using disposable fixtures. The release workflow repeats regression checks, builds the app and verifies its package signature. See docs/engine-evaluation-2026-11-05.md for scope and limitations.

## Requirements and limitations
Apple Silicon, macOS 14+. Preview release, signed with the existing fixed local certificate and hardened runtime; not Apple-notarized. macOS controls permission prompts. Scans can remain incomplete when files are protected, unavailable or blocked inside a filesystem call. Shared APFS space is an estimate, and moving files to Trash does not immediately reclaim it.
