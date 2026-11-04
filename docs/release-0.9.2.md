# Mac Polish 0.9.2 — One App Copy & Cleaner Updates

- Keep exactly one installed Mac Polish app in `~/Applications`. The installer archives one previous version as a ZIP under `~/Library/Application Support/Mac Polish/Previous Version` instead of keeping additional app bundles in Applications.
- Move recognized legacy `MacPolish-backup.*` folders to Trash and unregister those copies from Launch Services.
- Detect other app copies and warn about different signing identities in access setup.
- Preserve nonzero exit status on installation errors; support checked local release installation with `--from DIRECTORY`.
- Reuse the same signing certificate as 0.9.1, with hardened runtime enabled.

Validation: the source change passed the full GitHub build, 22 Swift regression checks, the isolated installer test, and signing checks before release preparation. The release pipeline reruns regression and installer checks and verifies the packaged signature and architecture. Runtime injection prevention is not validated on GitHub's SIP-disabled runners; the local behavioral check passed for the earlier signing release. Full Disk Access/App Management interactions and actual TCC persistence across installed updates are not exhaustively validated.

Apple Silicon, macOS 14+. Preview, self-signed and not Apple-notarized. Upgrading from the old ad-hoc builds may require granting access again. No privacy or security settings are changed by the installer.
