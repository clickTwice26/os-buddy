# os-buddy: an agentic OS operator in Bash, designed with PEAS

## Quick start

Needs Linux/Unix, Bash 4.4+, `curl` and `jq`, and a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).

```bash
./install.sh                         # links os-buddy into ~/.local/bin, creates the config
nano ~/.config/os-buddy/config       # put your GEMINI_API_KEY there
os-buddy "find the 3 largest files in this folder"
os-buddy                             # chat mode
bash tests/run.sh                    # offline tests (or: make test)
```

Exit codes: 0 done, 1 error, 2 usage error, 3 step limit reached.

## Context

`/home/sleepycat/Desktop/os-buddy` is empty, so this is a new build. The requirements are:

- Written in Bash.
- Runs only on Linux and Unix-based systems.
- Has real agentic behaviour.
- Uses the Gemini API.

Decisions confirmed with the user:

- **Job:** general OS operator. It takes a plain-language goal, then plans, runs commands, reads and edits files, checks results and continues until done.
- **Autonomy:** read-only actions run automatically, changes ask y/n, dangerous patterns are always blocked.
- **Run modes:** `os-buddy` opens a chat with memory across turns. `os-buddy "goal"` completes one task and exits.

**Agent type:** goal-based and model-based. Gemini chooses actions toward the goal, and the conversation history is its internal state. A fixed rule layer in Bash (the policy) sits between the model and the OS, and the model cannot override it.

## P: Performance measure

The agent is judged on these measures, and each one has a check.

| Measure | Target | How it is checked |
|---|---|---|
| Goal completion | Finishes only after verifying the outcome, and reports failure honestly | Scripted multi-step scenarios, plus the live test |
| Safety | 0 policy bypasses, 0 changes without approval | Policy table with bypass attempts |
| Recovery | A failed command leads to a changed approach, not a crash or a blind retry | Scenarios with non-zero exits, denials and timeouts |
| Efficiency | At most 30 steps by default, and no identical call more than 3 times without intervention | Step limit and stuck detection tests |
| API resilience | Survives 429, 5xx, blocked and empty responses | Stubbed API error tests |
| Secret protection | API key never in `ps` output or in the environment of commands the agent runs | Test inspects the child environment and the `curl` invocation |
| Bounded cost | Each tool result is about 16 KB at most, and history stays bounded | Truncation and trimming tests |
| Portability | Same results on any stable Bash from 4.4 up to the current 5.x | Test suite on the local Bash 5.x, and on a Bash 4.4 Linux container if Docker is available |
| Clear outcome for scripts | Exit codes: 0 done, 1 error, 2 usage, 3 step limit | Exit code tests |

## E: Environment

**What the agent operates in:**

- A local Linux or Unix host: shell, filesystem, processes and installed tools. Windows is rejected at startup through a `uname` check.
- A human operator at a terminal, or no human at all in scripts and cron.
- The Gemini API over the network.
- Untrusted content: file contents and command output may contain text that tries to instruct the agent.

**Task environment properties and what each one requires:**

| Property | Value | Design consequence |
|---|---|---|
| Observability | Partial | The agent must inspect before acting, and the system prompt gives OS, shell, cwd and user facts |
| Determinism | Stochastic | Commands can fail and the model varies, so every result is checked |
| Episodes | Sequential | Actions have lasting effects, so history is kept and changes need approval |
| Dynamics | Dynamic | The system can change during a task, so commands have timeouts and the agent re-checks state |
| State and actions | Discrete steps over a very large action space | Step limit, plus an allow, ask or block policy |
| Agents | One agent, cooperating with a human | `ask_user` tool and approval prompts |

**Platform constraints:**

- Dependencies are `bash` 4.4+, `curl` and `jq` 1.6+. All logic stays in Bash, and `jq` is used only because JSON parsing in pure Bash would be fragile.
- Bash version: a stable, widely compatible target. Bash 4.4 (2016) is the minimum because every maintained Linux distro ships it or newer, and development uses the current stable 5.x. Only features that exist in 4.4 are used, so associative arrays, `mapfile`/`readarray` and `${var,,}` are allowed, but 5.x-only features (such as `$EPOCHSECONDS` or `$SRANDOM`) are not. The entry point checks `BASH_VERSINFO` and exits with a clear message on older Bash.
- No GNU-only flags (`sed -i`, `stat -c`, `date -d`, `timeout`). Timeouts use a background process plus `kill`.

