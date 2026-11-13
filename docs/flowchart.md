# os-buddy flow charts

These flow charts show **every decision and branch** in os-buddy, from start to end.
They match the code in `bin/os-buddy` and `lib/*.sh`.

Related docs: [sequence-diagram.md](sequence-diagram.md) (who talks to whom), [use-case-diagram.md](use-case-diagram.md) (who can do what), [design.md](design.md) (PEAS design).

| # | Chart | Code |
|---|---|---|
| 1 | [The whole program, start to end](#1-the-whole-program-start-to-end) | `bin/os-buddy`, `lib/agent.sh` |
| 2 | [How a command is classified](#2-how-a-command-is-classified-allow-ask-or-block) | `policy_check_command` |
| 3 | [How an action gets approved](#3-how-an-action-gets-approved) | `tools_approve` |
| 4 | [What each tool does](#4-what-each-tool-does) | `lib/tools.sh` |
| 5 | [Gemini call with retries](#5-gemini-call-with-retries) | `gemini_call` |
| 6 | [Admin reports](#6-admin-reports-disk-and-health) | `lib/admin*.sh` |
| 7 | [Where settings come from](#7-where-settings-come-from) | `lib/config.sh` |

---

## 1. The whole program, start to end

Read it top to bottom. The three blocks are: **startup**, **the agent loop**, and **exit**.

```mermaid
flowchart TD
    Start(["User runs os-buddy"]) --> Bash{"Bash 4.4 or newer?"}
    Bash -->|no| E1["error: Bash 4.4 or newer is required"]
    Bash -->|yes| OS{"Linux, macOS or BSD?"}
    OS -->|no| E2["error: unsupported OS"]
    OS -->|yes| IsAdmin{"first word is an<br/>admin command?<br/>(disk, health)"}

    IsAdmin -->|yes| Admin["Run the admin report<br/>(chart 6, no API key needed)"]
    Admin --> ExitAdmin(["exit 0, 4, 5, 1 or 2"])

    IsAdmin -->|no| Deps{"curl and jq installed?"}
    Deps -->|no| E3["error: missing required tools"]
    Deps -->|yes| Cfg["Load settings<br/>defaults, config file, environment, flags<br/>(chart 7)"]
    Cfg --> Flags{"--help or --version?"}
    Flags -->|yes| ExitHelp(["print text, exit 0"])
    Flags -->|bad flag| ExitUsage(["usage error, exit 2"])
    Flags -->|no| Key{"GEMINI_API_KEY set?"}
    Key -->|no| E4["error: GEMINI_API_KEY is not set"]
    Key -->|yes| Init["agent_init<br/>make temp folder, empty history<br/>build system prompt with machine facts<br/>set traps: clean up on exit, Ctrl-C = 130"]
    Init --> HasGoal{"goal given on the<br/>command line?"}

    HasGoal -->|yes| RunGoal["agent_run_goal"]
    HasGoal -->|no| Tty{"human at a terminal?"}
    Tty -->|no| ExitNoTty(["error: no goal and no terminal, exit 2"])
    Tty -->|yes| Chat["chat_loop"]

    Chat --> Prompt["show prompt: you>"]
    Prompt --> Line{"what was typed?"}
    Line -->|"empty line"| Prompt
    Line -->|"/help"| Help["show help"] --> Prompt
    Line -->|"/reset"| Reset["clear history"] --> Prompt
    Line -->|"/exit or Ctrl-D"| ExitChat(["exit 0, temp folder deleted"])
    Line -->|"any other text"| RunGoal
    RunGoal -. "after the goal ends,<br/>chat mode only" .-> Prompt

    subgraph LOOP["The agent loop (one pass = one step)"]
        direction TB
        AddGoal["add the goal to history"] --> StepCheck{"step number<br/>above the limit?<br/>(default 30)"}
        StepCheck -->|yes| LimitWarn["warning: step limit reached"]
        StepCheck -->|no| Trim["trim history if above 300 KB<br/>(old tool results become trimmed)"]
        Trim --> Ask["Ask Gemini<br/>send history, system prompt, tool list<br/>(chart 5)"]
        Ask --> ApiOk{"API call ok?"}
        ApiOk -->|no| LoopErr["error already printed"]
        ApiOk -->|yes| HasContent{"reply has content?"}
        HasContent -->|"no (blocked or empty)"| EmptyErr["error: Gemini returned no answer"]
        HasContent -->|yes| Save["save the reply in history, exactly as received"]
        Save --> HasCalls{"reply has tool calls?"}

        HasCalls -->|no| Answer["print the answer on stdout<br/>(Markdown turned into terminal text)"]
        Answer --> Cut{"cut off by MAX_TOKENS?"}
        Cut -->|yes| CutWarn["warning: the answer was cut off"]
        Cut -->|no| Done["goal done"]
        CutWarn --> Done

        HasCalls -->|yes| Group["Several risky calls?<br/>ask once: all, none or one by one"]
        Group --> EachCall["take the next tool call"]
        EachCall --> Dispatch["Run the tool<br/>(charts 2, 3 and 4)"]
        Dispatch --> Same{"same call 3 times<br/>in a row?"}
        Same -->|yes| Nudge["add a note: try a different approach"]
        Same -->|no| Wrap["wrap result as functionResponse"]
        Nudge --> Wrap
        Wrap --> More{"more calls in<br/>this reply?"}
        More -->|yes| EachCall
        More -->|no| PushRes["add all results to history as one user turn"]
        PushRes --> StepCheck
    end

    RunGoal --> AddGoal
    Done --> CodeOk(["return 0"])
    LoopErr --> CodeErr(["return 1"])
    EmptyErr --> CodeErr
    LimitWarn --> CodeLimit(["return 3"])

    CodeOk --> HowEnd{"one-shot or chat?"}
    CodeErr --> HowEnd
    CodeLimit --> HowEnd
    HowEnd -->|"one-shot"| ExitCode(["exit with that code<br/>0 done, 1 error, 3 step limit"])
    HowEnd -->|"chat"| Prompt
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Done (also `--help`, `--version`, `/exit`) |
| 1 | Error (missing tool, no API key, API failure, empty reply) |
| 2 | Usage error (bad flag, or no goal and no terminal) |
| 3 | Step limit reached before the goal was finished |
| 4 | Admin report: warning level |
| 5 | Admin report: critical level |
| 130 | Interrupted with Ctrl-C |

---

## 2. How a command is classified (allow, ask or block)

`policy_check_command` fails closed: anything not clearly safe becomes **ask**. The model can never change this result.

```mermaid
flowchart TD
    In(["command text from the model"]) --> B{"matches a block pattern?<br/>rm -rf on / ~ or system folders<br/>mkfs, dd of=/dev/, redirect onto a disk<br/>fork bomb, recursive chmod or chown on /"}
    B -->|yes| Block(["BLOCK<br/>never runs, even with --yes"])
    B -->|no| S{"mentions a private path?<br/>.ssh .aws .gnupg .env .pem .key<br/>id_rsa, /etc/shadow, os-buddy config"}
    S -->|yes| Ask1(["ASK<br/>content would be sent to Google"])
    S -->|no| Mask["replace quoted text with Q<br/>so a | or ; inside quotes is not a real one"]
    Mask --> Strip["remove harmless redirects<br/>2>/dev/null, >/dev/null, 2>&1"]
    Strip --> Danger{"still has > or < or backtick<br/>or $( or a newline?"}
    Danger -->|yes| Ask2(["ASK<br/>may write a file or hide a command"])
    Danger -->|no| Split["split into simple commands<br/>at |  ||  &&  and ;"]
    Split --> Bg{"contains a single &<br/>(background job)?"}
    Bg -->|yes| Ask3(["ASK"])
    Bg -->|no| Next["take the next simple command"]
    Next --> Listed{"first word on the<br/>read-only list?<br/>ls cat grep df ps find git ..."}
    Listed -->|no| Ask4(["ASK<br/>not known to be safe"])
    Listed -->|yes| Flags{"has a flag that writes or acts?<br/>find -exec -delete, sort -o,<br/>git other than status log diff show,<br/>sysctl -w, ip add, systemctl start ..."}
    Flags -->|yes| Ask5(["ASK"])
    Flags -->|no| Last{"more simple<br/>commands left?"}
    Last -->|yes| Next
    Last -->|no| Allow(["ALLOW<br/>runs without asking"])
```

Reading a file (`read_file`) is simpler: a private path gives **ask**, everything else **allow**.
Writing (`write_file`) and editing (`edit_file`) always give **ask**.

---

## 3. How an action gets approved

`tools_approve` turns the policy answer into go or no-go. The checks run in this order.

```mermaid
flowchart TD
    In(["policy answer for one action"]) --> D{"allow, ask or block?"}
    D -->|allow| Go(["GO: run it"])
    D -->|block| Blocked["show: BLOCKED by policy"]
    Blocked --> BlockRes(["result to the model:<br/>blocked by safety policy,<br/>do not try to work around it"])

    D -->|ask| Always{"user already chose<br/>always allow for this<br/>program in this chat?"}
    Always -->|yes| Go
    Always -->|no| Batch{"user already answered<br/>for a group of calls?"}
    Batch -->|"all"| Go
    Batch -->|"none"| Deny
    Batch -->|"no group answer"| Yes{"--yes flag set?"}
    Yes -->|yes| Go
    Yes -->|no| Human{"human at a terminal?"}
    Human -->|no| Deny
    Human -->|yes| Prompt["show: approval needed<br/>action, reason, risk"]
    Prompt --> Ans{"answer?"}
    Ans -->|"y"| Go
    Ans -->|"a (only if offered)"| Remember["remember this program<br/>for the rest of the chat"] --> Go
    Ans -->|"n, Enter or Ctrl-D"| Deny
    Ans -->|"anything else"| Prompt

    Deny(["DENIED"]) --> DenyRes(["result to the model:<br/>denied by the user"])
```

"Always allow" is never offered for `sudo`, `su`, `rm`, `dd`, `mkfs`, `chmod`, `chown`, `kill` and its relatives, `shutdown`, `reboot`, `mv`, `cp`, shells, `eval` and `exec`, nor for chained or redirected commands.

---

## 4. What each tool does

The model can only act through these five tools (`share/tools.json`).

```mermaid
flowchart TD
    Call(["tool call from the model"]) --> Which{"which tool?"}

    Which -->|run_command| RC1{"command empty?"}
    RC1 -->|yes| Err(["result: error"])
    RC1 -->|no| RC2["policy check and approval<br/>(charts 2 and 3)"]
    RC2 --> RC3{"allowed?"}
    RC3 -->|no| Err
    RC3 -->|yes| RC4["run: env -u GEMINI_API_KEY bash -c command<br/>stdin from /dev/null<br/>background watcher kills it after timeout (default 120 s)"]
    RC4 --> RC5["cut stdout and stderr to about 16 KB each<br/>(first half, marker, last half)"]
    RC5 --> RCOut(["result: exit_code, timed_out, stdout, stderr"])

    Which -->|read_file| RF1{"is it a readable file?"}
    RF1 -->|no| Err
    RF1 -->|yes| RF2["policy check: private path asks"]
    RF2 --> RF3{"allowed?"}
    RF3 -->|no| Err
    RF3 -->|yes| RF4["number each line, take offset and limit<br/>(default from line 1, 400 lines), cap at 16 KB"]
    RF4 --> RFOut(["result: content, total_lines"])

    Which -->|write_file| WF1{"path empty?"}
    WF1 -->|yes| Err
    WF1 -->|no| WF2["show a preview of the first 20 lines"]
    WF2 --> WF3["always ask"]
    WF3 --> WF4{"approved?"}
    WF4 -->|no| Err
    WF4 -->|yes| WF5{"write succeeded?"}
    WF5 -->|no| Err
    WF5 -->|yes| OkOut(["result: ok, path"])

    Which -->|edit_file| EF1{"is it a file?"}
    EF1 -->|no| Err
    EF1 -->|yes| EF2{"old_text found<br/>exactly once?"}
    EF2 -->|"zero times"| Err
    EF2 -->|"two or more times"| Err
    EF2 -->|"once"| EF3["show a diff, then always ask"]
    EF3 --> EF4{"approved and written?"}
    EF4 -->|no| Err
    EF4 -->|yes| OkOut

    Which -->|ask_user| AU1{"human at a terminal?"}
    AU1 -->|no| Err
    AU1 -->|yes| AU2["show the question, read one line"]
    AU2 --> AUOut(["result: answer"])

    Which -->|"unknown name"| Err
```

Every result, success or error, goes back to the model as a `functionResponse`. Errors are information the model uses to change its approach.

---

## 5. Gemini call with retries

```mermaid
flowchart TD
    Start(["gemini_call"]) --> Init["attempt = 1, delay = 2 s"]
    Init --> Send["send POST generateContent<br/>API key on curl stdin, max 300 s"]
    Send --> Code{"HTTP status?"}
    Code -->|200| Ok(["success: response saved"])
    Code -->|"429, 5xx or 000 (network)"| Left{"attempt below 4?"}
    Left -->|yes| Wait["warning: retrying in N s<br/>sleep, delay x 2, attempt + 1"] --> Send
    Left -->|no| Fail
    Code -->|"any other status"| Fail["error: Gemini API error (HTTP code)<br/>with the server's message if there is one"]
    Fail --> Bad(["failure: the goal ends with exit 1"])
```

Waits are 2 s, 4 s and 8 s, so a failing call is tried 4 times in all.

---

## 6. Admin reports (disk and health)

No API key, no network, no Gemini. Fixed checks only.

```mermaid
flowchart TD
    Start(["os-buddy disk [PATH]<br/>or os-buddy health"]) --> Arg{"argument?"}
    Arg -->|"--help"| Usage(["print usage, exit 0"])
    Arg -->|"unknown option"| Bad(["error and usage, exit 2"])
    Arg -->|"disk: PATH is not a folder"| Bad1(["error, exit 1"])
    Arg -->|ok| Which{"which report?"}

    Which -->|disk| D1["df -P -k<br/>keep only /dev/ disks, skip loop and fake ones"]
    D1 --> D2["table: mount, device, size, used, free, bar, status"]
    D2 --> Lvl

    Which -->|health| H1["collect numbers<br/>Linux: /proc files<br/>macOS: sysctl, vm_stat, ps"]
    H1 --> H2["System section: host, OS, kernel, uptime, cores"]
    H2 --> H3["Resources table: CPU, load, memory, swap, fullest disk"]
    H3 --> Lvl

    Lvl{"each percent against<br/>WARN (default 70) and CRIT (default 90)"}
    Lvl -->|"below WARN"| Ok["green: ok"]
    Lvl -->|"WARN or more"| Warn["yellow: warn<br/>worst status = 4"]
    Lvl -->|"CRIT or more"| Crit["red: crit<br/>worst status = 5"]

    Ok --> Sum
    Warn --> Sum
    Crit --> Sum
    Sum["Alerts (disk) or Verdict (health) section<br/>one badge per problem, or all fine"]
    Sum --> P{"disk with a PATH?"}
    P -->|yes| Top["table of the 10 biggest items in PATH<br/>(du -sk, sorted, with a share bar)"] --> Fin
    P -->|no| Fin
    Fin(["exit with the worst status<br/>0 fine, 4 warning, 5 critical"])
```

---

## 7. Where settings come from

Later steps win over earlier ones.

```mermaid
flowchart LR
    A["1 Defaults<br/>model gemini-3.6-flash<br/>max steps 30<br/>yes off, verbose off"] --> B
    B["2 Config file<br/>only fills values still empty"] --> C
    C["3 Environment variables<br/>GEMINI_API_KEY, OSBUDDY_MODEL ..."] --> D
    D["4 Command-line flags<br/>-m, -n, -y, -v"] --> Final(["final settings"])

    F1{"which config file?"}
    F1 -->|"OSBUDDY_CONFIG_FILE is set"| FA["use that file"]
    F1 -->|"else .env exists next to bin/ and lib/"| FB["use the project .env"]
    F1 -->|"else"| FC["use ~/.config/os-buddy/config"]
    FA --> B
    FB --> B
    FC --> B
```

The config file is read line by line and **never executed**. Only `GEMINI_API_KEY`, `OSBUDDY_MODEL` and `OSBUDDY_MAX_STEPS` are accepted. If the file is not mode 600, a warning asks you to run `chmod 600`.
