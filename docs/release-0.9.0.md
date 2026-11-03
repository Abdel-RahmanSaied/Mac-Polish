# Mac Polish 0.9.0 — Storage Map & Safer Cleanup

- Whole Data-volume Storage Map with protected-folder workers and explicit incomplete scan results.
- APFS clone/hard-link attribution and reconciliation against the startup Data device.
- Partial cache measurements are excluded from automatic selection and Optimize. Cleanup rechecks readability and nested modification dates before moving an item.
- Regression coverage includes unreadable nested content, access lost after scanning, worker serialization, and multiple Data volumes in one APFS container.

Validation: all 17 regression checks passed locally. Full local UI build is blocked by the installed SDK's missing SwiftUIMacros plugin; release packaging and validation run on GitHub's macOS runner. No personal files were moved during the regression checks. Whole-disk coverage depends on permissions; unexplained space and APFS attribution remain estimates. Interactive UI and real-disk destructive cleanup have not been validated for this release.

Apple Silicon, macOS 14+. Ad-hoc signed, not Apple notarized. Preview release.