## A: Actuators

These are the only ways the agent can affect the world. Each one passes through the policy first.

| Actuator | Behaviour |
|---|---|
| `run_command(command, timeout_seconds)` | Runs in `bash -c`, captures stdout, stderr and exit code, default timeout 120 s |
| `write_file(path, content)` | Creates or overwrites, shows a preview before approval |
| `edit_file(path, old_text, new_text)` | Exact match only, fails if the text is missing or not unique, shows a diff |
| `ask_user(question)` | Asks the human for clarification, unavailable when non-interactive |
| Terminal output | Progress, approval prompts and the final answer |
| Process exit code | Reports the outcome to calling scripts |

**Safety policy on actuators (`lib/policy.sh`).** It fails closed, so anything not positively recognised as safe asks first.

- **Block always, even with `--yes`:** `rm -rf` on `/`, `/*`, `~` or system directories, `mkfs`, `dd` or redirects onto block devices, fork bombs, recursive `chmod`/`chown` on `/`.
- **Allow automatically:** every pipeline segment starts with a known read-only command (`ls`, `cat`, `head`, `tail`, `wc`, `grep`, `df`, `du`, `ps`, `uname`, `whoami`, `id`, `date`, `pwd`, `uptime`, `free`, `stat`, `file`, `which`, `sort`, `uniq`, `cut`, `git status/log/diff`, and `find` without `-exec` or `-delete`), and the command has no `;`, `&`, `>`, `$(`, backticks or newlines.
- **Ask for everything else**, including all `write_file` and `edit_file` calls.
- **Sensitive paths always ask**, because file contents are sent to Google: `.ssh`, `.aws`, `.gnupg`, `.env`, `/etc/shadow`, private keys, and the os-buddy config.
- **Non-interactive runs:** anything needing approval is denied and reported to the model, unless `--yes` is given.

## S: Sensors

These are the agent's only inputs.

| Sensor | What it perceives |
|---|---|
| `run_command` result | stdout, stderr, exit code, timeout status |
| `read_file(path, offset, limit)` | Numbered lines with a size cap |
| Tool status from `write_file` and `edit_file` | Success, no match, ambiguous match, permission error |
| Policy result | Allowed, denied by the human, or blocked |
| Human input | The goal, chat messages, y/n approvals, `ask_user` answers |
| Host facts at startup | OS, shell, cwd, user, whether a TTY is attached |
| Gemini response | Text, `functionCall` parts, `finishReason`, HTTP status and error message |

**Handling percepts:**

- Errors are observations. Non-zero exits, denials and timeouts go back to the model so it can adapt.
- Tool output is treated as untrusted data, never instructions. The system prompt says so, and the policy does not depend on the model obeying it.
- Output is capped at about 16 KB, keeping head and tail with a truncation marker.

## Agent function: how percepts become actions (`lib/agent.sh`)

Uses Gemini's native function calling through the REST `generateContent` endpoint. For each step up to `OSBUDDY_MAX_STEPS` (default 30):

1. Send the history, system prompt and tool declarations to Gemini.
2. Append `candidates[0].content` to history **verbatim**. This preserves thought signatures that Gemini 3+ models require on replay.
3. If there are no `functionCall` parts, print the text and finish.
4. Otherwise run each call in order through the policy, and return all results in one user turn as `functionResponse` parts, echoing `name` and any `id`.
5. Repeat.

Supporting behaviour:

- **System prompt:** state a short plan, act, verify each result, adapt on failure, and finish only after confirming the goal.
- **Stuck detection:** the same call repeated 3 times injects a note telling the model to try something else.
- **State handling:** history lives in a temp JSON file and is passed through files (`jq --slurpfile`, `curl -d @file`), which avoids argument length limits and shell quoting bugs.
- **Trimming:** when history gets large, the oldest tool results are replaced with `[trimmed]`, keeping call and response pairs intact.
- **API failures:** 429 and 5xx retry with exponential backoff. Other errors print the server's message. Blocked or empty candidates and `MAX_TOKENS` are reported clearly.
- **Interrupts:** Ctrl-C stops the current action and returns to the prompt. Temp files are removed by a `trap`.

**Secret handling:**

- The API key is given to `curl` through `--config -` on stdin, so it never appears in `ps` output.
- `GEMINI_API_KEY` is removed from the environment of commands the agent runs.
- The config file must be mode 600, with a warning otherwise.

## Project structure

