# os-buddy: an agentic OS operator in Bash, designed with PEAS

## Quick start

Needs Linux/Unix, Bash 4.4+, `curl` and `jq`, and a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).

Run it straight from the project folder:

```bash
echo 'GEMINI_API_KEY=your-key' > .env && chmod 600 .env   # .env is git-ignored
./bin/os-buddy "find the 3 largest files in this folder"
./bin/os-buddy                       # chat mode
bash tests/run.sh                    # offline tests (or: make test)
```

The key is read from the first of these that exists: the `GEMINI_API_KEY` environment variable, `.env` in the project folder, `~/.config/os-buddy/config`.

Optional: `./install.sh` links `os-buddy` into `~/.local/bin` so it runs from any folder.

Exit codes: 0 done, 1 error, 2 usage error, 3 step limit reached.

## What it does

You give os-buddy a goal in plain English. It plans, runs commands, reads and edits files, checks the results and keeps going until the goal is done. It uses Gemini's function calling to decide each step.

A fixed safety policy written in Bash sits between the model and your system, and the model cannot override it:

- **Read-only commands** (`ls`, `df`, `grep`, ...) run automatically.
- **Changes** (writing files, installing, deleting, ...) ask you `[y/N]` first.
- **Dangerous patterns** (`rm -rf /`, `mkfs`, fork bombs, ...) are always blocked, even with `--yes`.

## CLI

```
os-buddy                  # chat; /reset, /help, /exit
os-buddy "free up disk"   # one task, then exit
  --yes  --model M  --max-steps N  --verbose  --help
```

Default model is `gemini-3.6-flash`, the latest **stable** Flash model on Google's model list (checked 2026-11-12). `gemini-3.8-flash` also exists and is newer, but is marked "New" rather than "Stable". Override with `--model` or `OSBUDDY_MODEL`.

## Project structure

All files below exist as of version 0.1.0 (the MVP).

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
│   ├── design.md             # full PEAS design
│   └── limitations.md        # MVP gaps and future work
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
| `docs/design.md` | Documentation | Full PEAS design |
| `docs/limitations.md` | Documentation | Known MVP gaps and future work |
| `examples/config.example` | Environment | Sample config file |
| `install.sh` | Environment | Links `bin/os-buddy` into `~/.local/bin` |
| `Makefile` | Tooling | `make test`, `make lint`, `make install` |
| `.editorconfig`, `.shellcheckrc` | Tooling | Consistent formatting and ShellCheck settings |
| `.gitignore` | Tooling | Keeps secrets, editor folders and temp files out of git |
| `CHANGELOG.md`, `LICENSE` | Documentation | Version history and usage terms |
| `README.md` | Documentation | Install, configuration, usage, and the PEAS summary |
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
