# Setup And Run Ralph Loops

This guide explains how to run Codex in iterative "Ralph loop" mode using `scripts/ralph-loop.sh`.

## 0) Install
Choose one:

Homebrew:
```bash
brew tap discordwell/ralph-codex
brew install --HEAD discordwell/ralph-codex/ralph-loop
```

npm (from GitHub):
```bash
npm install -g github:discordwell/ralph-codex
```

## 1) Prerequisites
- `codex` CLI installed and authenticated.
- `rg` (ripgrep) installed (the script uses it for session lookups).
- A target repo where Codex should do work.

Check:
```bash
codex --version
rg --version
```

## 2) Script Location
Installed command:
- `ralph-loop`

If running from a local clone instead of package-manager install:
```bash
chmod +x scripts/ralph-loop.sh
```

## 3) Basic Single Loop
Run from the target project root:
```bash
ralph-loop \
  --count 20 \
  --prompt "Continue implementation. Keep tests green." \
  --non-interactive \
  --allow-low-progress \
  --sandbox danger-full-access \
  --bypass-sandbox
```

Useful outputs:
- `.ralph/session-state.md` (or custom state file)
- Optional `--log-file <path>`

## 4) Recommended Prompt File Workflow
Use a prompt file so objectives stay explicit.

Create prompt:
```bash
mkdir -p .ralph
cat > .ralph/prompt.txt <<'TXT'
Objective:
- Do X.
Required outcomes:
1) ...
2) ...
Validation target:
- npm run typecheck
- npm run build
- npm run test
TXT
```

Run:
```bash
ralph-loop \
  --count 60 \
  --prompt-file .ralph/prompt.txt \
  --state-file .ralph/session-state-x.md \
  --log-file .ralph/loop-x.log \
  --non-interactive \
  --allow-low-progress \
  --sandbox danger-full-access \
  --bypass-sandbox
```

## 5) Parallel Loops (Recommended: Worktrees)
Use one git worktree per objective to avoid collisions.

Example:
```bash
git worktree add -b codex/loop-a ../project_loop_a main
git worktree add -b codex/loop-b ../project_loop_b main
```

Start one loop per worktree (in each worktree root):
```bash
nohup ralph-loop \
  --count 120 \
  --prompt-file .ralph/prompt-loop-a.txt \
  --state-file .ralph/session-state-loop-a.md \
  --log-file .ralph/loop-a.log \
  --non-interactive \
  --allow-low-progress \
  --sandbox danger-full-access \
  --bypass-sandbox \
  > .ralph/loop-a.nohup.out 2>&1 &
```

## 6) Monitoring
Process status:
```bash
ps -p <PID> -o pid,etime,state,command
```

Tail logs:
```bash
tail -f .ralph/loop-a.log .ralph/loop-a.nohup.out
```

Current iteration snapshot:
```bash
cat .ralph/session-state-loop-a.md
```

## 7) Stop / Resume
Stop:
```bash
kill <PID>
```

Resume using the same session/state settings:
```bash
ralph-loop \
  --count 120 \
  --prompt-file .ralph/prompt-loop-a.txt \
  --state-file .ralph/session-state-loop-a.md \
  --log-file .ralph/loop-a.log \
  --non-interactive \
  --allow-low-progress \
  --sandbox danger-full-access \
  --bypass-sandbox
```

## 8) Helpful Flags
- `--new-agent`: force a fresh Codex session instead of `resume`.
- `--summary-every N`: periodic summary turns.
- `--progress-window N` + `--min-delta-lines X`: progress gate.
- `--completion-poll-interval` / `--completion-timeout`: turn completion polling behavior.
- `--state-file`: isolate loop state per objective.

## 9) Notes
- Keep one objective per loop prompt.
- Keep validation commands explicit in prompt.
- Prefer worktrees for concurrent loops.
