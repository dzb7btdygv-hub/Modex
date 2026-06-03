# macOS Signing And Notarization

The shipping product is the **native SwiftUI app** in `macos/`. Local development
builds are unsigned (`project.yml` sets `CODE_SIGNING_ALLOWED: "NO"`,
`CODE_SIGN_IDENTITY: "-"`, `ENABLE_HARDENED_RUNTIME: "NO"`). Public releases
should be signed with a Developer ID and notarized before broad distribution.

## Native app (canonical)

1. **Sign with a Developer ID.** Override the development defaults at build time:

   ```bash
   xcodegen generate --spec macos/project.yml --project macos
   xcodebuild -project macos/Modex.xcodeproj -scheme Modex -configuration Release \
     -derivedDataPath macos/build/DerivedData \
     CODE_SIGNING_ALLOWED=YES \
     CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
     DEVELOPMENT_TEAM=TEAMID \
     ENABLE_HARDENED_RUNTIME=YES \
     build
   ```

   The bundled Codex engine (`Modex.app/Contents/Resources/codex-*`) is a
   separate Mach-O and must be signed too (hardened runtime, with a deep sign):
   `codesign --force --options runtime --sign "Developer ID Application: …"` the
   helper, then the app.

2. **Notarize** the `.app` (or a DMG built from it) with `notarytool`, then
   `xcrun stapler staple` the result:

   ```bash
   xcrun notarytool submit Modex.dmg --apple-id "$APPLE_ID" \
     --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD" --wait
   xcrun stapler staple Modex.dmg
   ```

Store `APPLE_ID`, `APPLE_PASSWORD` (app-specific password), `APPLE_TEAM_ID`, and
the signing identity / certificate as GitHub Actions secrets. Without them a build
still runs, but Gatekeeper warns users the app is from an unidentified developer.

> CI note: the native build/release jobs require the macOS 26 SDK (Xcode 26),
> which is newer than current hosted runners. They are wired up but kept
> non-blocking until those runners are available; until then, cut releases from a
> local Xcode 26 machine using the steps above.

## Legacy Tauri client

The legacy Tauri build (`npm run tauri:build`, bundle id
`dev.modex.desktop.legacy`) signs/notarizes via Tauri's own flow and these env
vars: `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`,
`APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`. Reference:
https://v2.tauri.app/distribute/sign/macos/ — it is not the shipping product.
