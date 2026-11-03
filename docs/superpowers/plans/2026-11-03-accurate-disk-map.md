# Accurate Disk Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mac Polish explains at least 95% of the space macOS reports as used. It does this with clone-aware sizes, a whole-volume scan, an open "unexplained" remainder, and folder-by-folder drill-down.

**Architecture:** One `getattrlistbulk` directory reader feeds two consumers:
- a sequential size measurer (`FileSizeCalculator`);
- a parallel tree scanner (`DiskTreeScanner`) that prunes small entries as it goes.

Each file counts `allocated / cloneRefCount / linkCount` bytes, so APFS clones and hard links add up to their real usage. The read-only worker gains a `tree` mode. The Storage Map scans the data volume in one worker and each permission-protected folder in its own worker, then grafts the results together. It reconciles the total against the APFS volume usage from `diskutil apfs list -plist`. System Data and Optimize use the same measurer instead of `du`.

**Tech Stack:** Swift 6 / SwiftUI, macOS 14+, Darwin `getattrlistbulk`/`getattrlist`, no new dependencies.

**Spec:** Chat request "fix all" covering the six findings:
1. clone and hard-link overcount;
2. fixed location lists;
3. no reconciliation;
4. silent unreadable folders;
5. Large Files skips hidden files and packages;
6. flat, slow scanning.

Probe results on the user's Mac (2026-11-03):
- 25 s to scan the data volume with 8 threads.
- Data volume 389.2 GB; 296.0 GB found outside the protected folders.
- Modified-clone uncertainty 6.5 GB.

## Global Constraints

- Read-only scanning; nothing in this plan deletes or moves files.
- Scans that can meet a macOS access prompt run in the `--scan-worker` child process with a deadline, never in the app process.
- Stay on one device: never cross mount points or follow symlinks.
- Test binaries must never launch the worker. Every worker-backed API takes an injectable reader.
- Check binaries compile all sources except `MacPolishApp.swift`, `main.swift`, `ContentView.swift` and `AdvancedViews.swift`, so new non-view code must not reference views from those files.
- No commits unless the user asks.

## Review Focus

- **A protected folder's prompt is never answered:** that folder shows "No answer in time" and the rest of the map still appears. (Task 4 test: a failing reader for one protected folder.)
- **The data-volume total exceeds macOS used space** (modified clones counted twice): coverage is capped at 100% and the uncertainty is shown. (Task 3 test.)
- **A folder becomes unreadable mid-scan, or has `chmod 000`:** it is counted, listed with a lock, and the scan continues. (Task 2 test.)
- **The deadline passes mid-scan:** a partial tree is returned with `incomplete == true`, never a hang. (Task 2 test.)
- **Large hidden files inside `.git` in Documents** are not offered for trashing. (Task 6 test.)

---

### Task 1: Bulk attribute reader and clone-aware sizes

**Files:**
- Create: `Sources/MacPolish/FileAttributes.swift`
- Modify: `Sources/MacPolish/AdvancedScanners.swift` (`FileSizeCalculator`, `SizeMeasurement`)
- Test: `Tests/StorageMeasurementCheck.swift` (extend)

**Interfaces:**
- Produces:
  - `struct FileAttributes { name: String; kind: Kind (.file/.folder/.symlink/.other); device: Int32; isMountPoint: Bool; modified: Date?; linkCount: UInt32; allocated: Int64; privateSize: Int64?; cloneRefCount: UInt32; error: Int32 }`
  - `var attributedBytes: Int64`, computed as `allocated / max(cloneRefCount,1) / max(linkCount,1)`.
  - `var uncertainBytes: Int64`, computed as `(allocated - privateSize) / linkCount` when `cloneRefCount <= 1 && privateSize < allocated`, else 0.
  - `static func read(path: String) -> FileAttributes?` (`getattrlist`, no-follow).
  - `enum BulkDirectoryReader { static func entries(of path: String) -> Result<[FileAttributes], Int32> }` (errno on open/read failure).
  - `SizeMeasurement` gains `var unreadableFolders = 0`.

- [ ] Step 1: Add assertions to `StorageMeasurementCheck`:
  - A 4 MiB random file cloned once with `clonefile`: `allocatedSize(of: dir) == alloc(one file)`.
  - A hard link of a third file adds nothing.
  - A `chmod 000` subfolder gives `measure(root).unreadableFolders == 1`.
  - Keep the existing package, hidden-file and symlink assertions.
- [ ] Step 2: `Scripts/test.sh StorageMeasurementCheck` fails on the clone assertion.
- [ ] Step 3: Implement the reader. Parse each entry in attribute-bit order (`RETURNED`, `ERROR`, `NAME`, `DEVID`, `OBJTYPE`, `MODTIME`; dir `MOUNTSTATUS`; file `LINKCOUNT`, `ALLOCSIZE`; ext `PRIVATESIZE`, `CLONE_REFCNT`) with `loadUnaligned`. Rewrite `FileSizeCalculator.measure` as a same-device recursive walk over it, keeping the newest-modification rule.
- [ ] Step 4: All checks pass.

