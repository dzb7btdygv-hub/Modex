# Essential Features for AI Coding-Agent Desktop Apps

A reference for the genre Modex belongs to: desktop/CLI clients that wrap a coding
agent (Claude Code, OpenAI Codex, Aider, Cursor's agent, Continue, and similar
worktree/terminal/agent tools). It captures *what good looks like* so product and
review decisions can be measured against it.

This is a **no-code reference document**, not a backlog. Nothing here should be
built just because it is listed. For each feature: what it is, why it matters,
what "good" looks like, what failure looks like, a priority tier, and — where the
repository makes it inferable — a note on where **Modex** stands today.

Priority tiers:

- **Must-have** — the app is broken or untrustworthy without it.
- **Should-have** — expected by serious users; its absence is a real gap.
- **Advanced** — differentiator or power-user feature; valuable but not table stakes.

---

## 1. First-run onboarding

- **What:** The first launch explains what the app needs (a signed-in agent, a
  project folder, permissions) and gets the user to a working chat.
- **Why:** These tools have real prerequisites (CLI auth, a local engine). Without
  guidance, the first action fails and the user assumes the app is broken.
- **Good:** Detects missing prerequisites and tells the user exactly how to fix
  them; a few clear steps; never a blank screen with a silent failure.
- **Failure:** App boots to a chat that errors on first send with a vague message.
- **Tier:** Must-have.
- **Modex:** Empty state invites a first prompt; the engine status footer and the
  honest "Sign in to Codex" error path cover the failure case, but there is no
  guided first-run flow yet.

## 2. Repo / project selection

- **What:** Pick the working directory the agent operates in; manage several
  projects.
- **Why:** A coding agent without a scoped workspace is either useless or unsafe.
- **Good:** Native folder picker, recent/known projects, per-project memory of
  settings, clear handling of moved/deleted folders.
- **Failure:** Hardcoded paths; agent runs against the wrong directory; a missing
  folder crashes or silently does nothing.
- **Tier:** Must-have.
- **Modex:** Folder picker + first-class `Project` model with per-project defaults,
  git branch cache, missing-folder detection, and import of Codex trusted folders.

## 3. Secure auth & account linking

- **What:** Connect the agent's credentials (API key, OAuth/login) securely.
- **Why:** Tokens are high-value secrets; mishandling them is the worst failure a
  tool like this can have.
- **Good:** Credentials live in the OS keychain or the agent's own secure store;
  never in the bundle, logs, or plain files; expired/invalid auth is surfaced
  honestly with a path to re-auth.
- **Failure:** API keys in localStorage, in logs, committed to git, or printed.
- **Tier:** Must-have.
- **Modex:** Delegates entirely to local Codex auth (`codex login` / `~/.codex/`);
  stores no credentials itself. An unauthenticated turn now produces an honest
  "Sign in to Codex" prompt instead of a generic error.

## 4. Local environment detection

- **What:** Detect the tools the app depends on (the agent binary, git, build
  toolchain) and degrade gracefully when they're absent.
- **Why:** Users' machines differ; assuming a tool exists produces cryptic
  failures.
- **Good:** Probes for required binaries; clear, actionable message when one is
  missing; features that need a tool hide or disable themselves honestly.
- **Failure:** App assumes a binary/path exists and crashes or hangs without it.
- **Tier:** Must-have.
- **Modex:** Bundles the Codex engine and locates it (bundle → env override);
  surfaces a fatal "engine not found" screen if absent. The self-updater now hides
  unless the build toolchain is actually present.

## 5. Agent connection status

- **What:** A always-visible, truthful indicator of whether the agent is
  connected, starting, or failed.
- **Why:** Users need to trust that what they're talking to is real and reachable.
- **Good:** A live status reflecting genuine connection/health, not just "process
  launched"; recovery action on failure.
- **Failure:** A green "ready" light that doesn't reflect reality (e.g. shown
  before auth is verified).
- **Tier:** Must-have.
- **Modex:** Engine status footer + typed lifecycle states; crash/disconnect
  detection with a Restart action. (Caveat: "ready" currently means the local
  handshake succeeded, not that a turn has, end-to-end.)

## 6. Worktree / branch management

- **What:** Create, switch, and isolate work on git branches/worktrees so agent
  changes are contained and reviewable.
- **Why:** Letting an agent edit a repo without branch isolation risks the user's
  work.
- **Good:** One-click branch create/switch; isolated worktrees for parallel tasks;
  non-destructive (refuses to clobber uncommitted changes) with clear messaging.
