# macOS Signing And Notarization

Local development builds are unsigned. Public macOS releases should be signed and notarized before broad distribution.

Tauri supports macOS signing and notarization through these environment variables:

- `APPLE_CERTIFICATE`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_PASSWORD`
- `APPLE_TEAM_ID`

Set these as GitHub Actions secrets before publishing public releases. Without them, the release workflow can still produce a DMG, but macOS Gatekeeper will warn users that the app is from an unidentified developer.

Reference: https://v2.tauri.app/distribute/sign/macos/
