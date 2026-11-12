# Changelog

All notable changes to this project are listed here.
Format: [Keep a Changelog](https://keepachangelog.com), versions: [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- `os-buddy disk [PATH]`: disk monitoring report with usage bars, alert levels
  (exit code 4 warning, 5 critical) and the biggest items in a folder. Needs no API key.
- `lib/viz.sh`: drawing kit for terminal reports (titles, bars, badges, boxed tables).
- `lib/render.sh`: chat answers are shown as clean terminal text (headings, bullets,
  boxed tables, no Markdown symbols or emoji). Piped output stays plain Markdown.

### Changed
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
