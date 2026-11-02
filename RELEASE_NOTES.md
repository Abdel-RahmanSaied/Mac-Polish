# Mac Polish v0.3.0 — Personal preview

Native macOS storage analysis and cleanup for Apple Silicon (M1 or newer), macOS 14+.

Includes Optimize, System Data with Docker build-cache cleanup, large-file and duplicate discovery, application inspection, developer cleanup and startup-item auditing.

## Install

Download the ZIP and move **Mac Polish.app** into your Applications folder, or run:

```sh
curl -fsSL https://github.com/Abdel-RahmanSaied/Mac-Polish/releases/download/v0.3.0/install.sh | bash
```

The installer downloads the pinned release, verifies SHA-256 and the local code signature, and installs into `~/Applications` without sudo. Quit Mac Polish before updating. An existing installation is backed up rather than deleted.

Review the installer before executing it if preferred. Checksums detect download corruption; they are not an independent publisher identity check.

## Important release limitations

- This is a personal development preview, ad-hoc signed and **not Apple-notarized**. macOS may require manual approval in Privacy & Security. The installer does not disable Gatekeeper or remove quarantine attributes.
- Intel Macs are not supported by this package.
- Storage scans can be partial due to permissions and time limits.
- Review cleanup selections. Duplicate detection can include dependency files in managed caches such as gomodcache; do not bulk-remove those files.
- Application removal also targets detected related data, which can contain important user files. Back up important data first.
- Ordinary cleanup uses Trash; Docker build-cache cleanup permanently removes regenerable cache. Docker volumes are not targeted.

See README.md and CONTRIBUTING.md in the repository for usage and current limitations.