- **Failure:** Agent edits land on the wrong branch; switching loses work silently.
- **Tier:** Should-have (Must-have once the agent writes files).
- **Modex:** Top-bar branch switcher backed by `git switch`, non-destructive with a
  failure banner. No worktree isolation yet.

## 7. Parallel agents / tasks

- **What:** Run multiple agent tasks at once, each scoped to its own
  branch/worktree.
- **Why:** A major productivity multiplier for non-trivial work.
- **Good:** Clear per-task isolation, resource limits, and no cross-task state
  bleed.
- **Failure:** Tasks share state and corrupt each other; runaway concurrency.
- **Tier:** Advanced.
- **Modex:** Single active conversation today; not present.

## 8. Task queue & progress timeline

- **What:** A visible timeline of what the agent is doing (thinking, running a
  command, editing files) and what it has done.
- **Why:** Agents take long, multi-step actions; opacity breeds distrust.
- **Good:** Streamed, granular, honest activity states; persisted history.
- **Failure:** A spinner with no detail; fabricated progress.
- **Tier:** Should-have.
- **Modex:** Inline activity states (Thinking / Running command / Editing files /
  Waiting for permission) streamed live from the engine.

## 9. Diff review

- **What:** Review the agent's proposed/applied file changes as diffs before or
  after they land.
- **Why:** Reviewing changes is the core trust mechanism for code edits.
- **Good:** Per-file syntax-highlighted diffs; accept/reject; ties into the
  approval flow.
- **Failure:** Changes applied with no way to see what changed.
- **Tier:** Must-have (once the agent edits files).
- **Modex:** Streams file-change activity; a dedicated diff-review surface is a
  known gap.

## 10. Git branch / commit / PR flow

- **What:** Stage, commit, push, and open PRs from inside the app.
- **Why:** Keeps the review loop in one place.
- **Good:** Clear, native git operations; PR creation via the platform CLI/API.
- **Failure:** Forces the user out to a terminal for every commit.
- **Tier:** Should-have.
- **Modex:** Branch switching only; commit/PR flow not present.

## 11. Terminal / command actions

- **What:** The agent runs shell commands, and the user can see/approve them.
- **Why:** Real coding work needs builds, tests, and tooling.
- **Good:** Commands run via argument arrays (never shell string interpolation of
  user/agent input), scoped to the project, output streamed, approval-gated.
- **Failure:** Shell injection; unsandboxed commands; hidden execution.
- **Tier:** Should-have.
- **Modex:** Engine runs commands under a sandbox policy; Modex spawns processes
  with argument arrays (no shell), and command output streams into the chat.

## 12. Browser / visual feedback

- **What:** For UI work, show rendered output or screenshots so the agent and user
  can see results.
- **Why:** Closes the loop on front-end/visual tasks.
- **Good:** Live preview or screenshot capture wired to the task.
- **Failure:** Claiming visual capability that isn't wired up.
- **Tier:** Advanced.
- **Modex:** Not present (and not claimed).

## 13. File / context picker

- **What:** Attach specific files, selections, or symbols as context for a prompt.
- **Why:** Precise context dramatically improves agent output and saves tokens.
- **Good:** Fast fuzzy file/symbol picker; visible attached-context chips.
- **Failure:** A non-functional "attach" affordance that implies a feature that
  doesn't exist.
