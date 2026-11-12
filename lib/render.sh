# lib/render.sh: shows the model's Markdown answer nicely in a terminal.
# Loaded with "source" after viz.sh (it uses the viz_ colours and tables).
#
# Gemini answers in Markdown (# headings, **bold**, `code`, | tables |).
# A terminal shows those symbols as they are, so we turn them into
# colours, bullets and boxed tables. When stdout is not a terminal
# (a pipe or a file), the text is passed through unchanged for scripts.

# Patterns live in variables: Bash reads them more safely that way.
RENDER_BOLD_RE='^(.*)\*\*([^*]+)\*\*(.*)$'
RENDER_CODE_RE='^(.*)`([^`]+)`(.*)$'
RENDER_LINK_RE='^(.*)\[([^]]+)\]\(([^)]+)\)(.*)$'
RENDER_HEAD_RE='^(#{1,6})[[:space:]]+(.*)$'
RENDER_BULLET_RE='^([[:space:]]*)[-*+][[:space:]]+(.*)$'
RENDER_NUMBER_RE='^([[:space:]]*)([0-9]+)[.)][[:space:]]+(.*)$'
RENDER_SEP_RE='^[[:space:]|:-]+$'
RENDER_RULE_RE='^(-{3,}|[*]{3,}|_{3,})$'

# A bullet dot needs UTF-8, like the box lines in viz.sh.
if [[ "$VIZ_H" == "-" ]]; then RENDER_DOT="*"; else RENDER_DOT="•"; fi

# Emoji take two columns on screen but count as one character in Bash,
# so they break table borders. They also look noisy in a terminal.
# Remove the common emoji blocks, plus the invisible "joiner" characters.
render_strip_emoji() {
  local s="$1"
  # Without UTF-8, Bash sees bytes, not characters: leave the text alone.
  [[ "$VIZ_H" == "-" ]] && { printf '%s' "$s"; return 0; }
  s="${s//[$'\U1F300'-$'\U1FAFF']/}"     # pictures: 🖥 🧠 💾 📊 🕒
  s="${s//[$'\u2600'-$'\u27BF']/}"       # symbols: ⚡ ✅ ⚠ ❌
  s="${s//[$'\u2300'-$'\u23FF']/}"       # technical: ⏱ ⌛
  s="${s//[$'\uFE0F'$'\u200D']/}"        # emoji style + joiner marks
  printf '%s' "$s"
}

# Inline styles inside one line: **bold**, `code`, [text](link).
render_inline() {
  local s="$1"
  while [[ "$s" =~ $RENDER_CODE_RE ]]; do
    s="${BASH_REMATCH[1]}$VIZ_CYAN${BASH_REMATCH[2]}$VIZ_RESET${BASH_REMATCH[3]}"
  done
  while [[ "$s" =~ $RENDER_BOLD_RE ]]; do
    s="${BASH_REMATCH[1]}$VIZ_BOLD${BASH_REMATCH[2]}$VIZ_RESET${BASH_REMATCH[3]}"
  done
  while [[ "$s" =~ $RENDER_LINK_RE ]]; do
    s="${BASH_REMATCH[1]}${BASH_REMATCH[2]} $VIZ_DIM(${BASH_REMATCH[3]})$VIZ_RESET${BASH_REMATCH[4]}"
  done
  printf '%s' "$s"
}

