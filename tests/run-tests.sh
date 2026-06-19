#!/usr/bin/env bash
# Test suite for scripts/ralph-loop.sh.
#
# Each test runs the harness in a throwaway work dir against a mock `codex`
# binary (first on PATH) that records its argv and replays scripted behavior
# from $MOCK_CODEX_DIR/behavior_<n> files (first line = exit code, rest =
# stdout). HOME is sandboxed per test so no real ~/.codex state is touched.
#
# Requires: bash, git, rg (same prerequisites as the harness itself).
# Run: tests/run-tests.sh

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# Override to test an installed copy, e.g. RALPH_LOOP_BIN="$(command -v ralph-loop)" tests/run-tests.sh
RALPH="${RALPH_LOOP_BIN:-$REPO_ROOT/scripts/ralph-loop.sh}"

pass_count=0
fail_count=0

t_pass() {
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$1"
}

t_fail() {
  fail_count=$((fail_count + 1))
  printf 'not ok - %s%s\n' "$1" "${2:+ [$2]}"
}

setup() {
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/ralph-loop-test.XXXXXX")"
  work_dir="$test_root/work"
  mock_bin="$test_root/bin"
  export MOCK_CODEX_DIR="$test_root/mock"
  export HOME="$test_root/home"
  mkdir -p "$work_dir" "$mock_bin" "$MOCK_CODEX_DIR" "$HOME/.codex/sessions"

  cat > "$mock_bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -u
dir="${MOCK_CODEX_DIR:?}"
n=$(( $(cat "$dir/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$dir/calls"
printf '%s\n' "$@" > "$dir/argv_$n"
# Optional per-call side effect (run in the harness's working dir), e.g. to
# simulate an agent that edits and commits files.
if [ -f "$dir/action_$n" ]; then
  bash "$dir/action_$n"
fi
if [ -f "$dir/behavior_$n" ]; then
  code="$(head -n 1 "$dir/behavior_$n")"
  tail -n +2 "$dir/behavior_$n"
  exit "$code"
fi
echo "mock-codex run $n"
exit 0
MOCK
  chmod +x "$mock_bin/codex"

  saved_path="$PATH"
  saved_home="${ORIG_HOME}"
  export PATH="$mock_bin:$PATH"
  git -C "$work_dir" init -q
  cd "$work_dir" || exit 1
}

teardown() {
  cd / || true
  export PATH="$saved_path"
  export HOME="$saved_home"
  rm -rf "$test_root"
}

# Runs the harness, capturing combined output in $ralph_out and the exit
# status in $ralph_status (the harness uses set -e, so it may exit non-zero).
run_ralph() {
  ralph_out="$test_root/ralph-out.txt"
  if "$RALPH" "$@" > "$ralph_out" 2>&1; then
    ralph_status=0
  else
    ralph_status=$?
  fi
}

mock_calls() {
  cat "$MOCK_CODEX_DIR/calls" 2>/dev/null || echo 0
}

# True when call <n> received <arg> as one exact argv element.
argv_has() {
  grep -Fxq -- "$2" "$MOCK_CODEX_DIR/argv_$1" 2>/dev/null
}

set_behavior() {
  # set_behavior <call#> <exit code> <output lines...>
  local n="$1" code="$2"
  shift 2
  { echo "$code"; printf '%s\n' "$@"; } > "$MOCK_CODEX_DIR/behavior_$n"
}

set_action() {
  # set_action <call#> <shell snippet run in the work dir on that call>
  local n="$1"
  shift
  printf '%s\n' "$*" > "$MOCK_CODEX_DIR/action_$n"
}

# Configure a committable git identity in the current work dir (sandboxed HOME
# has none), for tests where the mock agent commits.
init_git_identity() {
  git config user.email "ralph-test@example.com"
  git config user.name "Ralph Test"
}

default_log() {
  ls .ralph/ralph-loop-*.log 2>/dev/null | head -n 1
}

# --- tests -------------------------------------------------------------------

test_help_exits_zero() {
  # Mirrors the Homebrew formula test: `ralph-loop --help` must succeed.
  run_ralph --help
  if [ "$ralph_status" -eq 0 ] && grep -q "Usage:" "$ralph_out"; then
    t_pass "--help exits 0 and prints usage"
  else
    t_fail "--help exits 0 and prints usage" "status=$ralph_status"
  fi
}

test_missing_prompt_fails() {
  run_ralph --count 1 --non-interactive
  if [ "$ralph_status" -eq 1 ] && grep -q "a prompt is required" "$ralph_out"; then
    t_pass "missing prompt is a usage error"
  else
    t_fail "missing prompt is a usage error" "status=$ralph_status"
  fi
}

test_rejects_non_numeric_count() {
  run_ralph --count nope --prompt "x" --non-interactive
  if [ "$ralph_status" -eq 1 ] && grep -q -- "--count must be a positive integer" "$ralph_out"; then
    t_pass "non-numeric --count is rejected cleanly"
  else
    t_fail "non-numeric --count is rejected cleanly" "status=$ralph_status"
  fi
}

test_rejects_invalid_sandbox() {
  run_ralph --count 1 --prompt "x" --sandbox full-yolo --non-interactive
  if [ "$ralph_status" -eq 1 ] && grep -q -- "--sandbox must be" "$ralph_out"; then
    t_pass "invalid --sandbox value is rejected"
  else
    t_fail "invalid --sandbox value is rejected" "status=$ralph_status"
  fi
}

test_runs_requested_iterations_and_resumes_last() {
  run_ralph --count 2 --prompt "continue" --non-interactive --allow-low-progress
  local log
  log="$(default_log)"
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 2 ] \
    && [ "$(head -n 1 "$MOCK_CODEX_DIR/argv_1")" = "exec" ] \
    && ! argv_has 1 "resume" \
    && argv_has 2 "resume" \
    && argv_has 2 "--last" \
    && [ -n "$log" ] && grep -q "\[END\]" "$log"; then
    t_pass "runs N iterations; later iterations resume --last"
  else
    t_fail "runs N iterations; later iterations resume --last" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_done_sentinel_ends_loop_early() {
  set_behavior 1 0 "done"
  run_ralph --count 3 --prompt "continue" --non-interactive --allow-low-progress
  local log
  log="$(default_log)"
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 1 ] \
    && [ -n "$log" ] && grep -q "\[DONE\]" "$log"; then
    t_pass "done sentinel ends the loop early"
  else
    t_fail "done sentinel ends the loop early" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_session_id_extracted_and_resumed() {
  set_behavior 1 0 "session id: aaaabbbb-1234-5678-9abc-def012345678" "working on it"
  run_ralph --count 2 --prompt "continue" --non-interactive --allow-low-progress
  if [ "$ralph_status" -eq 0 ] \
    && argv_has 2 "resume" \
    && argv_has 2 "aaaabbbb-1234-5678-9abc-def012345678"; then
    t_pass "session id from output is used for resume"
  else
    t_fail "session id from output is used for resume" "status=$ralph_status"
  fi
}

test_context_overflow_triggers_fresh_session() {
  set_behavior 1 1 "stream error: input exceeds the context window"
  run_ralph --count 2 --prompt "continue" --non-interactive --allow-low-progress
  local log
  log="$(default_log)"
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 2 ] \
    && [ -n "$log" ] \
    && grep -q "\[RECOVER\]" "$log" \
    && grep -q "event=context_overflow_detected" "$log" \
    && grep -q "session_mode=fresh_recovery" "$log" \
    && ! argv_has 2 "resume"; then
    t_pass "context overflow starts a fresh session next iteration"
  else
    t_fail "context overflow starts a fresh session next iteration" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_overflow_recovery_can_be_disabled() {
  set_behavior 1 1 "stream error: input exceeds the context window"
  run_ralph --count 2 --prompt "continue" --non-interactive --allow-low-progress \
    --no-context-overflow-recovery
  local log
  log="$(default_log)"
  if [ "$ralph_status" -eq 0 ] \
    && [ -n "$log" ] && ! grep -q "\[RECOVER\]" "$log" \
    && argv_has 2 "resume" \
    && argv_has 2 "--last"; then
    t_pass "--no-context-overflow-recovery keeps resuming"
  else
    t_fail "--no-context-overflow-recovery keeps resuming" "status=$ralph_status"
  fi
}

test_default_model_and_reasoning_injected() {
  run_ralph --count 1 --prompt "continue" --non-interactive --allow-low-progress
  if argv_has 1 "--model" \
    && argv_has 1 "gpt-5.3-codex-spark" \
    && argv_has 1 'model_reasoning_effort="extra_high"'; then
    t_pass "default model and plan reasoning effort are injected"
  else
    t_fail "default model and plan reasoning effort are injected"
  fi
}

test_model_override_respected_and_dash_c_normalized() {
  run_ralph --count 1 --prompt "continue" --non-interactive --allow-low-progress \
    -- -c 'model="custom-model"'
  if argv_has 1 "--config" \
    && argv_has 1 'model="custom-model"' \
    && ! argv_has 1 "-c" \
    && ! argv_has 1 "--model" \
    && ! argv_has 1 "gpt-5.3-codex-spark"; then
    t_pass "-c model override is normalized and suppresses default model"
  else
    t_fail "-c model override is normalized and suppresses default model"
  fi
}

test_no_alt_screen_stripped_in_non_interactive() {
  # Regression: with --no-alt-screen as the only pass-through arg, the
  # normalized array is empty, which crashed under set -u on bash < 4.4.
  run_ralph --count 1 --prompt "continue" --non-interactive --allow-low-progress \
    -- --no-alt-screen
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 1 ] \
    && ! argv_has 1 "--no-alt-screen"; then
    t_pass "--no-alt-screen is stripped in non-interactive mode without crashing"
  else
    t_fail "--no-alt-screen is stripped in non-interactive mode without crashing" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_log_file_appends_across_runs() {
  # Regression: resuming with the same --log-file used to truncate history.
  local log="$test_root/loop.log"
  run_ralph --count 1 --prompt "continue" --non-interactive --allow-low-progress --log-file "$log"
  run_ralph --count 1 --prompt "continue" --non-interactive --allow-low-progress --log-file "$log"
  local starts
  starts="$(grep -c "^\[START\]" "$log" 2>/dev/null || echo 0)"
  if [ "$ralph_status" -eq 0 ] && [ "$starts" -eq 2 ]; then
    t_pass "reusing --log-file appends instead of truncating"
  else
    t_fail "reusing --log-file appends instead of truncating" "starts=$starts"
  fi
}

test_default_tracking_log_and_state_file() {
  run_ralph --count 1 --prompt "continue" --non-interactive --allow-low-progress
  local log
  log="$(default_log)"
  if [ -n "$log" ] \
    && grep -q "tracking event=iteration_start" "$log" \
    && grep -q "session_mode=fresh_initial" "$log" \
    && [ -f .ralph/session-state.md ] \
    && grep -q "^run_id:" .ralph/session-state.md \
    && grep -q "^iteration: 1 / 1" .ralph/session-state.md; then
    t_pass "default tracking log and state file are written"
  else
    t_fail "default tracking log and state file are written"
  fi
}

test_progress_gate_blocks_low_progress() {
  run_ralph --count 1 --prompt "continue" --non-interactive \
    --progress-window 1 --min-delta-lines 5
  if [ "$ralph_status" -eq 1 ] && grep -q "progress gate failed" "$ralph_out"; then
    t_pass "progress gate fails the run when nothing changed"
  else
    t_fail "progress gate fails the run when nothing changed" "status=$ralph_status"
  fi
}

test_allow_low_progress_bypasses_gate() {
  run_ralph --count 1 --prompt "continue" --non-interactive \
    --progress-window 1 --min-delta-lines 5 --allow-low-progress
  if [ "$ralph_status" -eq 0 ]; then
    t_pass "--allow-low-progress bypasses the gate"
  else
    t_fail "--allow-low-progress bypasses the gate" "status=$ralph_status"
  fi
}

test_progress_gate_counts_committed_lines() {
  # Regression: the gate used to measure only the working tree, so an agent that
  # committed its work registered as zero progress (which is why every documented
  # invocation passes --allow-low-progress). It must now count committed churn
  # since the run started.
  init_git_identity
  printf 'seed\n' > seed.txt
  git add seed.txt
  git commit -qm seed
  # Baseline is captured at run start (this seed commit), before the agent works.
  local base_sha
  base_sha="$(git rev-parse HEAD)"
  # The action COMMITS its work, so the working tree is clean afterwards — the old
  # working-tree-only metric would read 0 here, the new base-relative metric reads 6.
  set_action 1 'printf "a\nb\nc\nd\ne\nf\n" > work.txt; git add work.txt; git commit -qm "agent work"'
  run_ralph --count 1 --prompt "continue" --non-interactive \
    --progress-window 1 --min-delta-lines 5
  # No pending change for work.txt proves it was committed (not merely staged: a
  # staged-only file would show "A  work.txt"), so the 6 counted lines can only
  # come from counting churn since base_sha, not from the working tree.
  if [ "$ralph_status" -eq 0 ] \
    && [ -z "$(git status --short -- work.txt)" ] \
    && grep -q "^total_changed_lines: 6$" .ralph/session-state.md \
    && grep -q "^progress_basis: ${base_sha}$" .ralph/session-state.md; then
    t_pass "progress gate counts committed lines since run start"
  else
    t_fail "progress gate counts committed lines since run start" "status=$ralph_status"
  fi
}

test_progress_gate_counts_untracked_new_files() {
  # Regression: `git diff` ignores untracked files, so an agent that writes new
  # files (modules, tests, docs) but has not staged them registered as zero
  # progress and tripped the gate even though it had done real work. New untracked
  # *text* files must now count toward progress.
  #
  # This also pins the exclusion: the harness writes .ralph/session-state.md and a
  # .ralph/ralph-loop-*.log into this work dir, which is NOT gitignored in the test
  # sandbox, so a naive untracked count would add their lines too and the total
  # would exceed 6. A clean 6 proves only the agent's new file was counted.
  init_git_identity
  printf 'seed\n' > seed.txt
  git add seed.txt
  git commit -qm seed
  # The action writes a NEW 6-line file but never stages or commits it.
  set_action 1 'printf "a\nb\nc\nd\ne\nf\n" > newmod.txt'
  run_ralph --count 1 --prompt "continue" --non-interactive \
    --progress-window 1 --min-delta-lines 5
  # The file is still untracked afterward, proving it was counted without staging.
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(git status --short -- newmod.txt)" = "?? newmod.txt" ] \
    && grep -q "^total_changed_lines: 6$" .ralph/session-state.md; then
    t_pass "progress gate counts untracked new-file lines (excludes own state/log)"
  else
    t_fail "progress gate counts untracked new-file lines (excludes own state/log)" "status=$ralph_status total=$(grep '^total_changed_lines:' .ralph/session-state.md 2>/dev/null)"
  fi
}

test_progress_gate_skips_untracked_binary_files() {
  # A new untracked *binary* file must not inflate progress: git reports binary
  # churn as `-` (counted 0), and the untracked count mirrors that by skipping
  # files grep flags as binary. Without the skip, a stray binary blob would let an
  # otherwise-idle iteration sail through the gate.
  init_git_identity
  printf 'seed\n' > seed.txt
  git add seed.txt
  git commit -qm seed
  # Write a NUL-containing binary file (no real line-based progress).
  set_action 1 'printf "\x00\x01\x02\x00bin\x00" > blob.bin'
  run_ralph --count 1 --prompt "continue" --non-interactive \
    --progress-window 1 --min-delta-lines 5
  # min-delta is 5 and the binary contributes 0, so the gate must fail the run.
  if [ "$ralph_status" -eq 1 ] \
    && grep -q "progress gate failed" "$ralph_out" \
    && [ "$(git status --short -- blob.bin)" = "?? blob.bin" ]; then
    t_pass "untracked binary files are not counted as progress"
  else
    t_fail "untracked binary files are not counted as progress" "status=$ralph_status"
  fi
}

test_version_flag_and_sync() {
  run_ralph --version
  if [ "$ralph_status" -ne 0 ] \
    || ! grep -Eq '^ralph-loop [0-9]+\.[0-9]+\.[0-9]+' "$ralph_out"; then
    t_fail "--version prints semver and exits 0" "status=$ralph_status"
    return
  fi
  # When exercising the in-repo script (not an installed binary via
  # RALPH_LOOP_BIN, which may legitimately be a different version), the script
  # version must match package.json so the two never silently drift.
  if [ -z "${RALPH_LOOP_BIN:-}" ] && [ -f "$REPO_ROOT/package.json" ]; then
    local pkg
    pkg="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/package.json" | head -n1)"
    if [ -n "$pkg" ] && ! grep -q "ralph-loop $pkg" "$ralph_out"; then
      t_fail "--version matches package.json ($pkg)" "got=$(cat "$ralph_out")"
      return
    fi
  fi
  t_pass "--version prints semver, exits 0, and matches package.json"
}

test_missing_flag_value_is_clean_error() {
  # Regression: a value-taking flag given no value used to crash with
  # "$2: unbound variable" under set -u instead of a usage error.
  local flag ok=1
  for flag in --count --prompt --session-id --sleep --log-file --min-delta-lines; do
    run_ralph "$flag"
    if [ "$ralph_status" -ne 1 ] \
      || ! grep -q "option $flag requires a value" "$ralph_out" \
      || grep -q "unbound variable" "$ralph_out"; then
      ok=0
      t_fail "missing value for $flag is a clean usage error" "status=$ralph_status"
      break
    fi
  done
  if [ "$ok" -eq 1 ]; then
    t_pass "missing value for value-taking flags is a clean usage error"
  fi
}

test_prompt_file_is_read() {
  # The --prompt-file contents become the execution base prompt, which
  # build_context_prompt embeds at the top of the prompt argv element. Iteration
  # 1 is always planning, so the execution prompt first appears on iteration 2.
  printf 'UNIQUE_PROMPT_MARKER_42\n' > prompt.txt
  run_ralph --count 2 --prompt-file prompt.txt --non-interactive --allow-low-progress
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 2 ] \
    && grep -q "UNIQUE_PROMPT_MARKER_42" "$MOCK_CODEX_DIR/argv_2"; then
    t_pass "--prompt-file contents are sent to codex"
  else
    t_fail "--prompt-file contents are sent to codex" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_missing_prompt_file_is_clean_error() {
  # Regression: a missing *-file used to leak a raw `cat: ... No such file`
  # error and abort under set -e instead of a clean usage error.
  local flag ok=1
  for flag in --prompt-file --plan-prompt-file --summary-prompt-file; do
    # Provide --prompt too so plan/summary cases fail on the file, not on a
    # missing prompt; --prompt-file's own case still triggers first for it.
    run_ralph --count 1 --prompt "x" "$flag" "$test_root/nope${flag}.txt" --non-interactive
    # `--` stops grep option parsing so the pattern (which starts with --) is not
    # mistaken for a flag.
    if [ "$ralph_status" -ne 1 ] \
      || ! grep -q -- "$flag file not found" "$ralph_out" \
      || grep -q "No such file or directory" "$ralph_out"; then
      ok=0
      t_fail "missing $flag is a clean usage error" "status=$ralph_status"
      break
    fi
  done
  if [ "$ok" -eq 1 ]; then
    t_pass "missing *-file flags are clean usage errors (no raw cat leak)"
  fi
}

test_unknown_long_flag_is_clean_error() {
  # Regression: an unrecognized long option (typo) before -- used to silently
  # break parsing and leak to codex as a pass-through arg, quietly changing
  # behavior (e.g. a typo'd --allow-low-progres leaves the gate enabled).
  run_ralph --count 1 --prompt "x" --allow-low-progres --non-interactive
  if [ "$ralph_status" -eq 1 ] \
    && grep -q "unknown option: --allow-low-progres" "$ralph_out" \
    && [ "$(mock_calls)" -eq 0 ]; then
    t_pass "unknown long option is rejected before invoking codex"
  else
    t_fail "unknown long option is rejected before invoking codex" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_new_agent_forces_fresh_session() {
  # --new-agent must override an explicit --session-id and start fresh, so the
  # first iteration never issues `resume`.
  run_ralph --count 1 --prompt "continue" --session-id SOME-EXISTING-ID --new-agent \
    --non-interactive --allow-low-progress
  local log
  log="$(default_log)"
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 1 ] \
    && ! argv_has 1 "resume" \
    && ! argv_has 1 "SOME-EXISTING-ID" \
    && [ -n "$log" ] && grep -q "session_mode=fresh_initial" "$log"; then
    t_pass "--new-agent forces a fresh session over an explicit --session-id"
  else
    t_fail "--new-agent forces a fresh session over an explicit --session-id" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_sandbox_and_bypass_passed_through() {
  run_ralph --count 1 --prompt "continue" --sandbox workspace-write --bypass-sandbox \
    --non-interactive --allow-low-progress
  if [ "$ralph_status" -eq 0 ] \
    && argv_has 1 "-s" \
    && argv_has 1 "workspace-write" \
    && argv_has 1 "--dangerously-bypass-approvals-and-sandbox"; then
    t_pass "--sandbox and --bypass-sandbox are passed to codex"
  else
    t_fail "--sandbox and --bypass-sandbox are passed to codex" "status=$ralph_status"
  fi
}

test_summary_phase_fires_on_interval() {
  # Iteration 1 is always planning; with --summary-every 1 the second iteration
  # is a summary phase, logged as phase=summary in the iteration_start tracking.
  run_ralph --count 2 --prompt "continue" --summary-every 1 --non-interactive --allow-low-progress
  local log
  log="$(default_log)"
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 2 ] \
    && [ -n "$log" ] \
    && grep -q "event=iteration_start iter=1/2 phase=planning" "$log" \
    && grep -q "event=iteration_start iter=2/2 phase=summary" "$log"; then
    t_pass "summary phase fires on the --summary-every interval"
  else
    t_fail "summary phase fires on the --summary-every interval" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_interactive_mode_uses_codex_not_exec() {
  # Default (no --non-interactive) drives `codex` interactively, so the first
  # recorded argv must not begin with the `exec` subcommand.
  run_ralph --count 1 --prompt "continue" --allow-low-progress
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 1 ] \
    && [ "$(head -n 1 "$MOCK_CODEX_DIR/argv_1")" != "exec" ] \
    && ! argv_has 1 "exec"; then
    t_pass "interactive (default) mode runs codex without the exec subcommand"
  else
    t_fail "interactive (default) mode runs codex without the exec subcommand" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_done_via_session_assistant_text() {
  # Exercises the jq/session path of done-detection: the visible mock output does
  # NOT end in "done", so completion can only be detected by parsing the assistant
  # message in the session .jsonl. (The output-file fallback alone would not fire.)
  if ! command -v jq >/dev/null 2>&1; then
    t_pass "done via session assistant text (skipped: jq not installed)"
    return
  fi
  local sid="dddddddd-1111-2222-3333-444444444444"
  local sess="$HOME/.codex/sessions/rollout-$sid.jsonl"
  mkdir -p "$(dirname "$sess")"
  {
    printf '%s\n' '{"type":"turn_context","payload":{"turn_id":"T1"}}'
    printf '%s\n' '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"task_complete"}}'
  } > "$sess"
  set_behavior 1 0 "session id: $sid" "still thinking"
  run_ralph --count 3 --prompt "continue" --non-interactive --allow-low-progress
  local log
  log="$(default_log)"
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 1 ] \
    && [ -n "$log" ] && grep -q "\[DONE\]" "$log"; then
    t_pass "done detected via session assistant text (jq path) ends loop"
  else
    t_fail "done detected via session assistant text (jq path) ends loop" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_missing_codex_fails_fast() {
  # Regression: a missing `codex` used to go unnoticed until mid-run. Each
  # iteration failed with command-not-found, and because the loop treats a
  # non-zero codex exit as a normal "keep going" result it burned through every
  # requested iteration — and with --allow-low-progress still exited 0, masking
  # the problem. The harness must now verify its hard deps up front and fail
  # immediately, before any iteration.
  #
  # Build a restricted PATH with git + rg + coreutils but no codex, independent
  # of whatever is installed system-wide, so the check actually fires here (the
  # test machine may well have a real codex on its normal PATH).
  local limited="$test_root/limited_bin"
  mkdir -p "$limited"
  ln -sf "$(command -v git)" "$limited/git"
  ln -sf "$(command -v rg)" "$limited/rg"
  local restore="$PATH"
  export PATH="$limited:/usr/bin:/bin"
  if command -v codex >/dev/null 2>&1; then
    # A codex leaked into the restricted PATH (e.g. installed under /usr/bin);
    # skip rather than report a misleading result.
    export PATH="$restore"
    t_pass "missing codex fails fast (skipped: codex present in restricted PATH)"
    return
  fi
  run_ralph --count 5 --prompt "continue" --non-interactive --allow-low-progress
  export PATH="$restore"
  if [ "$ralph_status" -ne 0 ] \
    && grep -q "not found on PATH: codex" "$ralph_out" \
    && [ "$(mock_calls)" -eq 0 ]; then
    t_pass "missing codex dependency fails fast before any iteration"
  else
    t_fail "missing codex dependency fails fast before any iteration" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_empty_prompt_file_is_clean_error() {
  # A --prompt-file that exists but has no usable content (empty or whitespace
  # only) is reported as such, not as the generic "a prompt is required" message
  # (which reads as if no prompt flag was given at all). Nothing should run.
  printf '   \n\t\n' > blank-prompt.txt
  run_ralph --count 1 --prompt-file blank-prompt.txt --non-interactive --allow-low-progress
  if [ "$ralph_status" -eq 1 ] \
    && grep -q -- "--prompt-file has no usable content" "$ralph_out" \
    && [ "$(mock_calls)" -eq 0 ]; then
    t_pass "empty/whitespace --prompt-file is a clean, specific usage error"
  else
    t_fail "empty/whitespace --prompt-file is a clean, specific usage error" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_whitespace_prompt_rejected() {
  # A --prompt that is only whitespace is as useless as an empty one and used to
  # be accepted as a valid prompt; it must now be rejected up front.
  run_ralph --count 1 --prompt "   " --non-interactive --allow-low-progress
  if [ "$ralph_status" -eq 1 ] \
    && grep -q "a prompt is required" "$ralph_out" \
    && [ "$(mock_calls)" -eq 0 ]; then
    t_pass "whitespace-only --prompt is rejected"
  else
    t_fail "whitespace-only --prompt is rejected" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_requires_git_repo() {
  # Regression: the progress gate, the context-prompt git snapshot, and the
  # churn baseline all assume a git work tree. Run from a non-repo dir, the
  # harness used to degrade silently — 0 churn reads as a misleading "progress
  # gate failed", or with --allow-low-progress as a meaningless run. It must now
  # fail fast with a clear "not a git repository" error before invoking codex,
  # in the same spirit as the missing-dependency check. --allow-low-progress is
  # passed to prove the rejection is the repo check, not the progress gate.
  local nogit="$test_root/nogit"
  mkdir -p "$nogit"
  cd "$nogit" || { t_fail "non-git working dir fails fast" "cd failed"; return; }
  # Guard: if some ancestor of the sandbox is itself a git repo, the check would
  # (correctly) pass and this test would be meaningless — skip, as other
  # environment-dependent tests do.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    t_pass "requires a git repository (skipped: sandbox is inside a repo)"
    return
  fi
  run_ralph --count 3 --prompt "continue" --non-interactive --allow-low-progress
  if [ "$ralph_status" -ne 0 ] \
    && grep -q "not a git repository" "$ralph_out" \
    && [ "$(mock_calls)" -eq 0 ]; then
    t_pass "non-git working dir fails fast before invoking codex"
  else
    t_fail "non-git working dir fails fast before invoking codex" "status=$ralph_status calls=$(mock_calls)"
  fi
}

test_plan_and_summary_prompt_files_are_read() {
  # Coverage: only --prompt-file's success path was exercised. The plan and
  # summary prompt files flow through the same require_readable_file + cat path
  # but route into different phases — iteration 1 (planning) and every
  # --summary-every-th iteration (summary). With --summary-every 1 and count 2,
  # iter1 is planning and iter2 is summary, so each file's marker must appear in
  # exactly its own phase's argv and not the other's.
  printf 'PLAN_MARKER_AAA\n' > plan.txt
  printf 'SUMMARY_MARKER_BBB\n' > summary.txt
  run_ralph --count 2 --prompt "continue" \
    --plan-prompt-file plan.txt --summary-prompt-file summary.txt \
    --summary-every 1 --non-interactive --allow-low-progress
  if [ "$ralph_status" -eq 0 ] \
    && [ "$(mock_calls)" -eq 2 ] \
    && grep -q "PLAN_MARKER_AAA" "$MOCK_CODEX_DIR/argv_1" \
    && grep -q "SUMMARY_MARKER_BBB" "$MOCK_CODEX_DIR/argv_2" \
    && ! grep -q "SUMMARY_MARKER_BBB" "$MOCK_CODEX_DIR/argv_1" \
    && ! grep -q "PLAN_MARKER_AAA" "$MOCK_CODEX_DIR/argv_2"; then
    t_pass "--plan-prompt-file/--summary-prompt-file route to planning/summary phases"
  else
    t_fail "--plan-prompt-file/--summary-prompt-file route to planning/summary phases" "status=$ralph_status calls=$(mock_calls)"
  fi
}

# --- runner ------------------------------------------------------------------

ORIG_HOME="$HOME"

tests="
test_help_exits_zero
test_missing_prompt_fails
test_rejects_non_numeric_count
test_rejects_invalid_sandbox
test_runs_requested_iterations_and_resumes_last
test_done_sentinel_ends_loop_early
test_session_id_extracted_and_resumed
test_context_overflow_triggers_fresh_session
test_overflow_recovery_can_be_disabled
test_default_model_and_reasoning_injected
test_model_override_respected_and_dash_c_normalized
test_no_alt_screen_stripped_in_non_interactive
test_log_file_appends_across_runs
test_default_tracking_log_and_state_file
test_progress_gate_blocks_low_progress
test_allow_low_progress_bypasses_gate
test_progress_gate_counts_committed_lines
test_progress_gate_counts_untracked_new_files
test_progress_gate_skips_untracked_binary_files
test_version_flag_and_sync
test_missing_flag_value_is_clean_error
test_prompt_file_is_read
test_missing_prompt_file_is_clean_error
test_unknown_long_flag_is_clean_error
test_new_agent_forces_fresh_session
test_sandbox_and_bypass_passed_through
test_summary_phase_fires_on_interval
test_interactive_mode_uses_codex_not_exec
test_done_via_session_assistant_text
test_missing_codex_fails_fast
test_empty_prompt_file_is_clean_error
test_whitespace_prompt_rejected
test_requires_git_repo
test_plan_and_summary_prompt_files_are_read
"

for t in $tests; do
  setup
  "$t"
  teardown
done

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
