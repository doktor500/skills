# Skills

Custom [Claude Code skills](https://docs.anthropic.com/en/docs/claude-code/skills) for autonomous development workflows.

## Skills

### `loop-agent` (`skills/engineering/loop-agent`)

Runs one autonomous development cycle. Designed to run on a recurring interval via `/loop`.

**Phase A — PR Cleanup:** Picks the oldest agent-authored PR with unresolved review threads or merge conflicts, addresses them, and promotes to `Ready for human review` when clean.

**Phase B — Issue Implementation:** Picks the oldest Linear issue labeled `Ready for agent` assigned to you, implements it in a git worktree, opens a GitHub PR, and drives CI to green.

Processes at most one PR and one issue per invocation, then stops.

**Usage:**
```
/loop 10m /loop-agent
```

**Requirements:**
- `gh` CLI authenticated
- `LINEAR_API_KEY` environment variable set (Linear API key)
- `curl` and `jq` available in the shell
- `pnpm` with `ts:check` and `lint:fix` scripts in the target repo

## Installation

### Via Claude plugin (recommended)

Install using the Claude Code plugin manager — the `.claude-plugin/plugin.json` registers all skills automatically.

### Via install script

Run the install script from the repo root:

```bash
./install.sh
```

This symlinks each skill directory into `~/.claude/skills/`, making all skills available globally in Claude Code. Re-running the script is safe — skills already pointing to the correct path are skipped.
