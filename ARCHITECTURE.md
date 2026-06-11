# Architecture

`ralph-codex` is a single-script harness (`scripts/ralph-loop.sh`, bash) that
drives the `codex` CLI through repeated iterations ("Ralph loops") against the
repository it is invoked from. There is no daemon and no state outside the
target repo's `.ralph/` directory and Codex's own `~/.codex/sessions` files.

## Iteration lifecycle

Each loop run executes up to `--count` iterations. Every iteration:

1. **Builds a context prompt** (`build_context_prompt`): the phase prompt plus
   a live snapshot — previous state file contents, `git status`/`diff --stat`,
   and the tail of the tracking log — ending with a continuation contract that
   tells the agent to reply with exactly `done` when nothing is left to do.
2. **Invokes codex** (`codex` interactive, or `codex exec` with
   `--non-interactive`), capturing combined output to a temp file.
3. **Detects the session id** printed by codex (`extract_session_id`) so later
   iterations can `resume` it.
4. **Waits for turn completion** by polling the session `.jsonl` for a
   `task_complete` event (`wait_for_turn_completion`), bounded by
   `--completion-poll-interval` / `--completion-timeout`.
5. **Checks the done sentinel**: the assistant's final message for the turn
   (via `jq` over the session file) or the last non-empty output line must be
   exactly `done` to end the loop early with success.
6. **Writes tracking**: appends events to the log file and rewrites the state
   file (`log_state`) with iteration counters, diff stats, and recovery stats.

## Phases

- Iteration 1 is the **planning** phase (`--plan-prompt`, default reasoning
  effort `extra_high`); it should assess and plan without editing.
- Every `--summary-every`-th iteration (persisted across runs via
  `summary_count` in the state file) is a **summary** phase.
- All other iterations are **execution** phases using the main `--prompt`.

## Session modes

Each iteration starts codex in one of four modes (logged as `session_mode=`):

- `fresh_initial` — first iteration without `--session-id`, or `--new-agent`.
- `resume_session` — a known session id is resumed explicitly.
- `resume_last` — no id known yet, so `codex resume --last`.
- `fresh_recovery` — forced fresh session after a context-overflow failure.

## Context-overflow recovery

When an iteration exits non-zero and its output matches known
context-window-exhaustion patterns (`output_indicates_context_overflow`), the
harness logs `[RECOVER]`, drops the session id, and forces the next iteration
to start a fresh session. The fresh session is "warm-started" purely through
the context prompt's state snapshot. Disable with
`--no-context-overflow-recovery`.

## Progress gate

`count_changed_lines` sums `git diff --numstat` in the working tree. Every
`--progress-window` iterations the delta since the last checkpoint must reach
`--min-delta-lines` or the run aborts (exit 1). Note the metric only sees
uncommitted changes — if the agent commits as it goes, pass
`--allow-low-progress` (the documented invocations do).

## Files written (in the target repo)

- `.ralph/session-state.md` (or `--state-file`) — rewritten every iteration;
  also the source of the persisted `summary_count`.
- `.ralph/ralph-loop-<run_id>.log` (or `--log-file`) — append-only tracking
  log: `[START]`/`[END]` run delimiters, per-iteration `tracking event=` lines,
  `[RECOVER]` and `[DONE]` markers.

## Defaults & dependencies

Model defaults (`gpt-5.3-codex-spark`, reasoning effort `high`, planning
`extra_high`) are injected only when not overridden via `-m/--model` or
`-c/--config` after `--`. Hard dependencies: `git`, `rg` (session lookups and
overflow detection); `jq` is optional (assistant-text done detection degrades
to output-file matching without it). Bash 3.2+ (macOS stock) is supported.

## Tests

`tests/run-tests.sh` exercises the harness end-to-end with a mock `codex`
binary placed first on `PATH` that records argv per call and replays scripted
exit codes/output. `$HOME` is pointed at a per-test sandbox so real Codex
sessions are never read or written. Run via `npm test` or directly; set
`RALPH_LOOP_BIN` to point the suite at an installed binary.

## Packaging

- npm: `bin` maps `ralph-loop` to the script (installed from the GitHub repo).
- Homebrew: `Formula/ralph-loop.rb` installs the script as `ralph-loop`
  (`--HEAD` only) and its `brew test` asserts `ralph-loop --help` succeeds.
