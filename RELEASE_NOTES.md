# Mac Polish release notes

Native macOS storage analysis and cleanup for Apple Silicon (M1 or newer), macOS 14+.

## Unreleased (after 0.8.0)

Accurate storage
- **Storage Map** now maps the whole startup disk:
  - It shows how the APFS container is split between macOS, virtual memory and your data.
  - It shows how much of the used space it explains (for example "97% explained").
  - It lets you open folders level by level down to single files.
  - Space it cannot explain is shown as **Not explained**, with the reasons.
- Sizes are clone-aware. APFS clones (files that share data on disk) and hard links count once across all their paths. `du` and Finder's Get Info count every clone in full. On a developer Mac, this changed one System Data location from 154 GB to 6.7 GB, and the uv cache from 104 GB to 24 GB.
- Folders are read with `getattrlistbulk` on several threads; a 390 GB data volume with 3.1 million files takes about 30 seconds.
- Folders macOS will not let Mac Polish read are counted and shown with a lock, with a shortcut to Full Disk Access, instead of counting as empty.
- Desktop, Documents, Downloads, Pictures, Movies, Music, iCloud Drive, cloud storage and app containers are read in their own workers. An unanswered access request marks only that folder as not read.
- System Data and Optimize use the same measurement instead of `du`. Optimize's disk overview covers the whole startup disk and shares its result with Storage Map.
- A folder that leads to an unreadable or unscanned folder keeps its own row in Storage Map, so the lock can always be reached.
- Large Files includes hidden files and lists packages (such as apps) as one item. Files inside hidden folders such as `.git` are not offered on their own.

Safety
- **Move Selected to Trash** on Cleanup, Large Files, Developer Cleanup and Old Files now asks for confirmation and shows the item count and size.
- Cleanup pages pre-select only what Optimize would suggest: caches and logs where nothing inside changed for more than 7 days. A folder's own date is no longer used alone, because it does not change when files inside it are edited.
- Poetry virtual environments (`pypoetry`) and Playwright browsers (`ms-playwright`) are protected from automatic selection and Optimize, alongside Go, Node, SwiftPM, Docker and Codex data.
- Items already in Trash are shown for review only; they cannot be selected or counted as moved.
- Cleanup skips a folder whose content changed after the scan, even when the folder's own date did not change.
- Old Xcode copies are identified by the bundle identifier `com.apple.dt.Xcode`, so tools such as Xcodes.app are no longer listed.
- Uninstall leftovers are only looked up for plain folder names; an app name such as `../Mail` can no longer point at another Library folder.
- The read-only scan worker refuses to run unless Mac Polish itself launched it, so other programs cannot read files through Mac Polish's file permissions.

Reliability and performance
- The file scan runs each location in its own worker with its own time limit. A location that does not respond (a cloud provider or a pending macOS access request) no longer discards the results from the others; the app names the missing location instead.
- Folder access checks run per folder with a longer time limit, so an unanswered macOS access request is reported as **No answer in time** for that folder only.
- Blocking work (child processes, folder measurements) runs on GCD instead of Swift concurrency's fixed-size thread pool, so opening several tools at once no longer stalls other tasks such as memory readings.
- System Data and Optimize measure up to four locations at once.
- Memory readings no longer launch `ps` every 5 seconds.
- Duplicate detection groups files by content length, so sparse or compressed copies with identical content are found.
- **Open Memory Dashboard** brings the existing main window forward instead of opening another one; File › New Window is removed. The main window is tracked from its own content, so this works however late the window is created.
- The update banner sits above the page content only; it no longer covers the sidebar's app name.
- Scan sections and folder checks all run at the same time on any Mac, including Macs with few cores, so stalled locations no longer delay the others.
- Xcode installers in Downloads are a separate scan section, so a pending Downloads access request no longer hides Xcode, DerivedData and simulator results.
- A renamed copy of Xcode that is listed as an old copy can also be cleaned; other apps are rejected even if named like Xcode.
- Docker build-cache sizes reported in TB are recognised.

## 0.8.0

Safer cleanup with typed failure reasons, bounded scans in child processes, duplicate revalidation and automated validation. See [docs/release-0.8.0-validation.md](docs/release-0.8.0-validation.md).

## Install

Download the ZIP and move **Mac Polish.app** into your Applications folder, or run:

```sh
curl -fsSL https://github.com/Abdel-RahmanSaied/Mac-Polish/releases/download/v0.8.0/install.sh | bash
```

The installer downloads the pinned release, verifies SHA-256 and the local code signature, and installs into `~/Applications` without sudo. Quit Mac Polish before updating. An existing installation is backed up rather than deleted.

Review the installer before executing it if preferred. Checksums detect download corruption; they are not an independent publisher identity check.

## Important release limitations

- This is a personal development preview, ad-hoc signed and **not Apple-notarized**. macOS may require manual approval in Privacy & Security. The installer does not disable Gatekeeper or remove quarantine attributes.
- Intel Macs are not supported by this package.
- Storage scans can be partial due to permissions and time limits.
- Review cleanup selections. Duplicate detection excludes managed dependency caches such as gomodcache and node_modules; do not bulk-remove dependency files found elsewhere.
- Application removal also targets detected related data, which can contain important user files. Back up important data first.
- Ordinary cleanup uses Trash; Docker build-cache cleanup permanently removes regenerable cache. Docker volumes are not targeted.

See README.md and CONTRIBUTING.md in the repository for usage and current limitations.