# Print the table rows collected so far (Markdown "| a | b |" lines) as a box.
render_flush_table() {
  (( ${#RENDER_TABLE[@]} == 0 )) && return 0
  local row cell out
  local -a cells
  for row in "${RENDER_TABLE[@]}"; do
    row="${row#"${row%%[![:space:]]*}"}"     # trim spaces on the left
    row="${row#|}"                           # drop the outer pipes
    row="${row%|}"
    [[ "$row" =~ $RENDER_SEP_RE ]] && continue   # skip the |---|---| line
    IFS='|' read -r -a cells <<< "$row"
    out=""
    for cell in "${cells[@]}"; do
      cell="${cell#"${cell%%[![:space:]]*}"}"   # trim both sides
      cell="${cell%"${cell##*[![:space:]]}"}"
      [[ -z "$cell" ]] && cell="-"              # viz_table needs a value
      out+="$(render_inline "$cell")"$'\t'
    done
    printf '%s\n' "${out%$'\t'}"
  done | viz_table
  RENDER_TABLE=()
}

# Read Markdown on stdin, print terminal text on stdout.
render_answer() {
  # Not a terminal: keep the text exactly as it is.
  # OSBUDDY_RENDER=1 forces rendering (used by the tests).
  if [[ ! -t 1 && "${OSBUDDY_RENDER:-0}" != 1 ]]; then
    cat
    return 0
  fi

  local line in_code=false trimmed blank=false after_head=false
  RENDER_TABLE=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"

    # Code blocks between ``` lines: print as they are, dim and indented.
    if [[ "$trimmed" == '```'* ]]; then
      render_flush_table
      if $in_code; then
        in_code=false
      else
        in_code=true
        $blank && printf '\n'
        blank=false
      fi
      continue
    fi
    if $in_code; then
      printf '    %s%s%s\n' "$VIZ_DIM" "$line" "$VIZ_RESET"
      continue
    fi

    # Drop emoji. If the line did not start with spaces, do not let
    # a removed emoji leave some behind (indented lists keep theirs).
    if [[ "$line" == [[:space:]]* ]]; then
      line="$(render_strip_emoji "$line")"
    else
      line="$(render_strip_emoji "$line")"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    trimmed="${line#"${line%%[![:space:]]*}"}"

    # Table lines are collected first, because a box needs every row.
    if [[ "$trimmed" == '|'* ]]; then
      RENDER_TABLE+=("$line")
      continue
    fi
    render_flush_table

    # Blank lines: remember one, print it before the next text.
    # Headings add their own space, so two gaps never stack up,
    # and the text under a heading starts right below it.
    if [[ -z "$trimmed" ]]; then
      $after_head || blank=true
      continue
    fi
    if $blank && [[ ! "$line" =~ $RENDER_HEAD_RE ]]; then
      printf '\n'
    fi
    blank=false
    after_head=false

    if [[ "$line" =~ $RENDER_HEAD_RE ]]; then
      after_head=true
      if (( ${#BASH_REMATCH[1]} <= 2 )); then
        viz_section "${BASH_REMATCH[2]//\*\*/}"          # # and ## : ruled heading
      else
        printf '\n%s%s%s%s\n' "$VIZ_BOLD" "$VIZ_CYAN" \
          "${BASH_REMATCH[2]//\*\*/}" "$VIZ_RESET"       # ### : coloured title
      fi
    elif [[ "$line" =~ $RENDER_BULLET_RE ]]; then
      printf '%s  %s%s%s %s\n' "${BASH_REMATCH[1]}" "$VIZ_CYAN" "$RENDER_DOT" "$VIZ_RESET" \
        "$(render_inline "${BASH_REMATCH[2]}")"
    elif [[ "$line" =~ $RENDER_NUMBER_RE ]]; then
      printf '%s  %s%s.%s %s\n' "${BASH_REMATCH[1]}" "$VIZ_CYAN" "${BASH_REMATCH[2]}" \
        "$VIZ_RESET" "$(render_inline "${BASH_REMATCH[3]}")"
    elif [[ "$trimmed" == '>'* ]]; then
      trimmed="${trimmed#>}"
      printf '  %s%s%s %s\n' "$VIZ_DIM" "$VIZ_V" "$VIZ_RESET" "$(render_inline "${trimmed# }")"
    elif [[ "$trimmed" =~ $RENDER_RULE_RE ]]; then
      printf '%s%s%s\n' "$VIZ_DIM" "$(viz_repeat "$VIZ_H" "$(viz_width)")" "$VIZ_RESET"
    else
      printf '%s\n' "$(render_inline "$line")"
    fi
  done
  render_flush_table
}
