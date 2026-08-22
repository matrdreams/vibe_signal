# Vibe Signal

Vibe Signal is a native macOS menu bar app that shows a traffic-light status for local coding agents.

- Red: an agent is blocked on approval or user input.
- Yellow: at least one verified agent is working, unless another task needs input or has failed.
- Green: every observed session has a confirmed completed/interrupted turn.
- Gray: no session is known, or no task is active and at least one state cannot be verified.

Each session row shows its task title, latest state, and elapsed time. Click the
row—or a macOS notification—to return to that exact Codex conversation. The app
only alerts when a task newly needs attention, and suppresses completion alerts
for tasks shorter than 15 seconds.

The app embeds the local status hub described in `ARCHITECTURE.md`. Agents and scripts publish JSON events through a per-user Unix domain socket, and the hub keeps an atomic JSON snapshot for startup recovery and diagnostics.

## Build

```sh
./scripts/build-app.sh
```

By default the script builds Universal Binaries containing both Apple Silicon
(`arm64`) and Intel (`x86_64`) slices. It creates:

- `dist/Vibe Signal.app`
- `dist/vibe-signal`
- `dist/libVibeSignalCore.dylib`

The build compiles `Resources/AppIcon.png` through a macOS asset catalog. The
application bundle contains both the legacy `AppIcon.icns` fallback and an
`Assets.car` with all 16–1024 px representations required by Finder and
Launchpad. Regenerate the compiled icon assets independently with:

```sh
./scripts/generate-app-icon.sh
```

For a faster single-architecture development build, override the architecture:

```sh
VIBE_SIGNAL_ARCHS=arm64 ./scripts/build-app.sh
```

`TARGET=x86_64-apple-macosx13.0` remains available when an exact Swift target
triple is required.

Development builds are unsigned by default. If an ad-hoc signature is useful
for local testing, build with `VIBE_SIGNAL_ADHOC_SIGN=1`. Developer ID signing
and notarization are handled by the release process.

Public releases require an Apple notary profile stored securely in the macOS
Keychain. `notarytool` prompts for the app-specific password without placing it
in shell history:

```sh
xcrun notarytool store-credentials VibeSignalNotary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "3TBP5MLMTQ"

VIBE_SIGNAL_NOTARY_PROFILE=VibeSignalNotary ./scripts/release-macos.sh
```

The release script signs and notarizes both the app and its Universal DMG,
staples their tickets, and runs Gatekeeper assessments. It exits before
building when no notary profile is configured, so an unnotarized public build
cannot be produced accidentally.

Launch the app from Finder or with:

```sh
"./dist/Vibe Signal.app/Contents/MacOS/VibeSignalApp" &
```

## Emit Status

```sh
./dist/vibe-signal emit \
  --source codex \
  --adapter codex-hooks \
  --session-id demo \
  --title "Fix login on macOS" \
  --workspace "$PWD" \
  --state working \
  --reason thinking \
  --message "Codex is thinking"
```

Useful shortcuts:

```sh
./dist/vibe-signal demo blocked
./dist/vibe-signal demo working
./dist/vibe-signal demo idle
./dist/vibe-signal ping
./dist/vibe-signal status
./dist/vibe-signal paths
```

## JSONL Event Schema

`vibe-signal emit --json` accepts the schema from `ARCHITECTURE.md`:

```json
{
  "schemaVersion": 1,
  "source": "codex",
  "adapter": "codex-hooks",
  "sessionId": "session-abc",
  "title": "Fix login on macOS",
  "workspace": "/Users/kun/Code/example",
  "state": "blocked",
  "reason": "approval",
  "message": "Waiting for shell command approval",
  "startedAt": "2026-05-24T10:30:00Z",
  "updatedAt": "2026-05-24T10:30:05Z",
  "ttlMs": 300000,
  "metadata": {
    "toolName": "Bash",
    "jump_url": "codex://threads/session-abc",
    "host_bundle_id": "com.openai.codex"
  }
}
```

Navigation metadata is optional. `jump_url` is preferred for an exact deep
link; `host_pid`, `host_bundle_id`, and finally `workspace` are used as safe
fallbacks. The CLI also accepts `VIBE_SIGNAL_JUMP_URL`,
`VIBE_SIGNAL_HOST_PID`, and `VIBE_SIGNAL_HOST_BUNDLE_ID`.

## Codex Integration

Vibe Signal monitors Codex passively. Codex can still be launched normally from
the desktop app, terminal, or an IDE; Vibe Signal never starts, proxies, or owns
the Codex app-server.

The built-in monitor combines:

- persisted Codex turn and tool events for verified working/idle/error states;
- request/call ID correlation so unrelated tool output cannot clear a red state;
- per-turn `approvals_reviewer` and `approval_policy` data to avoid treating
  automatic review as a human approval prompt;
- a fail-closed rule: missing, stale, conflicting, or unsupported evidence is
  gray rather than green.

Settings includes one optional **Instant status detection** switch. It adds
local lifecycle hooks for faster yellow-state updates. Hook input is reduced to
session/turn/event/workspace metadata; prompt text, command input, tool output,
and transcript contents are not published. Codex may require one trust review
after the hook is installed. Hook events are hints only: they never assert red
or green by themselves.

For older Codex versions, the stable `notify` callback remains available:

```toml
notify = ["/absolute/path/to/dist/vibe-signal", "codex-notify", "turn-ended"]
```

Custom adapters can still call `vibe-signal emit` at explicit lifecycle points:

```sh
./dist/vibe-signal emit --source codex --adapter codex-hooks --state blocked --reason approval --message "Waiting for approval"
./dist/vibe-signal emit --source codex --adapter codex-hooks --state working --reason command --message "Running command"
./dist/vibe-signal emit --source codex --adapter codex-hooks --state idle --reason done --message "Turn finished"
```

The monitor uses Codex's `session_index.jsonl` title so menu rows match the
Codex sidebar, falling back to a concise title from the latest user prompt
until the sidebar title is available. Internal subagent rollouts are not shown
as separate sidebar sessions. Each root session still carries the
`codex://threads/<session-id>` deep link. Notification types can be switched on
or off in Settings.

When the menu bar app is not running, the CLI writes the snapshot file and reports that the hub is offline. Once the app starts, it loads that snapshot and then listens on the socket for live events.

## Verify

```sh
./scripts/test-core.sh
./scripts/build-app.sh
./scripts/smoke-online.sh
./dist/vibe-signal demo working
./dist/vibe-signal status
```

`Package.swift` is included for normal SwiftPM/Xcode environments. The scripts compile with `swiftc` directly so the app can still be built on machines where SwiftPM's manifest linker is unavailable.
