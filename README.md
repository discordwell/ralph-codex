# ralph-codex

Utilities and docs for running iterative Codex "Ralph loops".

## Contents
- `scripts/ralph-loop.sh` — main loop harness
- `tests/run-tests.sh` — test suite (mock `codex`, no real sessions touched)
- `SETUP_AND_RUN_RALPH_LOOPS.md` — setup + run guide with examples
- `ARCHITECTURE.md` — how the loop, session modes, and recovery fit together

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

## Tests
```bash
tests/run-tests.sh   # or: npm test
```
The suite shadows `codex` with a mock binary and sandboxes `$HOME`, so it never
touches real Codex sessions. Set `RALPH_LOOP_BIN` to test an installed copy.

## Tracking Defaults
- Every run writes a tracking log by default at `.ralph/ralph-loop-<run_id>.log` (unless `--log-file` is provided).
- Logs append across runs: reusing the same `--log-file` (e.g. on resume) keeps prior history, with each run delimited by `[START]`/`[END]` markers.
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