### Task 2: Parallel pruned tree scanner

**Files:**
- Create: `Sources/MacPolish/DiskTree.swift`
- Test: `Tests/DiskTreeCheck.swift` (new; add to `CHECKS`)

**Interfaces:**
- Consumes: `FileAttributes`, `BulkDirectoryReader`.
- Produces:
  - `struct DiskNode: Codable, Sendable, Hashable { name; kind: Kind (.folder/.file/.smallerItems/.unreadable/.notScanned); bytes: Int64; files: Int; uncertainBytes: Int64; unreadable: Int; notScanned: Int; note: String?; children: [DiskNode] }`, with short coding keys.
  - `func grafting(_ node: DiskNode, at components: [String]) -> DiskNode`.
  - `struct DiskTreeOptions: Codable, Sendable { minimumListedBytes = 1 MiB; maximumChildren = 200; keepDepth = Int.max; excluded: [String] = []; deadline: Date? ; threads = 8 }`.
  - `struct DiskTreeResult: Codable, Sendable { root: DiskNode; incomplete: Bool; unreadablePaths: [String] (first 50) }`.
  - `enum DiskTreeScanner { static func scan(_ path: String, options: DiskTreeOptions) -> DiskTreeResult }`.

- [ ] Step 1: Tests on a fixture tree:
  - The total equals the sum of the files' attributed bytes, including hidden files and package contents.
  - Clones are counted once.
  - Entries under 1 MiB fold into one `.smallerItems` child, and `bytes` totals are preserved at every level.
  - A `chmod 000` folder appears as `.unreadable` and its path is in `unreadablePaths`.
  - An excluded path is absent.
  - A past deadline gives `incomplete == true`.
  - `threads: 1` and `threads: 8` give identical trees.
  - `grafting` adds a subtree, creating missing intermediate folders, and updates the ancestors' totals.
  - The fixture total matches `du -sk` within one block per file when there are no clones.
- [ ] Step 2: The check fails (the types are missing).
- [ ] Step 3: Implement it with a work stack and an `NSCondition`. Each pending folder counts its unfinished subfolders. When the count reaches 0, the folder is finalized: sort, prune, apply `keepDepth`, and report to its parent. Finalizing the root ends the scan. A LIFO stack keeps memory to the active path.
- [ ] Step 4: All checks pass.

### Task 3: Volume usage and reconciliation

**Files:**
- Create: `Sources/MacPolish/VolumeUsage.swift`
- Test: `Tests/VolumeUsageCheck.swift` (new; add to `CHECKS`)

**Interfaces:**
- Produces:
  - `struct VolumeUsage: Sendable { capacity; free; volumes: [Volume(name, role, bytes)]; snapshotCount; purgeable: Int64? }`, with `used` and `dataBytes`.
  - `static func parse(apfsList: Data, dataDevice: String) -> VolumeUsage?`.
  - `static func read() -> VolumeUsage?`, which runs `diskutil apfs list -plist` and `listSnapshots` through `SystemDataScanner.run` (15 s).
  - `struct StorageReconciliation { dataUsed; found; uncertain; unreadable; notScanned; unexplained; coverage (capped at 1) ; meetsTarget (>= 0.95) }`.

- [ ] Step 1: Tests:
  - The fixture plist is a trimmed copy of this Mac's output, with two containers. The parser picks `disk3`: capacity 494384795648, six volumes, `dataBytes` 389170425856.
  - An unknown device gives nil.
  - Reconciliation: found 380 of 389 → coverage ≈ 0.976, `meetsTarget` true. Found 400 of 389 → coverage 1, unexplained 0.
- [ ] Step 2: The check fails. Step 3: implement. Step 4: all checks pass.

### Task 4: Worker `tree` mode and disk map service

**Files:**
- Create: `Sources/MacPolish/DiskMapService.swift`
- Modify: `Sources/MacPolish/ScanWorker.swift` (replace `storage` with `tree`), `Sources/MacPolish/DiskScanService.swift` (single-value `readValue`)
- Remove: `StorageScanner` and `StorageEntry`
- Test: `Tests/DiskMapCheck.swift` (new; add to `CHECKS`)

