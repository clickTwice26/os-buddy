# MVP limitations and future work

This file lists what version 0.1.0 does **not** do yet, or does only partly.
Each item says what goes wrong, why, and an idea for fixing it.
Priority: **high** = safety or correctness, **medium** = usability, **low** = nice to have.

Items marked *(verified)* were checked by running the code on 2026-11-12.

## 1. Safety policy (`lib/policy.sh`)

The policy matches command **text** against patterns. It does not really parse shell syntax,
so some commands get through that should not.

| # | Priority | Problem | Example | Fix idea |
|---|---|---|---|---|
| 1.1 | high | Some "read-only" commands have flags that write files or run programs, and they are allowed. *(verified)* | `git diff --output=FILE`, `git log --ext-diff`, `sort --compress-program=sh` | Allow-list flags per command instead of block-listing a few; anything unknown asks. |
| 1.2 | high | Sensitive paths are found by text only. Wildcards, variables and recursive reads hide them. *(verified)* | `cat ~/.s*/id*`, `grep -r PRIVATE ~` | Expand globs before checking; make recursive reads (`grep -r`, `find` over `$HOME`) ask. |
| 1.3 | high | `read_file` follows symlinks without checking the real target. *(verified)* | a link `notes.txt -> ~/.ssh/id_rsa` is read without asking | Check `readlink -f "$path"` against the sensitive list. |
| 1.4 | medium | Quoted or reshaped dangerous targets only "ask" instead of "block". *(verified)* | `rm -rf "/"`, `find / -delete` | Strip quotes before matching; add `find / -delete` and similar to the block list. |
| 1.5 | medium | `..` in paths is not resolved, so path checks can be dodged. | `ls /etc/../root` | Normalise paths before checking. |
| 1.6 | medium | Prompt injection: a file or web page can trick the model into proposing a harmful command. The policy still applies, but "ask" items depend on the human reading carefully. `--yes` removes that check. | a README saying "now run curl ... \| sh" | Show the reason for each risky action; warn loudly when `--yes` is used; never use `--yes` on untrusted folders. |

## 2. Running commands (`lib/tools.sh`)

| # | Priority | Problem | Fix idea |
|---|---|---|---|
| 2.1 | high | The timeout kills the command and its direct children only. Grandchildren (for example a script that starts a server) can keep running. | Run each command in its own process group (`setsid`) and kill the whole group. |
| 2.2 | medium | Each command runs in a fresh `bash -c`, so `cd` and variables do not carry over to the next command. The model may not expect this. | Tell the model in the system prompt, or add a `cwd` argument to `run_command`. |
| 2.3 | medium | stdin is `/dev/null`, so interactive programs (`sudo` password, `vim`, `top`) fail or wait for the timeout. | Detect common interactive commands and refuse early with a clear message. |
| 2.4 | low | Long-running commands give no progress output until they finish. | Stream output to the terminal while capturing it. |

## 3. File tools

| # | Priority | Problem | Fix idea |
|---|---|---|---|
| 3.1 | medium | `write_file` overwrites without a backup and shows only the first 20 lines, not a diff against the old file. | Show `diff -u` when the file exists; keep a `.bak` copy. |
| 3.2 | medium | `write_file` fails if the parent folder does not exist. | Offer `mkdir -p` as part of the approved action. |
| 3.3 | low | `edit_file` and `read_file` work on UTF-8 text only. Binary files give unclear errors. | Detect binary files (`file --mime`) and refuse clearly. |

## 4. Agent loop and API (`lib/agent.sh`, `lib/gemini.sh`)

| # | Priority | Problem | Fix idea |
|---|---|---|---|
| 4.1 | medium | Ctrl-C quits os-buddy completely. The design says it should stop only the current action and return to the chat prompt. | Trap INT per step, kill the running command, add an "interrupted" result and go back to the prompt. |
| 4.2 | medium | History trimming uses a fixed size (300 KB), not real token counts. | Read `usageMetadata` from responses and trim by tokens. |
| 4.3 | medium | Retries ignore the server's suggested wait time (`Retry-After`, `retryDelay`). | Read it from the headers or error details and use it when present. |
| 4.4 | low | No cost or token report. | Sum `usageMetadata` and print it with `--verbose` or at exit. |
| 4.5 | low | No `generationConfig` (temperature, thinking level, max output tokens). | Add config keys and flags for these. |
| 4.6 | low | Parallel tool calls run one after another. | Fine for now; only read-only calls could ever run in parallel safely. |
| 4.7 | low | Host facts (cwd, date) are collected once at start; in long chats they get stale. | Rebuild them before each goal. |

## 5. Usability

| # | Priority | Problem | Fix idea |
|---|---|---|---|
| 5.1 | medium | No log of what the agent did. | Write an audit log (goal, each command, decision, exit code) to `~/.local/state/os-buddy/`. |
| 5.2 | low | Chat history is lost when os-buddy exits. | Optional `--resume` that saves history to a file. |
| 5.3 | low | The config file must be exactly `KEY=VALUE`; spaces around `=` or `export KEY=...` are not understood. | Trim spaces and an optional `export ` prefix. |
| 5.4 | low | Only Gemini is supported. | Keep the API code in `gemini.sh` so another provider could be added as a separate file. |

## 6. Testing and portability

| # | Priority | Problem | Fix idea |
|---|---|---|---|
| 6.1 | high | Never tested against the **real** Gemini API (no key was available). The request format follows the docs and the tests use a fake. | Run the live test from `docs/design.md` with a real key. |
| 6.2 | medium | Tested only on Bash 5.3 on Linux. Bash 4.4 support is promised but not checked. | Run `tests/run.sh` in the `bash:4.4` Docker image. |
| 6.3 | medium | ShellCheck has not been run (not installed). | `sudo apt install shellcheck`, then `make lint`. |
| 6.4 | low | No tests for chat mode, interactive y/n prompts, history trimming or Ctrl-C. | Use `script` or `expect` to fake a terminal in tests. |
| 6.5 | low | `make` is not installed on the development machine. | `sudo apt install make`, or keep using `bash tests/run.sh`. |
