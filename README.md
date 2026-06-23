# ralph-codex

[![CI](https://github.com/discordwell/ralph-codex/actions/workflows/ci.yml/badge.svg)](https://github.com/discordwell/ralph-codex/actions/workflows/ci.yml)

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
ralph-loop --version
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
- The progress gate counts churn (committed + staged + unstaged, plus lines in untracked new text files) since the run's starting commit, so committing as you go — or writing new files you haven't staged yet — still counts as progress; `--allow-low-progress` disables the gate.
- `--max-seconds <N>` sets an optional wall-clock budget: after any iteration, once the loop has run at least N seconds it stops gracefully (exit 0) without starting another; an in-flight turn always finishes. `0` (default) means no limit. This bounds long unattended runs by time/cost, complementing the work-based progress gate and context-based overflow recovery.
- Tracking logs include:
  - `[RECOVER]` when a context-overflow failure is detected.
  - `[DEADLINE]` when the `--max-seconds` budget is reached.
  - `tracking event=iteration_start` with the per-iteration session mode (`resume_session`, `resume_last`, `fresh_initial`, `fresh_recovery`).

Manual local path still works:
```bash
cd /Users/discordwell/Projects/ralph-codex
chmod +x scripts/ralph-loop.sh
scripts/ralph-loop.sh --help
```
