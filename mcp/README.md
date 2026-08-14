# Local Rig MCP

A local, tool-only stdio MCP server for Codex and Claude Code. The native macOS
app remains the human UI; this server gives agents the same structured rig
state, redacted logs, handoffs, and allowlisted controls.

## Safety contract

- Local filesystem, Git, loopback port probes, and `scripts/rig2.sh` only.
- No Firebase SDK, Firebase credentials, Firestore reads/writes, deployment, or
  network connector.
- No arbitrary shell, `reset`, `seed-save`, or Git checkout/repoint tool.
- A guarded bind tool can associate a stopped rig with existing dashboard and
  backend worktrees inside `rheos-repos`; the driver validates repository identity.
- Every log and command result is bounded and redacted before MCP output.
- Start/stop actions delegate to the verified rig driver, retaining its port,
  claim, shared-emulator, and PID protections.

## Run and test

```bash
npm install
npm test
./run.sh
```

The parent `.mcp.json` registers `local-rig` for Claude Code. Codex uses the
same `run.sh` command in its MCP configuration.

Claude Code also has a project skill at `.claude/skills/rig/SKILL.md`. Invoke
`/rig` for the guarded status, claim, worktree binding, mode-selection, logs,
handoff, and cleanup workflow.
