# Contributing

Thank you for your interest in SmartTAR STAR.

This project is currently a beta / experimental Windows PowerShell archiver. Contributions are welcome, especially in the following areas:

- testing on different Windows versions,
- testing different `tar.exe` / bsdtar capabilities,
- documentation improvements,
- archive format review,
- safety review,
- UI improvements,
- future CLI mode design.

## Development Notes

- Keep the archive format transparent and recovery-friendly.
- Avoid adding hard dependencies on bundled external compression tools.
- Prefer clear manifest metadata over hidden behavior.
- Keep extraction safety checks strict.
- Document format changes in `docs/archive-format.md` and `CHANGELOG.md`.

## Suggested Workflow

1. Fork the repository.
2. Create a feature branch.
3. Make your changes.
4. Test compression, extraction, and verification.
5. Update documentation if behavior changes.
6. Open a pull request.

## Code Style

- Keep PowerShell code readable and sectioned.
- Prefer explicit helper functions.
- Keep error messages useful for non-developer users.
- Do not remove verification or path-safety checks without a documented replacement.