- **Tier:** Should-have.
- **Modex:** Not present. (A dead "+" attach button was removed during hardening
  precisely to avoid implying a feature that isn't built.)

## 14. Permissions & sandboxing

- **What:** Bound what the agent can read/write/execute, with explicit user
  consent for risky actions.
- **Why:** The app runs a code-executing agent; unbounded access is dangerous.
- **Good:** Tiered access (read-only → write → full), scoped writable roots,
  explicit approval prompts for destructive actions, safe defaults.
- **Failure:** Full access by default; approvals silently auto-answered without
  the user knowing.
- **Tier:** Must-have.
- **Modex:** Read-only / Write / Full access modes mapped to engine sandbox
  policies; writes scoped to the chosen folder; approvals auto-declined by default
  (a real diff/approval UI is a known follow-up).

## 15. Secrets handling

- **What:** Keep tokens and secrets out of bundles, logs, screenshots, and commits.
- **Why:** A single leaked key can be catastrophic.
- **Good:** Secrets only in secure stores; structured logging that never prints
  them; `.env*` gitignored; example env files contain placeholders only.
- **Failure:** Secrets in logs, client bundles, or git history.
- **Tier:** Must-have.
- **Modex:** Stores no secrets; logs use redaction-friendly structured logging;
  `.env*` gitignored; `.env.example` has placeholders only.

## 16. Logs & debug export

- **What:** Accessible logs and a way to export them for bug reports.
- **Why:** Diagnosing agent/tooling failures requires visibility.
- **Good:** Structured logs to the OS log system; one-click export; copyable
  technical detail behind error UI.
- **Failure:** No logs, or logs that leak secrets.
- **Tier:** Should-have.
- **Modex:** OSLog throughout; error banners expose copyable technical detail. No
  one-click bundle export yet.

## 17. Test / build integration

- **What:** Run and surface the project's tests/builds from inside the app.
- **Why:** Closes the verify loop on agent changes.
- **Good:** Detects the project's test/build commands; surfaces pass/fail inline.
- **Failure:** No feedback on whether agent changes compile or pass.
- **Tier:** Should-have.
- **Modex:** The agent can run builds/tests as commands; no dedicated test-runner
  surface.

## 18. Error recovery

- **What:** Fail gracefully and offer a clear path back to working.
- **Why:** Long-running agent sessions hit network, auth, and engine failures.
- **Good:** Typed, human-readable errors with a recovery action; the app never
  crashes on a recoverable failure; mid-failure state is cleaned up.
- **Failure:** Crashes, dead-ends, or "Something went wrong" with no next step.
- **Tier:** Must-have.
- **Modex:** Typed `ModexError` vocabulary with banner vs. fatal-recovery routing,
  one-tap retry, crash/disconnect handling, and request timeouts so a hung engine
  can't wedge a turn forever.

## 19. Resumable sessions

- **What:** Restore prior conversations/projects across launches.
- **Why:** Work spans sessions; losing history is a serious regression.
- **Good:** Durable, corruption-tolerant local persistence; resume the agent's own
  threads where the backend supports it.
- **Failure:** History lost on relaunch; one corrupt file wipes everything.
- **Tier:** Should-have.
- **Modex:** Atomic local session persistence with corrupt-file quarantine;
  resumes Codex threads via `thread/resume`. (Re-selecting a resumed Codex thread
  on cold launch is a known rough edge.)

## 20. Usage / quota visibility

- **What:** Show token/credit usage and limits.
- **Why:** Users need to understand cost and avoid surprise rate limits.
- **Good:** Live usage where the backend exposes it; honest "unknown" when it
  doesn't.
- **Failure:** Fabricated usage numbers; silent quota-exhaustion failures.
- **Tier:** Should-have.
- **Modex:** Not surfaced. (Notably, the app must avoid inventing this — a prior
  fake "Pro Plan" account chip was removed during hardening.)

## 21. Model & reasoning controls

- **What:** Choose the model and reasoning/effort level per task.
- **Why:** Different work needs different cost/quality trade-offs.
- **Good:** Real model list from the backend; reasoning levels that map to true
  wire values; per-chat/project memory.
- **Failure:** A picker listing models the backend rejects; labels sent as-is
  instead of the wire slug.
- **Tier:** Should-have.
- **Modex:** Model picker populated from the engine's real `model/list` (with a
  fallback), reasoning levels, label→slug mapping, per-chat/project memory.

## 22. Agent instructions / rules / memory

- **What:** Persistent project rules and custom instructions the agent honors.
- **Why:** Encodes conventions so the agent fits the codebase.
- **Good:** Per-project instructions/memory files; clear precedence; visible to
  the user.
- **Failure:** Instructions ignored, or hidden behaviors the user can't see.
- **Tier:** Should-have.
- **Modex:** Sends concise developer instructions per turn (rendering vocabulary +
  environment); no user-editable project rules yet.

## 23. MCP / plugins / integrations

- **What:** Extend the agent with Model Context Protocol servers, tools, or plugins.
- **Why:** Connects the agent to the user's real systems.
- **Good:** Discoverable, permissioned integrations; clear when one is active.
- **Failure:** Integrations that silently fail or over-permission.
- **Tier:** Advanced.
- **Modex:** The engine supports MCP; Modex declines MCP elicitation by default and
  exposes no integration UI yet.

## 24. Notifications

- **What:** Alert the user when a long task finishes or needs input.
- **Why:** Agent tasks run long; users switch away.
- **Good:** Native notifications for completion/approval, respectful of focus.
- **Failure:** No signal that a task finished or is blocked waiting.
- **Tier:** Should-have.
- **Modex:** In-window status only; no system notifications yet.

