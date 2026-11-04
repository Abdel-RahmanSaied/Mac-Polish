# Mac Polish 0.9.1 — Stable Signing & Permission Fixes

- Reuse one signing certificate locally and in CI; hardened runtime blocks library injection. An encrypted signing backup is kept outside the repository.
- Detect denied folders and fingerprint reads instead of presenting incomplete scans as empty. Keep partial caches out of automatic cleanup.
- Report observed protected-location access without claiming to know the Full Disk Access setting. Reopen setup when previously readable probes become restricted.
- Check prompting folders sequentially, and explain filesystem ownership and App Management restrictions when removing apps.

Migration: the previous public build was ad-hoc signed. This first stable-signed update may require granting file access again. Future releases retain the same identity while the signing certificate is unchanged. Cross-build and backup-restore signing requirements have been verified; actual TCC permission retention through two installed updates has not yet been verified.

Validation: 21 local regression checks, signing/injection/Quit checks, isolated real-Trash E2E, and a full local release build using SDK 26.5 passed. Manual testing covered Settings, Memory, Cleanup partial results and Duplicates timeout reporting. The folder-access check can take about 4.5 minutes if all three personal-folder checks time out. GitHub macOS runners have SIP disabled, so they cannot validate runtime injection prevention; that behavioral test passed on the local Mac. App Management behavior with/without Full Disk Access is not exhaustively tested.

Apple Silicon, macOS 14+. Preview release, self-signed (not Apple-notarized). No privacy settings are changed by the installer; macOS remains in control of access.
