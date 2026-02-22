# Unix-native Skills + MCP Architecture (No Node.js)

This project can run an agentic workflow entirely with Unix primitives and Bash.

## Goals
- No JavaScript or Node.js runtime.
- Local-first tooling over Unix IPC.
- Composable skills as plain files.
- Daemonized tools for coding/ops workflows.
- Isolation via chroot/jail/VM when executing risky actions.

## Skills model
- Store skills as text/markdown files in `~/.chatgpt/skills` (or `--skills-dir`).
- Use `skills` to list available skills.
- Use `skill:<name>` to activate a skill into session system prompt.
- Keep skills under version control and treat them as policy + procedure docs.

## MCP model over Unix domain sockets
- Use `--mcp-socket /path/to/agent.sock`.
- Use `mcp:<payload>` to send a line payload to a local daemon.
- Transport is `AF_UNIX` via `socat` (no network port required).
- Recommended payload format: JSON lines (`{"tool":"git.status","args":{}}`).

## Daemon/process topology
- `chatgpt.sh` (interactive CLI)
- one or more local daemons exposing tools over Unix sockets
- optional supervisor (`systemd --user`, `runit`, `s6`) for restart policy

## Isolation strategy
Use least-privilege execution for tool daemons:

### Linux
- `chroot` / `unshare` / `bubblewrap` for filesystem + namespace limits.
- cgroups for CPU/memory quotas.
- seccomp/apparmor for syscall/profile constraints.

### FreeBSD
- jails for service isolation.
- bhyve for full VM isolation when stronger boundaries are required.

### Cross-platform virtualization
- QEMU/KVM for hermetic sandboxes and reproducible agent testbeds.

## Suggested workflow
1. Start local tool daemon(s) bound to Unix sockets.
2. Launch `chatgpt.sh --openclaw-mode --mcp-socket ...`.
3. Activate one or more local skills.
4. Send MCP payloads for deterministic tool calls.
5. Run dangerous operations only inside jail/chroot/VM targets.

## Why this aligns with Unix-first design
- Text streams + files + processes remain first-class interfaces.
- Tooling remains inspectable with standard Unix commands.
- Security boundaries are explicit and infrastructure-native.
