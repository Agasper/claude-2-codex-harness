# claude-2-codex-harness

<p align="center">
  <img src="assets/hero.png" alt="Claude Code walking Codex on a leash" width="640">
</p>

A [Claude Code](https://claude.com/claude-code) plugin that hands implementation work to the [Codex CLI](https://developers.openai.com/codex/cli/) and brings the result back in a form you can actually act on.

The plugin owns the mechanics of the handoff: launching Codex, watching the run, and taking the result back in a reviewable form. It deliberately does **not** decide which work goes to Codex — that split is yours to define.

## Why it exists

You can call Codex from Claude Code by hand, with `codex exec`. In practice that falls apart for three reasons, and each one is addressed here.

**The model rebuilds the command line every time.** Codex flags are not consistent with each other: `--approve-for-me` conflicts with `-s` and kills the run, and `codex exec resume` accepts neither `--cd` nor `-s` — the very flags that work in `codex exec` fail there with `unexpected argument`. Every hand-assembled invocation is a coin flip. Here all flags are baked into a single `codexctl` script, and only seven modes and five flags are exposed.

**Runs get lost.** A process started with `nohup` or `&` is detached from the session: no completion notification, no visible status, and both sides keep waiting on work that finished long ago. Here a run always stays a child process, writes a structured event log, and reports back.

**You cannot tell a working run from a stuck one.** "The process is alive" tells you nothing. `codexctl status` distinguishes five outcomes: **RUNNING**, **SILENT** (no events for over three minutes), **DONE**, **FAILED**, and **TRUNCATED** — Codex died mid-turn.

## Deciding what goes to Codex

The plugin is neutral about roles. It gives you a reliable way to run Codex and read the outcome; the policy of *when* to reach for it lives in your own `CLAUDE.md`, where Claude Code reads it at the start of every session.

A rule that keeps design with Claude and implementation with Codex:

```markdown
# Working with Codex
- A task explained in chat → do it yourself.
- A task that arrives as a document or spec → hand it to Codex.
- An explicit "use Codex" or "do it yourself" overrides both.
```

The opposite split works just as well — Codex reasons about the design, Claude writes the code:

```markdown
# Working with Codex
- Before implementing anything non-trivial, have Codex review the approach
  (`codexctl review`) and write the code yourself once it holds up.
```

Neither rule is built in. Without one, the plugin simply waits to be asked.

## Install

```bash
claude plugin marketplace add Agasper/claude-2-codex-harness
claude plugin install codex-bridge@claude-2-codex-harness
```

Restart your session, then run `/codex-bridge:setup` — it checks the prerequisites and puts `codexctl` on your `PATH` at `~/.local/bin`.

Requires the Codex CLI (`npm install -g @openai/codex`) with `codex login` completed, plus Python 3, Git and Bash.

## What's inside

| Component | What it does |
|---|---|
| `codexctl` | The core script. Every Codex invocation goes through it |
| `codex-bridge` skill | The working discipline: spec, launch, monitoring, acceptance |
| `codex-runner` subagent | Holds a long run so the UI shows Codex is busy |
| `/codex-bridge:run` | Hand a task to Codex |
| `/codex-bridge:review` | Have Codex review your current changes |
| `/codex-bridge:status` | What is happening right now |
| `/codex-bridge:result` | Run outcome and what changed in the repository |
| `/codex-bridge:cancel` | Stop a run |
| `/codex-bridge:setup` | Check prerequisites and install `codexctl` |

## codexctl

```
codexctl run     --cwd DIR (--prompt TEXT | --prompt-file F) [--model M] [--effort L]
codexctl review  --cwd DIR [--base REF] [--prompt TEXT] [--model M] [--effort L]
codexctl resume  --id ID  (--prompt TEXT | --prompt-file F) [--effort L]
codexctl status  [--id ID]
codexctl result  [--id ID]
codexctl cancel  [--id ID]
codexctl list
```

Each run is stored under `~/.claude/codex-runs/<id>/`: the spec, the event log, the final answer and metadata.

### Which run a command acts on

`--id` is optional. Without it, `status`, `result`, `cancel` and `resume` resolve the target in this order:

1. the newest run **started by the current Claude Code session**;
2. failing that, the newest run **in the current project** (git top level, or the working directory);
3. failing both, the command refuses and tells you to pick a run with `codexctl list`.

This matters most for `resume`, which has no working-directory flag of its own: it inherits the directory of the run it continues, so choosing a run *is* choosing a project. A plain "most recent run on this machine" would mean that a second Claude Code session, working on a different repository, could silently steer your follow-up into that repository — with write access. The session binding closes that off, and `codexctl list` marks runs from this session with `*` and runs from this project with `.`.

## What Codex is allowed to do

Everything below was established by experiment, not read off a documentation page.

Codex runs inside an OS-level sandbox (seatbelt on macOS), so the limits hold regardless of what the model decides. In `run` mode it **can** write to the project directory, `/tmp` and `$TMPDIR`; read the whole disk; reach the network; and create commits. It **cannot** write outside the project directory — attempts fail with `Operation not permitted`.

Inside the project Codex can delete anything, so before every run `codexctl` creates a git tag `codex-baseline-<timestamp>` — a rollback point and the base for the acceptance diff.

Environment variables prefixed with `CLAUDE*` — including Claude Code's local IPC token — are stripped from the environment Codex inherits. Everything else (`PATH`, `JAVA_HOME`, Python variables and so on) is passed through untouched.

Codex's built-in risk classifier (Guardian, the `--approve-for-me` flag) is deliberately **not** used: in a controlled run it approved an `rm -rf` of a directory in the user's home folder. It removes the sandbox's protection rather than adding its own.

## Codex configuration

The plugin uses your existing `~/.codex/config.toml`. Two settings are worth having:

```toml
# read the project's CLAUDE.md when it has no AGENTS.md
project_doc_fallback_filenames = ["CLAUDE.md"]

# network inside the sandbox: without it npm install, pip install and dotnet restore fail
[sandbox_workspace_write]
network_access = true
```

The default model comes from the server for your account; pin it with the `model` key in the same file, or with `--model` for a single run.

### Model and reasoning effort

The plugin passes `--model` and `--effort` through and substitutes nothing of its own:

| what you pass | what runs |
|---|---|
| neither | Codex's default model, at that model's default reasoning level |
| `--model` only | that model, at **its own** default reasoning level |
| both | exactly what you asked for |

Set a standing preference in `~/.codex/config.toml` rather than repeating flags:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
```

Worth knowing when you choose: reasoning defaults differ per model, and some are
low. `gpt-5.6-sol` defaults to `low`, while `gpt-6-astra`, `gpt-5.6-terra` and
`gpt-5.5` default to `medium`. Supported levels differ too — `low`, `medium`,
`high` and `xhigh` are common, `max` and `ultra` only on some models. Run
`codex debug models` for the current catalogue.

On a control task, raising `gpt-5.6-sol` from its default to `xhigh` took 92
seconds instead of 55 and spent 2581 reasoning tokens instead of 468 — worth it
for a hard design question, wasteful for a routine chore.

## Development

```bash
tests/smoke.sh   # checks that need no Codex call and burn no usage limits
```

## License

MIT
