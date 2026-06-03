# Security Policy

## Supported Versions

SmartTAR STAR is currently in beta. Security fixes, if needed, will target the latest public beta version.

| Version | Supported |
|---|---|
| v0.1.0-beta | Yes |

## Reporting a Vulnerability

If you find a security issue, please avoid publishing exploit details in a public issue first.

Recommended disclosure process:

1. Open a private security advisory on GitHub, if available for this repository.
2. Or contact the maintainer directly through the contact method listed in the repository profile.
3. Include:
   - affected version,
   - operating system,
   - archive sample if safe to share,
   - reproduction steps,
   - expected vs. actual behavior.

## Security Scope

SmartTAR performs safety checks such as:

- rejecting unsafe manifest block paths,
- rejecting absolute paths,
- rejecting drive-letter paths,
- rejecting `..` path traversal,
- listing TAR block entries before extraction,
- validating SHA-256 hashes where present.

However, SmartTAR is still beta software. Do not use it as the only protection mechanism for critical data.

## General Advice

- Verify archives after creation.
- Keep independent backups.
- Be careful when extracting archives from untrusted sources.
- Prefer extracting untrusted archives into an empty temporary folder.
