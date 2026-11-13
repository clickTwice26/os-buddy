# Changelog

All notable changes to this project are listed here.
Format: [Keep a Changelog](https://keepachangelog.com), versions: [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- `os-buddy disk [PATH]`: disk monitoring report with usage bars, alert levels
  (exit code 4 warning, 5 critical) and the biggest items in a folder. Needs no API key.
- `os-buddy health`: uptime, CPU usage, load, memory, swap and the fullest disk with bars
  and one verdict (exit code 4 warning, 5 critical). Works on Linux (/proc) and macOS
  (sysctl, vm_stat); macOS parsing is tested with sample output.
- `os-buddy proc`: process summary and top 10 by CPU and memory; `proc find WORD`;
  `proc kill PID [--force]` asks first and never stops PID 1 or os-buddy itself.
- `os-buddy backup`: `create` (tar.gz + SHA-256, keeps the newest N), `list`, `verify`
  (exit code 5 for a damaged backup), `restore` (only into a new or empty folder, never
  from a damaged backup), `schedule`/`unschedule` with cron.
- `--yes` and `--dry-run` work for every admin command; changes show the exact command first.
- `lib/viz.sh`: drawing kit for terminal reports (titles, bars, badges, boxed tables).
- `lib/render.sh`: chat answers are shown as clean terminal text (headings, bullets,
  boxed tables, no Markdown symbols or emoji). Piped output stays plain Markdown.

### Changed
- Fewer approval prompts: read-only commands no longer ask, including `2>/dev/null`,
  `2>&1`, `&&`, `||`, `;` chains of read-only parts, `|` inside quotes, and more read-only
  programs (lsblk, lscpu, free, ss, ip, systemctl status, journalctl, smartctl -H, ...).
- Smarter prompt: `[y]es [n]o [a]lways (this program, this chat) [?] why`, with the
  model's reason. "Always" is never offered for sudo, rm, kill and similar.
- Several actions in one model reply are listed together: all, none, or one by one.
- Tool calls are shown as one short dim line each, instead of the full command.
- System prompt asks for terminal-friendly answers: no intro line, tables for numbers, no emoji.

## [0.1.0] - 2026-11-12

### Added
- First minimal working version (MVP).
- Chat mode and one-shot mode (`os-buddy "goal"`).
- Agent loop with Gemini function calling: run_command, read_file, write_file, edit_file, ask_user.
- Safety policy: allow read-only commands, ask for changes, always block dangerous patterns.
- API retries with backoff, step limit, stuck detection, output cap, history trimming.
- API key kept out of `ps` output and out of commands the agent runs.
- Offline test suite with a fake Gemini API (`make test`).
