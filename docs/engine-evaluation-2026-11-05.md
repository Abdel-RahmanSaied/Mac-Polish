# Scan engine evaluation — 2026-11-05

Scope: the v0.9.2 source plus the changes in this working tree. No release was published or installed as part of this evaluation. Personal files were not cleaned; Trash actions used isolated test fixtures and restored their contents.

## Findings corrected

| Finding | Change | Evidence |
| --- | --- | --- |
| Cleanup omitted hidden direct children, including hidden Trash contents. | Include hidden entries in cleanup and aged-child enumeration; existing selection and symlink rules still apply. | New fixture failed on the original scanner, passes after the change. |
| Overlapping duplicate roots could list the same path multiple times; hard links appeared as extra copies. | Deduplicate by device and inode before hashing. | One file under overlapping roots produces no duplicates; adding a hard link still produces none; an independent copy is found. |
| Same-length files always required complete hashing. | Reject different 64 KiB beginning/middle/end samples before complete SHA-256. Samples never establish equality. | 24 different 2 MiB files require zero full hashes; two files with identical samples but different unsampled content require full hashes and are rejected. |
| Duplicate timeouts discarded all results. | Cooperative 50-second worker budget, checked during enumeration and hashing; return verified groups with an incomplete warning before the existing 60-second process limit. | Injected timeout after two verified copies retains that group, sets incomplete, and survives JSON encoding. Expired deadlines stop hashing. |
| Duplicate content length was presented as reclaimable disk space. | Preserve content length for grouping and display, separately estimate on-disk allocation for totals and cleanup accounting. | Sparse duplicate fixtures retain their logical size but report smaller on-disk estimates. UI explicitly labels the estimate. |
| Old Xcode/macOS installer measurements discarded access errors and appeared complete. | Use the same measured-item path as cleanup, including completeness, nested dates and denied paths. | Partly inaccessible macOS installer is reported as incomplete and not selected. |
| Folding zero-byte denied tree nodes could hide all child warnings. | Keep the folded summary when it contains unreadable or unscanned entries. | Zero-child display limit still exposes the denied count. |

## Verification

- Full arm64 release build succeeded using the locally installed MacOSX26.5 SDK (27.72 seconds). Existing CLT search-path/stale-build warnings remain; no compile errors.
- `Scripts/test.sh --e2e` succeeded: 23 Swift check executables, isolated installer test, real-Trash E2E and disk-map E2E.
- Real-Trash E2E: two fixture moves, one changed-file skip, both retained copies intact, restoration succeeded.
- Disk-map fixture: actual child processes, APFS clone/hard-link accounting, hidden/package content, denied folders, timeout termination, grafting, reconciliation, and worker-launch guard passed.
- Read-only startup-volume test: 1,148,335 files, 114.9 GB measured out of 184.4 GB reported for the Data volume, 355 unreadable entries, approximately 8 seconds. This test intentionally excludes privacy-sensitive folders; its 62% coverage is **not** a full-device coverage claim.
- Sampling fixture: 48 MiB of equal-length candidates, at most 4.5 MiB sampled, zero complete hashes. One observed run took 0.012 seconds. This is a synthetic fixture, not a promise of a universal speedup.
- `git diff --check` passed.

## Remaining limits

- Full Disk Access is controlled by macOS. This run did not grant permissions or validate a fully authorized scan of every protected folder, external disk or cloud provider. The startup test does not explain all remaining Data-volume bytes.
- Duplicate search remains scoped to Downloads, Documents, Desktop and Pictures, excludes hidden/package/managed-dependency contents, and defaults to files at least 1 MiB. Cleanup categories and the startup storage map have different scopes. They should not be expected to produce the same total.
- Cooperative deadlines cannot interrupt a filesystem call blocked inside macOS. The outer process timeout still handles that case, and can discard that worker's partial results. Basic cleanup and application workers still return their results at completion, not as a live stream.
- Scan results describe a changing filesystem, not an atomic snapshot. Duplicate removal re-hashes and retains a verified copy, and cleanup revalidates paths and dates.
- APFS clone allocation is an attribution estimate, not a guarantee of immediately freed bytes. Snapshots, sparse files, filesystem metadata and Trash affect the actual change in free space. Files moved to Trash do not immediately free that space.
- Application/startup discovery still has narrower error reporting than cleanup/duplicates. Non-permission I/O errors and files disappearing mid-scan are not yet represented by a comprehensive per-file diagnostics model.
- No new graphical click-through E2E, signing test, notarization test or cloud-provider test was run. Full compilation and the existing model/worker/filesystem regression and E2E checks were run. Signing code was not changed.

Recommended next development: expose per-location progress and a resumable scan, retain partial results even when a worker is forcibly terminated, and show a unified coverage report with explicit skipped/denied/failed locations. These are additional features, not claims about this patch.
