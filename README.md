# os-buddy: an agentic OS operator in Bash, designed with PEAS

[![tests](https://github.com/clickTwice26/os-buddy/actions/workflows/test.yml/badge.svg)](https://github.com/clickTwice26/os-buddy/actions/workflows/test.yml)

Shell scripts that automate system administration: **process management, disk monitoring,
backup automation, system health monitoring and user management**, each with a clear visual
report in the terminal. On top of that, an AI agent (Gemini) can do any other task you
describe in plain English, behind a safety policy.

Tested on every push: macOS 15 (Apple chip and Intel) and Linux (Bash 4.4 and 5.2, Ubuntu 22.04
and 24.04, Debian 12, Fedora 41, Alpine 3.20).

## Quick start

Needs Linux or macOS, Bash 4.4+ (macOS ships 3.2: run `brew install bash`), `curl` and `jq`. On Windows, run it inside [WSL](https://learn.microsoft.com/windows/wsl/install) (`wsl --install`); Git Bash and Cygwin are not supported.
The admin reports need no API key. The AI agent needs a Gemini API key from
[Google AI Studio](https://aistudio.google.com/apikey).

Run it straight from the project folder:

```bash
./bin/os-buddy status                # one dashboard for everything (no API key needed)
echo 'GEMINI_API_KEY=your-key' > .env && chmod 600 .env   # .env is git-ignored
./bin/os-buddy "find the 3 largest files in this folder"
./bin/os-buddy                       # chat mode
bash tests/run.sh                    # offline tests (or: make test)
```

The key is read from the first of these that exists: the `GEMINI_API_KEY` environment variable, `.env` in the project folder, `~/.config/os-buddy/config`.

Optional: `./install.sh` links `os-buddy` into `~/.local/bin` so it runs from any folder.

Exit codes: 0 done, 1 error, 2 usage error, 3 step limit reached.

## Admin commands

Fixed, safe scripts with a visual report. They need no API key, and every change shows the
exact command and asks first. `--dry-run` shows what would happen; `--yes` approves.

| Task | Command | What you get |
|---|---|---|
| Everything | `os-buddy status` | Health table, top 5 processes, users, backups, one verdict |
| System health | `os-buddy health` | Uptime, CPU, load, memory, swap and fullest disk with bars |
| Disk monitoring | `os-buddy disk [PATH]` | Every disk with a bar and alert level; biggest items in PATH |
| Processes | `os-buddy proc` | Counts by state, top 10 by CPU and by memory, zombie alert |
| | `os-buddy proc find WORD` | Processes whose command line contains WORD |
| | `os-buddy proc kill PID [--force]` | Shows it, asks, stops it (never PID 1 or os-buddy) |
| Backups | `os-buddy backup create PATH` | `.tar.gz` + SHA-256, keeps the newest 7 per name |
| | `os-buddy backup list` / `verify` | Archives, ages, sizes, schedules / damage check |
| | `os-buddy backup restore FILE [DEST]` | Only into a new or empty folder, never from a damaged file |
| | `os-buddy backup schedule PATH daily [HH:MM]` | Adds a cron job (also `hourly`, `weekly`, `unschedule`) |
| Users | `os-buddy users` | People accounts, admins, who is logged in, recent logins |
| | `os-buddy users add NAME [--admin]` | New account with a home folder (via sudo) |
| | `os-buddy users lock` / `unlock` / `delete NAME` | Delete keeps the home folder; root and you are protected |

Exit codes for reports: 0 fine, 4 warning, 5 critical, so they work in cron and scripts, for
example `os-buddy disk || notify-send "disk almost full"`. Warning and critical levels are
`OSBUDDY_WARN_PCT` (70) and `OSBUDDY_CRIT_PCT` (90).

In chat, the same reports are one word away: `/status`, `/health`, `/disk`, `/proc find ssh`,
`/users`, `/backup`. The AI can read them too (tool `system_report`), so "is my system okay?"
gets an exact answer.

## What it does

You give os-buddy a goal in plain English. It plans, runs commands, reads and edits files, checks the results and keeps going until the goal is done. It uses Gemini's function calling to decide each step.

A fixed safety policy written in Bash sits between the model and your system, and the model cannot override it:

- **Read-only commands** (`ls`, `df`, `lsblk`, `systemctl status`, ...) run automatically, also
  when chained with `&&`, `||`, `;` or `|` and with `2>/dev/null`.
- **Changes** (writing files, installing, deleting, ...) ask first and show the AI's reason and
  the risk: `[y] yes [n] no [a] always allow this program in this chat`. Several changes from
  one AI reply are listed together (all, none, or one by one).
- **Dangerous patterns** (`rm -rf /`, `mkfs`, fork bombs, ...) are always blocked, even with `--yes`.

## CLI

```
os-buddy                  # chat; /status /health /disk /proc /users /backup, /reset, /help, /exit
os-buddy "free up disk"   # one task, then exit
  --yes  --model M  --max-steps N  --verbose  --help
os-buddy status | health | disk | proc | users | backup   # admin commands (see above)
```

Default model is `gemini-3.6-flash`, the latest **stable** Flash model on Google's model list (checked 2026-11-12). `gemini-3.8-flash` also exists and is newer, but is marked "New" rather than "Stable". Override with `--model` or `OSBUDDY_MODEL`.

## Project structure


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
│   ├── agent.sh
│   ├── viz.sh                # drawing kit: titles, bars, badges, boxed tables
│   ├── render.sh             # shows the AI's Markdown as clean terminal text
│   ├── admin.sh              # runs admin commands; --yes, --dry-run, ask-then-run
│   ├── admin_status.sh       # os-buddy status
│   ├── admin_health.sh       # os-buddy health
│   ├── admin_disk.sh         # os-buddy disk
│   ├── admin_proc.sh         # os-buddy proc
│   ├── admin_backup.sh       # os-buddy backup
│   └── admin_users.sh        # os-buddy users
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
│   ├── test_render.sh
│   ├── test_status.sh, test_health.sh, test_disk.sh, test_proc.sh,
│   │   test_backup.sh, test_users.sh
│   └── fixtures/
│       └── gemini/           # scripted API responses replayed by tests
├── docs/
│   ├── design.md             # full PEAS design
│   └── limitations.md        # MVP gaps and future work
├── .github/workflows/
│   └── test.yml              # CI: macOS + 7 Linux versions + ShellCheck
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
| `lib/viz.sh`, `lib/render.sh` | Actuator (display) | Terminal visuals; Markdown answers turned into headings, bullets and boxed tables |
| `lib/admin*.sh` | Actuators and sensors | The admin commands: status, health, disk, proc, backup, users |
| `share/system-prompt.txt` | Agent function | System prompt text, kept out of Bash strings to avoid quoting bugs |
| `share/tools.json` | Actuators and sensors | Tool declarations, read directly by `jq` |
| `tests/run.sh` | Performance | Plain-Bash offline test runner, one test file per area |
| `tests/helpers.sh` | Performance | Shared assert functions |
| `tests/fixtures/gemini/` | Performance | Fake Gemini responses, so tests need no network or API key |
| `docs/design.md` | Documentation | Full PEAS design |
| `docs/limitations.md` | Documentation | Known MVP gaps and future work |
| `examples/config.example` | Environment | Sample config file |
| `install.sh` | Environment | Links `bin/os-buddy` into `~/.local/bin` |
| `Makefile` | Tooling | `make test`, `make lint`, `make install` |
| `.editorconfig`, `.shellcheckrc` | Tooling | Consistent formatting and ShellCheck settings |
| `.gitignore` | Tooling | Keeps secrets, editor folders and temp files out of git |
| `CHANGELOG.md`, `LICENSE` | Documentation | Version history and usage terms |
| `README.md` | Documentation | Install, configuration, usage, and the PEAS summary |
| `.github/workflows/test.yml` | Performance | Runs the tests on macOS and 7 Linux versions on every push |
| `.githooks/pre-commit` | Tooling | Blocks commits that contain API keys, `.env` files or private keys |

## Development

After cloning, turn on the secret-scanning commit hook once:

```bash
git config core.hooksPath .githooks
```

From then on, `git commit` is refused if a staged file contains a Gemini/Google API key, a long `GEMINI_API_KEY=` value, a private key, a GitHub token, or is a secret file such as `.env`. It prints only `file:line`, never the secret itself.

## Documentation

- [docs/design.md](docs/design.md): full design (PEAS: performance, environment, actuators, sensors, agent loop, safety policy).
- [docs/limitations.md](docs/limitations.md): known gaps in the MVP and ideas for future work.
- [CHANGELOG.md](CHANGELOG.md): changes per version.

## License

MIT, see [LICENSE](LICENSE).
