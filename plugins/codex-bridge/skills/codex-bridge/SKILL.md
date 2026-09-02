---
name: codex-bridge
description: Delegating implementation work to the Codex CLI through codexctl — the only sanctioned way to launch it. Use when a task arrives as a document or spec, when the user says to hand it to Codex, for Codex-run reviews, for checking on a run in progress ("how is it doing", "is it stuck"), for accepting the result, and for follow-ups.
---

# Codex through codexctl

Design, research and review stay with me; writing code against a spec goes to Codex. Codex is launched **only** through `codexctl`.

## Hard rule: never invoke `codex` directly

Codex flags are mutually inconsistent, so every hand-assembled invocation is a gamble. Real traps already hit:

- `--approve-for-me` conflicts with `-s` and silently kills the launch;
- `codex exec resume` accepts **neither** `--cd` nor `-s` — the same flags that work in `codex exec` break the command there;
- a forgotten `-o` leaves you with no final answer, a forgotten `--json` with no log to tell what happened.

All of that is baked into `codexctl` once. From the outside there are a few modes and a handful of flags, with nothing to get wrong. If it looks like a needed mode is missing, that is a reason to extend `codexctl`, not to hand-assemble a `codex` call.

## Modes

```
codexctl run     --cwd DIR (--prompt TEXT | --prompt-file F) [--model M]
codexctl review  --cwd DIR [--base REF] [--prompt TEXT] [--model M]
codexctl resume  --id ID (--prompt TEXT | --prompt-file F)
codexctl status  [--id ID]
codexctl result  [--id ID]
codexctl cancel  [--id ID]
codexctl list
```

If `codexctl` is not on PATH (`/codex-bridge:setup` was never run), call it by full path — `"${CLAUDE_PLUGIN_ROOT}/scripts/codexctl.sh"` — and suggest the user run `/codex-bridge:setup` once.

`--id` is optional and normally unnecessary: `status`, `result`, `cancel` and `resume` pick the newest run **started by this session**, falling back to the newest run of the current project, and refusing outright when neither matches. Do not pass a working directory — there is no flag for it, and the binding is automatic on purpose. Reach for `--id` only when the user names a specific earlier run.

Sandbox, network and `.git` access, stripping of Claude Code variables, the rollback tag and the event log are all handled inside; there is no need to bring them up on every run.

## How to launch

`run`, `review` and `resume` block until the work is finished. Launch them **only** through Bash with `run_in_background: true`.

Why exactly that: a Claude Code background task sends its own completion notification, and its output is visible to the user in the interface. Reach for `nohup`, `&` or `disown` instead and the process detaches from the session — no notification, no visible status, and both of us end up waiting on a run that finished long ago. **No `nohup`, `&`, `disown` or `setsid` — only `run_in_background`.**

While a run is in flight, answer "how is it doing" with `codexctl status`, which reports the state, the time since the last event and the latest steps. Do not paraphrase from memory and do not guess.

## States and what to do about them

| State | Meaning | Action |
|---|---|---|
| RUNNING | events are coming in | nothing; report the latest step |
| SILENT | no events for over three minutes | say so plainly, show the last step, offer `codexctl cancel` |
| DONE | finished normally | move to acceptance |
| FAILED | non-zero exit code | show the tail of `err.log`, work out the cause |
| TRUNCATED | no `turn.completed` | Codex died mid-turn; accept what exists, then `codexctl resume` |

Note that DONE does not mean "did the work". Codex can finish normally while reporting that it could not do the task. Always check its claims against the actual changes.

## Discipline around a run

1. **The spec.** If the user supplied a document, pass `--prompt-file` pointing at it and do not paraphrase its contents. If the spec came out of our conversation, write it myself, **show it to the user and wait for confirmation**, then launch. That is the only point where a misunderstanding is still free to fix.
2. **A clean tree.** If the project has uncommitted changes, say so before launching: otherwise acceptance cannot separate Codex's work from what was already there. The rollback tag is created by `codexctl` itself.
3. **Acceptance.** Run `codexctl result`, then `git diff` against the tag. If Codex claims the tests pass, find the corresponding command and its output in the run log. Its word alone is not evidence.
4. **Review is never automatic.** After acceptance, report the outcome and remind the user about review, asking who should do it — me or `codexctl review`. A "no" closes the topic immediately.

## Do not

- Invoke `codex` directly or improvise flags.
- Launch through `nohup` / `&` / `disown`.
- Commit or push Codex's work without being asked.
- Hand Codex a task that was explained in chat — that one is mine.
- Report "done" without looking at the changes.
- Recite the built-in safeguards (sandbox, environment filtering, tags) to the user — they work on their own.