**Interfaces:**
- Produces:
  - `typealias TreeReader = @Sendable (String, DiskTreeOptions, TimeInterval) -> Result<DiskTreeResult, DiskScanFailure>`.
  - `DiskMapService.workerReader` (arguments `--root`, `--options <json>`; the worker deadline is the timeout minus 10 s).
  - `DiskMapService.inProcessReader`.
  - `static func scan(home:, dataRoot: = "/System/Volumes/Data", timeout: 900, reader:, volumes: () -> VolumeUsage?) -> Result<DiskMapReport, DiskScanFailure>`.
  - `struct DiskMapReport: Sendable { tree: DiskTreeResult; volumes: VolumeUsage?; reconciliation: StorageReconciliation?; date }`.
  - `static func protectedFolders(home:) -> [URL]`: Desktop, Documents, Downloads, Pictures, Movies, Music, Library/Mobile Documents, Library/CloudStorage, Library/Containers, Library/Group Containers.
  - `static func displayPath(_ dataPath: String) -> String`.

- [ ] Step 1: Tests, using the in-process reader on a fixture "data root" with a fake home:
  - Protected folders are scanned separately and grafted at their paths.
  - A reader that fails for Desktop gives a `.notScanned` Desktop node with note "No answer in time…" while the other totals stay intact.
  - If the main reader fails, the result is `.failure`.
  - `displayPath("/System/Volumes/Data/Users/x")` returns `"/Users/x"`.
  - The worker argument parser round-trips the options.
- [ ] Step 2: The check fails. Step 3: implement. Step 4: all checks pass.

### Task 5: System Data and Optimize without `du`

**Files:**
- Modify: `Sources/MacPolish/SystemData.swift` (`measure` → tree reader, `keepDepth: 1`, `threads: 4`; drop `parseDU`/`measurementStatus` for `status(for:)`)
- Modify: `Sources/MacPolish/Optimize.swift` (disk areas from `DiskMapService.scan`; coverage text from reconciliation; `onDiskMap` callback)
- Modify: `Sources/MacPolish/AppModel.swift` (wire the callback)
- Test: `Tests/OptimizePolicyCheck.swift` (update the `du` assertions)

- [ ] Step 1: Tests. Replace the `parseDU`/`measurementStatus` assertions with these, using the in-process reader:
  - `measure(name:url:note:reader:)` on a fixture: `!partial`, bytes equal to the tree total, children ≤ 6.
  - A missing path: partial, `bytes == nil`, diagnostic contains "missing".
  - An unreadable child: partial, diagnostic contains "Full Disk Access".
  - A timed-out failure: diagnostic contains "time".
- [ ] Step 2: The check fails. Step 3: implement. Step 4: all checks pass.

### Task 6: Large Files includes hidden files and packages

**Files:**
- Modify: `Sources/MacPolish/Scanner.swift` (`DiskScanner.init(…, largeFileMinimum: Int64 = 100 MiB)`, `scanLargeFiles`)
- Test: `Tests/ScannerRegressionCheck.swift` (extend)

- [ ] Step 1: Tests with `largeFileMinimum: 1 MiB` on a fake home:
  - A hidden 2 MiB file in Downloads is listed.
  - A 2 MiB `.app`/`.bundle` package is listed once as one item, and its inner file is not.
  - A 2 MiB file inside `Documents/proj/.git/` is not listed.
  - Sizes use attributed bytes, so a cloned pair lists 1 MiB each.
- [ ] Step 2: The check fails. Step 3: implement: drop `.skipsHiddenFiles`; skip the descendants of hidden folders; measure packages whole. Step 4: all checks pass.

### Task 7: Storage Map screen

**Files:**
- Modify: `Sources/MacPolish/AdvancedViews.swift` (replace `StorageMapView`/`StorageBar`), `Sources/MacPolish/AppModel.swift` (`diskMap`, `diskMapState`, `analyzeStorage`)

- [ ] Step 1: Summary:
  - A capacity line with used, free and purgeable space.
  - Volume rows: macOS (System + Preboot + Recovery + Update), virtual memory, data.
  - An accuracy line: "Found X of Y on the data volume (Z%)", the unexplained remainder with its reasons, the uncertainty, and a Full Disk Access button when anything was unreadable.
- [ ] Step 2: Browser:
  - A breadcrumb from Macintosh HD.
  - Rows sorted by size, each with a bar relative to its parent, the size and a file count.
  - Folder rows drill down; file rows have Reveal in Finder.
  - Lock rows show "Needs Full Disk Access", and `.notScanned` rows show their note.
- [ ] Step 3: `swift build` succeeds and the offscreen render harness shows the summary and browser with fixture data.

### Task 8: Docs and full verification

- [ ] Update README (Arabic), CONTRIBUTING (file table and checks) and the "Unreleased" section of RELEASE_NOTES.
- [ ] `swift build`, `Scripts/test.sh` (all checks), `git diff --check`, and a release bundle build.
- [ ] A real run, read-only: build the app and run its worker `tree` mode against `/System/Volumes/Data`, excluding the protected folders. Compare against the probe (≈296 GB, about 25 s).
