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
"

for t in $tests; do
  setup
  "$t"
  teardown
done

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
