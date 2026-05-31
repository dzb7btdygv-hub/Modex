# Modex Agent Notes

Modex is a public, open-source product repo. Treat every committed change as release-facing.

## Product Direction

- Modex is a standalone desktop client, not a patcher for a user's installed Codex Desktop app.
- Modex consumes the upstream Codex engine/app-server as a pinned sidecar first.
- Do not fork Codex unless a concrete protocol limitation forces it.
- Do not vendor Codex binaries into git. Download or bundle them during release builds.
- Positioning: "open-source desktop client powered by the Codex engine."
- Do not imply Modex is official, affiliated with OpenAI, or a fork of OpenAI Codex Desktop.

## Release Discipline

- Keep `main` clean and releasable.
- Prefer small, reviewable changes.
- Add CI, release scripts, and installability before broad feature work.
- Pin external versions explicitly.
- Never commit secrets, auth caches, local logs, generated throwaway assets, or `.env` files.
- Include required third-party license and notice files when distributing bundled dependencies.

## Implementation Priorities

- Tauri + React desktop app.
- Rust supervisor for Codex process management, health checks, safe mode, repair, and logs.
- Connect to `codex app-server` over its JSON-RPC/WebSocket protocol.
- Start with API-key auth unless ChatGPT login is verified as allowed for third-party clients.
- Keep the Codex integration thin and replaceable.

## Code Style

- Prefer simple, direct solutions over abstractions.
- Preserve existing style and structure.
- Avoid comments unless they prevent confusion.
- Do not add large speculative architecture before it is needed.
