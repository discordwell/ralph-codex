# ralph-codex

Utilities and docs for running iterative Codex "Ralph loops".

## Contents
- `scripts/ralph-loop.sh` — main loop harness
- `SETUP_AND_RUN_RALPH_LOOPS.md` — setup + run guide with examples

## Install
### Homebrew (macOS/Linuxbrew)
```bash
brew tap discordwell/ralph-codex
brew install --HEAD discordwell/ralph-codex/ralph-loop
```

### npm (GitHub source, no npm publish required)
```bash
npm install -g github:discordwell/ralph-codex
```

## Quick Start
```bash
ralph-loop --help
```

## Tracking Defaults
- Every run writes a tracking log by default at `.ralph/ralph-loop-<run_id>.log` (unless `--log-file` is provided).
- Context-window recovery is enabled by default; disable with `--no-context-overflow-recovery`.
- Tracking logs include:
  - `[RECOVER]` when a context-overflow failure is detected.
  - `tracking event=iteration_start` with the per-iteration session mode (`resume_session`, `resume_last`, `fresh_initial`, `fresh_recovery`).

Manual local path still works:
```bash
cd /Users/discordwell/Projects/ralph-codex
chmod +x scripts/ralph-loop.sh
scripts/ralph-loop.sh --help
```