## 25. Accessibility

- **What:** Full keyboard navigation, VoiceOver labels, sufficient contrast,
  reduced-motion support.
- **Why:** Accessibility is a baseline obligation, and platforms enforce it.
- **Good:** Every interactive control labeled; visible focus; honors Reduce Motion
  and Reduce Transparency; meets contrast minimums.
- **Failure:** Unlabeled icon buttons; motion that ignores accessibility settings;
  low-contrast text.
- **Tier:** Must-have.
- **Modex:** Broad accessibility labels/help; Reduce Motion honored (shimmer/anim);
  composer auto-focus and standard shortcuts. Reduce Transparency adaptation is a
  remaining gap.

## 26. Responsive desktop / web layout

- **What:** A layout that holds up across window sizes and platform conventions.
- **Why:** A cramped or overflowing UI reads as unfinished.
- **Good:** Native window/sidebar/inspector structure; sensible min size; content
  that reflows; no clipped or escaping elements.
- **Failure:** Overflow, clipped controls, popovers off-screen, layout shift.
- **Tier:** Should-have.
- **Modex:** Native `NavigationSplitView`, content-width caps, `ViewThatFits` in the
  composer, window-resize-safe overlays for banners/menus.

## 27. Performance & resource controls

- **What:** Stay responsive and light, even during heavy streaming and long
  histories.
- **Why:** Agent output streams fast; naive rendering/persistence degrades quickly.
- **Good:** Memoized rendering of streamed content; coalesced persistence; bounded
  buffers; no busy-polling.
- **Failure:** UI jank during streaming; O(n²) re-rendering; constant background
  subprocess churn.
- **Tier:** Should-have.
- **Modex:** Markdown parse memoized per text; session persistence coalesced to
  turn boundaries; engine stdout buffer bounded; update polling throttled.

## 28. Update / version management

- **What:** Keep the app current safely.
- **Why:** Security and feature fixes need to reach users.
- **Good:** Signed, verified updates with a visible version and changelog; honest
  about whether an update path exists for this build.
- **Failure:** Unsigned auto-pull-and-run with no verification; an "Update" button
  that can't work for the current install.
- **Tier:** Should-have.
- **Modex:** Source-build self-updater, now gated so it only appears when a
  rebuildable checkout + toolchain is present. (Distribution-signed auto-update is
  a follow-up; see `docs/release-signing.md`.)

## 29. Privacy & security controls

- **What:** Be clear about what runs locally vs. leaves the machine, and bound
  network/file access.
- **Why:** These tools touch source code and credentials.
- **Good:** Local-first by default; explicit consent for anything outbound;
  loopback-only local services; least-privilege file access.
- **Failure:** Surprise telemetry; binding local services to non-loopback;
  over-broad file access.
- **Tier:** Must-have.
- **Modex:** Local-first; the engine endpoint is validated loopback-only; no
  telemetry. (App Sandbox is off in dev builds — a hardening item for distribution.)

## 30. Docs & troubleshooting

- **What:** Clear setup, prerequisites, and troubleshooting that match the shipped
  app.
- **Why:** A new developer must be able to clone, configure, run, and understand it.
- **Good:** Accurate README/build steps, a complete env example, honest known
  limitations.
- **Failure:** Docs that describe a different product than the one that ships.
- **Tier:** Must-have.
- **Modex:** README/AGENTS/signing docs and `.env.example` rewritten to describe
  the native app accurately, with prerequisites and known limitations called out.

## 31. Graceful offline / missing-tool states

- **What:** Behave sensibly with no network or a missing dependency.
- **Why:** These conditions are common and must not crash or mislead.
- **Good:** Honest "unavailable / requires setup" states; the app stays usable for
  what still works.
- **Failure:** Crashes, infinite spinners, or features that pretend to work.
- **Tier:** Must-have.
- **Modex:** Missing engine → fatal recovery screen; missing toolchain → updater
  hidden; failed turns → typed, recoverable errors.

---

## How to read this for Modex

The strongest areas today are **error recovery, permissions/sandboxing, secrets
handling, session persistence, model controls, and honest connection status** —
the trust-critical foundations. The clearest opportunities (deferred, not gaps to
paper over) are **diff review, a real approval UI, a file/context picker, worktree
isolation, usage visibility, and first-run onboarding**. None of these should be
faked: the right move when one isn't built is to leave it out or mark it honestly
unavailable, exactly as the hardening pass did with the attach button and the
fabricated account chip.
