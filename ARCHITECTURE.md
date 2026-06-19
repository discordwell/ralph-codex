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

At run start the harness records `base_commit` (the current `HEAD`).
`count_changed_lines` then sums `git diff --numstat <base_commit>`, i.e. total
churn — committed, staged, and unstaged — since the run began, so committing as
you go still counts as progress. (When the repo has no commits yet there is no
`HEAD`, so it falls back to working-tree-only churn.) Because `git diff` only
reports *tracked* files, the count adds the lines of any untracked, non-ignored
**new** files on top (`count_untracked_lines`); otherwise an agent that writes
new modules/tests/docs but has not staged them would read as zero progress and
falsely trip the gate. Untracked binaries are skipped (counted 0, matching how
`git diff --numstat` reports `-` for binary), and the harness's own state/log
files are excluded so its bookkeeping never reads as agent progress. Every
`--progress-window` iterations the delta since the last checkpoint must reach
`--min-delta-lines` or the run aborts (exit 1). The basis is recorded as
`progress_basis` in the state file. Use `--allow-low-progress` to disable the
gate entirely.

## Files written (in the target repo)

- `.ralph/session-state.md` (or `--state-file`) — rewritten every iteration;
  also the source of the persisted `summary_count`. Records `progress_basis`
  (the `base_commit` SHA, or `working-tree` when there is no `HEAD`).
- `.ralph/ralph-loop-<run_id>.log` (or `--log-file`) — append-only tracking
  log: `[START]`/`[END]` run delimiters, per-iteration `tracking event=` lines,
  `[RECOVER]` and `[DONE]` markers.

## Defaults & dependencies

Model defaults (`gpt-5.3-codex-spark`, reasoning effort `high`, planning
`extra_high`) are injected only when not overridden via `-m/--model` or
`-c/--config` after `--`. Hard dependencies: `codex`, `git`, and `rg` (session
lookups and overflow detection); `jq` is optional (assistant-text done detection
degrades to output-file matching without it). These hard dependencies are
verified on `PATH` up front (`require_commands`, after argument parsing so
`-h/--help` and `-V/--version` still work without them); a missing one is a
clean one-line error rather than a mid-run failure. The latter matters because
the loop treats a non-zero codex exit as a normal "keep going" result, so a
missing `codex` would otherwise burn through every requested iteration — and,
with `--allow-low-progress`, still exit 0. Bash 3.2+ (macOS stock) is supported.

Immediately after the dependency check, `require_git_repo` confirms the working
directory is a git work tree (`git rev-parse --is-inside-work-tree`). The whole
harness is built on git — the progress gate measures churn since `base_commit`,
the context prompt embeds `git status`/`diff --stat`, and the state file records
diff stats — so outside a repo every git call degrades silently to empty/zero
and the progress gate aborts with a misleading "progress gate failed" that reads
as if the agent did nothing. Failing fast with a clear "not a git repository"
message is the same trade as `require_commands`. A repo with **no commits yet**
is still a valid work tree, so the no-`HEAD` path the progress gate already
handles (working-tree-only churn) is unaffected.

`-h/--help` and `-V/--version` print and exit 0; the script version
(`ralph_loop_version`) is kept in lockstep with `package.json` by a test.
Argument handling fails fast and cleanly rather than silently or with a raw
error:

- Value-taking flags reject a missing value with a usage error rather than
  crashing under `set -u`.
- `--prompt-file` / `--plan-prompt-file` / `--summary-prompt-file` validate the
  path (`require_readable_file`) before reading it, so a missing or unreadable
  file is a usage error instead of a raw `cat:` message that aborts under
  `set -e`.
- An empty or whitespace-only execution prompt (no flag, an inline
  `--prompt "   "`, or a `--prompt-file` of only blank lines) is rejected up
  front; a blank `--prompt-file` reports the file by name rather than the generic
  "a prompt is required" message.
- An unrecognized long option *before* `--` (e.g. a typo'd `--allow-low-progres`)
  is a usage error, not a silent pass-through to codex that would quietly change
  loop behavior. Arguments intended for codex must come after `--`; anything
  there is forwarded verbatim.

The per-iteration temp output file is removed by an `EXIT` trap if the script
exits early (e.g. a `set -e` abort or the progress-gate `exit 1`) before its
inline cleanup runs.

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
