# os-buddy sequence diagrams

These diagrams show **who talks to whom, and in what order**, from the moment the user types `os-buddy` until the program exits.
They match the code in `bin/os-buddy` and `lib/*.sh`.

Related docs: [flowchart.md](flowchart.md) (decisions and branches), [use-case-diagram.md](use-case-diagram.md) (who can do what), [design.md](design.md) (PEAS design).

| # | Diagram | Covers |
|---|---|---|
| 1 | [Startup and mode selection](#1-startup-and-mode-selection) | `main()` in `bin/os-buddy` |
| 2 | [One goal, end to end](#2-one-goal-end-to-end-the-agent-loop) | `agent_run_goal` in `lib/agent.sh` |
| 3 | [Calling Gemini with retries](#3-calling-gemini-with-retries) | `gemini_call` in `lib/gemini.sh` |
| 4 | [Running one tool call](#4-running-one-tool-call-with-the-safety-policy) | `tools_dispatch`, `tools_approve`, `policy_check_command` |
| 5 | [Asking one approval for several actions](#5-grouped-approval-two-or-more-actions-in-one-reply) | `agent_group_approval` |
| 6 | [Chat mode](#6-chat-mode) | `chat_loop` |
| 7 | [Admin reports (disk, health)](#7-admin-reports-no-api-key-no-gemini) | `lib/admin*.sh`, `lib/viz.sh` |

Participants used below:

| Name in diagram | File | Role |
|---|---|---|
| Entry | `bin/os-buddy` | Checks the system, loads libraries, picks a mode |
| Config | `lib/config.sh` | Reads the config file, environment and flags |
| Agent | `lib/agent.sh` | The loop: ask the model, run tools, repeat |
| Gemini lib | `lib/gemini.sh` | Builds the request and calls the REST API |
| Tools | `lib/tools.sh` | The actions the model may take |
| Policy | `lib/policy.sh` | Classifies an action as allow, ask or block |
| UI | `lib/ui.sh` | Messages and prompts for the human (all on stderr) |
| Render | `lib/render.sh` | Turns the model's Markdown into terminal text |

---

## 1. Startup and mode selection

What happens before any AI call. Admin commands leave early because they need no API key.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Entry as bin/os-buddy
    participant Admin as admin.sh
    participant Config as config.sh
    participant Agent as agent.sh
    participant UI as ui.sh

    User->>Entry: os-buddy [flags] [goal]
    Entry->>Entry: load libs (ui, config, policy, gemini, tools, agent, viz, render, admin)
    Entry->>Entry: check_bash (4.4 or newer) and check_os (Linux, macOS, BSD)

    alt first word is an admin command (disk, health)
        Entry->>Admin: admin_run args
        Admin-->>User: report on stdout (see diagram 7)
        Admin-->>Entry: status 0, 4, 5, 1 or 2
        Entry-->>User: exit with that status
    else agent mode
        Entry->>Entry: check_deps (curl and jq)
        Entry->>Config: config_load
        Note over Config: priority: defaults, config file, environment, flags<br/>the file is parsed, never sourced
        Config-->>Entry: model, max steps, API key, API base
        Entry->>Config: config_parse_args
        Note over Config: -y, -v, -m, -n, -h and --version are handled<br/>other words are joined into the goal
        Config-->>Entry: OSBUDDY_GOAL (may be empty)

        opt GEMINI_API_KEY is empty
            Entry->>UI: ui_error "GEMINI_API_KEY is not set"
            Entry-->>User: exit 1
        end

        Entry->>Agent: agent_init
        Note over Agent: temp folder, history.json = [ ]<br/>system prompt + facts about this machine<br/>traps: delete temp on EXIT, Ctrl-C = exit 130

        alt a goal was given on the command line
            Entry->>Agent: agent_run_goal goal
            Note over Agent: loop in diagram 2
            Agent-->>Entry: 0 done, 1 error, 3 step limit
            Entry-->>User: exit with that code
        else no goal, and stdin and stderr are a terminal
            Entry->>Entry: chat_loop
            Note over Entry: see diagram 6
        else no goal and no terminal
            Entry->>UI: ui_error "no goal given and no terminal for chat"
            Entry-->>User: exit 2
        end
    end
```

---

## 2. One goal, end to end (the agent loop)

The heart of os-buddy. Each pass of the loop is one **step**. The loop stops when Gemini answers without asking for a tool, when an error happens, or after `OSBUDDY_MAX_STEPS` (default 30).

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Agent as agent.sh
    participant GLib as gemini.sh
    participant API as Gemini API (Google)
    participant Tools as tools.sh
    participant UI as ui.sh
    participant Render as render.sh

    User->>Agent: goal text
    Agent->>Agent: agent_add_user_text (append to history.json)

    loop step 1 to OSBUDDY_MAX_STEPS
        Agent->>Agent: agent_trim (history over 300 KB, old results become "[trimmed]")
        Agent->>GLib: gemini_build_request (history, system.txt, tools.json)
        GLib->>API: POST generateContent (see diagram 3)
        API-->>GLib: JSON reply
        GLib-->>Agent: response.json

        alt reply has no content (blocked or failed)
            Agent->>UI: ui_error "Gemini returned no answer (reason)"
            Agent-->>User: return 1
        end

        Agent->>Agent: push the model reply to history exactly as received
        Note over Agent: Gemini 3 needs its thoughtSignature fields<br/>sent back unchanged, so the reply is never rebuilt

        alt no functionCall parts (the model is finished)
            Agent->>Render: render_answer (Markdown text)
            Render-->>User: answer on stdout
            opt finishReason is MAX_TOKENS
                Agent->>UI: ui_warn "the answer was cut off"
            end
            Agent-->>User: return 0
        else one or more functionCall parts
            Agent->>Agent: agent_group_approval (diagram 5)
            loop each tool call, in order
                Agent->>Tools: tools_dispatch name and args
                Note over Tools: run_command, read_file, write_file, edit_file or ask_user<br/>policy and approval checks happen here (diagram 4)
                Tools-->>Agent: result.json (output or error)
                Agent->>Agent: stuck check (same call 3 times in a row adds a note)
                Agent->>Agent: wrap as functionResponse part
            end
            Agent->>Agent: push one user turn with all results
        end
    end

    Agent->>UI: ui_warn "step limit reached"
    Agent-->>User: return 3
```

---

## 3. Calling Gemini with retries

`gemini_call` keeps the API key out of `ps` output by sending it on `curl`'s stdin. It retries rate limits, server errors and network errors with exponential backoff.

```mermaid
sequenceDiagram
    autonumber
    participant Agent as agent.sh
    participant GLib as gemini.sh
    participant UI as ui.sh
    participant Curl as curl
    participant API as Gemini API

    Agent->>GLib: gemini_call request.json response.json
    Note over GLib: URL = API_BASE/models/MODEL:generateContent<br/>attempt = 1, delay = 2 s

    loop until success or out of attempts
        GLib->>Curl: header with the key on stdin (--config -), body from request.json
        Curl->>API: POST (max 300 s)
        API-->>Curl: HTTP status and JSON body
        Curl-->>GLib: status code, body saved to response.json

        alt status 200
            GLib-->>Agent: return 0
        else 429, 5xx or 000 (network error), attempts left
            GLib->>UI: ui_warn "Gemini API returned CODE, retrying in Ns"
            GLib->>GLib: sleep delay, delay x 2, attempt + 1
        else any other status, or last attempt used (4 attempts in total)
            GLib->>UI: ui_error "Gemini API error (HTTP CODE): message"
            GLib-->>Agent: return 1
        end
    end
```

---

## 4. Running one tool call with the safety policy

Every tool call goes through the policy first. The model cannot skip this step, and a **block** decision cannot be overridden, not even with `--yes`.

This diagram uses `run_command`. `read_file` is checked the same way (only private paths ask). `write_file` and `edit_file` always ask.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Agent as agent.sh
    participant Tools as tools.sh
    participant Policy as policy.sh
    participant UI as ui.sh
    participant Shell as bash -c (child process)

    Agent->>Tools: tools_dispatch run_command args.json
    Tools->>Tools: read command and timeout (default 120 s)
    Tools->>Policy: policy_check_command cmd
    Note over Policy: 1 block patterns (rm -rf /, mkfs, dd of=/dev/, fork bomb)<br/>2 sensitive paths (.ssh, .env, keys) ask<br/>3 redirects, $( ), backticks, newlines, & ask<br/>4 every piped part must start with a read-only program
    Policy-->>Tools: allow, ask or block

    alt block
        Tools->>UI: ui_error "BLOCKED by policy"
        Tools-->>Agent: error "blocked by safety policy, do not try to work around it"
    else ask
        Tools->>Tools: tools_approve
        alt "always allow" was chosen earlier for this program
            Tools->>UI: ui_step auto
        else a grouped answer exists (all or none)
            Note over Tools: all = go, none = denied
        else --yes flag is set
            Tools->>UI: ui_info "auto-approved (--yes)"
        else ask the human
            Tools->>UI: ui_approve (action, reason, risk)
            UI->>User: approval needed, y / n / a
            User-->>UI: answer (Enter alone means no)
            UI-->>Tools: 0 yes, 1 no, 3 always
        end
        opt answer was no (or no human is present)
            Tools-->>Agent: error "denied by the user"
        end
    else allow
        Note over Tools: runs without asking
    end

    opt allowed or approved
        Tools->>UI: ui_step run "command"
        Tools->>Shell: env -u GEMINI_API_KEY bash -c cmd (stdin from /dev/null)
        Note over Tools,Shell: a background watcher kills the command after the timeout
        Shell-->>Tools: stdout, stderr, exit code
        Tools->>Tools: cut each output to about 16 KB (head + marker + tail)
        Tools-->>Agent: result.json (exit_code, timed_out, stdout, stderr)
    end
```

---

## 5. Grouped approval (two or more actions in one reply)

When Gemini asks for several risky actions at once, os-buddy shows them together and asks **one** question instead of many. Blocked actions are not part of the question and stay blocked.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Agent as agent.sh
    participant Tools as tools.sh
    participant UI as ui.sh

    Agent->>Agent: n = number of functionCall parts in the reply
    alt n below 2, or --yes, or no human present
        Note over Agent: skip grouping (each call is handled on its own)
    else n is 2 or more
        loop each call
            Agent->>Tools: tools_needs_approval name and args
            Tools-->>Agent: "label, reason, risk" or nothing
        end
        alt fewer than 2 calls need approval
            Note over Agent: skip grouping
        else 2 or more need approval
            Agent->>UI: ui_approve_batch (list of actions)
            UI->>User: N actions need approval: y all, n none, o one by one
            User-->>UI: answer
            UI-->>Agent: 0 all, 1 none, 2 one by one
            Note over Agent: TOOLS_BATCH = all, none or empty<br/>it is cleared after this reply
        end
    end
```

---

## 6. Chat mode

Started when no goal is given and a human is at the terminal. The history is kept between turns, so the model remembers earlier goals until `/reset`.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Entry as bin/os-buddy (chat_loop)
    participant Agent as agent.sh
    participant UI as ui.sh

    Entry->>UI: ui_info "os-buddy 0.1.0 chat. /help, /exit"

    loop until /exit or Ctrl-D
        Entry->>User: prompt "you> " (arrow keys and line editing work)
        User-->>Entry: a line of text

        alt empty line
            Note over Entry: ignored
        else /exit or Ctrl-D
            Entry-->>User: leave the loop (exit 0)
        else /reset
            Entry->>Agent: agent_reset (history = [ ])
            Entry->>UI: ui_success "history cleared"
        else /help
            Entry->>UI: ui_info "/reset clears memory, /exit quits"
        else anything else is a goal
            Entry->>Agent: agent_run_goal line
            Note over Agent: loop in diagram 2<br/>an error is shown and the chat continues
            Agent-->>User: answer
        end
    end

    Note over Entry,Agent: on exit the EXIT trap deletes the temp folder
```

---

## 7. Admin reports (no API key, no Gemini)

`os-buddy disk [PATH]` and `os-buddy health` run fixed, read-only checks. The dispatcher finds a command by the function name `admin_cmd_<word>`, so a new command needs no change in the entry script.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Entry as bin/os-buddy
    participant Admin as admin.sh
    participant Report as admin_disk.sh / admin_health.sh
    participant OS as Operating system
    participant Viz as viz.sh

    User->>Entry: os-buddy disk /var  (or: os-buddy health)
    Entry->>Admin: admin_is_command "disk"
    Admin-->>Entry: true (function admin_cmd_disk exists)
    Entry->>Admin: admin_run disk /var
    Admin->>Report: admin_cmd_disk /var

    alt --help
        Report-->>User: usage text, status 0
    else unknown option or PATH is not a folder
        Report-->>User: error message, status 2 or 1
    else normal run
        Report->>OS: df -P -k (disk) or /proc files, sysctl, vm_stat (health)
        OS-->>Report: raw numbers
        Report->>Report: pick real disks, parse text into numbers (Linux and macOS differ)
        Report->>Viz: viz_title, viz_section, viz_table, viz_bar, viz_badge
        Viz-->>User: coloured report on stdout (plain text when not a terminal)
        opt disk was given a PATH
            Report->>OS: du -sk of each item in PATH
            OS-->>Report: sizes
            Report->>Viz: table of the 10 biggest items
            Viz-->>User: table
        end
        Report->>Report: compare each percent to WARN (70) and CRIT (90)
        Report->>Viz: Alerts or Verdict section
        Viz-->>User: ok, warn or crit badges
    end

    Report-->>Entry: 0 all fine, 4 warning, 5 critical
    Entry-->>User: exit with that status
```
