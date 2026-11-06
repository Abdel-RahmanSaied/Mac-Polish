# Mac Polish 0.11.0 — Deep scanner & Mac Health

## Scan every file
- Storage Map counts every readable file on the data volume, including files folded into "Smaller items", by kind and by last change, and lists the 250 largest files anywhere on the disk (review only).
- The sealed macOS system volume is read separately, excluding its firmlinks, so no data-volume file is counted twice.
- New pages: Project Artifacts (rebuildable build and dependency folders, never preselected), a startup items security audit (signatures, missing programs, risky locations), Leftover App Data (data of removed apps, review-only) and app details (Intel-only, App Store, signature, last used).
- Deep Scan on Overview runs every scanner at once, shows each step's status and time, and exports a report.

## Mac Health
- Seven categories: Battery, Storage, Memory, Temperature, Disk Health, Security and System Updates. Each shows a state (Healthy, Attention, Critical or Unknown), a plain explanation, measurements, a next step, a confidence level and the time of the reading.
- "Why this score?" shows the full calculation. Each category deducts at most once and is capped; unknown values and momentary memory or temperature readings never lower the score. The score is an estimate, not a hardware diagnosis or security audit.
- Quick Health and a cancellable Extended Health that repeats memory and temperature readings and checks every physical disk.
- A small local history (no file names or paths) shows trends, when a repeated warning was first and last seen, and a storage forecast only when the data is sufficient and steady.
- Buttons open the relevant System Settings page. Mac Polish never changes a setting.

## Permissions, cancellation and safety
- A scan is never refused silently: a notice explains when it is waiting for the permission review (including one open in Settings), and it starts by itself afterwards. Limited access is explained, with the locations that could not be read.
- Cancel stops scan workers within a fraction of a second. Finished results are kept and reports are marked partial. Workers exit when the app quits, and time asleep does not count against time limits.
- Every page uses one confirmation before Trash: names, count, size, selected items hidden by a search, why each category is suggested, and what may need to be downloaded or rebuilt. Items, including apps updated after the scan, are checked again and skipped if they changed.
- Cleanup History records what was moved or skipped, with sizes and reasons (paths only, never file contents), with Open Trash and Put Back instructions.
- Reports can be exported as a full report or a privacy-safe report that replaces your user name, home folder, project and file names.

## Engine fixes
- A folder chain deeper than about 250 levels no longer fails the whole Storage Map.
- The duplicate scan no longer keeps every byte it reads in memory (+4.6 GB before, about +70 MB now under load).
- Scan threads follow the number of cores instead of a fixed 8; on the test Mac the startup disk scan went from 8.6 s to 7.2 s.
- The app builds with Command Line Tools alone (`swift run MacPolish`), which previously failed with the newest SDK.

## Validation
34 regression checks pass locally and in CI, including new checks for disk insights, Mac Health and its history, project artifacts, the security audit, cleanup history, report privacy and the release flows (permissions, cancellation, partial results, cleanup and changed items, all with fakes; no real files moved). The new performance and load suite passes at standard scale (300,000-file trees, 400-level nesting, concurrent scans, duplicates under load and a read-only pass over the startup disk) with no regression, and runs in CI at smoke scale. The app was built and launched; an interactive walkthrough of every page was not part of this validation.

## Requirements and limitations
Apple Silicon, macOS 14+. Preview release, signed with the existing fixed local certificate and hardened runtime; not Apple-notarized. macOS controls permission prompts. Scans can remain incomplete when files are protected, unavailable or blocked inside a filesystem call. Mac Health reports what macOS exposes: some Macs do not report a battery condition, Optimized Battery Charging status is not available to apps, and update state comes from macOS's cached list. Docker build cache cleanup removes the cache permanently (not via Trash) and says so before you confirm.
