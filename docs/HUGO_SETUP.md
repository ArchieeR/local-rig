# Local Rig setup for Hugo

Local Rig is intended to help an 18 GB Apple-silicon Mac keep development
servers, Claude/Codex sessions, MCP servers, and browser automation under
control. Local models are optional and hidden by default in lean mode.

## Requirements

- Apple-silicon Mac running macOS 14 or newer
- Apple Command Line Tools or Xcode (`xcode-select --install` if needed)
- Node.js 18 or newer
- The local `rheos-repos` workspace containing `scripts/rig2.sh`
- Claude Code and/or Codex, if their Local Rig connector is wanted

## Install

Place this checkout at `<rheos-repos>/rheos-rig`, then run:

```bash
cd <rheos-repos>/rheos-rig
./script/install.sh --workspace "<rheos-repos>" --check
./script/install.sh --workspace "<rheos-repos>"
```

The first command only checks prerequisites. The second installs a production
build at `~/Applications/Local Rig.app`, a stable MCP copy under
`~/Library/Application Support/Local Rig`, the workspace `/rig` skill for
Claude and Codex, and the connector registrations. It does not start a dev
server, emulator, model, or agent session.

Restart Claude Code and Codex after installation so they reload the MCP. Start
Claude Code from the `rheos-repos` workspace. A useful first prompt is:

```text
/rig Check Local Rig status, show active dev servers and MCP memory grouped by
type, and identify conservative stale candidates. Do not stop anything without
my confirmation.
```

## 18 GB defaults

Lean mode automatically activates on machines with 24 GB or less. It:

- hides local-model controls;
- refreshes every twelve seconds instead of every eight;
- retains rigs, shared/isolated emulators, dev-server controls, agent sessions,
  MCP totals, logs, process handoffs, and confirmed cleanup;
- never terminates a process merely because memory use is high.

Use the MCP page to find expensive browser automation or duplicated connector
families. Stop actions always show a confirmation, re-check live PIDs and
commands, send graceful termination only, and report survivors without
force-killing them.

## Updating

Replace the Local Rig checkout with the newer version and run the same install
command again. The installer refreshes the app, MCP, skills, and connector path
while preserving other entries in the workspace `.mcp.json`.
