<p align="center">
  <img src="assets/brand/modex-readme-header.png" alt="Modex" width="960" />
</p>

<p align="center">
  Open-source desktop client powered by the Codex engine.
</p>

<p align="center">
  <img alt="Status" src="https://img.shields.io/badge/status-pre--alpha-15212a?style=flat-square" />
  <img alt="License" src="https://img.shields.io/badge/license-MIT-00aeef?style=flat-square" />
</p>

> Modex is not affiliated with OpenAI.

## Development

Modex is a Tauri desktop app. The Rust backend starts a pinned Codex sidecar,
then the UI talks to Codex through the app-server JSON-RPC protocol.

Before running chat, make sure Codex auth is configured locally with `codex login`
or an API key supported by Codex.

```bash
npm install
npm run tauri:dev
```

## Release Build

```bash
npm run tauri:build
```

The macOS app and DMG are written to `src-tauri/target/release/bundle/`.
