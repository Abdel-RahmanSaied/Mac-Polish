# Mac Polish

Mac Polish is a native macOS cleanup utility built with SwiftUI. The first milestone focuses on transparent, reversible cleanup rather than hidden “one-click” deletion.

## Current features

- Scans application caches, logs, and the current user's Trash.
- Finds files larger than 100 MB in Downloads, Documents, and Desktop.
- Shows every result and its exact location before cleanup.
- Never preselects personal large files.
- Moves selected items to Trash instead of deleting them permanently.
- Enforces a path allowlist inside the cleanup engine.
- Finds true duplicate files using streamed SHA-256 hashing.
- Audits installed applications, versions, sizes, and related user-library leftovers.
- Protects built-in macOS applications from removal.
- Maps storage usage across the main home folders.
- Audits user and system launch agents and daemons.
- Finds Xcode DerivedData older than 30 days and regenerable Xcode/Simulator caches.
- Lists Xcode archives and device-support folders older than 180 days for manual review.
- Detects extra installed Xcode copies while always keeping the newest version unselected.
- Detects old Xcode `.xip`/`.dmg` downloads, macOS installers, diagnostics, and device backups.

## Run locally

Requirements: macOS 14 or later and Swift 6.

```sh
swift run MacPolish
```

If the window does not come forward when launched through Swift Package Manager,
build a normal macOS application bundle instead:

```sh
./Scripts/build-app.sh
open "dist/Mac Polish.app"
```

## Safety model

The cleanup engine only accepts descendants of these user-owned directories:

- `~/Library/Caches`
- `~/Library/Logs`
- `~/.Trash`
- `~/Downloads`
- `~/Documents`
- `~/Desktop`
- `~/Pictures`

The roots themselves are blocked. System directories and paths outside this list are rejected.

> This machine currently has the Swift command-line toolchain rather than the full Xcode installation. Install Xcode to create a signed `.app`, add UI tests, and prepare the product for notarization.
