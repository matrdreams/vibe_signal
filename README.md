# Vibe Signal

Vibe Signal is a native macOS menu bar app that shows a traffic-light status for local coding agents.

- Red: an agent is blocked on approval or user input.
- Yellow: an agent is working.
- Green: observed sessions are idle.
- Gray: no live sessions are currently known.

The app embeds the local status hub described in `ARCHITECTURE.md`. Agents and scripts publish JSON events through a per-user Unix domain socket, and the hub keeps an atomic JSON snapshot for startup recovery and diagnostics.

## Build

```sh
./scripts/build-app.sh
```

The script creates:

- `dist/Vibe Signal.app`
- `dist/vibe-signal`
- `dist/libVibeSignalCore.dylib`

Launch the app from Finder or with:

```sh
open "dist/Vibe Signal.app"
```

## Emit Status

```sh
./dist/vibe-signal emit \
  --source codex \
  --adapter codex-hooks \
  --session-id demo \
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
  "workspace": "/Users/kun/Code/example",
  "state": "blocked",
  "reason": "approval",
  "message": "Waiting for shell command approval",
  "startedAt": "2026-05-24T10:30:00Z",
  "updatedAt": "2026-05-24T10:30:05Z",
  "ttlMs": 300000,
  "metadata": {
    "toolName": "Bash"
  }
}
```

## Codex Integration

For the stable Codex `notify` hook, point Codex at the CLI adapter:

```toml
notify = ["/absolute/path/to/dist/vibe-signal", "codex-notify", "turn-ended"]
```

For richer hooks or wrappers, call `vibe-signal emit` at the relevant lifecycle points:

```sh
./dist/vibe-signal emit --source codex --adapter codex-hooks --state blocked --reason approval --message "Waiting for approval"
./dist/vibe-signal emit --source codex --adapter codex-hooks --state working --reason command --message "Running command"
./dist/vibe-signal emit --source codex --adapter codex-hooks --state idle --reason done --message "Turn finished"
```

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