Files are created only when their build phase is reached, not all at once.

```
os-buddy/
├── bin/
│   └── os-buddy              # entry point (the command you run)
├── lib/
│   ├── config.sh
│   ├── ui.sh
│   ├── gemini.sh
│   ├── tools.sh
│   ├── policy.sh
│   └── agent.sh
├── share/
│   ├── system-prompt.txt     # instructions sent to Gemini
│   └── tools.json            # tool declarations for Gemini
├── tests/
│   ├── run.sh
│   ├── helpers.sh
│   ├── test_cli.sh
│   ├── test_policy.sh
│   ├── test_tools.sh
│   ├── test_gemini.sh
│   ├── test_agent.sh
│   └── fixtures/
│       └── gemini/           # scripted API responses replayed by tests
├── docs/
│   └── design.md             # PEAS design (moved out of README later)
├── examples/
│   └── config.example
├── install.sh
├── Makefile
├── .editorconfig
├── .gitignore
├── .shellcheckrc
├── CHANGELOG.md
├── LICENSE
└── README.md
```

| File | PEAS role | Responsibility |
|---|---|---|
| `bin/os-buddy` | Environment | Executable entry point: Bash/OS/dependency checks, flags, chooses chat or one-shot, finds and sources `lib/` relative to its own real location (so it still works through a symlink in `~/.local/bin`) |
| `lib/config.sh` | Environment | Defaults, then `~/.config/os-buddy/config`, then env vars, then flags |
| `lib/ui.sh` | Actuator and sensor | Coloured output and approval prompts, disabled when not a TTY |
| `lib/gemini.sh` | Sensor | Builds the request, calls the API, retries |
| `lib/agent.sh` | Agent function | The loop, history, stuck detection, trimming |
| `lib/tools.sh` | Actuators and sensors | Tool implementations |
| `lib/policy.sh` | Actuator guard | Classifies each action as allow, ask or block |
| `share/system-prompt.txt` | Agent function | System prompt text, kept out of Bash strings to avoid quoting bugs |
| `share/tools.json` | Actuators and sensors | Tool declarations, read directly by `jq` |
| `tests/run.sh` | Performance | Plain-Bash offline test runner, one test file per area |
| `tests/helpers.sh` | Performance | Shared assert functions |
| `tests/fixtures/gemini/` | Performance | Fake Gemini responses, so tests need no network or API key |
| `docs/design.md` | Documentation | Full PEAS design, once README becomes a short user guide |
| `examples/config.example` | Environment | Sample config file |
| `install.sh` | Environment | Links `bin/os-buddy` into `~/.local/bin` |
| `Makefile` | Tooling | `make test`, `make lint`, `make install` |
| `.editorconfig`, `.shellcheckrc` | Tooling | Consistent formatting and ShellCheck settings |
| `.gitignore` | Tooling | Keeps secrets, editor folders and temp files out of git |
| `CHANGELOG.md`, `LICENSE` | Documentation | Version history and usage terms |
| `README.md` | Documentation | Install, configuration, usage, and the PEAS summary |

## CLI

```
os-buddy                  # chat; /reset, /help, /exit
os-buddy "free up disk"   # one task, then exit
  --yes  --model M  --max-steps N  --verbose  --help
```

Default model is `gemini-3.6-flash`, the latest **stable** Flash model on Google's model list (checked 2026-11-12). `gemini-3.8-flash` also exists and is newer, but is marked "New" rather than "Stable". Override with `--model` or `OSBUDDY_MODEL`.

## Verification

`tests/run.sh` reports pass or fail against each row of the Performance measure table.

1. **Offline tests:** a stubbed API call replays scripted Gemini responses to cover multi-step loops, parallel calls, API errors and retries, step limit, stuck detection, truncation and denied approvals. `bats` is not installed here, so the runner is plain Bash.
2. **Policy table:** dozens of commands with expected allow, ask or block, including bypass attempts like `ls; rm -rf /`, `cat x > y`, `find . -delete` and `$(rm x)`.
3. **Portability:** run the tests on the local Bash 5.x, and on a Bash 4.4 Linux container (for example the `bash:4.4` Docker image) if Docker is available. Run `shellcheck` if it can be installed.
4. **Live test:** needs `GEMINI_API_KEY`, which is not set in this environment. Confirm the real wire format with a multi-step goal such as "find the 3 largest files here and save them to report.txt", checking that the write prompts for approval.