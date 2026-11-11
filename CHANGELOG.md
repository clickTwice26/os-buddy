# Changelog

All notable changes to this project are listed here.
Format: [Keep a Changelog](https://keepachangelog.com), versions: [Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-11-12

### Added
- First minimal working version (MVP).
- Chat mode and one-shot mode (`os-buddy "goal"`).
- Agent loop with Gemini function calling: run_command, read_file, write_file, edit_file, ask_user.
- Safety policy: allow read-only commands, ask for changes, always block dangerous patterns.
- API retries with backoff, step limit, stuck detection, output cap, history trimming.
- API key kept out of `ps` output and out of commands the agent runs.
- Offline test suite with a fake Gemini API (`make test`).
